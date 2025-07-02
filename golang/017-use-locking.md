# ADR 017: Distributed Locking Patterns in Go

## Status

**Accepted**

## Context

In distributed systems and concurrent applications, race conditions can occur when multiple processes, threads, or goroutines attempt to access and modify shared resources simultaneously. This leads to:

- **Data corruption**: Inconsistent state when multiple writers modify the same resource
- **Duplicate operations**: Multiple instances performing the same task (e.g., user registration)
- **Non-atomic operations**: Multi-step processes being interrupted by other operations
- **Thundering herd problems**: Multiple clients competing for the same resource

We need robust locking mechanisms that work both locally (single instance) and in distributed environments (multiple instances/services).

## Decision

We will implement a comprehensive locking strategy using multiple approaches based on the specific use case:

1. **Local locking** using Go's sync package for single-instance concurrency
2. **Distributed locking** using Redis for multi-instance coordination
3. **Database locking** using PostgreSQL advisory locks for transactional consistency
4. **Message queue partitioning** for ordered processing

### 1. Local Locking with Sync Package

For single-instance concurrency control:

```go
package sync

import (
    "context"
    "fmt"
    "sync"
    "time"
)

// KeyedMutex provides named mutex functionality
type KeyedMutex struct {
    mutexes sync.Map // map[string]*sync.Mutex
    pool    sync.Pool
}

func NewKeyedMutex() *KeyedMutex {
    return &KeyedMutex{
        pool: sync.Pool{
            New: func() interface{} {
                return &sync.Mutex{}
            },
        },
    }
}

func (km *KeyedMutex) Lock(key string) *sync.Mutex {
    value, _ := km.mutexes.LoadOrStore(key, km.pool.Get().(*sync.Mutex))
    mutex := value.(*sync.Mutex)
    mutex.Lock()
    return mutex
}

func (km *KeyedMutex) Unlock(key string, mutex *sync.Mutex) {
    mutex.Unlock()
    km.mutexes.Delete(key)
    km.pool.Put(mutex)
}

// Usage with defer pattern
func (km *KeyedMutex) WithLock(key string, fn func() error) error {
    mutex := km.Lock(key)
    defer km.Unlock(key, mutex)
    return fn()
}

// Example usage
func processUser(km *KeyedMutex, userID string) error {
    return km.WithLock(fmt.Sprintf("user:%s", userID), func() error {
        // Critical section - only one goroutine can process this user at a time
        return updateUserProfile(userID)
    })
}
```

### 2. Distributed Redis Locking

For multi-instance coordination with automatic renewal:

