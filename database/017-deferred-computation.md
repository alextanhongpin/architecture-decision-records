# Deferred Computation

## Status

`accepted`

## Context

Modern applications often need to perform expensive computations or external API calls that cannot be executed synchronously during user requests. Examples include sentiment analysis, image processing, data enrichment, recommendation generation, and analytics calculations. These operations need to be deferred and processed asynchronously while maintaining data consistency and tracking computation state.

The challenge is designing a system that can track when data changes require recomputation, manage computation state, handle failures gracefully, and provide mechanisms for both scheduled and on-demand processing.

## Decision

Implement a deferred computation pattern using tracking columns, processing queues, and background workers to handle expensive operations asynchronously while maintaining data integrity and providing visibility into computation status.

## Architecture

### Core Components

1. **State Tracking Columns**: Track modification and processing timestamps
2. **Processing Queue**: Queue items that need computation
3. **Background Workers**: Process queued items
4. **Status Management**: Track computation state and results
5. **Retry Logic**: Handle failures and retries
6. **Monitoring**: Track processing metrics and health

### Schema Design

```sql
-- Main table with deferred computation tracking
CREATE TABLE articles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    
    -- Computation tracking columns
    content_modified_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sentiment_processed_at TIMESTAMPTZ,
    sentiment_score DECIMAL(3,2),
    sentiment_status VARCHAR(50) DEFAULT 'pending',
    
    -- Metadata
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Processing queue table
CREATE TABLE computation_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name VARCHAR(100) NOT NULL,
    record_id UUID NOT NULL,
    computation_type VARCHAR(100) NOT NULL,
    priority INTEGER NOT NULL DEFAULT 0,
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,
    scheduled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    failed_at TIMESTAMPTZ,
    error_message TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(table_name, record_id, computation_type)
);

-- Computation results history
CREATE TABLE computation_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    table_name VARCHAR(100) NOT NULL,
    record_id UUID NOT NULL,
    computation_type VARCHAR(100) NOT NULL,
    input_hash VARCHAR(64), -- Hash of input data
    result JSONB,
    processing_time_ms INTEGER,
    worker_id VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX idx_computation_queue_status_scheduled 
ON computation_queue(status, scheduled_at) 
WHERE status IN ('pending', 'retrying');

CREATE INDEX idx_computation_queue_table_record 
ON computation_queue(table_name, record_id);

CREATE INDEX idx_articles_content_modified 
ON articles(content_modified_at) 
WHERE sentiment_processed_at IS NULL OR content_modified_at > sentiment_processed_at;
```

### Triggers for Automatic Queue Management

```sql
-- Function to queue computation when content changes
CREATE OR REPLACE FUNCTION queue_deferred_computation()
RETURNS TRIGGER AS $$
BEGIN
    -- Update modification timestamp
    NEW.content_modified_at = NOW();
    
    -- Queue sentiment analysis if content changed
    IF OLD.content IS DISTINCT FROM NEW.content THEN
        INSERT INTO computation_queue (
            table_name, 
            record_id, 
            computation_type,
            metadata
        ) VALUES (
            TG_TABLE_NAME,
            NEW.id,
            'sentiment_analysis',
            jsonb_build_object(
                'old_content_hash', md5(COALESCE(OLD.content, '')),
                'new_content_hash', md5(NEW.content)
            )
        ) ON CONFLICT (table_name, record_id, computation_type) 
        DO UPDATE SET
            scheduled_at = NOW(),
            status = 'pending',
            attempts = 0,
            failed_at = NULL,
            error_message = NULL,
            metadata = EXCLUDED.metadata;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to articles table
CREATE TRIGGER trigger_queue_sentiment_analysis
    BEFORE UPDATE ON articles
    FOR EACH ROW
    EXECUTE FUNCTION queue_deferred_computation();
```

## Implementation

### Go Background Worker

