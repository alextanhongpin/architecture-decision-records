# Pessimistic Locking Strategies

## Status
**Accepted**

## Context
Pessimistic locking ensures exclusive access to resources by acquiring locks before performing operations, preventing concurrent modifications and race conditions. This is critical for:

- **Financial transactions** where concurrent access could lead to data inconsistency
- **Inventory management** to prevent overselling
- **Job processing** to ensure single execution
- **Resource allocation** in distributed systems
- **Critical sections** that must be executed atomically

Traditional table-level locking can severely impact database performance and scalability. We need granular locking mechanisms that provide data integrity without blocking the entire table or database.

## Decision
We will implement pessimistic locking using multiple strategies based on the use case:
1. **PostgreSQL Advisory Locks** for database-level coordination
2. **Redis Distributed Locks (Redlock)** for cross-service coordination
3. **Row-level SELECT FOR UPDATE** for transaction-scoped locking
4. **Application-level semaphores** for in-memory coordination

## Implementation

### 1. PostgreSQL Advisory Locks

```go
// pkg/locking/advisory.go
package locking

import (
    "context"
    "database/sql"
    "fmt"
    "hash/fnv"
    "time"
)

type AdvisoryLock struct {
    db      *sql.DB
    timeout time.Duration
}

func NewAdvisoryLock(db *sql.DB) *AdvisoryLock {
    return &AdvisoryLock{
        db:      db,
        timeout: 30 * time.Second,
    }
}

// Lock acquires an advisory lock with automatic timeout
func (al *AdvisoryLock) Lock(ctx context.Context, lockName string) (*LockHandle, error) {
    lockID := al.generateLockID(lockName)
    
    // Try to acquire lock with timeout
    timeoutCtx, cancel := context.WithTimeout(ctx, al.timeout)
    defer cancel()
    
    var acquired bool
    err := al.db.QueryRowContext(timeoutCtx, 
        "SELECT pg_try_advisory_lock($1)", lockID).Scan(&acquired)
    if err != nil {
        return nil, fmt.Errorf("failed to acquire advisory lock: %w", err)
    }
    
    if !acquired {
        return nil, fmt.Errorf("could not acquire lock '%s' within timeout", lockName)
    }
    
    return &LockHandle{
        lockID:   lockID,
        lockName: lockName,
        db:       al.db,
        acquired: time.Now(),
    }, nil
}

// LockWithWait acquires lock and waits if necessary
func (al *AdvisoryLock) LockWithWait(ctx context.Context, lockName string) (*LockHandle, error) {
    lockID := al.generateLockID(lockName)
    
    var acquired bool
    err := al.db.QueryRowContext(ctx, 
        "SELECT pg_advisory_lock($1)", lockID).Scan(&acquired)
    if err != nil {
        return nil, fmt.Errorf("failed to acquire advisory lock with wait: %w", err)
    }
    
    return &LockHandle{
        lockID:   lockID,
        lockName: lockName,
        db:       al.db,
        acquired: time.Now(),
    }, nil
}

func (al *AdvisoryLock) generateLockID(lockName string) int64 {
    h := fnv.New64a()
    h.Write([]byte(lockName))
    return int64(h.Sum64())
}

type LockHandle struct {
    lockID   int64
    lockName string
    db       *sql.DB
    acquired time.Time
    released bool
}

func (lh *LockHandle) Release() error {
    if lh.released {
        return fmt.Errorf("lock '%s' already released", lh.lockName)
    }
    
    var released bool
    err := lh.db.QueryRow("SELECT pg_advisory_unlock($1)", lh.lockID).Scan(&released)
    if err != nil {
        return fmt.Errorf("failed to release advisory lock: %w", err)
    }
    
    if !released {
        return fmt.Errorf("failed to release lock '%s' - was it already released?", lh.lockName)
    }
    
    lh.released = true
    return nil
}

func (lh *LockHandle) HeldDuration() time.Duration {
    return time.Since(lh.acquired)
}

// WithLock executes function with acquired lock
func (al *AdvisoryLock) WithLock(ctx context.Context, lockName string, fn func() error) error {
    lock, err := al.Lock(ctx, lockName)
    if err != nil {
        return err
    }
    defer lock.Release()
    
    return fn()
}
```

