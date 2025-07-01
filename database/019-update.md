# Safe Database Update Patterns

## Status

`accepted`

## Context

Database updates are critical operations that can lead to data inconsistency, race conditions, and performance issues if not handled properly. The challenge lies in choosing between application-level logic with explicit locking versus database-level atomic operations. Each approach has different trade-offs in terms of performance, consistency, complexity, and maintainability.

Modern applications need to handle concurrent updates safely while maintaining good performance and clear business logic. The decision between "select-then-update" and "direct conditional updates" affects system scalability, data integrity, and code maintainability.

## Decision

Implement a multi-layered approach to database updates that combines conditional updates, optimistic locking, and explicit locking patterns based on the specific use case requirements. Provide clear guidelines for when to use each pattern and implement safeguards against common update pitfalls.

## Architecture

### Update Patterns

1. **Conditional Updates**: Direct database updates with conditions
2. **Optimistic Locking**: Version-based conflict detection
3. **Pessimistic Locking**: Explicit row locking
4. **Compare-and-Swap**: Atomic conditional updates
5. **Batch Updates**: Efficient bulk operations
6. **Audit Trail Updates**: Updates with change tracking

### Schema Design for Safe Updates

```sql
-- Base table with update safety features
CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    amount DECIMAL(10,2) NOT NULL,
    
    -- Optimistic locking
    version INTEGER NOT NULL DEFAULT 1,
    
    -- Audit fields
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by UUID,
    
    -- State transition tracking
    status_changed_at TIMESTAMPTZ,
    previous_status VARCHAR(50),
    
    -- Additional safety columns
    processing_started_at TIMESTAMPTZ,
    processing_completed_at TIMESTAMPTZ,
    
    CONSTRAINT valid_status CHECK (status IN ('pending', 'processing', 'paid', 'cancelled', 'failed'))
);

-- State transition history
CREATE TABLE order_status_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES orders(id),
    from_status VARCHAR(50),
    to_status VARCHAR(50) NOT NULL,
    changed_by UUID,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reason TEXT,
    metadata JSONB
);

-- Update triggers for safety
CREATE OR REPLACE FUNCTION update_order_audit() 
RETURNS TRIGGER AS $$
BEGIN
    -- Update version for optimistic locking
    NEW.version = OLD.version + 1;
    NEW.updated_at = NOW();
    
    -- Track status changes
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        NEW.status_changed_at = NOW();
        NEW.previous_status = OLD.status;
        
        -- Insert into history
        INSERT INTO order_status_history (order_id, from_status, to_status, changed_by)
        VALUES (NEW.id, OLD.status, NEW.status, NEW.updated_by);
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_order_audit
    BEFORE UPDATE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION update_order_audit();

-- Indexes for efficient updates
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_version ON orders(id, version);
CREATE INDEX idx_orders_processing ON orders(status, processing_started_at) 
    WHERE status = 'processing';
```

## Implementation

### Go Update Service

