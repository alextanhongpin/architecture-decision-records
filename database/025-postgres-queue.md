# PostgreSQL as a Scalable Queue

## Overview

This document extends the PostgreSQL job queue concepts to address scalability challenges in high-throughput scenarios. We explore advanced techniques including partitioning, consumer groups, and optimized polling strategies to handle millions of messages efficiently.

## Scaling Challenges

### Common Bottlenecks
- **Lock contention**: Multiple workers competing for the same rows
- **Sequential processing**: Single-threaded bottlenecks limiting throughput
- **Database load**: Excessive polling creating unnecessary database pressure  
- **Hot partitions**: Uneven distribution of work across partitions
- **Failure handling**: Infinite retry loops degrading performance

### Scaling Solutions
- **Horizontal partitioning**: Distribute work across multiple logical queues
- **Consumer groups**: Coordinate multiple workers efficiently
- **Batch processing**: Process multiple items together
- **Visibility timeouts**: Prevent duplicate processing
- **Optimized polling**: Reduce database load with smart polling strategies

## Partitioned Queue Architecture

### Partition Strategy

```sql
-- Create partitioned queue table
CREATE TABLE queue_messages (
    id BIGSERIAL,
    partition_key VARCHAR(100) NOT NULL,
    message_type VARCHAR(100) NOT NULL,
    payload JSONB NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    visibility_timeout TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    PRIMARY KEY (partition_key, id)
) PARTITION BY HASH (partition_key);

-- Create partitions (adjust number based on throughput needs)
CREATE TABLE queue_messages_p0 PARTITION OF queue_messages
    FOR VALUES WITH (MODULUS 16, REMAINDER 0);
CREATE TABLE queue_messages_p1 PARTITION OF queue_messages
    FOR VALUES WITH (MODULUS 16, REMAINDER 1);
-- ... continue for all 16 partitions

-- Indexes for efficient querying
CREATE INDEX idx_queue_messages_processing ON queue_messages 
    (partition_key, status, visibility_timeout, id) 
    WHERE status IN ('pending', 'processing');
```

### Partition Key Selection

```go
type PartitionStrategy interface {
    GetPartitionKey(message *QueueMessage) string
}

// Hash-based partitioning for even distribution
type HashPartitionStrategy struct {
    partitions int
}

func (h *HashPartitionStrategy) GetPartitionKey(message *QueueMessage) string {
    hash := fnv.New32a()
    hash.Write([]byte(message.Key))
    return fmt.Sprintf("partition_%d", hash.Sum32()%uint32(h.partitions))
}

// User-based partitioning for maintaining order per user
type UserPartitionStrategy struct{}

func (u *UserPartitionStrategy) GetPartitionKey(message *QueueMessage) string {
    return fmt.Sprintf("user_%s", message.UserID)
}

// Time-based partitioning for chronological processing
type TimePartitionStrategy struct{}

func (t *TimePartitionStrategy) GetPartitionKey(message *QueueMessage) string {
    return fmt.Sprintf("time_%s", time.Now().Format("2006010215")) // Hour-based
}
```

## Consumer Groups

### Consumer Group Management

```go
type ConsumerGroup struct {
    ID          string
    Partitions  []string
    Workers     []*Worker
    Coordinator *GroupCoordinator
    db          *sql.DB
    logger      *slog.Logger
}

type GroupCoordinator struct {
    groupID     string
    db          *sql.DB
    partitions  []string
    rebalancer  *PartitionRebalancer
    heartbeat   *HeartbeatManager
}

func NewConsumerGroup(groupID string, db *sql.DB, partitions []string) *ConsumerGroup {
    coordinator := &GroupCoordinator{
        groupID:    groupID,
        db:         db,
        partitions: partitions,
        rebalancer: NewPartitionRebalancer(),
        heartbeat:  NewHeartbeatManager(db, groupID),
    }
    
    return &ConsumerGroup{
        ID:          groupID,
        Partitions:  partitions,
        Coordinator: coordinator,
        db:          db,
        logger:      slog.Default(),
    }
}

func (cg *ConsumerGroup) Start(ctx context.Context, numWorkers int) error {
    // Register this consumer group
    if err := cg.registerGroup(ctx); err != nil {
        return fmt.Errorf("register consumer group: %w", err)
    }
    
    // Start heartbeat
    go cg.Coordinator.heartbeat.Start(ctx)
    
    // Start partition rebalancer
    go cg.Coordinator.rebalancer.Start(ctx, cg.ID)
    
    // Start workers
    for i := 0; i < numWorkers; i++ {
        worker := NewWorker(cg.ID, i, cg.db, cg.logger)
        cg.Workers = append(cg.Workers, worker)
        go worker.Start(ctx)
    }
    
    // Wait for shutdown
    <-ctx.Done()
    return cg.shutdown()
}

func (cg *ConsumerGroup) registerGroup(ctx context.Context) error {
    query := `
        INSERT INTO consumer_groups (group_id, partitions, created_at, last_heartbeat)
        VALUES ($1, $2, NOW(), NOW())
        ON CONFLICT (group_id) DO UPDATE SET
            partitions = EXCLUDED.partitions,
            last_heartbeat = NOW()
    `
    
    partitionJSON, _ := json.Marshal(cg.Partitions)
    _, err := cg.db.ExecContext(ctx, query, cg.ID, partitionJSON)
    return err
}
```