```go
package redislock

import (
    "context"
    "crypto/rand"
    "encoding/hex"
    "errors"
    "fmt"
    "time"
    
    "github.com/redis/go-redis/v9"
)

var (
    ErrLockNotObtained = errors.New("lock not obtained")
    ErrLockExpired     = errors.New("lock expired")
    ErrLockNotHeld     = errors.New("lock not held by this client")
)

type DistributedLock struct {
    client   redis.UniversalClient
    key      string
    token    string
    ttl      time.Duration
    renewals chan struct{}
    done     chan struct{}
}

type Locker struct {
    client redis.UniversalClient
}

func NewLocker(client redis.UniversalClient) *Locker {
    return &Locker{client: client}
}

// AcquireLock attempts to acquire a distributed lock
func (l *Locker) AcquireLock(ctx context.Context, key string, ttl time.Duration) (*DistributedLock, error) {
    token, err := generateToken()
    if err != nil {
        return nil, fmt.Errorf("generate token: %w", err)
    }
    
    // Try to acquire lock with SET NX EX
    acquired, err := l.client.SetNX(ctx, key, token, ttl).Result()
    if err != nil {
        return nil, fmt.Errorf("acquire lock: %w", err)
    }
    
    if !acquired {
        return nil, ErrLockNotObtained
    }
    
    lock := &DistributedLock{
        client:   l.client,
        key:      key,
        token:    token,
        ttl:      ttl,
        renewals: make(chan struct{}),
        done:     make(chan struct{}),
    }
    
    // Start renewal process
    go lock.startRenewal(ctx)
    
    return lock, nil
}

// TryLock attempts to acquire lock with retry logic
func (l *Locker) TryLock(ctx context.Context, key string, ttl, maxWait time.Duration) (*DistributedLock, error) {
    retryInterval := 100 * time.Millisecond
    maxRetryInterval := 1 * time.Second
    
    deadline := time.Now().Add(maxWait)
    
    for time.Now().Before(deadline) {
        lock, err := l.AcquireLock(ctx, key, ttl)
        if err == nil {
            return lock, nil
        }
        
        if !errors.Is(err, ErrLockNotObtained) {
            return nil, err
        }
        
        // Exponential backoff with jitter
        select {
        case <-ctx.Done():
            return nil, ctx.Err()
        case <-time.After(retryInterval):
            retryInterval = min(retryInterval*2, maxRetryInterval)
        }
    }
    
    return nil, ErrLockNotObtained
}

// WithLock executes function while holding the lock
func (l *Locker) WithLock(ctx context.Context, key string, ttl time.Duration, fn func(ctx context.Context) error) error {
    lock, err := l.AcquireLock(ctx, key, ttl)
    if err != nil {
        return err
    }
    defer lock.Release(ctx)
    
    return fn(ctx)
}

// startRenewal automatically renews the lock
func (dl *DistributedLock) startRenewal(ctx context.Context) {
    // Renew at 1/3 of TTL to provide safety margin
    renewInterval := dl.ttl / 3
    ticker := time.NewTicker(renewInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-dl.done:
            return
        case <-ticker.C:
            err := dl.renew(ctx)
            if err != nil {
                // Log error but continue - let the lock expire naturally
                fmt.Printf("failed to renew lock %s: %v\n", dl.key, err)
                return
            }
        }
    }
}

// renew extends the lock TTL using Lua script for atomicity
func (dl *DistributedLock) renew(ctx context.Context) error {
    script := `
        if redis.call("GET", KEYS[1]) == ARGV[1] then
            return redis.call("EXPIRE", KEYS[1], ARGV[2])
        else
            return 0
        end
    `
    
    result, err := dl.client.Eval(ctx, script, []string{dl.key}, dl.token, int(dl.ttl.Seconds())).Result()
    if err != nil {
        return fmt.Errorf("renew script: %w", err)
    }
    
    if result.(int64) != 1 {
        return ErrLockNotHeld
    }
    
    return nil
}

// Release unlocks the distributed lock
func (dl *DistributedLock) Release(ctx context.Context) error {
    close(dl.done)
    
    // Use Lua script to ensure we only delete our own lock
    script := `
        if redis.call("GET", KEYS[1]) == ARGV[1] then
            return redis.call("DEL", KEYS[1])
        else
            return 0
        end
    `
    
    result, err := dl.client.Eval(ctx, script, []string{dl.key}, dl.token).Result()
    if err != nil {
        return fmt.Errorf("release script: %w", err)
    }
    
    if result.(int64) != 1 {
        return ErrLockNotHeld
    }
    
    return nil
}

func generateToken() (string, error) {
    bytes := make([]byte, 16)
    if _, err := rand.Read(bytes); err != nil {
        return "", err
    }
    return hex.EncodeToString(bytes), nil
}

func min(a, b time.Duration) time.Duration {
    if a < b {
        return a
    }
    return b
}
```

### 3. PostgreSQL Advisory Locks

For transactional consistency with database operations:

