# Processing Outbox

## Overview

Processing outbox patterns are crucial for maintaining data consistency and reliability in distributed systems. This document explores various approaches to process database rows concurrently while ensuring correctness and preventing conflicts.

## Key Considerations

When designing outbox processing strategies, we must consider:

- **Ordered vs unordered processing**: Whether message order matters
- **Single-worker vs multi-worker**: Scaling and concurrency trade-offs
- **Delivery guarantees**: At-least-once vs at-most-once semantics
- **Stream vs batch processing**: Processing granularity and performance
- **Idempotency**: Handling duplicate processing safely
- **Error handling**: Retry strategies and failure recovery
- **Monitoring**: Observability and alerting

## Ordered vs Unordered Processing

### Ordered Processing

Ordered processing ensures messages are processed in First-In-First-Out (FIFO) order. This is critical for:
- Financial transactions where order matters
- State machines with sequential dependencies
- Audit logs requiring chronological order

**Implementation Strategy:**
```sql
-- Database schema for ordered processing
CREATE TABLE outbox_events (
    id BIGSERIAL PRIMARY KEY,
    aggregate_id UUID NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    status VARCHAR(20) DEFAULT 'pending',
    retry_count INTEGER DEFAULT 0,
    INDEX idx_outbox_processing (status, id) WHERE status = 'pending'
);
```

**Go Implementation:**
```go
type OrderedProcessor struct {
    db     *sql.DB
    logger *slog.Logger
}

func (p *OrderedProcessor) ProcessNext(ctx context.Context) error {
    tx, err := p.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()

    // Select and lock the next event for processing
    var event OutboxEvent
    query := `
        SELECT id, aggregate_id, event_type, payload, retry_count
        FROM outbox_events 
        WHERE status = 'pending'
        ORDER BY id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    `
    
    err = tx.QueryRowContext(ctx, query).Scan(
        &event.ID, &event.AggregateID, &event.EventType, 
        &event.Payload, &event.RetryCount,
    )
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return nil // No events to process
        }
        return fmt.Errorf("select event: %w", err)
    }

    // Process the event
    if err := p.handleEvent(ctx, &event); err != nil {
        return p.handleProcessingError(ctx, tx, &event, err)
    }

    // Mark as processed and delete
    _, err = tx.ExecContext(ctx, 
        "DELETE FROM outbox_events WHERE id = $1", event.ID)
    if err != nil {
        return fmt.Errorf("delete processed event: %w", err)
    }

    return tx.Commit()
}
```

### Unordered Processing

Unordered processing allows concurrent processing of multiple events, improving throughput when order doesn't matter.

**Go Implementation:**
```go
type UnorderedProcessor struct {
    db          *sql.DB
    concurrency int
    logger      *slog.Logger
}

func (p *UnorderedProcessor) ProcessBatch(ctx context.Context) error {
    sem := make(chan struct{}, p.concurrency)
    var wg sync.WaitGroup
    
    events, err := p.fetchBatch(ctx, p.concurrency * 2)
    if err != nil {
        return err
    }

    for _, event := range events {
        select {
        case sem <- struct{}{}:
            wg.Add(1)
            go func(e OutboxEvent) {
                defer func() { <-sem; wg.Done() }()
                p.processEvent(ctx, e)
            }(event)
        case <-ctx.Done():
            break
        }
    }
    
    wg.Wait()
    return nil
}

func (p *UnorderedProcessor) fetchBatch(ctx context.Context, limit int) ([]OutboxEvent, error) {
    query := `
        SELECT id, aggregate_id, event_type, payload, retry_count
        FROM outbox_events 
        WHERE status = 'pending'
        ORDER BY id
        LIMIT $1
        FOR UPDATE SKIP LOCKED
    `
    
    rows, err := p.db.QueryContext(ctx, query, limit)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var events []OutboxEvent
    for rows.Next() {
        var event OutboxEvent
        err := rows.Scan(&event.ID, &event.AggregateID, 
                        &event.EventType, &event.Payload, &event.RetryCount)
        if err != nil {
            return nil, err
        }
        events = append(events, event)
    }
    
    return events, rows.Err()
}
```