### 2. Redis Distributed Locks (Redlock Algorithm)

```go
// pkg/locking/redis.go
package locking

import (
    "context"
    "crypto/rand"
    "encoding/hex"
    "fmt"
    "time"
    
    "github.com/go-redis/redis/v8"
)

type RedisLock struct {
    clients   []redis.Cmdable
    keyPrefix string
    ttl       time.Duration
}

func NewRedisLock(clients []redis.Cmdable) *RedisLock {
    return &RedisLock{
        clients:   clients,
        keyPrefix: "redlock:",
        ttl:       30 * time.Second,
    }
}

func (rl *RedisLock) Lock(ctx context.Context, resource string) (*RedisLockHandle, error) {
    value := rl.generateValue()
    key := rl.keyPrefix + resource
    
    start := time.Now()
    quorum := len(rl.clients)/2 + 1
    acquired := 0
    
    // Try to acquire lock on majority of Redis instances
    for _, client := range rl.clients {
        success, err := rl.acquireLock(ctx, client, key, value, rl.ttl)
        if err == nil && success {
            acquired++
        }
    }
    
    // Check if we have quorum and sufficient time remaining
    elapsed := time.Since(start)
    if acquired >= quorum && elapsed < rl.ttl {
        return &RedisLockHandle{
            key:      key,
            value:    value,
            clients:  rl.clients,
            acquired: time.Now(),
            ttl:      rl.ttl,
        }, nil
    }
    
    // Failed to acquire quorum, release any acquired locks
    rl.releaseLocks(ctx, key, value)
    return nil, fmt.Errorf("failed to acquire distributed lock for resource '%s'", resource)
}

func (rl *RedisLock) acquireLock(ctx context.Context, client redis.Cmdable, key, value string, ttl time.Duration) (bool, error) {
    result, err := client.SetNX(ctx, key, value, ttl).Result()
    return result, err
}

func (rl *RedisLock) releaseLocks(ctx context.Context, key, value string) {
    script := `
        if redis.call("get", KEYS[1]) == ARGV[1] then
            return redis.call("del", KEYS[1])
        else
            return 0
        end
    `
    
    for _, client := range rl.clients {
        client.Eval(ctx, script, []string{key}, value)
    }
}

func (rl *RedisLock) generateValue() string {
    b := make([]byte, 16)
    rand.Read(b)
    return hex.EncodeToString(b)
}

type RedisLockHandle struct {
    key      string
    value    string
    clients  []redis.Cmdable
    acquired time.Time
    ttl      time.Duration
    released bool
}

func (rlh *RedisLockHandle) Release(ctx context.Context) error {
    if rlh.released {
        return fmt.Errorf("lock already released")
    }
    
    script := `
        if redis.call("get", KEYS[1]) == ARGV[1] then
            return redis.call("del", KEYS[1])
        else
            return 0
        end
    `
    
    released := 0
    for _, client := range rlh.clients {
        result, err := client.Eval(ctx, script, []string{rlh.key}, rlh.value).Int()
        if err == nil && result == 1 {
            released++
        }
    }
    
    rlh.released = true
    
    if released == 0 {
        return fmt.Errorf("failed to release any locks - they may have expired")
    }
    
    return nil
}

func (rlh *RedisLockHandle) Extend(ctx context.Context, extension time.Duration) error {
    script := `
        if redis.call("get", KEYS[1]) == ARGV[1] then
            return redis.call("pexpire", KEYS[1], ARGV[2])
        else
            return 0
        end
    `
    
    extended := 0
    extensionMs := int64(extension / time.Millisecond)
    
    for _, client := range rlh.clients {
        result, err := client.Eval(ctx, script, []string{rlh.key}, rlh.value, extensionMs).Int()
        if err == nil && result == 1 {
            extended++
        }
    }
    
    quorum := len(rlh.clients)/2 + 1
    if extended >= quorum {
        rlh.ttl = extension
        return nil
    }
    
    return fmt.Errorf("failed to extend lock on majority of instances")
}

func (rlh *RedisLockHandle) IsExpired() bool {
    return time.Since(rlh.acquired) >= rlh.ttl
}
```