```go
package computation

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "log"
    "time"
    
    "github.com/lib/pq"
)

type ComputationWorker struct {
    db       *sql.DB
    workerID string
    handlers map[string]ComputationHandler
}

type ComputationHandler interface {
    Process(ctx context.Context, recordID string, metadata map[string]interface{}) (interface{}, error)
}

type QueueItem struct {
    ID              string                 `json:"id"`
    TableName       string                 `json:"table_name"`
    RecordID        string                 `json:"record_id"`
    ComputationType string                 `json:"computation_type"`
    Priority        int                    `json:"priority"`
    Attempts        int                    `json:"attempts"`
    MaxAttempts     int                    `json:"max_attempts"`
    Metadata        map[string]interface{} `json:"metadata"`
    ScheduledAt     time.Time              `json:"scheduled_at"`
}

func NewComputationWorker(db *sql.DB, workerID string) *ComputationWorker {
    return &ComputationWorker{
        db:       db,
        workerID: workerID,
        handlers: make(map[string]ComputationHandler),
    }
}

func (w *ComputationWorker) RegisterHandler(computationType string, handler ComputationHandler) {
    w.handlers[computationType] = handler
}

func (w *ComputationWorker) Start(ctx context.Context) error {
    ticker := time.NewTicker(5 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-ticker.C:
            if err := w.processNextItem(ctx); err != nil {
                log.Printf("Error processing item: %v", err)
            }
        }
    }
}

func (w *ComputationWorker) processNextItem(ctx context.Context) error {
    tx, err := w.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Get next item with row locking
    var item QueueItem
    var metadataJSON []byte
    
    query := `
        SELECT id, table_name, record_id, computation_type, priority, 
               attempts, max_attempts, metadata, scheduled_at
        FROM computation_queue 
        WHERE status = 'pending' 
        AND scheduled_at <= NOW()
        ORDER BY priority DESC, scheduled_at ASC
        LIMIT 1
        FOR UPDATE SKIP LOCKED`
    
    err = tx.QueryRowContext(ctx, query).Scan(
        &item.ID, &item.TableName, &item.RecordID, &item.ComputationType,
        &item.Priority, &item.Attempts, &item.MaxAttempts, &metadataJSON,
        &item.ScheduledAt,
    )
    
    if err == sql.ErrNoRows {
        return nil // No items to process
    }
    if err != nil {
        return fmt.Errorf("fetch queue item: %w", err)
    }
    
    json.Unmarshal(metadataJSON, &item.Metadata)
    
    // Mark as processing
    _, err = tx.ExecContext(ctx, `
        UPDATE computation_queue 
        SET status = 'processing', started_at = NOW()
        WHERE id = $1`, item.ID)
    if err != nil {
        return fmt.Errorf("mark as processing: %w", err)
    }
    
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("commit transaction: %w", err)
    }
    
    // Process the item
    return w.processItem(ctx, item)
}

func (w *ComputationWorker) processItem(ctx context.Context, item QueueItem) error {
    handler, exists := w.handlers[item.ComputationType]
    if !exists {
        return w.markFailed(ctx, item.ID, fmt.Sprintf("no handler for type: %s", item.ComputationType))
    }
    
    startTime := time.Now()
    
    result, err := handler.Process(ctx, item.RecordID, item.Metadata)
    if err != nil {
        return w.handleProcessingError(ctx, item, err)
    }
    
    processingTime := time.Since(startTime)
    
    return w.markCompleted(ctx, item.ID, item.TableName, item.RecordID, 
        item.ComputationType, result, processingTime)
}

func (w *ComputationWorker) markCompleted(ctx context.Context, queueID, tableName, 
    recordID, computationType string, result interface{}, processingTime time.Duration) error {
    
    tx, err := w.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    resultJSON, _ := json.Marshal(result)
    
    // Record in history
    _, err = tx.ExecContext(ctx, `
        INSERT INTO computation_history 
        (table_name, record_id, computation_type, result, processing_time_ms, worker_id)
        VALUES ($1, $2, $3, $4, $5, $6)`,
        tableName, recordID, computationType, resultJSON, 
        processingTime.Milliseconds(), w.workerID)
    if err != nil {
        return fmt.Errorf("insert history: %w", err)
    }
    
    // Update main table based on computation type
    if err := w.updateMainTable(ctx, tx, tableName, recordID, computationType, result); err != nil {
        return fmt.Errorf("update main table: %w", err)
    }
    
    // Remove from queue
    _, err = tx.ExecContext(ctx, `
        UPDATE computation_queue 
        SET status = 'completed', completed_at = NOW()
        WHERE id = $1`, queueID)
    if err != nil {
        return fmt.Errorf("mark completed: %w", err)
    }
    
    return tx.Commit()
}

func (w *ComputationWorker) updateMainTable(ctx context.Context, tx *sql.Tx, 
    tableName, recordID, computationType string, result interface{}) error {
    
    switch computationType {
    case "sentiment_analysis":
        if sentiment, ok := result.(map[string]interface{}); ok {
            _, err := tx.ExecContext(ctx, `
                UPDATE articles 
                SET sentiment_score = $1, 
                    sentiment_processed_at = NOW(),
                    sentiment_status = 'completed'
                WHERE id = $2`,
                sentiment["score"], recordID)
            return err
        }
    }
    
    return fmt.Errorf("unknown computation type: %s", computationType)
}

func (w *ComputationWorker) handleProcessingError(ctx context.Context, item QueueItem, processingErr error) error {
    item.Attempts++
    
    if item.Attempts >= item.MaxAttempts {
        return w.markFailed(ctx, item.ID, processingErr.Error())
    }
    
    // Exponential backoff
    delay := time.Duration(item.Attempts*item.Attempts) * time.Minute
    scheduledAt := time.Now().Add(delay)
    
    _, err := w.db.ExecContext(ctx, `
        UPDATE computation_queue 
        SET status = 'retrying', 
            attempts = $1,
            scheduled_at = $2,
            error_message = $3
        WHERE id = $4`,
        item.Attempts, scheduledAt, processingErr.Error(), item.ID)
    
    return err
}

func (w *ComputationWorker) markFailed(ctx context.Context, queueID, errorMsg string) error {
    _, err := w.db.ExecContext(ctx, `
        UPDATE computation_queue 
        SET status = 'failed', 
            failed_at = NOW(),
            error_message = $1
        WHERE id = $2`,
        errorMsg, queueID)
    
    return err
}
```

