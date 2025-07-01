# Database Idempotency Patterns

## Status
**Accepted**

## Context
Idempotency ensures that multiple identical requests have the same effect as making the request once. This is crucial for:

- **Payment Processing**: Preventing duplicate charges from network retries
- **API Reliability**: Handling client retries gracefully without side effects
- **Distributed Systems**: Ensuring consistency in eventual consistency scenarios
- **Batch Operations**: Processing large datasets reliably with resume capability
- **Event Processing**: Preventing duplicate event handling in event-driven architectures

Different idempotency patterns are needed based on:
- **Storage duration** (seconds to days)
- **Response requirements** (return cached response vs. simple acknowledgment)
- **Performance needs** (Redis vs. database storage)
- **Batch operation complexity** (single vs. multi-level idempotency)

## Decision
We will implement a multi-tier idempotency system supporting:
1. **Redis-based idempotency** for high-performance, short-term operations
2. **Database-based idempotency** for long-term persistence and complex operations
3. **Batch idempotency** with cursor-based resume capability
4. **Request/Response caching** for operations requiring response replay

## Implementation

### 1. Redis-Based Idempotency for High-Performance Operations

```go
// pkg/idempotency/redis.go
package idempotency

import (
    "context"
    "crypto/sha256"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/go-redis/redis/v8"
)

type RedisIdempotency struct {
    client redis.Cmdable
    prefix string
    ttl    time.Duration
}

func NewRedisIdempotency(client redis.Cmdable) *RedisIdempotency {
    return &RedisIdempotency{
        client: client,
        prefix: "idempotent:",
        ttl:    24 * time.Hour,
    }
}

type IdempotentRequest struct {
    Key      string                 `json:"key"`
    Request  map[string]interface{} `json:"request"`
    Checksum string                 `json:"checksum"`
}

type IdempotentResponse struct {
    Status    string                 `json:"status"`
    Request   map[string]interface{} `json:"request"`
    Response  map[string]interface{} `json:"response,omitempty"`
    CreatedAt time.Time              `json:"created_at"`
    Checksum  string                 `json:"checksum"`
}

// CheckIdempotency verifies if request is idempotent and returns cached result if available
func (ri *RedisIdempotency) CheckIdempotency(ctx context.Context, key string, request map[string]interface{}) (*IdempotentResponse, error) {
    cacheKey := ri.buildKey(key)
    
    // Try to get existing idempotency record
    data, err := ri.client.Get(ctx, cacheKey).Result()
    if err == redis.Nil {
        // No existing record, this is a new request
        return nil, nil
    }
    if err != nil {
        return nil, fmt.Errorf("failed to check idempotency: %w", err)
    }
    
    var existing IdempotentResponse
    if err := json.Unmarshal([]byte(data), &existing); err != nil {
        return nil, fmt.Errorf("failed to unmarshal existing response: %w", err)
    }
    
    // Generate checksum for current request
    currentChecksum := ri.generateChecksum(request)
    
    // Verify request matches
    if existing.Checksum != currentChecksum {
        return nil, fmt.Errorf("idempotency key conflict: request content differs")
    }
    
    return &existing, nil
}

// StartIdempotentOperation marks the beginning of an idempotent operation
func (ri *RedisIdempotency) StartIdempotentOperation(ctx context.Context, key string, request map[string]interface{}) error {
    cacheKey := ri.buildKey(key)
    checksum := ri.generateChecksum(request)
    
    idempotentReq := IdempotentResponse{
        Status:    "pending",
        Request:   request,
        CreatedAt: time.Now(),
        Checksum:  checksum,
    }
    
    data, err := json.Marshal(idempotentReq)
    if err != nil {
        return fmt.Errorf("failed to marshal request: %w", err)
    }
    
    // Use SetNX to ensure atomicity
    result, err := ri.client.SetNX(ctx, cacheKey, string(data), ri.ttl).Result()
    if err != nil {
        return fmt.Errorf("failed to set idempotency key: %w", err)
    }
    
    if !result {
        return fmt.Errorf("idempotency key already exists")
    }
    
    return nil
}

// CompleteIdempotentOperation marks successful completion and stores response
func (ri *RedisIdempotency) CompleteIdempotentOperation(ctx context.Context, key string, response map[string]interface{}) error {
    cacheKey := ri.buildKey(key)
    
    // Get existing record to preserve request data
    data, err := ri.client.Get(ctx, cacheKey).Result()
    if err != nil {
        return fmt.Errorf("failed to get existing record: %w", err)
    }
    
    var existing IdempotentResponse
    if err := json.Unmarshal([]byte(data), &existing); err != nil {
        return fmt.Errorf("failed to unmarshal existing record: %w", err)
    }
    
    // Update with success status and response
    existing.Status = "success"
    existing.Response = response
    
    updatedData, err := json.Marshal(existing)
    if err != nil {
        return fmt.Errorf("failed to marshal updated response: %w", err)
    }
    
    // Extend TTL for successful operations
    return ri.client.Set(ctx, cacheKey, string(updatedData), ri.ttl*7).Err()
}

// FailIdempotentOperation removes the idempotency key on failure
func (ri *RedisIdempotency) FailIdempotentOperation(ctx context.Context, key string) error {
    cacheKey := ri.buildKey(key)
    return ri.client.Del(ctx, cacheKey).Err()
}

func (ri *RedisIdempotency) buildKey(key string) string {
    return ri.prefix + key
}

func (ri *RedisIdempotency) generateChecksum(request map[string]interface{}) string {
    data, _ := json.Marshal(request)
    hash := sha256.Sum256(data)
    return hex.EncodeToString(hash[:])
}

// Higher-level wrapper for automatic idempotency handling
func (ri *RedisIdempotency) ExecuteIdempotent(
    ctx context.Context,
    key string,
    request map[string]interface{},
    operation func() (map[string]interface{}, error),
) (map[string]interface{}, error) {
    // Check if operation already exists
    existing, err := ri.CheckIdempotency(ctx, key, request)
    if err != nil {
        return nil, err
    }
    
    if existing != nil {
        if existing.Status == "success" {
            return existing.Response, nil
        }
        if existing.Status == "pending" {
            return nil, fmt.Errorf("operation already in progress")
        }
    }
    
    // Start new operation
    if err := ri.StartIdempotentOperation(ctx, key, request); err != nil {
        return nil, err
    }
    
    // Execute operation
    response, err := operation()
    if err != nil {
        ri.FailIdempotentOperation(ctx, key)
        return nil, err
    }
    
    // Complete operation
    if err := ri.CompleteIdempotentOperation(ctx, key, response); err != nil {
        return nil, err
    }
    
    return response, nil
}
```

