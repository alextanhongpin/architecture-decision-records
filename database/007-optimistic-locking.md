# Optimistic Locking

## Status

`accepted`

## Context

Optimistic locking is a concurrency control mechanism that allows multiple transactions to proceed without blocking each other, based on the assumption that conflicts are rare. Before committing changes, each transaction verifies that the data hasn't been modified by another transaction since it was read.

### Concurrency Control Comparison

| Strategy | When to Use | Pros | Cons | Performance Impact |
|----------|-------------|------|------|-------------------|
| **Optimistic Locking** | Low conflict scenarios, read-heavy workloads | High concurrency, no blocking | Retry complexity, potential data loss | Low overhead |
| **Pessimistic Locking** | High conflict scenarios, critical updates | Guaranteed consistency | Reduced concurrency, deadlock risk | Higher overhead |
| **No Locking** | Read-only, eventual consistency acceptable | Maximum performance | No consistency guarantees | Minimal |

### Optimistic Locking Mechanisms

1. **Version Columns**: Integer version numbers incremented on each update
2. **Timestamp Columns**: Last modified timestamps for change detection
3. **Checksum/Hash**: Hash of record contents for integrity verification
4. **Field-Level Versioning**: Granular versioning for specific fields
5. **ETag-based**: Web-friendly entity tags for HTTP APIs

## Decision

Implement **version-based optimistic locking** as the primary strategy with the following architecture:

### Core Implementation Strategy

1. **Version Column Pattern**: Add `version` integer column to all critical tables
2. **Automatic Increment**: Version increments automatically on each update
3. **Conditional Updates**: Updates succeed only if version matches expected value
4. **Retry Logic**: Application-level retry with exponential backoff
5. **Conflict Resolution**: Configurable merge strategies for concurrent modifications

### Database Schema Design

```sql
-- Base table with version column
CREATE TABLE products (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    stock_quantity INTEGER NOT NULL DEFAULT 0,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Index on version for performance
CREATE INDEX idx_products_version ON products(id, version);

-- Trigger to auto-increment version
CREATE OR REPLACE FUNCTION increment_version()
RETURNS TRIGGER AS $$
BEGIN
    NEW.version = OLD.version + 1;
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER products_version_trigger
    BEFORE UPDATE ON products
    FOR EACH ROW
    EXECUTE FUNCTION increment_version();
```

## Implementation

### Go Optimistic Locking Framework