### Sentiment Analysis Handler

```go
package handlers

import (
    "context"
    "database/sql"
    "fmt"
    "math/rand"
    "time"
)

type SentimentAnalysisHandler struct {
    db *sql.DB
}

func NewSentimentAnalysisHandler(db *sql.DB) *SentimentAnalysisHandler {
    return &SentimentAnalysisHandler{db: db}
}

func (h *SentimentAnalysisHandler) Process(ctx context.Context, recordID string, 
    metadata map[string]interface{}) (interface{}, error) {
    
    // Fetch article content
    var content string
    err := h.db.QueryRowContext(ctx, 
        "SELECT content FROM articles WHERE id = $1", recordID).Scan(&content)
    if err != nil {
        return nil, fmt.Errorf("fetch article content: %w", err)
    }
    
    // Simulate sentiment analysis (replace with actual API call)
    score, confidence := h.analyzeSentiment(content)
    
    return map[string]interface{}{
        "score":      score,
        "confidence": confidence,
        "analyzed_at": time.Now(),
    }, nil
}

func (h *SentimentAnalysisHandler) analyzeSentiment(content string) (float64, float64) {
    // Simulate API call with random delay
    time.Sleep(time.Duration(rand.Intn(1000)) * time.Millisecond)
    
    // Return mock sentiment score and confidence
    return rand.Float64()*2 - 1, rand.Float64() // Score: -1 to 1, Confidence: 0 to 1
}
```

### Management Service