```go
package pglock

import (
    "context"
    "database/sql"
    "fmt"
    "hash/fnv"
)

type PostgresLocker struct {
    db *sql.DB
}

func NewPostgresLocker(db *sql.DB) *PostgresLocker {
    return &PostgresLocker{db: db}
}

// AcquireAdvisoryLock acquires a PostgreSQL advisory lock
func (pl *PostgresLocker) AcquireAdvisoryLock(ctx context.Context, key string) error {
    lockID := hashStringToInt64(key)
    
    query := "SELECT pg_advisory_lock($1)"
    _, err := pl.db.ExecContext(ctx, query, lockID)
    if err != nil {
        return fmt.Errorf("acquire advisory lock: %w", err)
    }
    
    return nil
}

// TryAcquireAdvisoryLock attempts to acquire lock without blocking
func (pl *PostgresLocker) TryAcquireAdvisoryLock(ctx context.Context, key string) (bool, error) {
    lockID := hashStringToInt64(key)
    
    query := "SELECT pg_try_advisory_lock($1)"
    var acquired bool
    err := pl.db.QueryRowContext(ctx, query, lockID).Scan(&acquired)
    if err != nil {
        return false, fmt.Errorf("try acquire advisory lock: %w", err)
    }
    
    return acquired, nil
}

// ReleaseAdvisoryLock releases the advisory lock
func (pl *PostgresLocker) ReleaseAdvisoryLock(ctx context.Context, key string) error {
    lockID := hashStringToInt64(key)
    
    query := "SELECT pg_advisory_unlock($1)"
    var released bool
    err := pl.db.QueryRowContext(ctx, query, lockID).Scan(&released)
    if err != nil {
        return fmt.Errorf("release advisory lock: %w", err)
    }
    
    if !released {
        return fmt.Errorf("lock was not held")
    }
    
    return nil
}

// WithAdvisoryLock executes function while holding advisory lock
func (pl *PostgresLocker) WithAdvisoryLock(ctx context.Context, key string, fn func(ctx context.Context) error) error {
    if err := pl.AcquireAdvisoryLock(ctx, key); err != nil {
        return err
    }
    defer pl.ReleaseAdvisoryLock(ctx, key)
    
    return fn(ctx)
}

// WithTransaction combines advisory lock with database transaction
func (pl *PostgresLocker) WithTransaction(ctx context.Context, key string, fn func(tx *sql.Tx) error) error {
    tx, err := pl.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    lockID := hashStringToInt64(key)
    
    // Acquire lock within transaction
    query := "SELECT pg_advisory_xact_lock($1)"
    _, err = tx.ExecContext(ctx, query, lockID)
    if err != nil {
        return fmt.Errorf("acquire transaction lock: %w", err)
    }
    
    if err := fn(tx); err != nil {
        return err
    }
    
    return tx.Commit()
}

func hashStringToInt64(s string) int64 {
    h := fnv.New64a()
    h.Write([]byte(s))
    return int64(h.Sum64())
}
```

### 4. Message Queue Partitioning

For ordered processing using Kafka-like partitioning:

```go
package partition

import (
    "context"
    "fmt"
    "hash/fnv"
)

type PartitionProcessor struct {
    partitions map[int]chan Task
    workers    map[int]*Worker
}

type Task struct {
    Key     string
    Payload interface{}
    Handler func(context.Context, interface{}) error
}

type Worker struct {
    id       int
    tasks    chan Task
    shutdown chan struct{}
}

func NewPartitionProcessor(numPartitions int) *PartitionProcessor {
    pp := &PartitionProcessor{
        partitions: make(map[int]chan Task, numPartitions),
        workers:    make(map[int]*Worker, numPartitions),
    }
    
    for i := 0; i < numPartitions; i++ {
        taskChan := make(chan Task, 100) // Buffered channel
        worker := &Worker{
            id:       i,
            tasks:    taskChan,
            shutdown: make(chan struct{}),
        }
        
        pp.partitions[i] = taskChan
        pp.workers[i] = worker
        
        go worker.start()
    }
    
    return pp
}

// Submit submits a task to the appropriate partition based on key
func (pp *PartitionProcessor) Submit(task Task) {
    partition := pp.getPartition(task.Key)
    pp.partitions[partition] <- task
}

// getPartition determines which partition to use based on key hash
func (pp *PartitionProcessor) getPartition(key string) int {
    h := fnv.New32a()
    h.Write([]byte(key))
    return int(h.Sum32()) % len(pp.partitions)
}

// start worker processing loop
func (w *Worker) start() {
    for {
        select {
        case task := <-w.tasks:
            ctx := context.Background()
            if err := task.Handler(ctx, task.Payload); err != nil {
                fmt.Printf("worker %d failed to process task: %v\n", w.id, err)
            }
        case <-w.shutdown:
            return
        }
    }
}

// Shutdown gracefully stops all workers
func (pp *PartitionProcessor) Shutdown() {
    for _, worker := range pp.workers {
        close(worker.shutdown)
    }
}

// Example usage for ordered user operations
func processUserOperations() {
    processor := NewPartitionProcessor(10)
    defer processor.Shutdown()
    
    // All operations for the same user go to the same partition
    processor.Submit(Task{
        Key:     "user:123",
        Payload: UpdateProfileRequest{UserID: "123", Name: "John"},
        Handler: handleProfileUpdate,
    })
    
    processor.Submit(Task{
        Key:     "user:123", // Same partition as above
        Payload: ChangePasswordRequest{UserID: "123", Password: "newpass"},
        Handler: handlePasswordChange,
    })
}

func handleProfileUpdate(ctx context.Context, payload interface{}) error {
    req := payload.(UpdateProfileRequest)
    // Process profile update
    return nil
}

func handlePasswordChange(ctx context.Context, payload interface{}) error {
    req := payload.(ChangePasswordRequest)
    // Process password change
    return nil
}
```