```go
package optimistic

import (
    "context"
    "database/sql"
    "fmt"
    "time"
)

// Versionable represents an entity that supports optimistic locking
type Versionable interface {
    GetID() int64
    GetVersion() int
    SetVersion(version int)
}

// ConflictError represents an optimistic locking conflict
type ConflictError struct {
    EntityID       int64
    ExpectedVersion int
    ActualVersion   int
    Message        string
}

func (e *ConflictError) Error() string {
    return fmt.Sprintf("optimistic lock conflict for entity %d: expected version %d, got %d - %s",
        e.EntityID, e.ExpectedVersion, e.ActualVersion, e.Message)
}

// OptimisticLocker provides optimistic locking capabilities
type OptimisticLocker struct {
    db     *sql.DB
    maxRetries int
    backoff    BackoffStrategy
}

type BackoffStrategy func(attempt int) time.Duration

// ExponentialBackoff implements exponential backoff with jitter
func ExponentialBackoff(baseDelay time.Duration) BackoffStrategy {
    return func(attempt int) time.Duration {
        if attempt == 0 {
            return 0
        }
        delay := baseDelay * time.Duration(1<<uint(attempt-1))
        // Add jitter (up to 10% of delay)
        jitter := time.Duration(rand.Int63n(int64(delay / 10)))
        return delay + jitter
    }
}

func NewOptimisticLocker(db *sql.DB) *OptimisticLocker {
    return &OptimisticLocker{
        db:         db,
        maxRetries: 3,
        backoff:    ExponentialBackoff(10 * time.Millisecond),
    }
}

// UpdateWithRetry executes an update with optimistic locking and retry logic
func (ol *OptimisticLocker) UpdateWithRetry(ctx context.Context, 
    entity Versionable, updateFn UpdateFunction) error {
    
    var lastErr error
    
    for attempt := 0; attempt <= ol.maxRetries; attempt++ {
        if attempt > 0 {
            select {
            case <-ctx.Done():
                return ctx.Err()
            case <-time.After(ol.backoff(attempt)):
                // Continue with retry
            }
        }
        
        // Refresh entity to get latest version
        if err := ol.refreshEntity(ctx, entity); err != nil {
            return fmt.Errorf("failed to refresh entity: %w", err)
        }
        
        // Execute update function
        if err := updateFn(ctx, entity); err != nil {
            return fmt.Errorf("update function failed: %w", err)
        }
        
        // Attempt optimistic update
        if err := ol.optimisticUpdate(ctx, entity); err != nil {
            if IsConflictError(err) {
                lastErr = err
                continue // Retry
            }
            return err // Non-conflict error
        }
        
        return nil // Success
    }
    
    return fmt.Errorf("max retries exceeded: %w", lastErr)
}

type UpdateFunction func(ctx context.Context, entity Versionable) error

// optimisticUpdate performs the actual database update with version check
func (ol *OptimisticLocker) optimisticUpdate(ctx context.Context, entity Versionable) error {
    query := `
        UPDATE products 
        SET name = $1, price = $2, stock_quantity = $3, version = version + 1, updated_at = NOW()
        WHERE id = $4 AND version = $5
        RETURNING version
    `
    
    var newVersion int
    err := ol.db.QueryRowContext(ctx, query,
        entity.(*Product).Name,
        entity.(*Product).Price,
        entity.(*Product).StockQuantity,
        entity.GetID(),
        entity.GetVersion(),
    ).Scan(&newVersion)
    
    if err == sql.ErrNoRows {
        // Get current version for better error message
        currentVersion, _ := ol.getCurrentVersion(ctx, entity.GetID())
        return &ConflictError{
            EntityID:        entity.GetID(),
            ExpectedVersion: entity.GetVersion(),
            ActualVersion:   currentVersion,
            Message:        "entity was modified by another transaction",
        }
    }
    
    if err != nil {
        return fmt.Errorf("optimistic update failed: %w", err)
    }
    
    entity.SetVersion(newVersion)
    return nil
}

func IsConflictError(err error) bool {
    _, ok := err.(*ConflictError)
    return ok
}
```

### Product Entity with Optimistic Locking

```go
package model

import (
    "context"
    "time"
)

type Product struct {
    ID            int64     `json:"id" db:"id"`
    Name          string    `json:"name" db:"name"`
    Price         float64   `json:"price" db:"price"`
    StockQuantity int       `json:"stock_quantity" db:"stock_quantity"`
    Version       int       `json:"version" db:"version"`
    CreatedAt     time.Time `json:"created_at" db:"created_at"`
    UpdatedAt     time.Time `json:"updated_at" db:"updated_at"`
}

func (p *Product) GetID() int64 {
    return p.ID
}

func (p *Product) GetVersion() int {
    return p.Version
}

func (p *Product) SetVersion(version int) {
    p.Version = version
}

// ProductRepository handles product data operations
type ProductRepository struct {
    db     *sql.DB
    locker *optimistic.OptimisticLocker
}

func NewProductRepository(db *sql.DB) *ProductRepository {
    return &ProductRepository{
        db:     db,
        locker: optimistic.NewOptimisticLocker(db),
    }
}

// UpdateStock updates product stock with optimistic locking
func (pr *ProductRepository) UpdateStock(ctx context.Context, productID int64, 
    newQuantity int) (*Product, error) {
    
    product, err := pr.FindByID(ctx, productID)
    if err != nil {
        return nil, err
    }
    
    err = pr.locker.UpdateWithRetry(ctx, product, func(ctx context.Context, entity optimistic.Versionable) error {
        product := entity.(*Product)
        product.StockQuantity = newQuantity
        return nil
    })
    
    if err != nil {
        return nil, err
    }
    
    return product, nil
}

// DecrementStock decreases stock quantity safely
func (pr *ProductRepository) DecrementStock(ctx context.Context, productID int64, 
    quantity int) (*Product, error) {
    
    product, err := pr.FindByID(ctx, productID)
    if err != nil {
        return nil, err
    }
    
    err = pr.locker.UpdateWithRetry(ctx, product, func(ctx context.Context, entity optimistic.Versionable) error {
        product := entity.(*Product)
        
        if product.StockQuantity < quantity {
            return fmt.Errorf("insufficient stock: have %d, need %d", 
                product.StockQuantity, quantity)
        }
        
        product.StockQuantity -= quantity
        return nil
    })
    
    if err != nil {
        return nil, err
    }
    
    return product, nil
}

func (pr *ProductRepository) FindByID(ctx context.Context, id int64) (*Product, error) {
    query := `
        SELECT id, name, price, stock_quantity, version, created_at, updated_at
        FROM products
        WHERE id = $1
    `
    
    product := &Product{}
    err := pr.db.QueryRowContext(ctx, query, id).Scan(
        &product.ID,
        &product.Name,
        &product.Price,
        &product.StockQuantity,
        &product.Version,
        &product.CreatedAt,
        &product.UpdatedAt,
    )
    
    if err != nil {
        return nil, err
    }
    
    return product, nil
}
```