### Partition Rebalancing

```go
type PartitionRebalancer struct {
    assignments map[string][]string // consumerID -> partitions
    mutex       sync.RWMutex
}

func (pr *PartitionRebalancer) Start(ctx context.Context, groupID string) {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            if err := pr.rebalance(ctx, groupID); err != nil {
                slog.Error("rebalancing failed", "error", err)
            }
        case <-ctx.Done():
            return
        }
    }
}

func (pr *PartitionRebalancer) rebalance(ctx context.Context, groupID string) error {
    // Get active consumers
    activeConsumers, err := pr.getActiveConsumers(ctx, groupID)
    if err != nil {
        return err
    }
    
    // Get all partitions
    allPartitions, err := pr.getAllPartitions(ctx)
    if err != nil {
        return err
    }
    
    // Redistribute partitions evenly
    newAssignments := pr.redistributePartitions(activeConsumers, allPartitions)
    
    pr.mutex.Lock()
    pr.assignments = newAssignments
    pr.mutex.Unlock()
    
    // Update partition assignments in database
    return pr.saveAssignments(ctx, groupID, newAssignments)
}

func (pr *PartitionRebalancer) redistributePartitions(consumers []string, partitions []string) map[string][]string {
    assignments := make(map[string][]string)
    
    if len(consumers) == 0 {
        return assignments
    }
    
    // Distribute partitions evenly across consumers
    for i, partition := range partitions {
        consumerIndex := i % len(consumers)
        consumer := consumers[consumerIndex]
        assignments[consumer] = append(assignments[consumer], partition)
    }
    
    return assignments
}
```

## Efficient Polling Strategies

### Visibility Timeout Pattern