```go
package updates

import (
    "context"
    "database/sql"
    "fmt"
    "time"
    
    "github.com/google/uuid"
    "github.com/lib/pq"
)

type UpdateService struct {
    db *sql.DB
}

type UpdateResult struct {
    Success     bool
    RowsAffected int64
    Version     int
    ConflictType string
    Error       error
}

type Order struct {
    ID                   uuid.UUID  `json:"id"`
    CustomerID           uuid.UUID  `json:"customer_id"`
    Status               string     `json:"status"`
    Amount               float64    `json:"amount"`
    Version              int        `json:"version"`
    CreatedAt            time.Time  `json:"created_at"`
    UpdatedAt            time.Time  `json:"updated_at"`
    UpdatedBy            *uuid.UUID `json:"updated_by,omitempty"`
    StatusChangedAt      *time.Time `json:"status_changed_at,omitempty"`
    PreviousStatus       *string    `json:"previous_status,omitempty"`
    ProcessingStartedAt  *time.Time `json:"processing_started_at,omitempty"`
    ProcessingCompletedAt *time.Time `json:"processing_completed_at,omitempty"`
}

func NewUpdateService(db *sql.DB) *UpdateService {
    return &UpdateService{db: db}
}

// Pattern 1: Conditional Update (Recommended for most cases)
func (s *UpdateService) UpdateOrderStatusConditional(ctx context.Context, 
    orderID uuid.UUID, fromStatus, toStatus string, updatedBy uuid.UUID) (*UpdateResult, error) {
    
    query := `
        UPDATE orders 
        SET status = $1, updated_by = $2
        WHERE id = $3 AND status = $4
        RETURNING version`
    
    var newVersion int
    err := s.db.QueryRowContext(ctx, query, toStatus, updatedBy, orderID, fromStatus).Scan(&newVersion)
    
    if err == sql.ErrNoRows {
        // Check if order exists to provide better error message
        var currentStatus string
        checkQuery := `SELECT status FROM orders WHERE id = $1`
        if s.db.QueryRowContext(ctx, checkQuery, orderID).Scan(&currentStatus) == nil {
            return &UpdateResult{
                Success:      false,
                ConflictType: "status_mismatch",
                Error:        fmt.Errorf("order status is %s, expected %s", currentStatus, fromStatus),
            }, nil
        }
        
        return &UpdateResult{
            Success:      false,
            ConflictType: "not_found",
            Error:        fmt.Errorf("order not found"),
        }, nil
    }
    
    if err != nil {
        return nil, fmt.Errorf("update order status: %w", err)
    }
    
    return &UpdateResult{
        Success:      true,
        RowsAffected: 1,
        Version:      newVersion,
    }, nil
}

// Pattern 2: Optimistic Locking Update
func (s *UpdateService) UpdateOrderWithOptimisticLocking(ctx context.Context, 
    order *Order) (*UpdateResult, error) {
    
    query := `
        UPDATE orders 
        SET customer_id = $1, status = $2, amount = $3, updated_by = $4
        WHERE id = $5 AND version = $6
        RETURNING version`
    
    var newVersion int
    err := s.db.QueryRowContext(ctx, query, 
        order.CustomerID, order.Status, order.Amount, order.UpdatedBy,
        order.ID, order.Version).Scan(&newVersion)
    
    if err == sql.ErrNoRows {
        // Version conflict - get current version
        var currentVersion int
        versionQuery := `SELECT version FROM orders WHERE id = $1`
        if s.db.QueryRowContext(ctx, versionQuery, order.ID).Scan(&currentVersion) == nil {
            return &UpdateResult{
                Success:      false,
                ConflictType: "version_conflict",
                Version:      currentVersion,
                Error:        fmt.Errorf("version conflict: expected %d, current %d", order.Version, currentVersion),
            }, nil
        }
        
        return &UpdateResult{
            Success:      false,
            ConflictType: "not_found",
            Error:        fmt.Errorf("order not found"),
        }, nil
    }
    
    if err != nil {
        return nil, fmt.Errorf("optimistic update: %w", err)
    }
    
    order.Version = newVersion
    return &UpdateResult{
        Success:      true,
        RowsAffected: 1,
        Version:      newVersion,
    }, nil
}

// Pattern 3: Pessimistic Locking Update
func (s *UpdateService) UpdateOrderWithPessimisticLocking(ctx context.Context, 
    orderID uuid.UUID, updateFunc func(*Order) error) (*UpdateResult, error) {
    
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Select with locking
    var order Order
    selectQuery := `
        SELECT id, customer_id, status, amount, version, created_at, updated_at,
               updated_by, status_changed_at, previous_status, 
               processing_started_at, processing_completed_at
        FROM orders 
        WHERE id = $1 
        FOR UPDATE`
    
    err = tx.QueryRowContext(ctx, selectQuery, orderID).Scan(
        &order.ID, &order.CustomerID, &order.Status, &order.Amount,
        &order.Version, &order.CreatedAt, &order.UpdatedAt,
        &order.UpdatedBy, &order.StatusChangedAt, &order.PreviousStatus,
        &order.ProcessingStartedAt, &order.ProcessingCompletedAt)
    
    if err == sql.ErrNoRows {
        return &UpdateResult{
            Success:      false,
            ConflictType: "not_found",
            Error:        fmt.Errorf("order not found"),
        }, nil
    }
    
    if err != nil {
        return nil, fmt.Errorf("select for update: %w", err)
    }
    
    // Apply business logic
    originalVersion := order.Version
    if err := updateFunc(&order); err != nil {
        return &UpdateResult{
            Success: false,
            Error:   fmt.Errorf("update function failed: %w", err),
        }, nil
    }
    
    // Update with new values
    updateQuery := `
        UPDATE orders 
        SET customer_id = $1, status = $2, amount = $3, updated_by = $4,
            processing_started_at = $5, processing_completed_at = $6
        WHERE id = $7 AND version = $8
        RETURNING version`
    
    var newVersion int
    err = tx.QueryRowContext(ctx, updateQuery,
        order.CustomerID, order.Status, order.Amount, order.UpdatedBy,
        order.ProcessingStartedAt, order.ProcessingCompletedAt,
        order.ID, originalVersion).Scan(&newVersion)
    
    if err != nil {
        return nil, fmt.Errorf("update order: %w", err)
    }
    
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("commit transaction: %w", err)
    }
    
    order.Version = newVersion
    return &UpdateResult{
        Success:      true,
        RowsAffected: 1,
        Version:      newVersion,
    }, nil
}

// Pattern 4: Compare-and-Swap Update
func (s *UpdateService) CompareAndSwapOrderStatus(ctx context.Context, 
    orderID uuid.UUID, expectedStatus, newStatus string, updatedBy uuid.UUID) (*UpdateResult, error) {
    
    // Atomic compare-and-swap operation
    query := `
        UPDATE orders 
        SET status = $1, 
            updated_by = $2,
            processing_started_at = CASE 
                WHEN $1 = 'processing' THEN NOW() 
                ELSE processing_started_at 
            END,
            processing_completed_at = CASE 
                WHEN $1 IN ('paid', 'cancelled', 'failed') THEN NOW() 
                ELSE processing_completed_at 
            END
        WHERE id = $3 AND status = $4
        RETURNING version, status, processing_started_at, processing_completed_at`
    
    var version int
    var status string
    var processingStartedAt, processingCompletedAt sql.NullTime
    
    err := s.db.QueryRowContext(ctx, query, newStatus, updatedBy, orderID, expectedStatus).Scan(
        &version, &status, &processingStartedAt, &processingCompletedAt)
    
    if err == sql.ErrNoRows {
        return &UpdateResult{
            Success:      false,
            ConflictType: "status_mismatch",
            Error:        fmt.Errorf("status mismatch or order not found"),
        }, nil
    }
    
    if err != nil {
        return nil, fmt.Errorf("compare and swap: %w", err)
    }
    
    return &UpdateResult{
        Success:      true,
        RowsAffected: 1,
        Version:      version,
    }, nil
}

// Pattern 5: Batch Update with Safety Checks
func (s *UpdateService) BatchUpdateOrderStatus(ctx context.Context, 
    orderIDs []uuid.UUID, fromStatus, toStatus string, updatedBy uuid.UUID) (*UpdateResult, error) {
    
    if len(orderIDs) == 0 {
        return &UpdateResult{Success: true}, nil
    }
    
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // First, validate all orders can be updated
    validateQuery := `
        SELECT COUNT(*) 
        FROM orders 
        WHERE id = ANY($1) AND status = $2`
    
    var validCount int
    err = tx.QueryRowContext(ctx, validateQuery, pq.Array(orderIDs), fromStatus).Scan(&validCount)
    if err != nil {
        return nil, fmt.Errorf("validate orders: %w", err)
    }
    
    if validCount != len(orderIDs) {
        return &UpdateResult{
            Success:      false,
            ConflictType: "partial_validation_failure",
            Error:        fmt.Errorf("only %d of %d orders can be updated", validCount, len(orderIDs)),
        }, nil
    }
    
    // Perform batch update
    updateQuery := `
        UPDATE orders 
        SET status = $1, updated_by = $2
        WHERE id = ANY($3) AND status = $4`
    
    result, err := tx.ExecContext(ctx, updateQuery, toStatus, updatedBy, pq.Array(orderIDs), fromStatus)
    if err != nil {
        return nil, fmt.Errorf("batch update: %w", err)
    }
    
    rowsAffected, _ := result.RowsAffected()
    
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("commit transaction: %w", err)
    }
    
    return &UpdateResult{
        Success:      true,
        RowsAffected: rowsAffected,
    }, nil
}

// Pattern 6: Update with Complex Business Logic
func (s *UpdateService) ProcessOrderPayment(ctx context.Context, 
    orderID uuid.UUID, paymentAmount float64, updatedBy uuid.UUID) (*UpdateResult, error) {
    
    // Complex update with multiple conditions and calculations
    query := `
        UPDATE orders 
        SET 
            status = CASE 
                WHEN amount = $1 THEN 'paid'
                WHEN amount > $1 THEN 'partial_payment'
                ELSE status
            END,
            updated_by = $2,
            processing_completed_at = CASE 
                WHEN amount = $1 THEN NOW()
                ELSE processing_completed_at
            END
        WHERE id = $3 
        AND status IN ('pending', 'partial_payment')
        AND amount >= $1
        RETURNING status, amount, version`
    
    var newStatus string
    var orderAmount float64
    var version int
    
    err := s.db.QueryRowContext(ctx, query, paymentAmount, updatedBy, orderID).Scan(
        &newStatus, &orderAmount, &version)
    
    if err == sql.ErrNoRows {
        return &UpdateResult{
            Success:      false,
            ConflictType: "business_rule_violation",
            Error:        fmt.Errorf("order cannot be processed (invalid status or amount)"),
        }, nil
    }
    
    if err != nil {
        return nil, fmt.Errorf("process payment: %w", err)
    }
    
    return &UpdateResult{
        Success:      true,
        RowsAffected: 1,
        Version:      version,
    }, nil
}

// Utility: Get Order with Version Check
func (s *UpdateService) GetOrderForUpdate(ctx context.Context, orderID uuid.UUID) (*Order, error) {
    query := `
        SELECT id, customer_id, status, amount, version, created_at, updated_at,
               updated_by, status_changed_at, previous_status, 
               processing_started_at, processing_completed_at
        FROM orders 
        WHERE id = $1`
    
    var order Order
    err := s.db.QueryRowContext(ctx, query, orderID).Scan(
        &order.ID, &order.CustomerID, &order.Status, &order.Amount,
        &order.Version, &order.CreatedAt, &order.UpdatedAt,
        &order.UpdatedBy, &order.StatusChangedAt, &order.PreviousStatus,
        &order.ProcessingStartedAt, &order.ProcessingCompletedAt)
    
    if err != nil {
        return nil, err
    }
    
    return &order, nil
}
```