### Advanced Conflict Resolution

```go
package optimistic

// ConflictResolutionStrategy defines how to handle optimistic lock conflicts
type ConflictResolutionStrategy int

const (
    StrategyFail ConflictResolutionStrategy = iota
    StrategyRetry
    StrategyMerge
    StrategyOverwrite
)

// ConflictResolver handles different conflict resolution strategies
type ConflictResolver struct {
    strategy ConflictResolutionStrategy
    mergeFn  MergeFunction
}

type MergeFunction func(current, incoming Versionable) (Versionable, error)

// ThreeWayMerge attempts to merge changes from multiple sources
func ThreeWayMerge(base, current, incoming *Product) (*Product, error) {
    merged := &Product{
        ID:      current.ID,
        Version: current.Version,
    }
    
    // Merge name: prefer incoming if changed from base
    if incoming.Name != base.Name {
        merged.Name = incoming.Name
    } else {
        merged.Name = current.Name
    }
    
    // Merge price: prefer incoming if changed from base
    if incoming.Price != base.Price {
        merged.Price = incoming.Price
    } else {
        merged.Price = current.Price
    }
    
    // Merge stock: add delta if both changed
    if incoming.StockQuantity != base.StockQuantity && current.StockQuantity != base.StockQuantity {
        incomingDelta := incoming.StockQuantity - base.StockQuantity
        merged.StockQuantity = current.StockQuantity + incomingDelta
    } else if incoming.StockQuantity != base.StockQuantity {
        merged.StockQuantity = incoming.StockQuantity
    } else {
        merged.StockQuantity = current.StockQuantity
    }
    
    return merged, nil
}
```

### Timestamp-Based Optimistic Locking

```go
package optimistic

import (
    "time"
)

// TimestampEntity uses last-modified timestamps for optimistic locking
type TimestampEntity struct {
    ID          int64     `json:"id"`
    Name        string    `json:"name"`
    LastModified time.Time `json:"last_modified"`
}

// UpdateWithTimestamp performs optimistic update using timestamp
func (ol *OptimisticLocker) UpdateWithTimestamp(ctx context.Context, 
    entity *TimestampEntity, updates map[string]interface{}) error {
    
    query := `
        UPDATE entities 
        SET name = $1, last_modified = NOW()
        WHERE id = $2 AND last_modified = $3
        RETURNING last_modified
    `
    
    var newTimestamp time.Time
    err := ol.db.QueryRowContext(ctx, query,
        updates["name"],
        entity.ID,
        entity.LastModified,
    ).Scan(&newTimestamp)
    
    if err == sql.ErrNoRows {
        return &ConflictError{
            EntityID: entity.ID,
            Message:  "entity was modified since last read",
        }
    }
    
    if err != nil {
        return err
    }
    
    entity.LastModified = newTimestamp
    return nil
}
```

### HTTP API Integration