### 2. Database-Based Idempotency for Long-Term Operations

```sql
-- Idempotency tracking table
CREATE TABLE idempotent_operations (
    id BIGSERIAL PRIMARY KEY,
    idempotency_key VARCHAR(255) UNIQUE NOT NULL,
    operation_type VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    request_checksum VARCHAR(64) NOT NULL,
    request_data JSONB NOT NULL,
    response_data JSONB,
    error_message TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,
    
    -- Indexes
    INDEX idx_idempotent_key (idempotency_key),
    INDEX idx_idempotent_type_status (operation_type, status),
    INDEX idx_idempotent_expires (expires_at),
    
    -- Constraints
    CONSTRAINT chk_status CHECK (status IN ('pending', 'success', 'failed', 'timeout')),
    CONSTRAINT chk_success_has_response CHECK (
        status != 'success' OR response_data IS NOT NULL
    )
);

-- Auto-cleanup expired records
CREATE OR REPLACE FUNCTION cleanup_expired_idempotent_operations()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM idempotent_operations 
    WHERE expires_at < NOW();
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Schedule cleanup job
SELECT cron.schedule('cleanup-idempotent-operations', '0 2 * * *', 'SELECT cleanup_expired_idempotent_operations();');
```

```go
// pkg/idempotency/database.go
package idempotency

import (
    "context"
    "crypto/sha256"
    "database/sql"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/lib/pq"
)

type DatabaseIdempotency struct {
    db  *sql.DB
    ttl time.Duration
}

func NewDatabaseIdempotency(db *sql.DB) *DatabaseIdempotency {
    return &DatabaseIdempotency{
        db:  db,
        ttl: 7 * 24 * time.Hour, // 7 days default retention
    }
}

type DatabaseIdempotentOperation struct {
    ID              int64                  `json:"id"`
    IdempotencyKey  string                 `json:"idempotency_key"`
    OperationType   string                 `json:"operation_type"`
    Status          string                 `json:"status"`
    RequestData     map[string]interface{} `json:"request_data"`
    ResponseData    map[string]interface{} `json:"response_data,omitempty"`
    ErrorMessage    string                 `json:"error_message,omitempty"`
    CreatedAt       time.Time              `json:"created_at"`
    UpdatedAt       time.Time              `json:"updated_at"`
}

func (di *DatabaseIdempotency) CheckIdempotency(
    ctx context.Context,
    key, operationType string,
    request map[string]interface{},
) (*DatabaseIdempotentOperation, error) {
    checksum := di.generateChecksum(request)
    
    var op DatabaseIdempotentOperation
    var requestDataJSON, responseDataJSON []byte
    var errorMessage sql.NullString
    
    err := di.db.QueryRowContext(ctx, `
        SELECT 
            id, idempotency_key, operation_type, status,
            request_data, response_data, error_message,
            created_at, updated_at
        FROM idempotent_operations
        WHERE idempotency_key = $1 AND operation_type = $2
    `, key, operationType).Scan(
        &op.ID,
        &op.IdempotencyKey,
        &op.OperationType,
        &op.Status,
        &requestDataJSON,
        &responseDataJSON,
        &errorMessage,
        &op.CreatedAt,
        &op.UpdatedAt,
    )
    
    if err == sql.ErrNoRows {
        return nil, nil // No existing operation
    }
    if err != nil {
        return nil, fmt.Errorf("failed to check idempotency: %w", err)
    }
    
    // Verify request checksum
    if err := json.Unmarshal(requestDataJSON, &op.RequestData); err != nil {
        return nil, fmt.Errorf("failed to unmarshal request data: %w", err)
    }
    
    existingChecksum := di.generateChecksum(op.RequestData)
    if existingChecksum != checksum {
        return nil, fmt.Errorf("idempotency key conflict: request content differs")
    }
    
    // Unmarshal response data if available
    if responseDataJSON != nil {
        if err := json.Unmarshal(responseDataJSON, &op.ResponseData); err != nil {
            return nil, fmt.Errorf("failed to unmarshal response data: %w", err)
        }
    }
    
    if errorMessage.Valid {
        op.ErrorMessage = errorMessage.String
    }
    
    return &op, nil
}

func (di *DatabaseIdempotency) StartIdempotentOperation(
    ctx context.Context,
    key, operationType string,
    request map[string]interface{},
) (*DatabaseIdempotentOperation, error) {
    checksum := di.generateChecksum(request)
    requestJSON, err := json.Marshal(request)
    if err != nil {
        return nil, fmt.Errorf("failed to marshal request: %w", err)
    }
    
    expiresAt := time.Now().Add(di.ttl)
    
    var op DatabaseIdempotentOperation
    err = di.db.QueryRowContext(ctx, `
        INSERT INTO idempotent_operations (
            idempotency_key, operation_type, request_checksum,
            request_data, expires_at, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, NOW(), NOW())
        ON CONFLICT (idempotency_key) DO NOTHING
        RETURNING id, idempotency_key, operation_type, status, created_at, updated_at
    `, key, operationType, checksum, requestJSON, expiresAt).Scan(
        &op.ID,
        &op.IdempotencyKey,
        &op.OperationType,
        &op.Status,
        &op.CreatedAt,
        &op.UpdatedAt,
    )
    
    if err != nil {
        return nil, fmt.Errorf("failed to start idempotent operation: %w", err)
    }
    
    op.RequestData = request
    return &op, nil
}

func (di *DatabaseIdempotency) CompleteIdempotentOperation(
    ctx context.Context,
    operationID int64,
    response map[string]interface{},
) error {
    responseJSON, err := json.Marshal(response)
    if err != nil {
        return fmt.Errorf("failed to marshal response: %w", err)
    }
    
    _, err = di.db.ExecContext(ctx, `
        UPDATE idempotent_operations
        SET status = 'success', response_data = $1, updated_at = NOW()
        WHERE id = $2
    `, responseJSON, operationID)
    
    return err
}

func (di *DatabaseIdempotency) FailIdempotentOperation(
    ctx context.Context,
    operationID int64,
    errorMessage string,
) error {
    _, err := di.db.ExecContext(ctx, `
        UPDATE idempotent_operations
        SET status = 'failed', error_message = $1, updated_at = NOW()
        WHERE id = $2
    `, errorMessage, operationID)
    
    return err
}

func (di *DatabaseIdempotency) generateChecksum(request map[string]interface{}) string {
    data, _ := json.Marshal(request)
    hash := sha256.Sum256(data)
    return hex.EncodeToString(hash[:])
}

// ExecuteIdempotent provides high-level idempotent operation execution
func (di *DatabaseIdempotency) ExecuteIdempotent(
    ctx context.Context,
    key, operationType string,
    request map[string]interface{},
    operation func(ctx context.Context) (map[string]interface{}, error),
) (map[string]interface{}, error) {
    // Check for existing operation
    existing, err := di.CheckIdempotency(ctx, key, operationType, request)
    if err != nil {
        return nil, err
    }
    
    if existing != nil {
        switch existing.Status {
        case "success":
            return existing.ResponseData, nil
        case "pending":
            return nil, fmt.Errorf("operation already in progress")
        case "failed":
            return nil, fmt.Errorf("previous operation failed: %s", existing.ErrorMessage)
        }
    }
    
    // Start new operation
    op, err := di.StartIdempotentOperation(ctx, key, operationType, request)
    if err != nil {
        return nil, err
    }
    
    // Execute operation
    response, err := operation(ctx)
    if err != nil {
        di.FailIdempotentOperation(ctx, op.ID, err.Error())
        return nil, err
    }
    
    // Complete operation
    if err := di.CompleteIdempotentOperation(ctx, op.ID, response); err != nil {
        return nil, err
    }
    
    return response, nil
}
```