### Retry and Error Handling

```go
package updates

import (
    "context"
    "fmt"
    "math/rand"
    "time"
)

type RetryConfig struct {
    MaxAttempts int
    InitialDelay time.Duration
    MaxDelay     time.Duration
    Multiplier   float64
    Jitter       bool
}

func DefaultRetryConfig() *RetryConfig {
    return &RetryConfig{
        MaxAttempts:  3,
        InitialDelay: 100 * time.Millisecond,
        MaxDelay:     2 * time.Second,
        Multiplier:   2.0,
        Jitter:       true,
    }
}

func (s *UpdateService) UpdateWithRetry(ctx context.Context, 
    updateFunc func() (*UpdateResult, error), config *RetryConfig) (*UpdateResult, error) {
    
    if config == nil {
        config = DefaultRetryConfig()
    }
    
    var lastResult *UpdateResult
    var lastErr error
    
    for attempt := 1; attempt <= config.MaxAttempts; attempt++ {
        result, err := updateFunc()
        
        if err != nil {
            lastErr = err
            if attempt < config.MaxAttempts {
                delay := s.calculateDelay(attempt, config)
                select {
                case <-ctx.Done():
                    return nil, ctx.Err()
                case <-time.After(delay):
                    continue
                }
            }
            break
        }
        
        lastResult = result
        
        // Success or non-retryable failure
        if result.Success || !s.shouldRetry(result) {
            return result, nil
        }
        
        // Retryable failure
        if attempt < config.MaxAttempts {
            delay := s.calculateDelay(attempt, config)
            select {
            case <-ctx.Done():
                return nil, ctx.Err()
            case <-time.After(delay):
                continue
            }
        }
    }
    
    if lastErr != nil {
        return nil, fmt.Errorf("update failed after %d attempts: %w", config.MaxAttempts, lastErr)
    }
    
    return lastResult, nil
}

func (s *UpdateService) shouldRetry(result *UpdateResult) bool {
    // Retry on version conflicts and certain types of errors
    return result.ConflictType == "version_conflict" || 
           result.ConflictType == "status_mismatch"
}

func (s *UpdateService) calculateDelay(attempt int, config *RetryConfig) time.Duration {
    delay := time.Duration(float64(config.InitialDelay) * 
        pow(config.Multiplier, float64(attempt-1)))
    
    if delay > config.MaxDelay {
        delay = config.MaxDelay
    }
    
    if config.Jitter {
        jitter := time.Duration(rand.Float64() * float64(delay) * 0.1)
        delay += jitter
    }
    
    return delay
}

func pow(base, exp float64) float64 {
    result := 1.0
    for i := 0; i < int(exp); i++ {
        result *= base
    }
    return result
}
```