## Single Worker vs Multi-Worker

### Single Worker

Use single worker when:
- Message order is critical
- Processing logic has global state dependencies
- Simplicity is preferred over throughput

**Advantages:**
- Guaranteed processing order
- No coordination overhead
- Simpler error handling and monitoring

**Disadvantages:**
- Limited throughput
- Single point of failure
- Cannot utilize multi-core systems effectively

### Multi-Worker with Partitioning

To scale processing while maintaining some ordering guarantees, partition work by aggregate ID or other business keys:

```go
type PartitionedProcessor struct {
    db       *sql.DB
    workers  int
    workerID int
}

func (p *PartitionedProcessor) ProcessPartition(ctx context.Context) error {
    query := `
        SELECT id, aggregate_id, event_type, payload
        FROM outbox_events 
        WHERE status = 'pending' 
        AND MOD(EXTRACT(epoch FROM created_at)::bigint, $1) = $2
        ORDER BY id
        LIMIT 10
        FOR UPDATE SKIP LOCKED
    `
    
    rows, err := p.db.QueryContext(ctx, query, p.workers, p.workerID)
    if err != nil {
        return err
    }
    defer rows.Close()

    for rows.Next() {
        var event OutboxEvent
        if err := rows.Scan(&event.ID, &event.AggregateID, 
                          &event.EventType, &event.Payload); err != nil {
            return err
        }
        
        if err := p.processEvent(ctx, &event); err != nil {
            p.logger.Error("processing failed", 
                          "event_id", event.ID, "error", err)
            continue
        }
    }
    
    return rows.Err()
}
```

### Load Balancing Strategy

Prevent slow workers from affecting overall throughput:

```go
type LoadBalancedProcessor struct {
    db      *sql.DB
    workers []*Worker
    workCh  chan OutboxEvent
}

func (p *LoadBalancedProcessor) Start(ctx context.Context) error {
    // Start workers
    for _, worker := range p.workers {
        go worker.Run(ctx, p.workCh)
    }
    
    // Start event fetcher
    go p.fetchEvents(ctx)
    
    <-ctx.Done()
    return ctx.Err()
}

func (p *LoadBalancedProcessor) fetchEvents(ctx context.Context) {
    ticker := time.NewTicker(100 * time.Millisecond)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            events, err := p.fetchBatch(ctx, 50)
            if err != nil {
                p.logger.Error("fetch batch failed", "error", err)
                continue
            }
            
            for _, event := range events {
                select {
                case p.workCh <- event:
                case <-ctx.Done():
                    return
                }
            }
        case <-ctx.Done():
            return
        }
    }
}
```


## Delivery Guarantees

### At-Least-Once Processing

In distributed systems, we cannot guarantee exactly-once delivery due to potential failures between processing and marking as complete. At-least-once processing is more realistic and achievable.

**Implementation Considerations:**
- Always mark events as processed after successful external calls
- Use idempotent operations where possible
- Implement proper retry logic with exponential backoff
- Monitor duplicate processing rates

```go
type DeliveryGuarantee struct {
    maxRetries int
    backoff    time.Duration
}

func (d *DeliveryGuarantee) ProcessWithRetry(ctx context.Context, event *OutboxEvent) error {
    var lastErr error
    
    for attempt := 0; attempt <= d.maxRetries; attempt++ {
        if attempt > 0 {
            select {
            case <-time.After(d.backoff * time.Duration(1<<attempt)):
            case <-ctx.Done():
                return ctx.Err()
            }
        }
        
        err := d.processEvent(ctx, event)
        if err == nil {
            return nil // Success
        }
        
        lastErr = err
        if !d.isRetryable(err) {
            break // Non-retryable error
        }
        
        d.logger.Warn("retrying event processing", 
                     "attempt", attempt+1, "error", err)
    }
    
    return fmt.Errorf("max retries exceeded: %w", lastErr)
}

func (d *DeliveryGuarantee) isRetryable(err error) bool {
    // Network errors, timeouts, and temporary failures are retryable
    var netErr net.Error
    if errors.As(err, &netErr) && netErr.Temporary() {
        return true
    }
    
    // HTTP 5xx errors are typically retryable
    var httpErr *HTTPError
    if errors.As(err, &httpErr) && httpErr.StatusCode >= 500 {
        return true
    }
    
    return false
}
```