### 3. Batch Idempotency with Cursor-Based Resume

```sql
-- Batch operations tracking
CREATE TABLE batch_operations (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(255) UNIQUE NOT NULL,
    operation_type VARCHAR(100) NOT NULL,
    total_items INTEGER NOT NULL,
    processed_items INTEGER DEFAULT 0,
    failed_items INTEGER DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    cursor_position JSONB DEFAULT '{}',
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    
    -- Constraints
    CONSTRAINT chk_batch_status CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'paused')),
    CONSTRAINT chk_batch_counts CHECK (
        processed_items >= 0 AND 
        failed_items >= 0 AND 
        processed_items + failed_items <= total_items
    )
);

-- Individual batch item tracking
CREATE TABLE batch_operation_items (
    id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(255) NOT NULL,
    item_id VARCHAR(255) NOT NULL,
    item_data JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    result_data JSONB,
    error_message TEXT,
    processed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    UNIQUE(batch_id, item_id),
    INDEX idx_batch_items_batch_status (batch_id, status),
    INDEX idx_batch_items_processed (batch_id, processed_at),
    
    CONSTRAINT chk_item_status CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'skipped'))
);
```

```go
// pkg/idempotency/batch.go
package idempotency

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "time"
)

type BatchIdempotency struct {
    db *sql.DB
}

func NewBatchIdempotency(db *sql.DB) *BatchIdempotency {
    return &BatchIdempotency{db: db}
}

type BatchOperation struct {
    ID              int64                  `json:"id"`
    BatchID         string                 `json:"batch_id"`
    OperationType   string                 `json:"operation_type"`
    TotalItems      int                    `json:"total_items"`
    ProcessedItems  int                    `json:"processed_items"`
    FailedItems     int                    `json:"failed_items"`
    Status          string                 `json:"status"`
    CursorPosition  map[string]interface{} `json:"cursor_position"`
    Metadata        map[string]interface{} `json:"metadata"`
    CreatedAt       time.Time              `json:"created_at"`
    UpdatedAt       time.Time              `json:"updated_at"`
    CompletedAt     *time.Time             `json:"completed_at"`
}

type BatchItem struct {
    ID           int64                  `json:"id"`
    BatchID      string                 `json:"batch_id"`
    ItemID       string                 `json:"item_id"`
    ItemData     map[string]interface{} `json:"item_data"`
    Status       string                 `json:"status"`
    ResultData   map[string]interface{} `json:"result_data"`
    ErrorMessage string                 `json:"error_message"`
    ProcessedAt  *time.Time             `json:"processed_at"`
}

func (bi *BatchIdempotency) StartBatchOperation(
    ctx context.Context,
    batchID, operationType string,
    items []map[string]interface{},
    metadata map[string]interface{},
) (*BatchOperation, error) {
    tx, err := bi.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, err
    }
    defer tx.Rollback()
    
    metadataJSON, _ := json.Marshal(metadata)
    cursorJSON, _ := json.Marshal(map[string]interface{}{})
    
    // Insert batch operation
    var batchOp BatchOperation
    err = tx.QueryRowContext(ctx, `
        INSERT INTO batch_operations (
            batch_id, operation_type, total_items, metadata, cursor_position
        ) VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (batch_id) DO NOTHING
        RETURNING id, batch_id, operation_type, total_items, processed_items, 
                  failed_items, status, created_at, updated_at
    `, batchID, operationType, len(items), metadataJSON, cursorJSON).Scan(
        &batchOp.ID,
        &batchOp.BatchID,
        &batchOp.OperationType,
        &batchOp.TotalItems,
        &batchOp.ProcessedItems,
        &batchOp.FailedItems,
        &batchOp.Status,
        &batchOp.CreatedAt,
        &batchOp.UpdatedAt,
    )
    
    if err != nil {
        return nil, fmt.Errorf("failed to create batch operation: %w", err)
    }
    
    // Insert batch items
    for i, item := range items {
        itemID := fmt.Sprintf("%s_%d", batchID, i)
        itemJSON, _ := json.Marshal(item)
        
        _, err = tx.ExecContext(ctx, `
            INSERT INTO batch_operation_items (batch_id, item_id, item_data)
            VALUES ($1, $2, $3)
            ON CONFLICT (batch_id, item_id) DO NOTHING
        `, batchID, itemID, itemJSON)
        
        if err != nil {
            return nil, fmt.Errorf("failed to insert batch item: %w", err)
        }
    }
    
    if err := tx.Commit(); err != nil {
        return nil, err
    }
    
    batchOp.Metadata = metadata
    batchOp.CursorPosition = map[string]interface{}{}
    
    return &batchOp, nil
}

func (bi *BatchIdempotency) GetBatchOperation(ctx context.Context, batchID string) (*BatchOperation, error) {
    var batchOp BatchOperation
    var metadataJSON, cursorJSON []byte
    var completedAt sql.NullTime
    
    err := bi.db.QueryRowContext(ctx, `
        SELECT id, batch_id, operation_type, total_items, processed_items,
               failed_items, status, metadata, cursor_position,
               created_at, updated_at, completed_at
        FROM batch_operations
        WHERE batch_id = $1
    `, batchID).Scan(
        &batchOp.ID,
        &batchOp.BatchID,
        &batchOp.OperationType,
        &batchOp.TotalItems,
        &batchOp.ProcessedItems,
        &batchOp.FailedItems,
        &batchOp.Status,
        &metadataJSON,
        &cursorJSON,
        &batchOp.CreatedAt,
        &batchOp.UpdatedAt,
        &completedAt,
    )
    
    if err != nil {
        return nil, err
    }
    
    json.Unmarshal(metadataJSON, &batchOp.Metadata)
    json.Unmarshal(cursorJSON, &batchOp.CursorPosition)
    
    if completedAt.Valid {
        batchOp.CompletedAt = &completedAt.Time
    }
    
    return &batchOp, nil
}

func (bi *BatchIdempotency) GetPendingBatchItems(
    ctx context.Context,
    batchID string,
    limit int,
) ([]BatchItem, error) {
    rows, err := bi.db.QueryContext(ctx, `
        SELECT id, batch_id, item_id, item_data, status, result_data,
               error_message, processed_at
        FROM batch_operation_items
        WHERE batch_id = $1 AND status = 'pending'
        ORDER BY id
        LIMIT $2
    `, batchID, limit)
    
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var items []BatchItem
    for rows.Next() {
        var item BatchItem
        var itemDataJSON, resultDataJSON []byte
        var errorMessage sql.NullString
        var processedAt sql.NullTime
        
        err := rows.Scan(
            &item.ID,
            &item.BatchID,
            &item.ItemID,
            &itemDataJSON,
            &item.Status,
            &resultDataJSON,
            &errorMessage,
            &processedAt,
        )
        
        if err != nil {
            continue
        }
        
        json.Unmarshal(itemDataJSON, &item.ItemData)
        if resultDataJSON != nil {
            json.Unmarshal(resultDataJSON, &item.ResultData)
        }
        if errorMessage.Valid {
            item.ErrorMessage = errorMessage.String
        }
        if processedAt.Valid {
            item.ProcessedAt = &processedAt.Time
        }
        
        items = append(items, item)
    }
    
    return items, nil
}

func (bi *BatchIdempotency) CompleteItem(
    ctx context.Context,
    batchID, itemID string,
    result map[string]interface{},
) error {
    resultJSON, _ := json.Marshal(result)
    
    _, err := bi.db.ExecContext(ctx, `
        UPDATE batch_operation_items
        SET status = 'completed', result_data = $1, processed_at = NOW()
        WHERE batch_id = $2 AND item_id = $3
    `, resultJSON, batchID, itemID)
    
    if err != nil {
        return err
    }
    
    // Update batch progress
    _, err = bi.db.ExecContext(ctx, `
        UPDATE batch_operations
        SET processed_items = (
            SELECT COUNT(*) FROM batch_operation_items
            WHERE batch_id = $1 AND status IN ('completed', 'skipped')
        ),
        updated_at = NOW()
        WHERE batch_id = $1
    `, batchID)
    
    return err
}

func (bi *BatchIdempotency) FailItem(
    ctx context.Context,
    batchID, itemID string,
    errorMessage string,
) error {
    _, err := bi.db.ExecContext(ctx, `
        UPDATE batch_operation_items
        SET status = 'failed', error_message = $1, processed_at = NOW()
        WHERE batch_id = $2 AND item_id = $3
    `, errorMessage, batchID, itemID)
    
    if err != nil {
        return err
    }
    
    // Update batch progress
    _, err = bi.db.ExecContext(ctx, `
        UPDATE batch_operations
        SET 
            processed_items = (
                SELECT COUNT(*) FROM batch_operation_items
                WHERE batch_id = $1 AND status IN ('completed', 'skipped')
            ),
            failed_items = (
                SELECT COUNT(*) FROM batch_operation_items
                WHERE batch_id = $1 AND status = 'failed'
            ),
            updated_at = NOW()
        WHERE batch_id = $1
    `, batchID)
    
    return err
}

func (bi *BatchIdempotency) UpdateCursor(
    ctx context.Context,
    batchID string,
    cursor map[string]interface{},
) error {
    cursorJSON, _ := json.Marshal(cursor)
    
    _, err := bi.db.ExecContext(ctx, `
        UPDATE batch_operations
        SET cursor_position = $1, updated_at = NOW()
        WHERE batch_id = $2
    `, cursorJSON, batchID)
    
    return err
}

func (bi *BatchIdempotency) CompleteBatch(ctx context.Context, batchID string) error {
    _, err := bi.db.ExecContext(ctx, `
        UPDATE batch_operations
        SET status = 'completed', completed_at = NOW(), updated_at = NOW()
        WHERE batch_id = $1
    `, batchID)
    
    return err
}

// ProcessBatch handles the complete batch processing workflow
func (bi *BatchIdempotency) ProcessBatch(
    ctx context.Context,
    batchID string,
    processor func(ctx context.Context, item BatchItem) (map[string]interface{}, error),
    batchSize int,
) error {
    for {
        // Get pending items
        items, err := bi.GetPendingBatchItems(ctx, batchID, batchSize)
        if err != nil {
            return err
        }
        
        if len(items) == 0 {
            // No more items to process
            break
        }
        
        // Process items
        for _, item := range items {
            result, err := processor(ctx, item)
            if err != nil {
                bi.FailItem(ctx, batchID, item.ItemID, err.Error())
                continue
            }
            
            bi.CompleteItem(ctx, batchID, item.ItemID, result)
        }
        
        // Update cursor with last processed item
        if len(items) > 0 {
            lastItem := items[len(items)-1]
            cursor := map[string]interface{}{
                "last_item_id": lastItem.ItemID,
                "processed_at": time.Now(),
            }
            bi.UpdateCursor(ctx, batchID, cursor)
        }
    }
    
    // Mark batch as completed
    return bi.CompleteBatch(ctx, batchID)
}
```