```go
type VisibilityTimeoutQueue struct {
    db             *sql.DB
    partitionKey   string
    visibilityTime time.Duration
    batchSize      int
    cache          *MessageCache
}

func NewVisibilityTimeoutQueue(db *sql.DB, partitionKey string, visibilityTime time.Duration) *VisibilityTimeoutQueue {
    return &VisibilityTimeoutQueue{
        db:             db,
        partitionKey:   partitionKey,
        visibilityTime: visibilityTime,
        batchSize:      100,
        cache:          NewMessageCache(),
    }
}

func (vq *VisibilityTimeoutQueue) PollMessages(ctx context.Context) ([]*QueueMessage, error) {
    tx, err := vq.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, err
    }
    defer tx.Rollback()
    
    // Select messages with visibility timeout
    query := `
        SELECT id, partition_key, message_type, payload, retry_count, max_retries
        FROM queue_messages
        WHERE partition_key = $1 
        AND status = 'pending'
        AND (visibility_timeout IS NULL OR visibility_timeout < NOW())
        ORDER BY id
        LIMIT $2
        FOR UPDATE SKIP LOCKED
    `
    
    rows, err := tx.QueryContext(ctx, query, vq.partitionKey, vq.batchSize)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var messages []*QueueMessage
    var messageIDs []int64
    
    for rows.Next() {
        var msg QueueMessage
        err := rows.Scan(&msg.ID, &msg.PartitionKey, &msg.MessageType, 
                        &msg.Payload, &msg.RetryCount, &msg.MaxRetries)
        if err != nil {
            return nil, err
        }
        
        messages = append(messages, &msg)
        messageIDs = append(messageIDs, msg.ID)
    }
    
    if len(messages) == 0 {
        return nil, nil
    }
    
    // Set visibility timeout for selected messages
    visibilityDeadline := time.Now().Add(vq.visibilityTime)
    _, err = tx.ExecContext(ctx, `
        UPDATE queue_messages 
        SET status = 'processing', visibility_timeout = $1
        WHERE id = ANY($2) AND partition_key = $3
    `, visibilityDeadline, pq.Array(messageIDs), vq.partitionKey)
    
    if err != nil {
        return nil, err
    }
    
    if err := tx.Commit(); err != nil {
        return nil, err
    }
    
    // Cache message status
    for _, msg := range messages {
        vq.cache.SetProcessing(msg.ID, visibilityDeadline)
    }
    
    return messages, nil
}

func (vq *VisibilityTimeoutQueue) CompleteMessage(ctx context.Context, messageID int64) error {
    query := `
        UPDATE queue_messages 
        SET status = 'completed', processed_at = NOW()
        WHERE id = $1 AND partition_key = $2
    `
    
    _, err := vq.db.ExecContext(ctx, query, messageID, vq.partitionKey)
    if err != nil {
        return err
    }
    
    vq.cache.Remove(messageID)
    return nil
}

func (vq *VisibilityTimeoutQueue) FailMessage(ctx context.Context, messageID int64, errorMsg string) error {
    tx, err := vq.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Get current retry count
    var retryCount, maxRetries int
    err = tx.QueryRowContext(ctx, `
        SELECT retry_count, max_retries 
        FROM queue_messages 
        WHERE id = $1 AND partition_key = $2
    `, messageID, vq.partitionKey).Scan(&retryCount, &maxRetries)
    
    if err != nil {
        return err
    }
    
    retryCount++
    
    if retryCount >= maxRetries {
        // Move to dead letter queue
        _, err = tx.ExecContext(ctx, `
            UPDATE queue_messages 
            SET status = 'failed', retry_count = $1, processed_at = NOW()
            WHERE id = $2 AND partition_key = $3
        `, retryCount, messageID, vq.partitionKey)
    } else {
        // Retry with exponential backoff
        backoffDelay := time.Duration(retryCount*retryCount) * time.Second
        nextVisibility := time.Now().Add(backoffDelay)
        
        _, err = tx.ExecContext(ctx, `
            UPDATE queue_messages 
            SET status = 'pending', retry_count = $1, visibility_timeout = $2
            WHERE id = $3 AND partition_key = $4
        `, retryCount, nextVisibility, messageID, vq.partitionKey)
    }
    
    if err != nil {
        return err
    }
    
    vq.cache.Remove(messageID)
    return tx.Commit()
}
```

### Batch Processing with Cache

```go
type MessageCache struct {
    processed map[int64]bool
    visibility map[int64]time.Time
    mutex     sync.RWMutex
}

func NewMessageCache() *MessageCache {
    return &MessageCache{
        processed:  make(map[int64]bool),
        visibility: make(map[int64]time.Time),
    }
}

func (mc *MessageCache) IsProcessed(messageID int64) bool {
    mc.mutex.RLock()
    defer mc.mutex.RUnlock()
    return mc.processed[messageID]
}

func (mc *MessageCache) SetProcessing(messageID int64, visibilityTimeout time.Time) {
    mc.mutex.Lock()
    defer mc.mutex.Unlock()
    mc.visibility[messageID] = visibilityTimeout
    mc.processed[messageID] = false
}

func (mc *MessageCache) SetProcessed(messageID int64) {
    mc.mutex.Lock()
    defer mc.mutex.Unlock()
    mc.processed[messageID] = true
}

func (mc *MessageCache) Remove(messageID int64) {
    mc.mutex.Lock()
    defer mc.mutex.Unlock()
    delete(mc.processed, messageID)
    delete(mc.visibility, messageID)
}

func (mc *MessageCache) IsVisible(messageID int64) bool {
    mc.mutex.RLock()
    defer mc.mutex.RUnlock()
    
    if visibilityTime, exists := mc.visibility[messageID]; exists {
        return time.Now().After(visibilityTime)
    }
    return true
}

type BatchProcessor struct {
    queue  *VisibilityTimeoutQueue
    cache  *MessageCache
    logger *slog.Logger
}

func (bp *BatchProcessor) ProcessBatch(ctx context.Context) error {
    // Poll messages
    messages, err := bp.queue.PollMessages(ctx)
    if err != nil {
        return fmt.Errorf("poll messages: %w", err)
    }
    
    if len(messages) == 0 {
        return nil
    }
    
    // Process messages concurrently
    var wg sync.WaitGroup
    semaphore := make(chan struct{}, 10) // Limit concurrent processing
    
    for _, message := range messages {
        wg.Add(1)
        go func(msg *QueueMessage) {
            defer wg.Done()
            
            semaphore <- struct{}{}
            defer func() { <-semaphore }()
            
            bp.processMessage(ctx, msg)
        }(message)
    }
    
    wg.Wait()
    return nil
}

func (bp *BatchProcessor) processMessage(ctx context.Context, message *QueueMessage) {
    // Check cache to avoid duplicate processing
    if bp.cache.IsProcessed(message.ID) {
        bp.queue.CompleteMessage(ctx, message.ID)
        return
    }
    
    // Mark as being processed
    bp.cache.SetProcessing(message.ID, time.Now().Add(time.Minute))
    
    // Process the message
    err := bp.handleMessage(ctx, message)
    if err != nil {
        bp.logger.Error("message processing failed", 
                       "message_id", message.ID, "error", err)
        bp.queue.FailMessage(ctx, message.ID, err.Error())
        return
    }
    
    // Mark as processed
    bp.cache.SetProcessed(message.ID)
    bp.queue.CompleteMessage(ctx, message.ID)
}

func (bp *BatchProcessor) handleMessage(ctx context.Context, message *QueueMessage) error {
    // Implement your message processing logic here
    switch message.MessageType {
    case "email":
        return bp.handleEmailMessage(ctx, message)
    case "webhook":
        return bp.handleWebhookMessage(ctx, message)
    default:
        return fmt.Errorf("unknown message type: %s", message.MessageType)
    }
}

func (bp *BatchProcessor) handleEmailMessage(ctx context.Context, message *QueueMessage) error {
    // Simulate email processing
    time.Sleep(100 * time.Millisecond)
    bp.logger.Info("email sent", "message_id", message.ID)
    return nil
}

func (bp *BatchProcessor) handleWebhookMessage(ctx context.Context, message *QueueMessage) error {
    // Simulate webhook processing
    time.Sleep(200 * time.Millisecond)
    bp.logger.Info("webhook sent", "message_id", message.ID)
    return nil
}
```