### Idempotency Handling

Ensure operations can be safely retried:

```go
type IdempotentProcessor struct {
    cache map[string]bool // In production, use Redis or similar
    mutex sync.RWMutex
}

func (p *IdempotentProcessor) ProcessIdempotent(ctx context.Context, event *OutboxEvent) error {
    key := fmt.Sprintf("event:%d:%s", event.ID, event.EventType)
    
    p.mutex.RLock()
    processed, exists := p.cache[key]
    p.mutex.RUnlock()
    
    if exists && processed {
        return nil // Already processed
    }
    
    // Process the event
    if err := p.handleEvent(ctx, event); err != nil {
        return err
    }
    
    // Mark as processed
    p.mutex.Lock()
    p.cache[key] = true
    p.mutex.Unlock()
    
    return nil
}
```


## Stream vs Batch Processing

### Stream Processing

Process events one by one as they arrive. Good for:
- Low latency requirements
- Simple processing logic
- Real-time systems

```go
type StreamProcessor struct {
    db       *sql.DB
    interval time.Duration
}

func (p *StreamProcessor) Run(ctx context.Context) error {
    ticker := time.NewTicker(p.interval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            if err := p.processNext(ctx); err != nil {
                p.logger.Error("stream processing failed", "error", err)
            }
        case <-ctx.Done():
            return ctx.Err()
        }
    }
}

func (p *StreamProcessor) processNext(ctx context.Context) error {
    tx, err := p.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    var event OutboxEvent
    query := `
        SELECT id, event_type, payload 
        FROM outbox_events 
        WHERE status = 'pending'
        ORDER BY id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    `
    
    err = tx.QueryRowContext(ctx, query).Scan(
        &event.ID, &event.EventType, &event.Payload)
    if errors.Is(err, sql.ErrNoRows) {
        return nil // No events to process
    }
    if err != nil {
        return err
    }
    
    // Process event
    if err := p.handleEvent(ctx, &event); err != nil {
        return err
    }
    
    // Mark as processed
    _, err = tx.ExecContext(ctx, 
        "UPDATE outbox_events SET status = 'processed', processed_at = NOW() WHERE id = $1", 
        event.ID)
    if err != nil {
        return err
    }
    
    return tx.Commit()
}
```

### Batch Processing

Process multiple events together for better throughput:

```go
type BatchProcessor struct {
    db        *sql.DB
    batchSize int
    timeout   time.Duration
}

func (p *BatchProcessor) ProcessBatch(ctx context.Context) error {
    batch, err := p.fetchBatch(ctx)
    if err != nil {
        return err
    }
    if len(batch) == 0 {
        return nil
    }
    
    // Process all events in the batch
    results := make([]ProcessResult, len(batch))
    var wg sync.WaitGroup
    
    for i, event := range batch {
        wg.Add(1)
        go func(idx int, e OutboxEvent) {
            defer wg.Done()
            results[idx] = ProcessResult{
                EventID: e.ID,
                Error:   p.handleEvent(ctx, &e),
            }
        }(i, event)
    }
    
    wg.Wait()
    
    // Update batch status
    return p.updateBatchStatus(ctx, results)
}

func (p *BatchProcessor) updateBatchStatus(ctx context.Context, results []ProcessResult) error {
    tx, err := p.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    successIDs := make([]int64, 0)
    failedUpdates := make([]FailedEvent, 0)
    
    for _, result := range results {
        if result.Error == nil {
            successIDs = append(successIDs, result.EventID)
        } else {
            failedUpdates = append(failedUpdates, FailedEvent{
                ID:    result.EventID,
                Error: result.Error.Error(),
            })
        }
    }
    
    // Mark successful events as processed
    if len(successIDs) > 0 {
        query := `
            UPDATE outbox_events 
            SET status = 'processed', processed_at = NOW() 
            WHERE id = ANY($1)
        `
        _, err = tx.ExecContext(ctx, query, pq.Array(successIDs))
        if err != nil {
            return err
        }
    }
    
    // Update failed events with error details
    for _, failed := range failedUpdates {
        _, err = tx.ExecContext(ctx, `
            UPDATE outbox_events 
            SET retry_count = retry_count + 1, 
                last_error = $2,
                status = CASE WHEN retry_count >= 5 THEN 'failed' ELSE 'pending' END
            WHERE id = $1
        `, failed.ID, failed.Error)
        if err != nil {
            return err
        }
    }
    
    return tx.Commit()
}

type ProcessResult struct {
    EventID int64
    Error   error
}

type FailedEvent struct {
    ID    int64
    Error string
}
```