### 4. High-Level Service Integration

```go
// pkg/services/payment.go
package services

import (
    "context"
    "fmt"
    
    "your-project/pkg/idempotency"
)

type PaymentService struct {
    redisIdempotency *idempotency.RedisIdempotency
    dbIdempotency    *idempotency.DatabaseIdempotency
    paymentGateway   PaymentGateway
}

func (ps *PaymentService) ProcessPayment(
    ctx context.Context,
    idempotencyKey string,
    amount float64,
    customerID string,
    paymentMethodID string,
) (*PaymentResult, error) {
    request := map[string]interface{}{
        "amount":            amount,
        "customer_id":       customerID,
        "payment_method_id": paymentMethodID,
    }
    
    // Use Redis for quick payment processing
    response, err := ps.redisIdempotency.ExecuteIdempotent(
        ctx,
        idempotencyKey,
        request,
        func() (map[string]interface{}, error) {
            // Actual payment processing
            result, err := ps.paymentGateway.ProcessPayment(ctx, PaymentRequest{
                Amount:          amount,
                CustomerID:      customerID,
                PaymentMethodID: paymentMethodID,
            })
            
            if err != nil {
                return nil, err
            }
            
            return map[string]interface{}{
                "transaction_id": result.TransactionID,
                "status":         result.Status,
                "amount":         result.Amount,
                "processed_at":   result.ProcessedAt,
            }, nil
        },
    )
    
    if err != nil {
        return nil, err
    }
    
    return &PaymentResult{
        TransactionID: response["transaction_id"].(string),
        Status:        response["status"].(string),
        Amount:        response["amount"].(float64),
    }, nil
}

// For long-running operations like refunds
func (ps *PaymentService) ProcessRefund(
    ctx context.Context,
    idempotencyKey string,
    transactionID string,
    amount float64,
    reason string,
) (*RefundResult, error) {
    request := map[string]interface{}{
        "transaction_id": transactionID,
        "amount":         amount,
        "reason":         reason,
    }
    
    // Use database for persistent refund tracking
    response, err := ps.dbIdempotency.ExecuteIdempotent(
        ctx,
        idempotencyKey,
        "refund",
        request,
        func(ctx context.Context) (map[string]interface{}, error) {
            result, err := ps.paymentGateway.ProcessRefund(ctx, RefundRequest{
                TransactionID: transactionID,
                Amount:        amount,
                Reason:        reason,
            })
            
            if err != nil {
                return nil, err
            }
            
            return map[string]interface{}{
                "refund_id":    result.RefundID,
                "status":       result.Status,
                "amount":       result.Amount,
                "processed_at": result.ProcessedAt,
            }, nil
        },
    )
    
    if err != nil {
        return nil, err
    }
    
    return &RefundResult{
        RefundID:    response["refund_id"].(string),
        Status:      response["status"].(string),
        Amount:      response["amount"].(float64),
        ProcessedAt: response["processed_at"].(time.Time),
    }, nil
}

// Batch payment processing
func (ps *PaymentService) ProcessBulkPayments(
    ctx context.Context,
    batchID string,
    payments []PaymentRequest,
) error {
    batchIdempotency := idempotency.NewBatchIdempotency(ps.db)
    
    // Convert payments to generic items
    items := make([]map[string]interface{}, len(payments))
    for i, payment := range payments {
        items[i] = map[string]interface{}{
            "amount":            payment.Amount,
            "customer_id":       payment.CustomerID,
            "payment_method_id": payment.PaymentMethodID,
        }
    }
    
    // Start batch operation
    _, err := batchIdempotency.StartBatchOperation(
        ctx,
        batchID,
        "bulk_payment",
        items,
        map[string]interface{}{
            "initiated_by": "payment_service",
            "total_amount": calculateTotalAmount(payments),
        },
    )
    
    if err != nil {
        return err
    }
    
    // Process batch
    return batchIdempotency.ProcessBatch(
        ctx,
        batchID,
        func(ctx context.Context, item idempotency.BatchItem) (map[string]interface{}, error) {
            // Process individual payment
            result, err := ps.paymentGateway.ProcessPayment(ctx, PaymentRequest{
                Amount:          item.ItemData["amount"].(float64),
                CustomerID:      item.ItemData["customer_id"].(string),
                PaymentMethodID: item.ItemData["payment_method_id"].(string),
            })
            
            if err != nil {
                return nil, err
            }
            
            return map[string]interface{}{
                "transaction_id": result.TransactionID,
                "status":         result.Status,
                "amount":         result.Amount,
            }, nil
        },
        100, // Process 100 items at a time
    )
}
```