## Advanced Polling Techniques

### Adaptive Polling

```go
type AdaptivePoller struct {
    queue        *VisibilityTimeoutQueue
    minInterval  time.Duration
    maxInterval  time.Duration
    currentInterval time.Duration
    consecutiveEmpty int
    metrics      *PollerMetrics
}

func NewAdaptivePoller(queue *VisibilityTimeoutQueue) *AdaptivePoller {
    return &AdaptivePoller{
        queue:           queue,
        minInterval:     50 * time.Millisecond,
        maxInterval:     5 * time.Second,
        currentInterval: 1 * time.Second,
        metrics:         NewPollerMetrics(),
    }
}

func (ap *AdaptivePoller) Start(ctx context.Context) error {
    for {
        select {
        case <-time.After(ap.currentInterval):
            start := time.Now()
            messages, err := ap.queue.PollMessages(ctx)
            pollDuration := time.Since(start)
            
            ap.metrics.PollDuration.Observe(pollDuration.Seconds())
            
            if err != nil {
                ap.metrics.PollErrors.Inc()
                ap.adjustInterval(0, true)
                continue
            }
            
            messageCount := len(messages)
            ap.metrics.MessagesPolled.Add(float64(messageCount))
            ap.adjustInterval(messageCount, false)
            
            if messageCount > 0 {
                ap.processMessages(ctx, messages)
            }
            
        case <-ctx.Done():
            return ctx.Err()
        }
    }
}

func (ap *AdaptivePoller) adjustInterval(messageCount int, hasError bool) {
    if hasError {
        // Back off on errors
        ap.currentInterval = min(ap.maxInterval, ap.currentInterval*2)
        return
    }
    
    if messageCount == 0 {
        ap.consecutiveEmpty++
        // Gradually increase interval when no messages
        if ap.consecutiveEmpty > 3 {
            ap.currentInterval = min(ap.maxInterval, ap.currentInterval*1.5)
        }
    } else {
        ap.consecutiveEmpty = 0
        // Decrease interval when messages are available
        ap.currentInterval = max(ap.minInterval, ap.currentInterval/2)
    }
}

func (ap *AdaptivePoller) processMessages(ctx context.Context, messages []*QueueMessage) {
    for _, message := range messages {
        go ap.processMessage(ctx, message)
    }
}

func (ap *AdaptivePoller) processMessage(ctx context.Context, message *QueueMessage) {
    start := time.Now()
    defer func() {
        ap.metrics.ProcessingDuration.Observe(time.Since(start).Seconds())
    }()
    
    err := ap.handleMessage(ctx, message)
    if err != nil {
        ap.metrics.ProcessingErrors.Inc()
        ap.queue.FailMessage(ctx, message.ID, err.Error())
        return
    }
    
    ap.metrics.MessagesProcessed.Inc()
    ap.queue.CompleteMessage(ctx, message.ID)
}
```