### 3. Row-Level Locking with SELECT FOR UPDATE

```go
// pkg/locking/rowlock.go
package locking

import (
    "context"
    "database/sql"
    "fmt"
)

type RowLock struct {
    db *sql.DB
}

func NewRowLock(db *sql.DB) *RowLock {
    return &RowLock{db: db}
}

// LockUser locks a specific user record for update
func (rl *RowLock) LockUser(ctx context.Context, userID int) (*UserLock, error) {
    tx, err := rl.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("failed to begin transaction: %w", err)
    }
    
    var user User
    err = tx.QueryRowContext(ctx, `
        SELECT id, username, email, balance, version 
        FROM users 
        WHERE id = $1 
        FOR UPDATE
    `, userID).Scan(&user.ID, &user.Username, &user.Email, &user.Balance, &user.Version)
    
    if err != nil {
        tx.Rollback()
        return nil, fmt.Errorf("failed to lock user: %w", err)
    }
    
    return &UserLock{
        tx:   tx,
        user: user,
    }, nil
}

// LockInventoryItem locks inventory for update
func (rl *RowLock) LockInventoryItem(ctx context.Context, itemID int) (*InventoryLock, error) {
    tx, err := rl.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("failed to begin transaction: %w", err)
    }
    
    var item InventoryItem
    err = tx.QueryRowContext(ctx, `
        SELECT id, name, quantity, reserved_quantity, version
        FROM inventory_items 
        WHERE id = $1 
        FOR UPDATE
    `, itemID).Scan(&item.ID, &item.Name, &item.Quantity, &item.ReservedQuantity, &item.Version)
    
    if err != nil {
        tx.Rollback()
        return nil, fmt.Errorf("failed to lock inventory item: %w", err)
    }
    
    return &InventoryLock{
        tx:   tx,
        item: item,
    }, nil
}

type UserLock struct {
    tx   *sql.Tx
    user User
}

func (ul *UserLock) GetUser() User {
    return ul.user
}

func (ul *UserLock) UpdateBalance(ctx context.Context, newBalance float64) error {
    _, err := ul.tx.ExecContext(ctx, `
        UPDATE users 
        SET balance = $1, version = version + 1 
        WHERE id = $2 AND version = $3
    `, newBalance, ul.user.ID, ul.user.Version)
    
    if err != nil {
        return fmt.Errorf("failed to update user balance: %w", err)
    }
    
    ul.user.Balance = newBalance
    ul.user.Version++
    return nil
}

func (ul *UserLock) Commit() error {
    return ul.tx.Commit()
}

func (ul *UserLock) Rollback() error {
    return ul.tx.Rollback()
}

type InventoryLock struct {
    tx   *sql.Tx
    item InventoryItem
}

func (il *InventoryLock) GetItem() InventoryItem {
    return il.item
}

func (il *InventoryLock) ReserveQuantity(ctx context.Context, quantity int) error {
    if il.item.Quantity-il.item.ReservedQuantity < quantity {
        return fmt.Errorf("insufficient quantity available")
    }
    
    newReserved := il.item.ReservedQuantity + quantity
    _, err := il.tx.ExecContext(ctx, `
        UPDATE inventory_items 
        SET reserved_quantity = $1, version = version + 1 
        WHERE id = $2 AND version = $3
    `, newReserved, il.item.ID, il.item.Version)
    
    if err != nil {
        return fmt.Errorf("failed to reserve quantity: %w", err)
    }
    
    il.item.ReservedQuantity = newReserved
    il.item.Version++
    return nil
}

func (il *InventoryLock) Commit() error {
    return il.tx.Commit()
}

func (il *InventoryLock) Rollback() error {
    return il.tx.Rollback()
}

type User struct {
    ID       int     `json:"id"`
    Username string  `json:"username"`
    Email    string  `json:"email"`
    Balance  float64 `json:"balance"`
    Version  int     `json:"version"`
}

type InventoryItem struct {
    ID               int    `json:"id"`
    Name            string  `json:"name"`
    Quantity        int     `json:"quantity"`
    ReservedQuantity int     `json:"reserved_quantity"`
    Version         int     `json:"version"`
}
```