```go
package computation

import (
    "context"
    "database/sql"
    "fmt"
    "time"
)

type ComputationManager struct {
    db *sql.DB
}

func NewComputationManager(db *sql.DB) *ComputationManager {
    return &ComputationManager{db: db}
}

// Queue a specific computation manually
func (m *ComputationManager) QueueComputation(ctx context.Context, 
    tableName, recordID, computationType string, priority int, metadata map[string]interface{}) error {
    
    metadataJSON, _ := json.Marshal(metadata)
    
    _, err := m.db.ExecContext(ctx, `
        INSERT INTO computation_queue 
        (table_name, record_id, computation_type, priority, metadata)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (table_name, record_id, computation_type)
        DO UPDATE SET
            priority = EXCLUDED.priority,
            scheduled_at = NOW(),
            status = 'pending',
            attempts = 0,
            metadata = EXCLUDED.metadata`,
        tableName, recordID, computationType, priority, metadataJSON)
    
    return err
}

// Bulk queue items that need reprocessing
func (m *ComputationManager) QueueStaleComputations(ctx context.Context, 
    computationType string, staleDuration time.Duration) (int, error) {
    
    query := `
        INSERT INTO computation_queue (table_name, record_id, computation_type, priority)
        SELECT 'articles', id, $1, 0
        FROM articles 
        WHERE sentiment_processed_at IS NULL 
        OR content_modified_at > sentiment_processed_at 
        OR sentiment_processed_at < NOW() - INTERVAL '%d seconds'
        ON CONFLICT (table_name, record_id, computation_type) DO NOTHING`
    
    result, err := m.db.ExecContext(ctx, 
        fmt.Sprintf(query, int(staleDuration.Seconds())), computationType)
    if err != nil {
        return 0, err
    }
    
    affected, _ := result.RowsAffected()
    return int(affected), nil
}

// Get processing statistics
func (m *ComputationManager) GetStats(ctx context.Context) (map[string]interface{}, error) {
    stats := make(map[string]interface{})
    
    // Queue statistics
    queueStats := `
        SELECT 
            status,
            computation_type,
            COUNT(*) as count,
            AVG(attempts) as avg_attempts
        FROM computation_queue 
        GROUP BY status, computation_type`
    
    rows, err := m.db.QueryContext(ctx, queueStats)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    queueData := make([]map[string]interface{}, 0)
    for rows.Next() {
        var status, computationType string
        var count int
        var avgAttempts float64
        
        rows.Scan(&status, &computationType, &count, &avgAttempts)
        queueData = append(queueData, map[string]interface{}{
            "status":           status,
            "computation_type": computationType,
            "count":           count,
            "avg_attempts":    avgAttempts,
        })
    }
    
    stats["queue"] = queueData
    
    // Processing performance
    perfStats := `
        SELECT 
            computation_type,
            COUNT(*) as total_processed,
            AVG(processing_time_ms) as avg_processing_time_ms,
            PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY processing_time_ms) as p95_processing_time_ms
        FROM computation_history 
        WHERE created_at > NOW() - INTERVAL '24 hours'
        GROUP BY computation_type`
    
    rows, err = m.db.QueryContext(ctx, perfStats)
    if err != nil {
        return stats, err
    }
    defer rows.Close()
    
    perfData := make([]map[string]interface{}, 0)
    for rows.Next() {
        var computationType string
        var totalProcessed int
        var avgTime, p95Time float64
        
        rows.Scan(&computationType, &totalProcessed, &avgTime, &p95Time)
        perfData = append(perfData, map[string]interface{}{
            "computation_type":       computationType,
            "total_processed":       totalProcessed,
            "avg_processing_time_ms": avgTime,
            "p95_processing_time_ms": p95Time,
        })
    }
    
    stats["performance"] = perfData
    
    return stats, nil
}

// Clean up old completed/failed items
func (m *ComputationManager) CleanupOldItems(ctx context.Context, olderThan time.Duration) (int, error) {
    result, err := m.db.ExecContext(ctx, `
        DELETE FROM computation_queue 
        WHERE status IN ('completed', 'failed') 
        AND (completed_at < NOW() - INTERVAL '%d seconds' 
             OR failed_at < NOW() - INTERVAL '%d seconds')`,
        int(olderThan.Seconds()), int(olderThan.Seconds()))
    
    if err != nil {
        return 0, err
    }
    
    affected, _ := result.RowsAffected()
    return int(affected), nil
}
```

### Monitoring and Observability

```go
package monitoring

import (
    "context"
    "database/sql"
    "log"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
)

var (
    computationDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "deferred_computation_duration_seconds",
            Help: "Duration of deferred computations",
        },
        []string{"computation_type", "status"},
    )
    
    queueSize = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "computation_queue_size",
            Help: "Number of items in computation queue",
        },
        []string{"status", "computation_type"},
    )
    
    processingErrors = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "computation_processing_errors_total",
            Help: "Total number of computation processing errors",
        },
        []string{"computation_type", "error_type"},
    )
)

func init() {
    prometheus.MustRegister(computationDuration, queueSize, processingErrors)
}

type Monitor struct {
    db *sql.DB
}

func NewMonitor(db *sql.DB) *Monitor {
    return &Monitor{db: db}
}

func (m *Monitor) Start(ctx context.Context) {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            m.updateMetrics(ctx)
        }
    }
}

func (m *Monitor) updateMetrics(ctx context.Context) {
    // Update queue size metrics
    rows, err := m.db.QueryContext(ctx, `
        SELECT status, computation_type, COUNT(*)
        FROM computation_queue 
        GROUP BY status, computation_type`)
    if err != nil {
        log.Printf("Error querying queue metrics: %v", err)
        return
    }
    defer rows.Close()
    
    // Reset gauges
    queueSize.Reset()
    
    for rows.Next() {
        var status, computationType string
        var count float64
        
        if err := rows.Scan(&status, &computationType, &count); err != nil {
            continue
        }
        
        queueSize.WithLabelValues(status, computationType).Set(count)
    }
}

func (m *Monitor) RecordProcessingDuration(computationType, status string, duration time.Duration) {
    computationDuration.WithLabelValues(computationType, status).Observe(duration.Seconds())
}

func (m *Monitor) RecordError(computationType, errorType string) {
    processingErrors.WithLabelValues(computationType, errorType).Inc()
}
```