## Polling Strategies

### Simple Polling

Basic polling approach with configurable intervals:

```go
type SimplePoller struct {
    processor Processor
    interval  time.Duration
    logger    *slog.Logger
}

func (p *SimplePoller) Run(ctx context.Context) error {
    ticker := time.NewTicker(p.interval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            start := time.Now()
            processed, err := p.processor.ProcessBatch(ctx)
            duration := time.Since(start)
            
            if err != nil {
                p.logger.Error("polling failed", 
                              "error", err, "duration", duration)
            } else {
                p.logger.Info("polling completed", 
                              "processed", processed, "duration", duration)
            }
            
        case <-ctx.Done():
            return ctx.Err()
        }
    }
}
```

### Adaptive Polling

Adjust polling frequency based on workload:

```go
type AdaptivePoller struct {
    processor   Processor
    minInterval time.Duration
    maxInterval time.Duration
    current     time.Duration
}

func (p *AdaptivePoller) Run(ctx context.Context) error {
    p.current = p.minInterval
    
    for {
        select {
        case <-time.After(p.current):
            processed, err := p.processor.ProcessBatch(ctx)
            if err != nil {
                p.logger.Error("adaptive polling failed", "error", err)
                p.current = p.maxInterval // Back off on error
                continue
            }
            
            // Adjust polling frequency based on load
            if processed > 0 {
                // More work available, poll faster
                p.current = max(p.minInterval, p.current/2)
            } else {
                // No work, poll slower
                p.current = min(p.maxInterval, p.current*2)
            }
            
        case <-ctx.Done():
            return ctx.Err()
        }
    }
}
```

### Concurrent Processing with Semaphore

Control concurrency while ensuring graceful shutdown:

```go
type ConcurrentProcessor struct {
    db          *sql.DB
    maxWorkers  int
    semaphore   chan struct{}
    workerCount atomic.Int32
}

func NewConcurrentProcessor(db *sql.DB, maxWorkers int) *ConcurrentProcessor {
    return &ConcurrentProcessor{
        db:         db,
        maxWorkers: maxWorkers,
        semaphore:  make(chan struct{}, maxWorkers),
    }
}

func (p *ConcurrentProcessor) Run(ctx context.Context) error {
    ctx, cancel := context.WithCancel(ctx)
    defer cancel()
    
    var wg sync.WaitGroup
    
    // Start workers
    for i := 0; i < p.maxWorkers; i++ {
        wg.Add(1)
        go func(workerID int) {
            defer wg.Done()
            p.worker(ctx, workerID)
        }(i)
    }
    
    // Wait for all workers to complete
    wg.Wait()
    return nil
}

func (p *ConcurrentProcessor) worker(ctx context.Context, workerID int) {
    p.workerCount.Add(1)
    defer p.workerCount.Add(-1)
    
    ticker := time.NewTicker(100 * time.Millisecond)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            if err := p.processNext(ctx, workerID); err != nil {
                if errors.Is(err, sql.ErrNoRows) {
                    continue // No work available
                }
                p.logger.Error("worker failed", 
                              "worker_id", workerID, "error", err)
            }
            
        case <-ctx.Done():
            p.logger.Info("worker shutting down", "worker_id", workerID)
            return
        }
    }
}

func (p *ConcurrentProcessor) processNext(ctx context.Context, workerID int) error {
    // Acquire semaphore
    select {
    case p.semaphore <- struct{}{}:
        defer func() { <-p.semaphore }()
    case <-ctx.Done():
        return ctx.Err()
    }
    
    tx, err := p.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    var event OutboxEvent
    err = tx.QueryRowContext(ctx, `
        SELECT id, event_type, payload
        FROM outbox_events 
        WHERE status = 'pending'
        ORDER BY id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    `).Scan(&event.ID, &event.EventType, &event.Payload)
    
    if errors.Is(err, sql.ErrNoRows) {
        return sql.ErrNoRows
    }
    if err != nil {
        return err
    }
    
    // Process event
    if err := p.handleEvent(ctx, &event); err != nil {
        return err
    }
    
    // Mark as processed
    _, err = tx.ExecContext(ctx, 
        "DELETE FROM outbox_events WHERE id = $1", event.ID)
    if err != nil {
        return err
    }
    
    return tx.Commit()
}
```