### Long Polling

```go
type LongPoller struct {
    db           *sql.DB
    partitionKey string
    timeout      time.Duration
    batchSize    int
    notifyChan   chan struct{}
}

func NewLongPoller(db *sql.DB, partitionKey string, timeout time.Duration) *LongPoller {
    return &LongPoller{
        db:           db,
        partitionKey: partitionKey,
        timeout:      timeout,
        batchSize:    10,
        notifyChan:   make(chan struct{}, 1),
    }
}

func (lp *LongPoller) Start(ctx context.Context) error {
    // Start NOTIFY listener
    go lp.listenForNotifications(ctx)
    
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-lp.notifyChan:
            // New messages available
            if err := lp.pollAndProcess(ctx); err != nil {
                slog.Error("long polling failed", "error", err)
            }
        case <-time.After(lp.timeout):
            // Timeout reached, check for messages anyway
            if err := lp.pollAndProcess(ctx); err != nil {
                slog.Error("timeout polling failed", "error", err)
            }
        }
    }
}

func (lp *LongPoller) listenForNotifications(ctx context.Context) {
    listener := pq.NewListener("postgres://user:pass@localhost/db", 
                              10*time.Second, time.Minute, nil)
    defer listener.Close()
    
    err := listener.Listen("new_message")
    if err != nil {
        slog.Error("failed to listen for notifications", "error", err)
        return
    }
    
    for {
        select {
        case <-ctx.Done():
            return
        case notification := <-listener.NotificationChannel():
            if notification != nil {
                select {
                case lp.notifyChan <- struct{}{}:
                default:
                    // Channel is full, skip
                }
            }
        }
    }
}

func (lp *LongPoller) pollAndProcess(ctx context.Context) error {
    messages, err := lp.pollMessages(ctx)
    if err != nil {
        return err
    }
    
    for _, message := range messages {
        go lp.processMessage(ctx, message)
    }
    
    return nil
}

// Database trigger to send notifications
/*
CREATE OR REPLACE FUNCTION notify_new_message() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('new_message', NEW.partition_key);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_notify_new_message
    AFTER INSERT ON queue_messages
    FOR EACH ROW EXECUTE FUNCTION notify_new_message();
*/
```

## Message Ordering and Consistency

### FIFO Queues per Partition

```go
type FIFOQueue struct {
    db           *sql.DB
    partitionKey string
    orderingKey  string
}

func (fq *FIFOQueue) EnqueueOrdered(ctx context.Context, message *QueueMessage, orderingKey string) error {
    tx, err := fq.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Get next sequence number for this ordering key
    var nextSeq int64
    err = tx.QueryRowContext(ctx, `
        SELECT COALESCE(MAX(sequence_number), 0) + 1
        FROM queue_messages 
        WHERE partition_key = $1 AND ordering_key = $2
    `, fq.partitionKey, orderingKey).Scan(&nextSeq)
    if err != nil {
        return err
    }
    
    // Insert message with sequence number
    _, err = tx.ExecContext(ctx, `
        INSERT INTO queue_messages 
        (partition_key, ordering_key, sequence_number, message_type, payload, status)
        VALUES ($1, $2, $3, $4, $5, 'pending')
    `, fq.partitionKey, orderingKey, nextSeq, message.MessageType, message.Payload)
    
    if err != nil {
        return err
    }
    
    return tx.Commit()
}

func (fq *FIFOQueue) DequeueOrdered(ctx context.Context, orderingKey string) (*QueueMessage, error) {
    tx, err := fq.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, err
    }
    defer tx.Rollback()
    
    var message QueueMessage
    err = tx.QueryRowContext(ctx, `
        SELECT id, partition_key, ordering_key, sequence_number, message_type, payload
        FROM queue_messages
        WHERE partition_key = $1 
        AND ordering_key = $2
        AND status = 'pending'
        ORDER BY sequence_number
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    `, fq.partitionKey, orderingKey).Scan(
        &message.ID, &message.PartitionKey, &message.OrderingKey,
        &message.SequenceNumber, &message.MessageType, &message.Payload,
    )
    
    if err != nil {
        return nil, err
    }
    
    // Mark as processing
    _, err = tx.ExecContext(ctx, `
        UPDATE queue_messages 
        SET status = 'processing', visibility_timeout = NOW() + INTERVAL '5 minutes'
        WHERE id = $1
    `, message.ID)
    
    if err != nil {
        return nil, err
    }
    
    if err := tx.Commit(); err != nil {
        return nil, err
    }
    
    return &message, nil
}
```