### 4. High-Level Lock Manager

```go
// pkg/locking/manager.go
package locking

import (
    "context"
    "fmt"
    "sync"
    "time"
)

type LockManager struct {
    advisoryLock *AdvisoryLock
    redisLock    *RedisLock
    rowLock      *RowLock
    
    // In-memory locks for single-instance coordination
    mutexes map[string]*sync.RWMutex
    mu      sync.RWMutex
}

func NewLockManager(advisoryLock *AdvisoryLock, redisLock *RedisLock, rowLock *RowLock) *LockManager {
    return &LockManager{
        advisoryLock: advisoryLock,
        redisLock:    redisLock,
        rowLock:      rowLock,
        mutexes:      make(map[string]*sync.RWMutex),
    }
}

// AcquireDistributedLock for cross-service coordination
func (lm *LockManager) AcquireDistributedLock(ctx context.Context, resource string) (*RedisLockHandle, error) {
    return lm.redisLock.Lock(ctx, resource)
}

// AcquireDatabaseLock for database-level coordination
func (lm *LockManager) AcquireDatabaseLock(ctx context.Context, lockName string) (*LockHandle, error) {
    return lm.advisoryLock.Lock(ctx, lockName)
}

// AcquireRowLock for transaction-scoped locking
func (lm *LockManager) AcquireUserLock(ctx context.Context, userID int) (*UserLock, error) {
    return lm.rowLock.LockUser(ctx, userID)
}

// AcquireInMemoryLock for single-instance coordination
func (lm *LockManager) AcquireInMemoryLock(resource string) func() {
    lm.mu.Lock()
    mutex, exists := lm.mutexes[resource]
    if !exists {
        mutex = &sync.RWMutex{}
        lm.mutexes[resource] = mutex
    }
    lm.mu.Unlock()
    
    mutex.Lock()
    return mutex.Unlock
}

// High-level business operations with appropriate locking
func (lm *LockManager) TransferMoney(ctx context.Context, fromUserID, toUserID int, amount float64) error {
    // Use distributed lock to prevent deadlocks with ordered locking
    lockKey := fmt.Sprintf("transfer:%d:%d", min(fromUserID, toUserID), max(fromUserID, toUserID))
    
    return lm.advisoryLock.WithLock(ctx, lockKey, func() error {
        // Lock both users in consistent order
        fromLock, err := lm.rowLock.LockUser(ctx, fromUserID)
        if err != nil {
            return err
        }
        defer fromLock.Rollback()
        
        toLock, err := lm.rowLock.LockUser(ctx, toUserID)
        if err != nil {
            return err
        }
        defer toLock.Rollback()
        
        // Perform transfer
        fromUser := fromLock.GetUser()
        if fromUser.Balance < amount {
            return fmt.Errorf("insufficient balance")
        }
        
        toUser := toLock.GetUser()
        
        if err := fromLock.UpdateBalance(ctx, fromUser.Balance-amount); err != nil {
            return err
        }
        
        if err := toLock.UpdateBalance(ctx, toUser.Balance+amount); err != nil {
            return err
        }
        
        // Commit both transactions
        if err := fromLock.Commit(); err != nil {
            return err
        }
        
        return toLock.Commit()
    })
}

func min(a, b int) int {
    if a < b {
        return a
    }
    return b
}

func max(a, b int) int {
    if a > b {
        return a
    }
    return b
}

// ProcessInventoryOrder with pessimistic locking
func (lm *LockManager) ProcessInventoryOrder(ctx context.Context, itemID, quantity int) error {
    inventoryLock, err := lm.rowLock.LockInventoryItem(ctx, itemID)
    if err != nil {
        return err
    }
    defer inventoryLock.Rollback()
    
    if err := inventoryLock.ReserveQuantity(ctx, quantity); err != nil {
        return err
    }
    
    return inventoryLock.Commit()
}
```