## Monitoring and Observability

### Key Metrics

Monitor the following metrics for outbox processing:

```go
type OutboxMetrics struct {
    EventsProcessed      prometheus.Counter
    EventsFailedTotal    prometheus.Counter
    EventsRetried        prometheus.Counter
    ProcessingDuration   prometheus.Histogram
    QueueDepth          prometheus.Gauge
    WorkerCount         prometheus.Gauge
    ErrorsByType        *prometheus.CounterVec
}

func NewOutboxMetrics() *OutboxMetrics {
    return &OutboxMetrics{
        EventsProcessed: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "outbox_events_processed_total",
            Help: "Total number of events processed",
        }),
        EventsFailedTotal: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "outbox_events_failed_total", 
            Help: "Total number of events that failed processing",
        }),
        ProcessingDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
            Name:    "outbox_processing_duration_seconds",
            Help:    "Time spent processing events",
            Buckets: prometheus.DefBuckets,
        }),
        QueueDepth: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "outbox_queue_depth",
            Help: "Number of pending events in the outbox",
        }),
        ErrorsByType: prometheus.NewCounterVec(prometheus.CounterOpts{
            Name: "outbox_errors_by_type_total",
            Help: "Errors by type",
        }, []string{"error_type"}),
    }
}
```

### Health Checks

Implement health checks for outbox processing:

```go
type OutboxHealth struct {
    db             *sql.DB
    maxPendingAge  time.Duration
    maxQueueDepth  int
}

func (h *OutboxHealth) Check(ctx context.Context) error {
    // Check database connectivity
    if err := h.db.PingContext(ctx); err != nil {
        return fmt.Errorf("database unhealthy: %w", err)
    }
    
    // Check queue depth
    var queueDepth int
    err := h.db.QueryRowContext(ctx, 
        "SELECT COUNT(*) FROM outbox_events WHERE status = 'pending'").Scan(&queueDepth)
    if err != nil {
        return fmt.Errorf("failed to check queue depth: %w", err)
    }
    
    if queueDepth > h.maxQueueDepth {
        return fmt.Errorf("queue depth too high: %d > %d", queueDepth, h.maxQueueDepth)
    }
    
    // Check for stuck events
    var oldestAge time.Duration
    err = h.db.QueryRowContext(ctx, `
        SELECT COALESCE(EXTRACT(epoch FROM NOW() - MIN(created_at)), 0)
        FROM outbox_events 
        WHERE status = 'pending'
    `).Scan(&oldestAge)
    if err != nil {
        return fmt.Errorf("failed to check oldest pending event: %w", err)
    }
    
    if oldestAge > h.maxPendingAge.Seconds() {
        return fmt.Errorf("events stuck too long: %v > %v", 
                         time.Duration(oldestAge)*time.Second, h.maxPendingAge)
    }
    
    return nil
}
```

