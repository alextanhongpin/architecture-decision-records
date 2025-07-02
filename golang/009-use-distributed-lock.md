# Use Distributed Lock Pattern

## Status

`accepted`

## Context

Distributed locks coordinate access to shared resources across multiple processes or services in a distributed system. They prevent race conditions and ensure data consistency when multiple instances of an application need to perform mutually exclusive operations.

## Problem

In distributed systems, traditional synchronization primitives (mutexes, semaphores) only work within a single process. When scaling applications horizontally, we need mechanisms to:
- **Prevent concurrent execution** of critical sections across multiple instances
- **Ensure exclusive access** to shared resources (databases, files, APIs)
- **Coordinate leadership election** in distributed services
- **Implement rate limiting** across multiple service instances
- **Manage resource allocation** in cloud environments

## Solution

Implement distributed locking using external coordination services like Redis, etcd, or database-based solutions. Provide abstractions for different locking strategies with proper timeout handling, lease renewal, and failure recovery.

## Go Distributed Lock Implementation

### Core Lock Interface

```go
package lock

import (
    "context"
    "time"
)

// DistributedLock interface defines the contract for distributed locking
type DistributedLock interface {
    // Lock attempts to acquire a lock with the given key
    Lock(ctx context.Context, key string, ttl time.Duration) (Lock, error)
    
    // TryLock attempts to acquire a lock without blocking
    TryLock(ctx context.Context, key string, ttl time.Duration) (Lock, bool, error)
    
    // LockWithOptions attempts to acquire a lock with advanced options
    LockWithOptions(ctx context.Context, options LockOptions) (Lock, error)
}

// Lock represents an acquired distributed lock
type Lock interface {
    // Key returns the lock key
    Key() string
    
    // TTL returns the time-to-live for the lock
    TTL() time.Duration
    
    // ExpiresAt returns when the lock expires
    ExpiresAt() time.Time
    
    // Refresh extends the lock TTL
    Refresh(ctx context.Context, ttl time.Duration) error
    
    // Release releases the lock
    Release(ctx context.Context) error
    
    // IsValid checks if the lock is still valid
    IsValid(ctx context.Context) (bool, error)
}

// LockOptions provides configuration for lock acquisition
type LockOptions struct {
    Key           string
    TTL           time.Duration
    Timeout       time.Duration
    RetryInterval time.Duration
    Metadata      map[string]string
    AutoRefresh   bool
    RefreshTTL    time.Duration
}
```

### Redis-based Distributed Lock