### 5. Lock Monitoring and Metrics

```go
// pkg/locking/monitoring.go
package locking

import (
    "log"
    "sync"
    "time"
)

type LockMonitor struct {
    metrics map[string]*LockMetrics
    mu      sync.RWMutex
}

type LockMetrics struct {
    AcquisitionCount    int64
    AcquisitionFailures int64
    TotalWaitTime       time.Duration
    MaxWaitTime         time.Duration
    AverageHoldTime     time.Duration
    ActiveLocks         int64
}

func NewLockMonitor() *LockMonitor {
    return &LockMonitor{
        metrics: make(map[string]*LockMetrics),
    }
}

func (lm *LockMonitor) RecordAcquisition(lockName string, waitTime, holdTime time.Duration, success bool) {
    lm.mu.Lock()
    defer lm.mu.Unlock()
    
    metrics, exists := lm.metrics[lockName]
    if !exists {
        metrics = &LockMetrics{}
        lm.metrics[lockName] = metrics
    }
    
    if success {
        metrics.AcquisitionCount++
        metrics.TotalWaitTime += waitTime
        if waitTime > metrics.MaxWaitTime {
            metrics.MaxWaitTime = waitTime
        }
        
        // Update average hold time
        if metrics.AcquisitionCount > 1 {
            metrics.AverageHoldTime = (metrics.AverageHoldTime*time.Duration(metrics.AcquisitionCount-1) + holdTime) / time.Duration(metrics.AcquisitionCount)
        } else {
            metrics.AverageHoldTime = holdTime
        }
    } else {
        metrics.AcquisitionFailures++
    }
}

func (lm *LockMonitor) IncrementActiveLocks(lockName string) {
    lm.mu.Lock()
    defer lm.mu.Unlock()
    
    metrics, exists := lm.metrics[lockName]
    if !exists {
        metrics = &LockMetrics{}
        lm.metrics[lockName] = metrics
    }
    
    metrics.ActiveLocks++
}

func (lm *LockMonitor) DecrementActiveLocks(lockName string) {
    lm.mu.Lock()
    defer lm.mu.Unlock()
    
    if metrics, exists := lm.metrics[lockName]; exists {
        metrics.ActiveLocks--
    }
}

func (lm *LockMonitor) GetMetrics(lockName string) *LockMetrics {
    lm.mu.RLock()
    defer lm.mu.RUnlock()
    
    if metrics, exists := lm.metrics[lockName]; exists {
        // Return a copy to avoid race conditions
        return &LockMetrics{
            AcquisitionCount:    metrics.AcquisitionCount,
            AcquisitionFailures: metrics.AcquisitionFailures,
            TotalWaitTime:       metrics.TotalWaitTime,
            MaxWaitTime:         metrics.MaxWaitTime,
            AverageHoldTime:     metrics.AverageHoldTime,
            ActiveLocks:         metrics.ActiveLocks,
        }
    }
    
    return &LockMetrics{}
}

func (lm *LockMonitor) LogMetrics() {
    lm.mu.RLock()
    defer lm.mu.RUnlock()
    
    for lockName, metrics := range lm.metrics {
        log.Printf("Lock: %s, Acquisitions: %d, Failures: %d, Active: %d, Avg Hold Time: %v",
            lockName, metrics.AcquisitionCount, metrics.AcquisitionFailures, 
            metrics.ActiveLocks, metrics.AverageHoldTime)
    }
}
```

### 6. Usage Examples