```go
package api

import (
    "encoding/json"
    "net/http"
    "strconv"
)

// ProductHandler handles HTTP requests for products
type ProductHandler struct {
    repo *ProductRepository
}

// UpdateProduct handles product updates with optimistic locking
func (ph *ProductHandler) UpdateProduct(w http.ResponseWriter, r *http.Request) {
    productID, _ := strconv.ParseInt(r.URL.Query().Get("id"), 10, 64)
    
    var updateRequest struct {
        Name          string  `json:"name"`
        Price         float64 `json:"price"`
        StockQuantity int     `json:"stock_quantity"`
        Version       int     `json:"version"`
    }
    
    if err := json.NewDecoder(r.Body).Decode(&updateRequest); err != nil {
        http.Error(w, "Invalid request body", http.StatusBadRequest)
        return
    }
    
    product := &Product{
        ID:            productID,
        Name:          updateRequest.Name,
        Price:         updateRequest.Price,
        StockQuantity: updateRequest.StockQuantity,
        Version:       updateRequest.Version,
    }
    
    err := ph.repo.locker.UpdateWithRetry(r.Context(), product, 
        func(ctx context.Context, entity optimistic.Versionable) error {
            // Update logic here
            return nil
        })
    
    if err != nil {
        if IsConflictError(err) {
            w.Header().Set("Content-Type", "application/json")
            w.WriteHeader(http.StatusConflict)
            json.NewEncoder(w).Encode(map[string]interface{}{
                "error": "Conflict: Resource was modified by another request",
                "code":  "OPTIMISTIC_LOCK_CONFLICT",
                "details": err.Error(),
            })
            return
        }
        
        http.Error(w, "Internal server error", http.StatusInternalServerError)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(product)
}
```

### Monitoring and Metrics

```go
package monitoring

import (
    "context"
    "time"
    "github.com/prometheus/client_golang/prometheus"
)

var (
    optimisticLockConflicts = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "optimistic_lock_conflicts_total",
            Help: "Total number of optimistic lock conflicts",
        },
        []string{"entity_type", "operation"},
    )
    
    optimisticLockRetries = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "optimistic_lock_retries",
            Help: "Number of retries for optimistic lock operations",
            Buckets: prometheus.LinearBuckets(0, 1, 6),
        },
        []string{"entity_type", "operation"},
    )
    
    optimisticLockDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "optimistic_lock_duration_seconds",
            Help: "Duration of optimistic lock operations",
            Buckets: prometheus.ExponentialBuckets(0.001, 2, 10),
        },
        []string{"entity_type", "operation", "result"},
    )
)

// InstrumentedOptimisticLocker adds monitoring to optimistic locking
type InstrumentedOptimisticLocker struct {
    *OptimisticLocker
    entityType string
}

func NewInstrumentedOptimisticLocker(locker *OptimisticLocker, entityType string) *InstrumentedOptimisticLocker {
    return &InstrumentedOptimisticLocker{
        OptimisticLocker: locker,
        entityType:       entityType,
    }
}

func (iol *InstrumentedOptimisticLocker) UpdateWithRetry(ctx context.Context, 
    entity Versionable, updateFn UpdateFunction) error {
    
    start := time.Now()
    operation := "update"
    attempts := 0
    
    defer func() {
        duration := time.Since(start).Seconds()
        optimisticLockDuration.WithLabelValues(iol.entityType, operation, "completed").Observe(duration)
        optimisticLockRetries.WithLabelValues(iol.entityType, operation).Observe(float64(attempts))
    }()
    
    var lastErr error
    
    for attempt := 0; attempt <= iol.maxRetries; attempt++ {
        attempts = attempt + 1
        
        if attempt > 0 {
            optimisticLockConflicts.WithLabelValues(iol.entityType, operation).Inc()
            
            select {
            case <-ctx.Done():
                return ctx.Err()
            case <-time.After(iol.backoff(attempt)):
                // Continue with retry
            }
        }
        
        // Original update logic...
        if err := iol.OptimisticLocker.UpdateWithRetry(ctx, entity, updateFn); err != nil {
            if IsConflictError(err) {
                lastErr = err
                continue
            }
            return err
        }
        
        return nil
    }
    
    return lastErr
}
```

### Testing Optimistic Locking