## Best Practices

### 1. Schema Design
- Use appropriate indexes for query patterns
- Include created_at for monitoring and cleanup
- Add retry_count and last_error for debugging
- Consider partitioning for high-volume tables

### 2. Error Handling
- Implement exponential backoff for retries
- Distinguish between retryable and non-retryable errors
- Log errors with sufficient context for debugging
- Set maximum retry limits to prevent infinite loops

### 3. Performance Optimization
- Use `FOR UPDATE SKIP LOCKED` for concurrent processing
- Batch operations when possible
- Monitor query performance and optimize indexes
- Consider read replicas for metrics queries

### 4. Operational Considerations
- Implement proper monitoring and alerting
- Plan for graceful shutdown of workers
- Regular cleanup of processed events
- Load testing under realistic conditions

### 5. Testing Strategy
```go
func TestOutboxProcessing(t *testing.T) {
    tests := []struct {
        name           string
        events         []OutboxEvent
        processingFunc func(OutboxEvent) error
        expectedStatus []string
    }{
        {
            name: "successful processing",
            events: []OutboxEvent{
                {ID: 1, EventType: "user.created", Payload: `{"id": 1}`},
            },
            processingFunc: func(e OutboxEvent) error { return nil },
            expectedStatus: []string{"processed"},
        },
        {
            name: "failed processing with retry",
            events: []OutboxEvent{
                {ID: 2, EventType: "user.updated", Payload: `{"id": 2}`},
            },
            processingFunc: func(e OutboxEvent) error { 
                return errors.New("temporary error") 
            },
            expectedStatus: []string{"pending"},
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Setup test database and processor
            // Run test scenarios
            // Verify expected outcomes
        })
    }
}
```