## Best Practices

### 1. Idempotency Key Guidelines

- **Use UUIDs**: Generate globally unique idempotency keys
- **Include Context**: Incorporate user/tenant information in keys
- **Avoid Collisions**: Use cryptographically secure key generation
- **Meaningful Keys**: Include operation type or date for debugging

### 2. Storage Duration Strategies

| Operation Type | Storage Method | Duration | Reason |
|----------------|----------------|----------|---------|
| Payment Processing | Redis | 24 hours | Fast access, short-term |
| Order Creation | Database | 7 days | Audit requirements |
| Bulk Operations | Database | 30 days | Resume capability |
| Critical Transactions | Database | 1 year | Compliance |

### 3. Error Handling Patterns

```go
func (service *Service) HandleIdempotentOperation(
    ctx context.Context,
    key string,
    operation func() (*Result, error),
) (*Result, error) {
    // Check idempotency with circuit breaker pattern
    existing, err := service.checkWithCircuitBreaker(ctx, key)
    if err != nil {
        // Fallback: proceed without idempotency if Redis is down
        log.Warn("Idempotency check failed, proceeding without protection")
        return operation()
    }
    
    if existing != nil {
        return existing, nil
    }
    
    // Implement with timeout and retry
    return service.executeWithRetry(ctx, key, operation, 3)
}
```

## Consequences

### Positive
- **Reliability**: Prevents duplicate operations from client retries
- **Data Consistency**: Ensures financial and critical operations are safe
- **Resume Capability**: Batch operations can recover from failures
- **Performance**: Redis provides fast idempotency checks
- **Audit Trail**: Complete history of idempotent operations

### Negative
- **Storage Overhead**: Additional storage required for idempotency tracking
- **Complexity**: Multiple storage tiers increase system complexity
- **Latency**: Additional checks add latency to operations
- **Maintenance**: Cleanup processes required for expired records

## Related Patterns
- [Pessimistic Locking](008-pessimistic-locking.md) - Preventing concurrent access
- [State Machine](010-state-machine.md) - Managing entity state transitions
- [Redis Convention](012-redis-convention.md) - Redis key naming and usage
- [Database Logging](013-logging.md) - Audit trail implementation 