```go
package redis

import (
    "context"
    "crypto/rand"
    "encoding/hex"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

// redisLock implements distributed locking using Redis
type redisLock struct {
    client *redis.Client
}

// NewRedisLock creates a new Redis-based distributed lock
func NewRedisLock(client *redis.Client) lock.DistributedLock {
    return &redisLock{client: client}
}

// Lock acquires a distributed lock
func (r *redisLock) Lock(ctx context.Context, key string, ttl time.Duration) (lock.Lock, error) {
    options := lock.LockOptions{
        Key:           key,
        TTL:           ttl,
        Timeout:       30 * time.Second,
        RetryInterval: 100 * time.Millisecond,
    }
    
    return r.LockWithOptions(ctx, options)
}

// TryLock attempts to acquire a lock without blocking
func (r *redisLock) TryLock(ctx context.Context, key string, ttl time.Duration) (lock.Lock, bool, error) {
    value := generateLockValue()
    
    result, err := r.client.SetNX(ctx, key, value, ttl).Result()
    if err != nil {
        return nil, false, fmt.Errorf("failed to acquire lock: %w", err)
    }
    
    if !result {
        return nil, false, nil
    }
    
    return &redisLockInstance{
        client:    r.client,
        key:       key,
        value:     value,
        ttl:       ttl,
        expiresAt: time.Now().Add(ttl),
    }, true, nil
}

// LockWithOptions acquires a lock with advanced configuration
func (r *redisLock) LockWithOptions(ctx context.Context, options lock.LockOptions) (lock.Lock, error) {
    value := generateLockValue()
    
    // Set up timeout context
    lockCtx := ctx
    if options.Timeout > 0 {
        var cancel context.CancelFunc
        lockCtx, cancel = context.WithTimeout(ctx, options.Timeout)
        defer cancel()
    }
    
    retryInterval := options.RetryInterval
    if retryInterval == 0 {
        retryInterval = 100 * time.Millisecond
    }
    
    ticker := time.NewTicker(retryInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-lockCtx.Done():
            return nil, fmt.Errorf("lock acquisition timeout: %w", lockCtx.Err())
            
        default:
            // Try to acquire lock
            result, err := r.client.SetNX(lockCtx, options.Key, value, options.TTL).Result()
            if err != nil {
                return nil, fmt.Errorf("failed to acquire lock: %w", err)
            }
            
            if result {
                lockInstance := &redisLockInstance{
                    client:      r.client,
                    key:         options.Key,
                    value:       value,
                    ttl:         options.TTL,
                    expiresAt:   time.Now().Add(options.TTL),
                    autoRefresh: options.AutoRefresh,
                    refreshTTL:  options.RefreshTTL,
                }
                
                // Start auto-refresh if enabled
                if options.AutoRefresh {
                    go lockInstance.startAutoRefresh(ctx)
                }
                
                return lockInstance, nil
            }
            
            // Wait before retrying
            select {
            case <-lockCtx.Done():
                return nil, fmt.Errorf("lock acquisition timeout: %w", lockCtx.Err())
            case <-ticker.C:
                continue
            }
        }
    }
}

// redisLockInstance represents an acquired Redis lock
type redisLockInstance struct {
    client      *redis.Client
    key         string
    value       string
    ttl         time.Duration
    expiresAt   time.Time
    autoRefresh bool
    refreshTTL  time.Duration
    refreshStop chan struct{}
}

// Key returns the lock key
func (l *redisLockInstance) Key() string {
    return l.key
}

// TTL returns the lock TTL
func (l *redisLockInstance) TTL() time.Duration {
    return l.ttl
}

// ExpiresAt returns the lock expiration time
func (l *redisLockInstance) ExpiresAt() time.Time {
    return l.expiresAt
}

// Refresh extends the lock TTL
func (l *redisLockInstance) Refresh(ctx context.Context, ttl time.Duration) error {
    script := `
        if redis.call("GET", KEYS[1]) == ARGV[1] then
            return redis.call("EXPIRE", KEYS[1], ARGV[2])
        else
            return 0
        end
    `
    
    result, err := l.client.Eval(ctx, script, []string{l.key}, l.value, int(ttl.Seconds())).Result()
    if err != nil {
        return fmt.Errorf("failed to refresh lock: %w", err)
    }
    
    if result.(int64) == 0 {
        return fmt.Errorf("lock no longer owned")
    }
    
    l.ttl = ttl
    l.expiresAt = time.Now().Add(ttl)
    return nil
}

// Release releases the lock
func (l *redisLockInstance) Release(ctx context.Context) error {
    // Stop auto-refresh if running
    if l.refreshStop != nil {
        close(l.refreshStop)
    }
    
    script := `
        if redis.call("GET", KEYS[1]) == ARGV[1] then
            return redis.call("DEL", KEYS[1])
        else
            return 0
        end
    `
    
    result, err := l.client.Eval(ctx, script, []string{l.key}, l.value).Result()
    if err != nil {
        return fmt.Errorf("failed to release lock: %w", err)
    }
    
    if result.(int64) == 0 {
        return fmt.Errorf("lock no longer owned")
    }
    
    return nil
}

// IsValid checks if the lock is still valid
func (l *redisLockInstance) IsValid(ctx context.Context) (bool, error) {
    value, err := l.client.Get(ctx, l.key).Result()
    if err != nil {
        if err == redis.Nil {
            return false, nil
        }
        return false, fmt.Errorf("failed to check lock validity: %w", err)
    }
    
    return value == l.value, nil
}

// startAutoRefresh automatically refreshes the lock
func (l *redisLockInstance) startAutoRefresh(ctx context.Context) {
    if l.refreshTTL == 0 {
        l.refreshTTL = l.ttl
    }
    
    refreshInterval := l.refreshTTL / 3 // Refresh at 1/3 of TTL
    if refreshInterval < time.Second {
        refreshInterval = time.Second
    }
    
    l.refreshStop = make(chan struct{})
    ticker := time.NewTicker(refreshInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-l.refreshStop:
            return
        case <-ticker.C:
            if err := l.Refresh(ctx, l.refreshTTL); err != nil {
                // Log error and stop auto-refresh
                fmt.Printf("Auto-refresh failed: %v\n", err)
                return
            }
        }
    }
}

// generateLockValue creates a unique value for the lock
func generateLockValue() string {
    bytes := make([]byte, 16)
    rand.Read(bytes)
    return hex.EncodeToString(bytes)
}
```