### 5. Lock Manager with Multiple Backends

Unified interface supporting multiple locking strategies:

```go
package lockmanager

import (
    "context"
    "fmt"
    "time"
)

type LockManager interface {
    AcquireLock(ctx context.Context, key string, ttl time.Duration) (Lock, error)
    TryLock(ctx context.Context, key string, ttl, maxWait time.Duration) (Lock, error)
    WithLock(ctx context.Context, key string, ttl time.Duration, fn func(ctx context.Context) error) error
}

type Lock interface {
    Release(ctx context.Context) error
    Renew(ctx context.Context, ttl time.Duration) error
    IsHeld(ctx context.Context) bool
}

type LockConfig struct {
    Backend     string        // "redis", "postgres", "memory"
    TTL         time.Duration
    MaxWait     time.Duration
    RetryDelay  time.Duration
    EnableRetry bool
}

func NewLockManager(backend string, config interface{}) (LockManager, error) {
    switch backend {
    case "redis":
        if redisClient, ok := config.(redis.UniversalClient); ok {
            return NewRedisLockManager(redisClient), nil
        }
        return nil, fmt.Errorf("invalid redis config")
    case "postgres":
        if db, ok := config.(*sql.DB); ok {
            return NewPostgresLockManager(db), nil
        }
        return nil, fmt.Errorf("invalid postgres config")
    case "memory":
        return NewMemoryLockManager(), nil
    default:
        return nil, fmt.Errorf("unsupported backend: %s", backend)
    }
}

// Example usage with factory pattern
func createLockManager() LockManager {
    // Environment-specific configuration
    switch os.Getenv("LOCK_BACKEND") {
    case "redis":
        redisClient := redis.NewClient(&redis.Options{
            Addr: os.Getenv("REDIS_URL"),
        })
        manager, _ := NewLockManager("redis", redisClient)
        return manager
    case "postgres":
        db, _ := sql.Open("postgres", os.Getenv("DATABASE_URL"))
        manager, _ := NewLockManager("postgres", db)
        return manager
    default:
        manager, _ := NewLockManager("memory", nil)
        return manager
    }
}
```

### 6. Testing Distributed Locks