```go
package optimistic_test

import (
    "context"
    "sync"
    "testing"
    "time"
)

func TestOptimisticLockingConcurrency(t *testing.T) {
    suite := dbtest.NewTestSuite(t)
    defer suite.Cleanup()
    
    repo := NewProductRepository(suite.DB())
    
    // Create test product
    product := &Product{
        Name:          "Test Product",
        Price:         10.00,
        StockQuantity: 100,
    }
    
    // Insert product
    _, err := suite.DB().ExecContext(suite.Context(),
        "INSERT INTO products (name, price, stock_quantity) VALUES ($1, $2, $3)",
        product.Name, product.Price, product.StockQuantity)
    if err != nil {
        t.Fatal(err)
    }
    
    // Test concurrent updates
    const numGoroutines = 10
    const decrementAmount = 5
    
    var wg sync.WaitGroup
    errors := make(chan error, numGoroutines)
    
    for i := 0; i < numGoroutines; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            
            _, err := repo.DecrementStock(context.Background(), 1, decrementAmount)
            if err != nil {
                errors <- err
            }
        }()
    }
    
    wg.Wait()
    close(errors)
    
    // Check for conflicts (some operations should fail due to conflicts)
    conflictCount := 0
    for err := range errors {
        if IsConflictError(err) {
            conflictCount++
        } else if err != nil {
            t.Errorf("Unexpected error: %v", err)
        }
    }
    
    // Verify final stock quantity
    finalProduct, err := repo.FindByID(context.Background(), 1)
    if err != nil {
        t.Fatal(err)
    }
    
    // Should have decremented successfully for some operations
    expectedStock := 100 - (decrementAmount * (numGoroutines - conflictCount))
    if finalProduct.StockQuantity != expectedStock {
        t.Errorf("Expected stock %d, got %d", expectedStock, finalProduct.StockQuantity)
    }
    
    t.Logf("Conflicts encountered: %d out of %d operations", conflictCount, numGoroutines)
}

func TestOptimisticLockingVersionIncrement(t *testing.T) {
    suite := dbtest.NewTestSuite(t)
    defer suite.Cleanup()
    
    repo := NewProductRepository(suite.DB())
    
    // Create and insert product
    product, err := repo.Create(suite.Context(), &Product{
        Name:          "Version Test",
        Price:         5.00,
        StockQuantity: 50,
    })
    if err != nil {
        t.Fatal(err)
    }
    
    initialVersion := product.Version
    
    // Update product
    _, err = repo.UpdateStock(suite.Context(), product.ID, 45)
    if err != nil {
        t.Fatal(err)
    }
    
    // Verify version incremented
    updatedProduct, err := repo.FindByID(suite.Context(), product.ID)
    if err != nil {
        t.Fatal(err)
    }
    
    if updatedProduct.Version != initialVersion+1 {
        t.Errorf("Expected version %d, got %d", initialVersion+1, updatedProduct.Version)
    }
    
    if updatedProduct.StockQuantity != 45 {
        t.Errorf("Expected stock 45, got %d", updatedProduct.StockQuantity)
    }
}
```

## Consequences

### Positive

- **High Concurrency**: No blocking locks, multiple transactions can proceed simultaneously
- **Deadlock Prevention**: No risk of deadlocks since no locks are held
- **Performance**: Lower overhead compared to pessimistic locking
- **Scalability**: Better horizontal scaling characteristics
- **Flexibility**: Easy to implement retry logic and conflict resolution strategies

### Negative

- **Conflict Resolution Complexity**: Applications must handle version conflicts gracefully
- **Potential Data Loss**: Lost updates if conflicts aren't handled properly
- **Retry Logic Required**: Exponential backoff and retry mechanisms needed
- **Version Management**: Additional storage and complexity for version tracking
- **Race Conditions**: Possible ABA problems in edge cases

### Mitigations

- **Comprehensive Testing**: Test concurrent scenarios thoroughly
- **Monitoring**: Track conflict rates and retry patterns
- **Graceful Degradation**: Fallback strategies for high-conflict scenarios
- **User Experience**: Clear error messages and conflict resolution options
- **Performance Monitoring**: Monitor retry overhead and optimize backoff strategies

## Related Patterns

- **[Pessimistic Locking](008-pessimistic-locking.md)**: Alternative concurrency control strategy
- **[State Machine](010-state-machine.md)**: Managing state transitions with version control
- **[Idempotency](011-idempotency.md)**: Ensuring operations can be safely retried
- **[Docker Testing](004-dockertest.md)**: Testing concurrent scenarios in isolation