### Database-based Distributed Lock

```go
package database

import (
    "context"
    "database/sql"
    "fmt"
    "time"

    "github.com/lib/pq"
)

// dbLock implements distributed locking using PostgreSQL
type dbLock struct {
    db *sql.DB
}

// NewDatabaseLock creates a new database-based distributed lock
func NewDatabaseLock(db *sql.DB) lock.DistributedLock {
    return &dbLock{db: db}
}

// Lock acquires a distributed lock using database
func (d *dbLock) Lock(ctx context.Context, key string, ttl time.Duration) (lock.Lock, error) {
    options := lock.LockOptions{
        Key:           key,
        TTL:           ttl,
        Timeout:       30 * time.Second,
        RetryInterval: 100 * time.Millisecond,
    }
    
    return d.LockWithOptions(ctx, options)
}

// TryLock attempts to acquire a lock without blocking
func (d *dbLock) TryLock(ctx context.Context, key string, ttl time.Duration) (lock.Lock, bool, error) {
    lockValue := generateLockValue()
    expiresAt := time.Now().Add(ttl)
    
    query := `
        INSERT INTO distributed_locks (lock_key, lock_value, expires_at, created_at)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (lock_key) DO NOTHING
    `
    
    result, err := d.db.ExecContext(ctx, query, key, lockValue, expiresAt, time.Now())
    if err != nil {
        return nil, false, fmt.Errorf("failed to acquire lock: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return nil, false, fmt.Errorf("failed to check lock acquisition: %w", err)
    }
    
    if rowsAffected == 0 {
        return nil, false, nil
    }
    
    return &dbLockInstance{
        db:        d.db,
        key:       key,
        value:     lockValue,
        ttl:       ttl,
        expiresAt: expiresAt,
    }, true, nil
}

// LockWithOptions acquires a lock with advanced configuration
func (d *dbLock) LockWithOptions(ctx context.Context, options lock.LockOptions) (lock.Lock, error) {
    lockCtx := ctx
    if options.Timeout > 0 {
        var cancel context.CancelFunc
        lockCtx, cancel = context.WithTimeout(ctx, options.Timeout)
        defer cancel()
    }
    
    retryInterval := options.RetryInterval
    if retryInterval == 0 {
        retryInterval = 100 * time.Millisecond
    }
    
    ticker := time.NewTicker(retryInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-lockCtx.Done():
            return nil, fmt.Errorf("lock acquisition timeout: %w", lockCtx.Err())
            
        default:
            // Clean up expired locks first
            d.cleanupExpiredLocks(ctx)
            
            // Try to acquire lock
            lock, acquired, err := d.TryLock(ctx, options.Key, options.TTL)
            if err != nil {
                return nil, err
            }
            
            if acquired {
                return lock, nil
            }
            
            // Wait before retrying
            select {
            case <-lockCtx.Done():
                return nil, fmt.Errorf("lock acquisition timeout: %w", lockCtx.Err())
            case <-ticker.C:
                continue
            }
        }
    }
}

// cleanupExpiredLocks removes expired locks from the database
func (d *dbLock) cleanupExpiredLocks(ctx context.Context) {
    query := `DELETE FROM distributed_locks WHERE expires_at < $1`
    d.db.ExecContext(ctx, query, time.Now())
}

// dbLockInstance represents an acquired database lock
type dbLockInstance struct {
    db        *sql.DB
    key       string
    value     string
    ttl       time.Duration
    expiresAt time.Time
}

// Key returns the lock key
func (l *dbLockInstance) Key() string {
    return l.key
}

// TTL returns the lock TTL
func (l *dbLockInstance) TTL() time.Duration {
    return l.ttl
}

// ExpiresAt returns the lock expiration time
func (l *dbLockInstance) ExpiresAt() time.Time {
    return l.expiresAt
}

// Refresh extends the lock TTL
func (l *dbLockInstance) Refresh(ctx context.Context, ttl time.Duration) error {
    newExpiresAt := time.Now().Add(ttl)
    
    query := `
        UPDATE distributed_locks
        SET expires_at = $1
        WHERE lock_key = $2 AND lock_value = $3 AND expires_at > $4
    `
    
    result, err := l.db.ExecContext(ctx, query, newExpiresAt, l.key, l.value, time.Now())
    if err != nil {
        return fmt.Errorf("failed to refresh lock: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return fmt.Errorf("failed to check lock refresh: %w", err)
    }
    
    if rowsAffected == 0 {
        return fmt.Errorf("lock no longer owned or expired")
    }
    
    l.ttl = ttl
    l.expiresAt = newExpiresAt
    return nil
}

// Release releases the lock
func (l *dbLockInstance) Release(ctx context.Context) error {
    query := `
        DELETE FROM distributed_locks
        WHERE lock_key = $1 AND lock_value = $2
    `
    
    result, err := l.db.ExecContext(ctx, query, l.key, l.value)
    if err != nil {
        return fmt.Errorf("failed to release lock: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return fmt.Errorf("failed to check lock release: %w", err)
    }
    
    if rowsAffected == 0 {
        return fmt.Errorf("lock no longer owned")
    }
    
    return nil
}

// IsValid checks if the lock is still valid
func (l *dbLockInstance) IsValid(ctx context.Context) (bool, error) {
    query := `
        SELECT 1 FROM distributed_locks
        WHERE lock_key = $1 AND lock_value = $2 AND expires_at > $3
    `
    
    var exists int
    err := l.db.QueryRowContext(ctx, query, l.key, l.value, time.Now()).Scan(&exists)
    if err != nil {
        if err == sql.ErrNoRows {
            return false, nil
        }
        return false, fmt.Errorf("failed to check lock validity: %w", err)
    }
    
    return true, nil
}

// Database schema for distributed locks
const CreateDistributedLocksTable = `
CREATE TABLE IF NOT EXISTS distributed_locks (
    lock_key VARCHAR(255) PRIMARY KEY,
    lock_value VARCHAR(255) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_distributed_locks_expires_at 
ON distributed_locks(expires_at);
`
```

### High-Level Lock Manager

```go
package lockmanager

import (
    "context"
    "fmt"
    "sync"
    "time"

    "myapp/lock"
)

// Manager provides high-level distributed locking functionality
type Manager struct {
    backend lock.DistributedLock
    locks   map[string]lock.Lock
    mutex   sync.RWMutex
}

// NewManager creates a new lock manager
func NewManager(backend lock.DistributedLock) *Manager {
    return &Manager{
        backend: backend,
        locks:   make(map[string]lock.Lock),
    }
}

// WithLock executes a function while holding a distributed lock
func (m *Manager) WithLock(ctx context.Context, key string, ttl time.Duration, fn func() error) error {
    lock, err := m.backend.Lock(ctx, key, ttl)
    if err != nil {
        return fmt.Errorf("failed to acquire lock %s: %w", key, err)
    }
    
    defer func() {
        if err := lock.Release(ctx); err != nil {
            fmt.Printf("Failed to release lock %s: %v\n", key, err)
        }
    }()
    
    return fn()
}

// TryWithLock executes a function if lock can be acquired immediately
func (m *Manager) TryWithLock(ctx context.Context, key string, ttl time.Duration, fn func() error) (bool, error) {
    lock, acquired, err := m.backend.TryLock(ctx, key, ttl)
    if err != nil {
        return false, fmt.Errorf("failed to try lock %s: %w", key, err)
    }
    
    if !acquired {
        return false, nil
    }
    
    defer func() {
        if err := lock.Release(ctx); err != nil {
            fmt.Printf("Failed to release lock %s: %v\n", key, err)
        }
    }()
    
    return true, fn()
}

// AcquireLock acquires a lock and tracks it
func (m *Manager) AcquireLock(ctx context.Context, key string, ttl time.Duration) (lock.Lock, error) {
    m.mutex.Lock()
    defer m.mutex.Unlock()
    
    // Check if lock already exists
    if existingLock, exists := m.locks[key]; exists {
        valid, err := existingLock.IsValid(ctx)
        if err != nil {
            return nil, fmt.Errorf("failed to check existing lock validity: %w", err)
        }
        if valid {
            return existingLock, nil
        }
        delete(m.locks, key)
    }
    
    // Acquire new lock
    newLock, err := m.backend.Lock(ctx, key, ttl)
    if err != nil {
        return nil, err
    }
    
    m.locks[key] = newLock
    return newLock, nil
}

// ReleaseLock releases a tracked lock
func (m *Manager) ReleaseLock(ctx context.Context, key string) error {
    m.mutex.Lock()
    defer m.mutex.Unlock()
    
    lock, exists := m.locks[key]
    if !exists {
        return fmt.Errorf("lock %s not found", key)
    }
    
    err := lock.Release(ctx)
    delete(m.locks, key)
    return err
}

// ReleaseAll releases all tracked locks
func (m *Manager) ReleaseAll(ctx context.Context) error {
    m.mutex.Lock()
    defer m.mutex.Unlock()
    
    var errors []error
    for key, lock := range m.locks {
        if err := lock.Release(ctx); err != nil {
            errors = append(errors, fmt.Errorf("failed to release lock %s: %w", key, err))
        }
    }
    
    // Clear all locks
    m.locks = make(map[string]lock.Lock)
    
    if len(errors) > 0 {
        return fmt.Errorf("failed to release some locks: %v", errors)
    }
    
    return nil
}
```

### Usage Examples

```go
package main

import (
    "context"
    "fmt"
    "log"
    "time"

    "github.com/redis/go-redis/v9"
    "myapp/lock"
    "myapp/lock/redis"
    "myapp/lockmanager"
)

func main() {
    // Initialize Redis client
    rdb := redis.NewClient(&redis.Options{
        Addr: "localhost:6379",
    })
    
    // Create distributed lock
    distLock := redis.NewRedisLock(rdb)
    
    // Create lock manager
    manager := lockmanager.NewManager(distLock)
    
    ctx := context.Background()
    
    // Example 1: Simple exclusive operation
    err := manager.WithLock(ctx, "critical-section", 30*time.Second, func() error {
        fmt.Println("Executing critical section...")
        time.Sleep(5 * time.Second)
        fmt.Println("Critical section completed")
        return nil
    })
    if err != nil {
        log.Printf("Failed to execute with lock: %v", err)
    }
    
    // Example 2: Try lock without blocking
    executed, err := manager.TryWithLock(ctx, "quick-task", 10*time.Second, func() error {
        fmt.Println("Executing quick task...")
        return nil
    })
    if err != nil {
        log.Printf("Error during try lock: %v", err)
    }
    if !executed {
        fmt.Println("Could not acquire lock, skipping task")
    }
    
    // Example 3: Manual lock management
    lock, err := manager.AcquireLock(ctx, "manual-lock", 60*time.Second)
    if err != nil {
        log.Printf("Failed to acquire manual lock: %v", err)
        return
    }
    
    fmt.Printf("Acquired lock: %s, expires at: %v\n", lock.Key(), lock.ExpiresAt())
    
    // Do some work...
    time.Sleep(2 * time.Second)
    
    // Refresh lock
    err = lock.Refresh(ctx, 60*time.Second)
    if err != nil {
        log.Printf("Failed to refresh lock: %v", err)
    }
    
    // Release lock
    err = manager.ReleaseLock(ctx, "manual-lock")
    if err != nil {
        log.Printf("Failed to release lock: %v", err)
    }
}

// Example: Rate limiting across multiple instances
func rateLimitedOperation(ctx context.Context, distLock lock.DistributedLock) error {
    lockKey := fmt.Sprintf("rate-limit:%s", time.Now().Format("2006-01-02-15-04"))
    
    lock, acquired, err := distLock.TryLock(ctx, lockKey, 60*time.Second)
    if err != nil {
        return fmt.Errorf("failed to check rate limit: %w", err)
    }
    
    if !acquired {
        return fmt.Errorf("rate limit exceeded")
    }
    
    defer lock.Release(ctx)
    
    // Perform rate-limited operation
    fmt.Println("Executing rate-limited operation...")
    return nil
}

// Example: Leader election
func leaderElection(ctx context.Context, distLock lock.DistributedLock, instanceID string) {
    lockKey := "leader-election"
    
    for {
        select {
        case <-ctx.Done():
            return
        default:
            lock, acquired, err := distLock.TryLock(ctx, lockKey, 30*time.Second)
            if err != nil {
                log.Printf("Leader election error: %v", err)
                time.Sleep(5 * time.Second)
                continue
            }
            
            if acquired {
                fmt.Printf("Instance %s became leader\n", instanceID)
                
                // Perform leader duties with auto-refresh
                err = performLeaderDuties(ctx, lock)
                if err != nil {
                    log.Printf("Leader duties failed: %v", err)
                }
                
                lock.Release(ctx)
                fmt.Printf("Instance %s stepped down as leader\n", instanceID)
            } else {
                fmt.Printf("Instance %s is follower\n", instanceID)
                time.Sleep(10 * time.Second)
            }
        }
    }
}

func performLeaderDuties(ctx context.Context, lock lock.Lock) error {
    // Auto-refresh the lock while performing duties
    refreshTicker := time.NewTicker(10 * time.Second)
    defer refreshTicker.Stop()
    
    dutiesTicker := time.NewTicker(5 * time.Second)
    defer dutiesTicker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
            
        case <-refreshTicker.C:
            if err := lock.Refresh(ctx, 30*time.Second); err != nil {
                return fmt.Errorf("failed to refresh leader lock: %w", err)
            }
            
        case <-dutiesTicker.C:
            // Perform actual leader duties
            fmt.Println("Performing leader duties...")
            
            // Check if we're still the leader
            valid, err := lock.IsValid(ctx)
            if err != nil {
                return fmt.Errorf("failed to validate leadership: %w", err)
            }
            if !valid {
                return fmt.Errorf("leadership lost")
            }
        }
    }
}
```

### Testing Distributed Locks

```go
package lock_test

import (
    "context"
    "sync"
    "testing"
    "time"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
    "myapp/lock"
    "myapp/lock/memory"
)

func TestDistributedLock_Exclusivity(t *testing.T) {
    distLock := memory.NewMemoryLock()
    ctx := context.Background()
    
    var counter int
    var mu sync.Mutex
    var wg sync.WaitGroup
    
    // Start multiple goroutines trying to increment counter
    for i := 0; i < 10; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            
            lock, err := distLock.Lock(ctx, "counter-lock", 5*time.Second)
            require.NoError(t, err)
            defer lock.Release(ctx)
            
            // Critical section
            mu.Lock()
            current := counter
            time.Sleep(10 * time.Millisecond) // Simulate work
            counter = current + 1
            mu.Unlock()
        }()
    }
    
    wg.Wait()
    
    // Counter should be exactly 10 if locks worked correctly
    assert.Equal(t, 10, counter)
}

func TestDistributedLock_Timeout(t *testing.T) {
    distLock := memory.NewMemoryLock()
    ctx := context.Background()
    
    // Acquire lock
    lock1, err := distLock.Lock(ctx, "timeout-test", 1*time.Second)
    require.NoError(t, err)
    defer lock1.Release(ctx)
    
    // Try to acquire same lock with timeout
    timeoutCtx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
    defer cancel()
    
    start := time.Now()
    _, err = distLock.Lock(timeoutCtx, "timeout-test", 1*time.Second)
    elapsed := time.Since(start)
    
    assert.Error(t, err)
    assert.True(t, elapsed >= 500*time.Millisecond)
    assert.True(t, elapsed < 600*time.Millisecond)
}

func TestDistributedLock_Refresh(t *testing.T) {
    distLock := memory.NewMemoryLock()
    ctx := context.Background()
    
    lock, err := distLock.Lock(ctx, "refresh-test", 1*time.Second)
    require.NoError(t, err)
    defer lock.Release(ctx)
    
    // Wait until lock would expire
    time.Sleep(1500 * time.Millisecond)
    
    // Lock should be invalid now
    valid, err := lock.IsValid(ctx)
    require.NoError(t, err)
    assert.False(t, valid)
    
    // Acquire new lock and test refresh
    lock2, err := distLock.Lock(ctx, "refresh-test-2", 1*time.Second)
    require.NoError(t, err)
    defer lock2.Release(ctx)
    
    // Refresh before expiration
    time.Sleep(500 * time.Millisecond)
    err = lock2.Refresh(ctx, 2*time.Second)
    require.NoError(t, err)
    
    // Wait original TTL period
    time.Sleep(1*time.Second)
    
    // Lock should still be valid
    valid, err = lock2.IsValid(ctx)
    require.NoError(t, err)
    assert.True(t, valid)
}

func TestDistributedLock_TryLock(t *testing.T) {
    distLock := memory.NewMemoryLock()
    ctx := context.Background()
    
    // Acquire lock
    lock1, acquired1, err := distLock.TryLock(ctx, "try-test", 1*time.Second)
    require.NoError(t, err)
    require.True(t, acquired1)
    defer lock1.Release(ctx)
    
    // Try to acquire same lock - should fail immediately
    _, acquired2, err := distLock.TryLock(ctx, "try-test", 1*time.Second)
    require.NoError(t, err)
    assert.False(t, acquired2)
}
```

## Best Practices

### 1. Always Set Appropriate TTL

```go
// Good: Set TTL based on expected operation duration
func processLongRunningTask(ctx context.Context, distLock lock.DistributedLock) error {
    // Task takes 5 minutes, set TTL to 10 minutes with refresh
    lock, err := distLock.Lock(ctx, "long-task", 10*time.Minute)
    if err != nil {
        return err
    }
    defer lock.Release(ctx)
    
    // Refresh lock periodically
    refreshTicker := time.NewTicker(3 * time.Minute)
    defer refreshTicker.Stop()
    
    go func() {
        for range refreshTicker.C {
            lock.Refresh(ctx, 10*time.Minute)
        }
    }()
    
    return performLongTask()
}

// Bad: TTL too short or too long
func badLockUsage(ctx context.Context, distLock lock.DistributedLock) error {
    // TTL too short - lock might expire during operation
    lock, err := distLock.Lock(ctx, "task", 1*time.Second)
    if err != nil {
        return err
    }
    defer lock.Release(ctx)
    
    time.Sleep(5 * time.Second) // Operation takes longer than TTL
    return nil
}
```

### 2. Handle Lock Failures Gracefully

```go
// Good: Graceful degradation
func criticalOperation(ctx context.Context, distLock lock.DistributedLock) error {
    lock, acquired, err := distLock.TryLock(ctx, "critical-op", 30*time.Second)
    if err != nil {
        // Log error but continue with degraded functionality
        log.Printf("Failed to acquire lock: %v", err)
        return performDegradedOperation()
    }
    
    if !acquired {
        // Another instance is handling this
        return nil
    }
    
    defer lock.Release(ctx)
    return performCriticalOperation()
}
```

### 3. Use Unique Lock Keys

```go
// Good: Hierarchical and unique keys
func processUserData(ctx context.Context, distLock lock.DistributedLock, userID string) error {
    lockKey := fmt.Sprintf("user:process:%s", userID)
    return manager.WithLock(ctx, lockKey, 30*time.Second, func() error {
        return processUser(userID)
    })
}

// Bad: Generic keys that may conflict
func badKeyUsage(ctx context.Context, distLock lock.DistributedLock) error {
    // Too generic - might block unrelated operations
    lockKey := "process"
    return manager.WithLock(ctx, lockKey, 30*time.Second, func() error {
        return doSomething()
    })
}
```

## Decision

1. **Use Redis or database-based** distributed locks for production systems
2. **Always set appropriate TTL** based on operation duration
3. **Implement lock refresh** for long-running operations
4. **Handle lock acquisition failures** gracefully
5. **Use hierarchical lock keys** to avoid conflicts
6. **Provide in-memory implementation** for testing
7. **Monitor lock metrics** (acquisition time, hold duration, failures)

## Consequences

### Positive
- **Prevents race conditions** in distributed systems
- **Ensures data consistency** across multiple instances
- **Enables coordination** of distributed operations
- **Supports leader election** and resource allocation

### Negative
- **Additional complexity** in application architecture
- **Single point of failure** if lock service becomes unavailable
- **Performance overhead** from lock acquisition and release
- **Potential for deadlocks** if not designed carefully

### Trade-offs
- **Consistency vs Availability**: Locks can reduce system availability
- **Performance vs Safety**: Lock overhead vs data consistency
- **Complexity vs Reliability**: More complex code but better coordination