```go
package locktest

import (
    "context"
    "sync"
    "sync/atomic"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestDistributedLock_Concurrency(t *testing.T) {
    locker := setupRedisLocker(t)
    
    const (
        numGoroutines = 10
        lockKey       = "test:concurrency"
        lockTTL       = 5 * time.Second
    )
    
    var (
        counter   int64
        wg        sync.WaitGroup
        successes int64
    )
    
    // Launch multiple goroutines trying to acquire the same lock
    for i := 0; i < numGoroutines; i++ {
        wg.Add(1)
        go func(id int) {
            defer wg.Done()
            
            ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
            defer cancel()
            
            err := locker.WithLock(ctx, lockKey, lockTTL, func(ctx context.Context) error {
                // Critical section - only one goroutine should be here at a time
                currentValue := atomic.LoadInt64(&counter)
                time.Sleep(100 * time.Millisecond) // Simulate work
                atomic.StoreInt64(&counter, currentValue+1)
                atomic.AddInt64(&successes, 1)
                return nil
            })
            
            if err != nil {
                t.Logf("Goroutine %d failed to acquire lock: %v", id, err)
            }
        }(i)
    }
    
    wg.Wait()
    
    // Verify that only one goroutine succeeded
    assert.Equal(t, int64(1), atomic.LoadInt64(&successes))
    assert.Equal(t, int64(1), atomic.LoadInt64(&counter))
}

func TestDistributedLock_AutoRenewal(t *testing.T) {
    locker := setupRedisLocker(t)
    
    lockKey := "test:renewal"
    lockTTL := 2 * time.Second
    
    ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
    defer cancel()
    
    lock, err := locker.AcquireLock(ctx, lockKey, lockTTL)
    require.NoError(t, err)
    defer lock.Release(ctx)
    
    // Wait longer than the original TTL to test renewal
    time.Sleep(5 * time.Second)
    
    // Lock should still be held due to auto-renewal
    assert.True(t, lock.IsHeld(ctx))
}

func TestDistributedLock_Timeout(t *testing.T) {
    locker := setupRedisLocker(t)
    
    lockKey := "test:timeout"
    lockTTL := 5 * time.Second
    maxWait := 1 * time.Second
    
    ctx := context.Background()
    
    // First goroutine acquires the lock
    lock1, err := locker.AcquireLock(ctx, lockKey, lockTTL)
    require.NoError(t, err)
    defer lock1.Release(ctx)
    
    // Second goroutine should timeout waiting for the lock
    _, err = locker.TryLock(ctx, lockKey, lockTTL, maxWait)
    assert.ErrorIs(t, err, ErrLockNotObtained)
}

func BenchmarkLockAcquisition(b *testing.B) {
    locker := setupRedisLocker(b)
    
    ctx := context.Background()
    lockTTL := 1 * time.Second
    
    b.ResetTimer()
    b.RunParallel(func(pb *testing.PB) {
        i := 0
        for pb.Next() {
            lockKey := fmt.Sprintf("bench:lock:%d", i%100) // Use 100 different keys
            
            err := locker.WithLock(ctx, lockKey, lockTTL, func(ctx context.Context) error {
                // Minimal work
                return nil
            })
            
            if err != nil {
                b.Errorf("Failed to acquire lock: %v", err)
            }
            i++
        }
    })
}

func setupRedisLocker(t testing.TB) *Locker {
    // Setup Redis test client
    client := redis.NewClient(&redis.Options{
        Addr: "localhost:6379",
        DB:   1, // Use test database
    })
    
    // Verify connection
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()
    
    err := client.Ping(ctx).Err()
    if err != nil {
        t.Skipf("Redis not available: %v", err)
    }
    
    return NewLocker(client)
}
```

### 7. Monitoring and Metrics

```go
package lockmetrics

import (
    "context"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    lockAcquisitions = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "lock_acquisitions_total",
            Help: "Total number of lock acquisitions",
        },
        []string{"key", "backend", "status"},
    )
    
    lockDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "lock_duration_seconds",
            Help:    "Time spent holding locks",
            Buckets: prometheus.DefBuckets,
        },
        []string{"key", "backend"},
    )
    
    lockWaitTime = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "lock_wait_time_seconds", 
            Help:    "Time spent waiting to acquire locks",
            Buckets: prometheus.DefBuckets,
        },
        []string{"key", "backend"},
    )
)

type InstrumentedLockManager struct {
    backend LockManager
    name    string
}

func NewInstrumentedLockManager(backend LockManager, name string) *InstrumentedLockManager {
    return &InstrumentedLockManager{
        backend: backend,
        name:    name,
    }
}

func (ilm *InstrumentedLockManager) WithLock(ctx context.Context, key string, ttl time.Duration, fn func(ctx context.Context) error) error {
    start := time.Now()
    
    err := ilm.backend.WithLock(ctx, key, ttl, func(ctx context.Context) error {
        // Record that we successfully acquired the lock
        lockAcquisitions.WithLabelValues(key, ilm.name, "success").Inc()
        
        // Track how long we waited to acquire the lock
        waitTime := time.Since(start)
        lockWaitTime.WithLabelValues(key, ilm.name).Observe(waitTime.Seconds())
        
        // Track how long we hold the lock
        holdStart := time.Now()
        defer func() {
            holdTime := time.Since(holdStart)
            lockDuration.WithLabelValues(key, ilm.name).Observe(holdTime.Seconds())
        }()
        
        return fn(ctx)
    })
    
    if err != nil {
        lockAcquisitions.WithLabelValues(key, ilm.name, "failure").Inc()
    }
    
    return err
}
```