## Dead Letter Queue Management

### Dead Letter Queue Implementation

```go
type DeadLetterQueue struct {
    db           *sql.DB
    sourceQueue  string
    dlqTable     string
    retentionDays int
}

func NewDeadLetterQueue(db *sql.DB, sourceQueue string) *DeadLetterQueue {
    return &DeadLetterQueue{
        db:            db,
        sourceQueue:   sourceQueue,
        dlqTable:      sourceQueue + "_dlq",
        retentionDays: 30,
    }
}

func (dlq *DeadLetterQueue) MoveToDLQ(ctx context.Context, messageID int64, reason string) error {
    tx, err := dlq.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Copy message to DLQ
    _, err = tx.ExecContext(ctx, fmt.Sprintf(`
        INSERT INTO %s (original_id, partition_key, message_type, payload, 
                       original_created_at, failed_at, failure_reason, retry_count)
        SELECT id, partition_key, message_type, payload, 
               created_at, NOW(), $1, retry_count
        FROM queue_messages 
        WHERE id = $2
    `, dlq.dlqTable), reason, messageID)
    
    if err != nil {
        return err
    }
    
    // Remove from original queue
    _, err = tx.ExecContext(ctx, `
        DELETE FROM queue_messages WHERE id = $1
    `, messageID)
    
    if err != nil {
        return err
    }
    
    return tx.Commit()
}

func (dlq *DeadLetterQueue) ReplayMessage(ctx context.Context, dlqMessageID int64) error {
    tx, err := dlq.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Move message back to main queue
    _, err = tx.ExecContext(ctx, fmt.Sprintf(`
        INSERT INTO queue_messages (partition_key, message_type, payload, status, retry_count)
        SELECT partition_key, message_type, payload, 'pending', 0
        FROM %s 
        WHERE id = $1
    `, dlq.dlqTable), dlqMessageID)
    
    if err != nil {
        return err
    }
    
    // Remove from DLQ
    _, err = tx.ExecContext(ctx, fmt.Sprintf(`
        DELETE FROM %s WHERE id = $1
    `, dlq.dlqTable), dlqMessageID)
    
    if err != nil {
        return err
    }
    
    return tx.Commit()
}

func (dlq *DeadLetterQueue) CleanupExpired(ctx context.Context) error {
    query := fmt.Sprintf(`
        DELETE FROM %s 
        WHERE failed_at < NOW() - INTERVAL '%d days'
    `, dlq.dlqTable, dlq.retentionDays)
    
    result, err := dlq.db.ExecContext(ctx, query)
    if err != nil {
        return err
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return err
    }
    
    if rowsAffected > 0 {
        slog.Info("cleaned up expired DLQ messages", "count", rowsAffected)
    }
    
    return nil
}
```

## Monitoring and Metrics

### Queue Metrics