## Usage Examples

### Setting Up the System

```go
func main() {
    db := setupDatabase()
    
    // Create computation worker
    worker := computation.NewComputationWorker(db, "worker-1")
    
    // Register handlers
    worker.RegisterHandler("sentiment_analysis", 
        handlers.NewSentimentAnalysisHandler(db))
    
    // Start worker
    ctx := context.Background()
    go worker.Start(ctx)
    
    // Start monitoring
    monitor := monitoring.NewMonitor(db)
    go monitor.Start(ctx)
    
    // Management interface
    manager := computation.NewComputationManager(db)
    
    // Queue stale computations every hour
    ticker := time.NewTicker(time.Hour)
    go func() {
        for range ticker.C {
            count, err := manager.QueueStaleComputations(ctx, 
                "sentiment_analysis", 24*time.Hour)
            if err != nil {
                log.Printf("Error queuing stale computations: %v", err)
            } else {
                log.Printf("Queued %d stale computations", count)
            }
        }
    }()
    
    select {}
}
```

### Manual Computation Triggering

```go
// Queue specific computation
manager.QueueComputation(ctx, "articles", articleID, "sentiment_analysis", 10, 
    map[string]interface{}{
        "reason": "manual_trigger",
        "user_id": userID,
    })

// Bulk reprocessing
count, err := manager.QueueStaleComputations(ctx, "sentiment_analysis", 7*24*time.Hour)
log.Printf("Queued %d items for reprocessing", count)
```

### Querying Computation Status

```sql
-- Articles needing sentiment analysis
SELECT id, title, content_modified_at, sentiment_processed_at,
       sentiment_score, sentiment_status
FROM articles 
WHERE sentiment_processed_at IS NULL 
   OR content_modified_at > sentiment_processed_at
ORDER BY content_modified_at DESC;

-- Queue status
SELECT computation_type, status, COUNT(*), 
       AVG(attempts) as avg_attempts,
       MIN(scheduled_at) as oldest_scheduled
FROM computation_queue 
GROUP BY computation_type, status;

-- Processing performance
SELECT computation_type,
       COUNT(*) as total_processed,
       AVG(processing_time_ms) as avg_time_ms,
       PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY processing_time_ms) as p95_time_ms
FROM computation_history 
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY computation_type;
```

## Best Practices

### Performance Optimization

1. **Batch Processing**: Process multiple items in batches where possible
2. **Connection Pooling**: Use appropriate database connection pools
3. **Index Optimization**: Ensure proper indexes on queue and tracking columns
4. **Partition Tables**: Consider partitioning large history tables by date

### Error Handling

1. **Graceful Degradation**: Handle external API failures gracefully
2. **Circuit Breakers**: Implement circuit breakers for external services
3. **Dead Letter Queues**: Move permanently failed items to dead letter queues
4. **Alerting**: Set up alerts for high failure rates or queue backlogs

### Monitoring

1. **Queue Health**: Monitor queue sizes and processing rates
2. **Processing Times**: Track computation duration and identify bottlenecks
3. **Error Rates**: Monitor and alert on error rates by computation type
4. **Resource Usage**: Track CPU, memory, and database connection usage

### Data Consistency

1. **Atomic Updates**: Use transactions for consistency
2. **Idempotency**: Ensure computations are idempotent
3. **Input Hashing**: Track input hashes to avoid recomputing unchanged data
4. **Version Control**: Consider versioning computation algorithms

## Consequences

### Positive

- **Improved User Experience**: Fast response times for user-facing operations
- **Scalability**: Can handle varying loads by scaling workers
- **Reliability**: Built-in retry logic and error handling
- **Observability**: Comprehensive monitoring and tracking
- **Flexibility**: Easy to add new computation types
- **Data Integrity**: Strong consistency guarantees

### Negative

- **Complexity**: Additional infrastructure and code complexity
- **Eventual Consistency**: Results are not immediately available
- **Resource Usage**: Additional database tables and background processes
- **Monitoring Overhead**: Requires comprehensive monitoring setup

## Related Patterns

- **Background Jobs**: General background processing patterns
- **Event Sourcing**: For audit trails of computation changes  
- **CQRS**: Separating read/write models for computed data
- **Saga Pattern**: For complex multi-step computations
- **Circuit Breaker**: For external API reliability
- **Rate Limiting**: For controlling external API usage