## Implementation Guidelines

### Choosing the Right Lock Type

1. **Local locks (sync.Mutex)**: 
   - Single process/instance
   - High performance requirements
   - Short-lived operations

2. **Redis distributed locks**:
   - Multiple instances/services
   - Network partitions are rare
   - Need automatic expiration

3. **PostgreSQL advisory locks**:
   - Database transactions involved
   - Strong consistency requirements
   - Complex business logic

4. **Message queue partitioning**:
   - Ordered processing required
   - High throughput needed
   - Eventual consistency acceptable

### Lock Granularity

```go
// ❌ Too coarse - blocks all user operations
func processUser(userID string) error {
    return globalLock.WithLock("all_users", func() error {
        // Process single user
        return nil
    })
}

// ✅ Appropriate granularity - blocks only specific user
func processUser(userID string) error {
    return userLock.WithLock(fmt.Sprintf("user:%s", userID), func() error {
        // Process specific user
        return nil
    })
}
```

### Error Handling and Timeouts

```go
func criticalOperation(ctx context.Context, key string) error {
    // Set reasonable timeout for lock acquisition
    lockCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()
    
    return lockManager.WithLock(lockCtx, key, 30*time.Second, func(ctx context.Context) error {
        // Use original context for the actual work
        return performWork(ctx)
    })
}
```

## Consequences

### Positive
- **Data consistency**: Prevents race conditions and data corruption
- **Ordered processing**: Ensures operations happen in correct sequence
- **Scalability**: Supports horizontal scaling with coordination
- **Flexibility**: Multiple backends for different requirements

### Negative
- **Complexity**: Additional infrastructure and code complexity
- **Performance overhead**: Network calls and coordination delays
- **Failure modes**: Lock holders can fail, leaving locks orphaned
- **Deadlock potential**: Multiple locks can create deadlock scenarios

## Best Practices

1. **Keep locks short**: Minimize lock duration to reduce contention
2. **Use timeouts**: Always set timeouts for lock acquisition
3. **Handle failures gracefully**: Plan for lock acquisition failures
4. **Monitor lock metrics**: Track acquisition rates and hold times
5. **Test thoroughly**: Verify behavior under high concurrency
6. **Document lock requirements**: Clear documentation of what requires locking

## Anti-patterns to Avoid

```go
// ❌ Bad: No timeout
lock, _ := lockManager.AcquireLock(context.Background(), key, time.Minute)

// ❌ Bad: Holding lock too long
lockManager.WithLock(ctx, key, 1*time.Hour, longRunningFunction)

// ❌ Bad: Not handling lock acquisition failure
lock, _ := lockManager.AcquireLock(ctx, key, ttl) // Ignoring error

// ❌ Bad: Nested locks (potential deadlock)
func operation1() {
    lockManager.WithLock(ctx, "lock1", ttl, func() {
        lockManager.WithLock(ctx, "lock2", ttl, func() {
            // Work
        })
    })
}

// ✅ Good: Acquire locks in consistent order
func operation1() {
    keys := []string{"lock1", "lock2"}
    sort.Strings(keys) // Always acquire in same order
    // Acquire locks sequentially
}
```

## References

- [Distributed Locks with Redis](https://redis.io/docs/manual/patterns/distributed-locks/)
- [PostgreSQL Advisory Locks](https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS)
- [The Redlock Algorithm](https://redis.io/docs/manual/patterns/distributed-locks/#the-redlock-algorithm)
- [Go Concurrency Patterns](https://blog.golang.org/pipelines)
- [Distributed Systems Consensus](https://raft.github.io/)