```go
type QueueMetrics struct {
    MessagesEnqueued     prometheus.Counter
    MessagesProcessed    prometheus.Counter
    MessagesFailed       prometheus.Counter
    MessagesInDLQ        prometheus.Gauge
    QueueDepth          *prometheus.GaugeVec
    ProcessingDuration   prometheus.Histogram
    VisibilityTimeouts   prometheus.Counter
    ConsumerLag         *prometheus.GaugeVec
}

func NewQueueMetrics() *QueueMetrics {
    return &QueueMetrics{
        MessagesEnqueued: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "queue_messages_enqueued_total",
            Help: "Total messages enqueued",
        }),
        MessagesProcessed: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "queue_messages_processed_total",
            Help: "Total messages processed successfully",
        }),
        MessagesFailed: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "queue_messages_failed_total",
            Help: "Total messages that failed processing",
        }),
        MessagesInDLQ: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "queue_messages_in_dlq",
            Help: "Number of messages in dead letter queue",
        }),
        QueueDepth: prometheus.NewGaugeVec(prometheus.GaugeOpts{
            Name: "queue_depth",
            Help: "Number of pending messages per partition",
        }, []string{"partition"}),
        ProcessingDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
            Name:    "queue_message_processing_duration_seconds",
            Help:    "Time spent processing messages",
            Buckets: []float64{0.01, 0.1, 0.5, 1, 5, 10, 30},
        }),
        VisibilityTimeouts: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "queue_visibility_timeouts_total",
            Help: "Total number of visibility timeouts",
        }),
        ConsumerLag: prometheus.NewGaugeVec(prometheus.GaugeOpts{
            Name: "queue_consumer_lag_seconds",
            Help: "Consumer lag in seconds",
        }, []string{"partition", "consumer_group"}),
    }
}

type MetricsCollector struct {
    db      *sql.DB
    metrics *QueueMetrics
}

func (mc *MetricsCollector) Start(ctx context.Context) {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            mc.collectMetrics(ctx)
        case <-ctx.Done():
            return
        }
    }
}

func (mc *MetricsCollector) collectMetrics(ctx context.Context) {
    // Collect queue depth per partition
    rows, err := mc.db.QueryContext(ctx, `
        SELECT partition_key, COUNT(*) 
        FROM queue_messages 
        WHERE status = 'pending'
        GROUP BY partition_key
    `)
    if err != nil {
        slog.Error("failed to collect queue depth metrics", "error", err)
        return
    }
    defer rows.Close()
    
    for rows.Next() {
        var partition string
        var depth int
        if err := rows.Scan(&partition, &depth); err != nil {
            continue
        }
        mc.metrics.QueueDepth.WithLabelValues(partition).Set(float64(depth))
    }
    
    // Collect DLQ size
    var dlqCount int
    err = mc.db.QueryRowContext(ctx, `
        SELECT COUNT(*) FROM queue_messages_dlq
    `).Scan(&dlqCount)
    if err == nil {
        mc.metrics.MessagesInDLQ.Set(float64(dlqCount))
    }
    
    // Collect consumer lag
    mc.collectConsumerLag(ctx)
}

func (mc *MetricsCollector) collectConsumerLag(ctx context.Context) {
    rows, err := mc.db.QueryContext(ctx, `
        SELECT cg.group_id, qm.partition_key,
               EXTRACT(epoch FROM NOW() - MIN(qm.created_at)) as lag_seconds
        FROM consumer_groups cg
        CROSS JOIN queue_messages qm
        WHERE qm.status = 'pending'
        AND cg.last_heartbeat > NOW() - INTERVAL '1 minute'
        GROUP BY cg.group_id, qm.partition_key
    `)
    if err != nil {
        return
    }
    defer rows.Close()
    
    for rows.Next() {
        var groupID, partition string
        var lagSeconds float64
        if err := rows.Scan(&groupID, &partition, &lagSeconds); err != nil {
            continue
        }
        mc.metrics.ConsumerLag.WithLabelValues(partition, groupID).Set(lagSeconds)
    }
}
```

## Complete Example

### Production-Ready Queue System