### Update Monitoring

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
    updateDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "database_update_duration_seconds",
            Help: "Duration of database update operations",
        },
        []string{"table", "operation", "result"},
    )
    
    updateConflicts = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "database_update_conflicts_total",
            Help: "Total number of update conflicts",
        },
        []string{"table", "conflict_type"},
    )
    
    concurrentUpdates = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "database_concurrent_updates",
            Help: "Number of concurrent update operations",
        },
        []string{"table"},
    )
)

func init() {
    prometheus.MustRegister(updateDuration, updateConflicts, concurrentUpdates)
}

type UpdateMonitor struct {
    db *sql.DB
}

func NewUpdateMonitor(db *sql.DB) *UpdateMonitor {
    return &UpdateMonitor{db: db}
}

func (m *UpdateMonitor) RecordUpdate(table, operation, result string, duration time.Duration) {
    updateDuration.WithLabelValues(table, operation, result).Observe(duration.Seconds())
}

func (m *UpdateMonitor) RecordConflict(table, conflictType string) {
    updateConflicts.WithLabelValues(table, conflictType).Inc()
}

func (m *UpdateMonitor) TrackConcurrentUpdate(table string) func() {
    concurrentUpdates.WithLabelValues(table).Inc()
    return func() {
        concurrentUpdates.WithLabelValues(table).Dec()
    }
}