Working example:
```go
// Complete example with proper error handling and monitoring
package main

import (
    "context"
    "database/sql"
    "encoding/json"
    "errors"
    "fmt"
    "log/slog"
    "sync"
    "sync/atomic"
    "time"

    _ "github.com/lib/pq"
)

type OutboxEvent struct {
    ID          int64           `json:"id"`
    AggregateID string          `json:"aggregate_id"`
    EventType   string          `json:"event_type"`
    Payload     json.RawMessage `json:"payload"`
    CreatedAt   time.Time       `json:"created_at"`
    RetryCount  int             `json:"retry_count"`
}

type OutboxProcessor struct {
    db            *sql.DB
    maxWorkers    int
    pollInterval  time.Duration
    maxRetries    int
    logger        *slog.Logger
    metrics       *OutboxMetrics
    shutdown      chan struct{}
    activeWorkers atomic.Int32
}

func NewOutboxProcessor(db *sql.DB, opts ProcessorOptions) *OutboxProcessor {
    return &OutboxProcessor{
        db:           db,
        maxWorkers:   opts.MaxWorkers,
        pollInterval: opts.PollInterval,
        maxRetries:   opts.MaxRetries,
        logger:       opts.Logger,
        metrics:      NewOutboxMetrics(),
        shutdown:     make(chan struct{}),
    }
}

func (p *OutboxProcessor) Start(ctx context.Context) error {
    var wg sync.WaitGroup
    
    // Start workers
    for i := 0; i < p.maxWorkers; i++ {
        wg.Add(1)
        go func(workerID int) {
            defer wg.Done()
            p.worker(ctx, workerID)
        }(i)
    }
    
    // Start metrics updater
    go p.updateMetrics(ctx)
    
    // Wait for shutdown
    <-ctx.Done()
    close(p.shutdown)
    wg.Wait()
    
    return nil
}

func (p *OutboxProcessor) worker(ctx context.Context, workerID int) {
    p.activeWorkers.Add(1)
    defer p.activeWorkers.Add(-1)
    
    ticker := time.NewTicker(p.pollInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            if err := p.processNext(ctx); err != nil {
                if !errors.Is(err, sql.ErrNoRows) {
                    p.logger.Error("worker processing failed", 
                                  "worker_id", workerID, "error", err)
                }
            }
        case <-p.shutdown:
            return
        case <-ctx.Done():
            return
        }
    }
}

func (p *OutboxProcessor) processNext(ctx context.Context) error {
    start := time.Now()
    defer func() {
        p.metrics.ProcessingDuration.Observe(time.Since(start).Seconds())
    }()
    
    tx, err := p.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    var event OutboxEvent
    err = tx.QueryRowContext(ctx, `
        SELECT id, aggregate_id, event_type, payload, created_at, retry_count
        FROM outbox_events 
        WHERE status = 'pending' AND retry_count < $1
        ORDER BY id
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    `, p.maxRetries).Scan(
        &event.ID, &event.AggregateID, &event.EventType, 
        &event.Payload, &event.CreatedAt, &event.RetryCount,
    )
    
    if errors.Is(err, sql.ErrNoRows) {
        return sql.ErrNoRows
    }
    if err != nil {
        return err
    }
    
    // Process the event
    if err := p.handleEvent(ctx, &event); err != nil {
        return p.handleProcessingError(ctx, tx, &event, err)
    }
    
    // Mark as processed
    _, err = tx.ExecContext(ctx, 
        "DELETE FROM outbox_events WHERE id = $1", event.ID)
    if err != nil {
        return err
    }
    
    p.metrics.EventsProcessed.Inc()
    return tx.Commit()
}

func (p *OutboxProcessor) handleEvent(ctx context.Context, event *OutboxEvent) error {
    // Implement your event handling logic here
    // This is where you'd send to message queues, call APIs, etc.
    p.logger.Info("processing event", 
                  "event_id", event.ID, "type", event.EventType)
    
    // Simulate processing time
    time.Sleep(10 * time.Millisecond)
    
    return nil
}

func (p *OutboxProcessor) handleProcessingError(ctx context.Context, tx *sql.Tx, event *OutboxEvent, err error) error {
    p.metrics.EventsFailedTotal.Inc()
    p.metrics.ErrorsByType.WithLabelValues(fmt.Sprintf("%T", err)).Inc()
    
    retryCount := event.RetryCount + 1
    status := "pending"
    
    if retryCount >= p.maxRetries {
        status = "failed"
        p.logger.Error("event failed permanently", 
                      "event_id", event.ID, "retries", retryCount, "error", err)
    } else {
        p.metrics.EventsRetried.Inc()
        p.logger.Warn("event retry scheduled", 
                     "event_id", event.ID, "retry", retryCount, "error", err)
    }
    
    _, updateErr := tx.ExecContext(ctx, `
        UPDATE outbox_events 
        SET retry_count = $1, last_error = $2, status = $3
        WHERE id = $4
    `, retryCount, err.Error(), status, event.ID)
    
    if updateErr != nil {
        return updateErr
    }
    
    return tx.Commit()
}

func (p *OutboxProcessor) updateMetrics(ctx context.Context) {
    ticker := time.NewTicker(10 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            var queueDepth int
            err := p.db.QueryRowContext(ctx, 
                "SELECT COUNT(*) FROM outbox_events WHERE status = 'pending'").Scan(&queueDepth)
            if err == nil {
                p.metrics.QueueDepth.Set(float64(queueDepth))
            }
            
            p.metrics.WorkerCount.Set(float64(p.activeWorkers.Load()))
            
        case <-ctx.Done():
            return
        }
    }
}

type ProcessorOptions struct {
    MaxWorkers   int
    PollInterval time.Duration
    MaxRetries   int
    Logger       *slog.Logger
}

func main() {
    // Example usage
    db, err := sql.Open("postgres", "postgres://user:pass@localhost/db?sslmode=disable")
    if err != nil {
        panic(err)
    }
    defer db.Close()
    
    processor := NewOutboxProcessor(db, ProcessorOptions{
        MaxWorkers:   5,
        PollInterval: 100 * time.Millisecond,
        MaxRetries:   3,
        Logger:       slog.Default(),
    })
    
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    
    if err := processor.Start(ctx); err != nil {
        panic(err)
    }
}
```