```go
// Example: Financial transaction with pessimistic locking
func TransferMoney(ctx context.Context, lm *LockManager, fromID, toID int, amount float64) error {
    return lm.TransferMoney(ctx, fromID, toID, amount)
}

// Example: Job processing with distributed locking
func ProcessJob(ctx context.Context, redisLock *RedisLock, jobID string) error {
    lockKey := fmt.Sprintf("job:%s", jobID)
    
    lock, err := redisLock.Lock(ctx, lockKey)
    if err != nil {
        return fmt.Errorf("job already being processed: %w", err)
    }
    defer lock.Release(ctx)
    
    // Process job exclusively
    log.Printf("Processing job %s", jobID)
    time.Sleep(5 * time.Second) // Simulate work
    log.Printf("Completed job %s", jobID)
    
    return nil
}

// Example: Critical section with advisory lock
func UpdateGlobalCounter(ctx context.Context, advisoryLock *AdvisoryLock, db *sql.DB) error {
    return advisoryLock.WithLock(ctx, "global_counter", func() error {
        var current int
        err := db.QueryRowContext(ctx, "SELECT value FROM global_counter WHERE id = 1").Scan(&current)
        if err != nil {
            return err
        }
        
        _, err = db.ExecContext(ctx, "UPDATE global_counter SET value = $1 WHERE id = 1", current+1)
        return err
    })
}
```

## Best Practices

### 1. Lock Selection Guidelines

| Use Case | Recommended Lock Type | Rationale |
|----------|----------------------|-----------|
| Financial transactions | Row-level (SELECT FOR UPDATE) | ACID compliance, data consistency |
| Distributed job processing | Redis Redlock | Cross-service coordination |
| Critical sections | PostgreSQL Advisory | Database-level coordination |
| Rate limiting | Redis locks | Performance, TTL support |
| In-memory coordination | sync.Mutex | Single instance, high performance |

### 2. Avoiding Deadlocks

```go
// Always acquire locks in consistent order
func OrderedLocking(ctx context.Context, lm *LockManager, userIDs []int) error {
    // Sort IDs to ensure consistent ordering
    sort.Ints(userIDs)
    
    var locks []*UserLock
    defer func() {
        // Release in reverse order
        for i := len(locks) - 1; i >= 0; i-- {
            locks[i].Rollback()
        }
    }()
    
    for _, userID := range userIDs {
        lock, err := lm.AcquireUserLock(ctx, userID)
        if err != nil {
            return err
        }
        locks = append(locks, lock)
    }
    
    // Perform operations...
    
    // Commit in original order
    for _, lock := range locks {
        if err := lock.Commit(); err != nil {
            return err
        }
    }
    
    return nil
}
```

### 3. Lock Timeout and Retry Strategies

```go
func AcquireLockWithRetry(ctx context.Context, redisLock *RedisLock, resource string, maxRetries int) (*RedisLockHandle, error) {
    backoff := time.Millisecond * 100
    
    for i := 0; i < maxRetries; i++ {
        lock, err := redisLock.Lock(ctx, resource)
        if err == nil {
            return lock, nil
        }
        
        if i < maxRetries-1 {
            select {
            case <-time.After(backoff):
                backoff *= 2 // Exponential backoff
            case <-ctx.Done():
                return nil, ctx.Err()
            }
        }
    }
    
    return nil, fmt.Errorf("failed to acquire lock after %d retries", maxRetries)
}
```

## Consequences

### Positive
- **Data Consistency**: Prevents race conditions and ensures data integrity
- **Controlled Access**: Guarantees exclusive access to critical resources
- **Scalability**: Different lock types support various scaling patterns
- **Flexibility**: Multiple locking strategies for different use cases
- **Monitoring**: Comprehensive metrics and monitoring capabilities

### Negative
- **Performance Impact**: Locks can reduce system throughput
- **Complexity**: Multiple locking mechanisms increase system complexity
- **Deadlock Risk**: Improper lock ordering can cause deadlocks
- **Single Points of Failure**: Lock servers become critical dependencies
- **Lock Contention**: High contention can lead to poor performance

## Related Patterns
- [Optimistic Locking](007-optimistic-locking.md) - Alternative approach using version control
- [Database Design Record](009-database-design-record.md) - Schema design for locking
- [Redis Convention](012-redis-convention.md) - Redis key naming for locks
- [Background Jobs](../backend/029-background-job.md) - Job processing with locks