func (m *UpdateMonitor) StartPeriodicMonitoring(ctx context.Context) {
    ticker := time.NewTicker(1 * time.Minute)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            m.checkLongRunningUpdates(ctx)
        }
    }
}

func (m *UpdateMonitor) checkLongRunningUpdates(ctx context.Context) {
    query := `
        SELECT pid, now() - pg_stat_activity.query_start AS duration, query
        FROM pg_stat_activity 
        WHERE (now() - pg_stat_activity.query_start) > interval '30 seconds'
        AND query ILIKE '%UPDATE%'
        AND state = 'active'`
    
    rows, err := m.db.QueryContext(ctx, query)
    if err != nil {
        log.Printf("Error checking long running updates: %v", err)
        return
    }
    defer rows.Close()
    
    for rows.Next() {
        var pid int
        var duration time.Duration
        var query string
        
        if err := rows.Scan(&pid, &duration, &query); err != nil {
            continue
        }
        
        log.Printf("Long running update detected: PID=%d, Duration=%v, Query=%s", 
            pid, duration, query)
    }
}
```

## Usage Examples

### Simple Status Update

```go
func handleOrderPayment(w http.ResponseWriter, r *http.Request) {
    orderID := extractOrderID(r)
    userID := extractUserID(r)
    
    // Use conditional update (recommended approach)
    result, err := updateService.UpdateOrderStatusConditional(
        r.Context(), orderID, "pending", "paid", userID)
    
    if err != nil {
        http.Error(w, "Update failed", http.StatusInternalServerError)
        return
    }
    
    if !result.Success {
        switch result.ConflictType {
        case "not_found":
            http.Error(w, "Order not found", http.StatusNotFound)
        case "status_mismatch":
            http.Error(w, "Order cannot be paid in current status", http.StatusConflict)
        default:
            http.Error(w, "Update failed", http.StatusInternalServerError)
        }
        return
    }
    
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]interface{}{
        "success": true,
        "version": result.Version,
    })
}
```

### Optimistic Locking Update

```go
func handleOrderUpdate(w http.ResponseWriter, r *http.Request) {
    var order Order
    if err := json.NewDecoder(r.Body).Decode(&order); err != nil {
        http.Error(w, "Invalid request", http.StatusBadRequest)
        return
    }
    
    // Validate business rules
    if err := validateOrderUpdate(&order); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    // Attempt optimistic update with retry
    result, err := updateService.UpdateWithRetry(r.Context(), 
        func() (*UpdateResult, error) {
            return updateService.UpdateOrderWithOptimisticLocking(r.Context(), &order)
        }, 
        DefaultRetryConfig())
    
    if err != nil {
        http.Error(w, "Update failed", http.StatusInternalServerError)
        return
    }
    
    if !result.Success {
        if result.ConflictType == "version_conflict" {
            w.Header().Set("X-Current-Version", fmt.Sprintf("%d", result.Version))
            http.Error(w, "Version conflict", http.StatusConflict)
            return
        }
        http.Error(w, result.Error.Error(), http.StatusBadRequest)
        return
    }
    
    json.NewEncoder(w).Encode(order)
}
```

### Complex Business Logic Update

```go
func handleComplexOrderProcessing(orderID uuid.UUID, userID uuid.UUID) error {
    // Use pessimistic locking for complex business logic
    result, err := updateService.UpdateOrderWithPessimisticLocking(
        context.Background(), orderID, 
        func(order *Order) error {
            // Complex business logic
            if order.Status != "pending" {
                return fmt.Errorf("order not in pending status")
            }
            
            // Check inventory, calculate discounts, etc.
            if err := checkInventory(order.CustomerID); err != nil {
                return err
            }
            
            discount := calculateDiscount(order)
            order.Amount = order.Amount * (1 - discount)
            order.Status = "processing"
            order.UpdatedBy = &userID
            
            now := time.Now()
            order.ProcessingStartedAt = &now
            
            return nil
        })
    
    if err != nil {
        return fmt.Errorf("complex update failed: %w", err)
    }
    
    if !result.Success {
        return fmt.Errorf("update failed: %s", result.Error.Error())
    }
    
    return nil
}
```

### Batch Operations

```go
func processBulkOrderCancellation(orderIDs []uuid.UUID, userID uuid.UUID) error {
    // Batch update with validation
    result, err := updateService.BatchUpdateOrderStatus(
        context.Background(), orderIDs, "pending", "cancelled", userID)
    
    if err != nil {
        return fmt.Errorf("batch update failed: %w", err)
    }
    
    if !result.Success {
        return fmt.Errorf("batch update failed: %s", result.Error.Error())
    }
    
    log.Printf("Successfully cancelled %d orders", result.RowsAffected)
    return nil
}
```

## Best Practices

### When to Use Each Pattern

1. **Conditional Updates**: 
   - Simple status transitions
   - High-throughput operations
   - When business logic is simple

2. **Optimistic Locking**:
   - Updates with potential conflicts
   - When user input might be stale
   - Concurrent editing scenarios

3. **Pessimistic Locking**:
   - Complex business logic
   - Critical operations requiring consistency
   - When conflicts are expensive

4. **Compare-and-Swap**:
   - Simple atomic operations
   - High-performance scenarios
   - When you need guaranteed atomicity

### Performance Considerations

1. **Index Usage**: Ensure proper indexes on WHERE clause columns
2. **Batch Size**: Limit batch operations to prevent lock escalation
3. **Connection Pooling**: Use appropriate connection pool settings
4. **Query Planning**: Analyze query execution plans regularly
5. **Lock Duration**: Minimize time holding locks

### Safety Guidelines

1. **Always Use Conditions**: Never update without WHERE clauses
2. **Validate Inputs**: Check data validity before updates
3. **Handle Conflicts**: Implement proper conflict resolution
4. **Audit Changes**: Track who changed what and when
5. **Test Concurrency**: Test update operations under load

### Monitoring and Alerting

1. **Track Update Performance**: Monitor update duration and throughput
2. **Conflict Detection**: Alert on high conflict rates
3. **Lock Monitoring**: Watch for lock waits and deadlocks
4. **Business Metrics**: Track update success rates by operation type

## Consequences

### Positive

- **Data Consistency**: Strong consistency guarantees with proper patterns
- **Performance**: Optimized for different use cases and loads
- **Scalability**: Patterns that work well under concurrent load
- **Maintainability**: Clear separation of concerns and error handling
- **Auditability**: Complete tracking of changes and conflicts
- **Flexibility**: Multiple patterns for different requirements

### Negative

- **Complexity**: Multiple patterns increase cognitive load
- **Error Handling**: More complex error scenarios to handle
- **Performance Overhead**: Some patterns have higher overhead
- **Lock Contention**: Pessimistic locking can create bottlenecks
- **Retry Logic**: Additional complexity for handling conflicts

## Related Patterns

- **Optimistic Locking**: For handling concurrent modifications
- **Event Sourcing**: For complete audit trails
- **Saga Pattern**: For distributed transaction management
- **State Machine**: For complex state transitions
- **CQRS**: For separating read and write operations
- **Database Migration**: For schema evolution with data changes