```go
package main

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "log/slog"
    "sync"
    "time"

    _ "github.com/lib/pq"
    "github.com/prometheus/client_golang/prometheus"
)

type QueueMessage struct {
    ID             int64           `json:"id"`
    PartitionKey   string          `json:"partition_key"`
    OrderingKey    string          `json:"ordering_key,omitempty"`
    SequenceNumber int64           `json:"sequence_number,omitempty"`
    MessageType    string          `json:"message_type"`
    Payload        json.RawMessage `json:"payload"`
    Status         string          `json:"status"`
    RetryCount     int             `json:"retry_count"`
    MaxRetries     int             `json:"max_retries"`
    CreatedAt      time.Time       `json:"created_at"`
    ProcessedAt    *time.Time      `json:"processed_at,omitempty"`
}

type ScalableQueue struct {
    db               *sql.DB
    partitionStrategy PartitionStrategy
    consumers        map[string]*ConsumerGroup
    dlq              *DeadLetterQueue
    metrics          *QueueMetrics
    logger           *slog.Logger
    mutex            sync.RWMutex
}

func NewScalableQueue(db *sql.DB, strategy PartitionStrategy) *ScalableQueue {
    return &ScalableQueue{
        db:               db,
        partitionStrategy: strategy,
        consumers:        make(map[string]*ConsumerGroup),
        dlq:              NewDeadLetterQueue(db, "queue_messages"),
        metrics:          NewQueueMetrics(),
        logger:           slog.Default(),
    }
}

func (sq *ScalableQueue) Enqueue(ctx context.Context, messageType string, payload interface{}) error {
    payloadBytes, err := json.Marshal(payload)
    if err != nil {
        return fmt.Errorf("marshal payload: %w", err)
    }
    
    message := &QueueMessage{
        MessageType: messageType,
        Payload:     payloadBytes,
    }
    
    partitionKey := sq.partitionStrategy.GetPartitionKey(message)
    
    query := `
        INSERT INTO queue_messages (partition_key, message_type, payload, status, max_retries)
        VALUES ($1, $2, $3, 'pending', 3)
    `
    
    _, err = sq.db.ExecContext(ctx, query, partitionKey, messageType, payloadBytes)
    if err != nil {
        return fmt.Errorf("enqueue message: %w", err)
    }
    
    sq.metrics.MessagesEnqueued.Inc()
    sq.logger.Info("message enqueued", 
                  "type", messageType, "partition", partitionKey)
    
    return nil
}

func (sq *ScalableQueue) StartConsumerGroup(ctx context.Context, groupID string, partitions []string, numWorkers int) error {
    sq.mutex.Lock()
    defer sq.mutex.Unlock()
    
    if _, exists := sq.consumers[groupID]; exists {
        return fmt.Errorf("consumer group %s already exists", groupID)
    }
    
    consumer := NewConsumerGroup(groupID, sq.db, partitions)
    sq.consumers[groupID] = consumer
    
    go func() {
        if err := consumer.Start(ctx, numWorkers); err != nil {
            sq.logger.Error("consumer group failed", 
                           "group_id", groupID, "error", err)
        }
    }()
    
    return nil
}

func (sq *ScalableQueue) StartMonitoring(ctx context.Context) {
    collector := &MetricsCollector{
        db:      sq.db,
        metrics: sq.metrics,
    }
    
    go collector.Start(ctx)
    
    // Start DLQ cleanup
    go sq.dlqCleanupLoop(ctx)
}

func (sq *ScalableQueue) dlqCleanupLoop(ctx context.Context) {
    ticker := time.NewTicker(24 * time.Hour)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            if err := sq.dlq.CleanupExpired(ctx); err != nil {
                sq.logger.Error("DLQ cleanup failed", "error", err)
            }
        case <-ctx.Done():
            return
        }
    }
}

func main() {
    // Database connection
    db, err := sql.Open("postgres", "postgres://user:pass@localhost/db?sslmode=disable")
    if err != nil {
        panic(err)
    }
    defer db.Close()
    
    // Create scalable queue
    strategy := &HashPartitionStrategy{partitions: 16}
    queue := NewScalableQueue(db, strategy)
    
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    
    // Start monitoring
    queue.StartMonitoring(ctx)
    
    // Start consumer groups
    partitions := make([]string, 16)
    for i := 0; i < 16; i++ {
        partitions[i] = fmt.Sprintf("partition_%d", i)
    }
    
    err = queue.StartConsumerGroup(ctx, "email-processors", partitions[:8], 5)
    if err != nil {
        panic(err)
    }
    
    err = queue.StartConsumerGroup(ctx, "webhook-processors", partitions[8:], 3)
    if err != nil {
        panic(err)
    }
    
    // Enqueue some test messages
    for i := 0; i < 100; i++ {
        payload := map[string]interface{}{
            "id":    i,
            "data": fmt.Sprintf("test message %d", i),
        }
        
        messageType := "email"
        if i%2 == 0 {
            messageType = "webhook"
        }
        
        if err := queue.Enqueue(ctx, messageType, payload); err != nil {
            slog.Error("failed to enqueue message", "error", err)
        }
    }
    
    slog.Info("scalable queue system started")
    
    // Keep running
    select {}
}
```

## Best Practices

### 1. Partition Design
- Choose partition keys that distribute load evenly
- Avoid hot partitions by using hash-based strategies
- Consider message ordering requirements when partitioning
- Monitor partition utilization and rebalance as needed

### 2. Consumer Management
- Implement proper consumer group coordination
- Use heartbeats to detect failed consumers
- Plan for graceful consumer shutdown and failover
- Monitor consumer lag and scale appropriately

### 3. Error Handling
- Implement proper retry logic with exponential backoff
- Use dead letter queues for permanently failed messages
- Monitor error rates and failure patterns
- Implement circuit breakers for external dependencies

### 4. Performance Optimization
- Use visibility timeouts to prevent duplicate processing
- Batch operations when possible to reduce database load
- Implement adaptive polling to balance latency and efficiency
- Use connection pooling and prepared statements

### 5. Operational Excellence
- Implement comprehensive monitoring and alerting
- Plan for database maintenance and upgrades
- Regular cleanup of processed messages and DLQ
- Load testing under realistic conditions
- Document operational procedures and runbooks
