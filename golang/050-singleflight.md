# ADR 050: Singleflight Pattern for Duplicate Function Call Suppression

## Status

**Accepted**

## Context

In high-traffic applications, multiple goroutines or requests often need to perform the same expensive operation simultaneously. Without coordination, this leads to:

- **Resource waste**: Multiple identical expensive operations running concurrently
- **System overload**: Database, cache, or external service being hit with duplicate requests
- **Thundering herd**: Sudden spikes in load when cache expires or system restarts
- **Poor user experience**: Slower response times due to resource contention

Common scenarios include:
- Cache miss storms (multiple requests rebuilding the same cache entry)
- Expensive database queries or aggregations
- External API calls with rate limits
- Large file generation (reports, exports)
- Heavy computational tasks

## Decision

We will implement the singleflight pattern using Go's `golang.org/x/sync/singleflight` package and custom implementations for advanced use cases, ensuring that identical expensive operations are executed only once while multiple callers wait for the same result.

### 1. Basic Singleflight Implementation

```go
package singleflight

import (
    "context"
    "fmt"
    "sync"
    "time"
    
    "golang.org/x/sync/singleflight"
)

// Manager wraps singleflight.Group with additional functionality
type Manager struct {
    group   singleflight.Group
    metrics MetricsCollector
}

func NewManager(metrics MetricsCollector) *Manager {
    return &Manager{
        metrics: metrics,
    }
}

// Do executes and returns the results of the given function, making sure that
// only one execution is in-flight for a given key at a time
func (m *Manager) Do(key string, fn func() (interface{}, error)) (interface{}, error) {
    start := time.Now()
    
    result, err, shared := m.group.Do(key, fn)
    
    // Record metrics
    duration := time.Since(start)
    m.metrics.RecordSingleflight(key, duration, shared, err != nil)
    
    return result, err
}

// DoChan is like Do but returns a channel that will receive the results
func (m *Manager) DoChan(key string, fn func() (interface{}, error)) <-chan Result {
    ch := m.group.DoChan(key, fn)
    resultCh := make(chan Result, 1)
    
    go func() {
        defer close(resultCh)
        res := <-ch
        resultCh <- Result{
            Val:    res.Val,
            Err:    res.Err,
            Shared: res.Shared,
        }
    }()
    
    return resultCh
}

// Forget tells the singleflight to forget about a key
func (m *Manager) Forget(key string) {
    m.group.Forget(key)
}

type Result struct {
    Val    interface{}
    Err    error
    Shared bool
}

type MetricsCollector interface {
    RecordSingleflight(key string, duration time.Duration, shared bool, failed bool)
}
```

### 2. Context-Aware Singleflight

```go
package contextsingleflight

import (
    "context"
    "errors"
    "sync"
    "time"
)

var (
    ErrContextCanceled = errors.New("context canceled before function completed")
    ErrTimeout        = errors.New("function execution timed out")
)

// ContextManager provides context-aware singleflight functionality
type ContextManager struct {
    mu     sync.RWMutex
    calls  map[string]*call
}

type call struct {
    wg     sync.WaitGroup
    val    interface{}
    err    error
    forgot bool
    
    // Context handling
    ctx    context.Context
    cancel context.CancelFunc
    done   chan struct{}
}

func NewContextManager() *ContextManager {
    return &ContextManager{
        calls: make(map[string]*call),
    }
}

// DoContext executes function with context support
func (cm *ContextManager) DoContext(ctx context.Context, key string, fn func(context.Context) (interface{}, error)) (interface{}, error) {
    cm.mu.Lock()
    
    if c, ok := cm.calls[key]; ok && !c.forgot {
        cm.mu.Unlock()
        
        // Wait for either the call to complete or our context to be canceled
        select {
        case <-c.done:
            return c.val, c.err
        case <-ctx.Done():
            return nil, ctx.Err()
        }
    }
    
    // Create new call
    callCtx, cancel := context.WithCancel(context.Background())
    c := &call{
        ctx:    callCtx,
        cancel: cancel,
        done:   make(chan struct{}),
    }
    c.wg.Add(1)
    cm.calls[key] = c
    cm.mu.Unlock()
    
    go func() {
        defer func() {
            c.wg.Done()
            close(c.done)
            
            cm.mu.Lock()
            delete(cm.calls, key)
            cm.mu.Unlock()
        }()
        
        // Execute the function with the call's context
        c.val, c.err = fn(c.ctx)
    }()
    
    // Wait for either the call to complete or our context to be canceled
    select {
    case <-c.done:
        return c.val, c.err
    case <-ctx.Done():
        // Our context was canceled, but we don't cancel the ongoing call
        // Other waiters might still be interested in the result
        return nil, ctx.Err()
    }
}

// ForgetContext cancels and forgets about a key
func (cm *ContextManager) ForgetContext(key string) {
    cm.mu.Lock()
    defer cm.mu.Unlock()
    
    if c, ok := cm.calls[key]; ok {
        c.forgot = true
        c.cancel() // Cancel the ongoing operation
        delete(cm.calls, key)
    }
}
```

### 3. TTL-Based Singleflight

For caching expensive operations with automatic expiration:

```go
package ttlsingleflight

import (
    "sync"
    "time"
)

// TTLManager provides singleflight with TTL-based result caching
type TTLManager struct {
    mu      sync.RWMutex
    calls   map[string]*ttlCall
    results map[string]*cachedResult
}

type ttlCall struct {
    wg   sync.WaitGroup
    val  interface{}
    err  error
}

type cachedResult struct {
    val      interface{}
    err      error
    expireAt time.Time
}

func NewTTLManager() *TTLManager {
    tm := &TTLManager{
        calls:   make(map[string]*ttlCall),
        results: make(map[string]*cachedResult),
    }
    
    // Start cleanup goroutine
    go tm.cleanup()
    
    return tm
}

// DoWithTTL executes function and caches result for TTL duration
func (tm *TTLManager) DoWithTTL(key string, ttl time.Duration, fn func() (interface{}, error)) (interface{}, error) {
    // Check for cached result first
    tm.mu.RLock()
    if cached, ok := tm.results[key]; ok && time.Now().Before(cached.expireAt) {
        tm.mu.RUnlock()
        return cached.val, cached.err
    }
    tm.mu.RUnlock()
    
    // Check for ongoing call
    tm.mu.Lock()
    if c, ok := tm.calls[key]; ok {
        tm.mu.Unlock()
        c.wg.Wait()
        return c.val, c.err
    }
    
    // Create new call
    c := &ttlCall{}
    c.wg.Add(1)
    tm.calls[key] = c
    tm.mu.Unlock()
    
    // Execute function
    go func() {
        defer func() {
            c.wg.Done()
            
            tm.mu.Lock()
            delete(tm.calls, key)
            
            // Cache result if TTL > 0
            if ttl > 0 && c.err == nil {
                tm.results[key] = &cachedResult{
                    val:      c.val,
                    err:      c.err,
                    expireAt: time.Now().Add(ttl),
                }
            }
            tm.mu.Unlock()
        }()
        
        c.val, c.err = fn()
    }()
    
    c.wg.Wait()
    return c.val, c.err
}

// cleanup removes expired cached results
func (tm *TTLManager) cleanup() {
    ticker := time.NewTicker(time.Minute)
    defer ticker.Stop()
    
    for range ticker.C {
        now := time.Now()
        tm.mu.Lock()
        for key, cached := range tm.results {
            if now.After(cached.expireAt) {
                delete(tm.results, key)
            }
        }
        tm.mu.Unlock()
    }
}
```

### 4. Real-World Usage Examples

#### Cache Miss Storm Prevention

```go
package cache

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/redis/go-redis/v9"
)

type UserCache struct {
    redis       redis.UniversalClient
    db          UserRepository
    singleflight *Manager
}

func NewUserCache(redis redis.UniversalClient, db UserRepository) *UserCache {
    return &UserCache{
        redis:       redis,
        db:          db,
        singleflight: NewManager(NewPrometheusMetrics()),
    }
}

// GetUser prevents cache miss storms for user data
func (uc *UserCache) GetUser(ctx context.Context, userID string) (*User, error) {
    cacheKey := fmt.Sprintf("user:%s", userID)
    
    // Try cache first
    cached, err := uc.redis.Get(ctx, cacheKey).Result()
    if err == nil {
        var user User
        if err := json.Unmarshal([]byte(cached), &user); err == nil {
            return &user, nil
        }
    }
    
    // Use singleflight to prevent multiple DB queries for the same user
    result, err := uc.singleflight.Do(cacheKey, func() (interface{}, error) {
        // Fetch from database
        user, err := uc.db.GetUserByID(ctx, userID)
        if err != nil {
            return nil, err
        }
        
        // Cache the result
        userData, _ := json.Marshal(user)
        uc.redis.Set(ctx, cacheKey, userData, 5*time.Minute)
        
        return user, nil
    })
    
    if err != nil {
        return nil, err
    }
    
    return result.(*User), nil
}
```

#### Expensive Report Generation

```go
package reports

import (
    "context"
    "fmt"
    "time"
)

type ReportGenerator struct {
    singleflight *ContextManager
    storage      ReportStorage
    analytics    AnalyticsService
}

func NewReportGenerator(storage ReportStorage, analytics AnalyticsService) *ReportGenerator {
    return &ReportGenerator{
        singleflight: NewContextManager(),
        storage:      storage,
        analytics:    analytics,
    }
}

// GenerateMonthlyReport ensures only one report generation per month
func (rg *ReportGenerator) GenerateMonthlyReport(ctx context.Context, year int, month int) (*Report, error) {
    reportKey := fmt.Sprintf("monthly_report:%d-%02d", year, month)
    
    // Check if report already exists
    if existing, err := rg.storage.GetReport(ctx, reportKey); err == nil {
        return existing, nil
    }
    
    // Use singleflight to prevent multiple report generations
    result, err := rg.singleflight.DoContext(ctx, reportKey, func(ctx context.Context) (interface{}, error) {
        // Check storage again in case another goroutine completed while we waited
        if existing, err := rg.storage.GetReport(ctx, reportKey); err == nil {
            return existing, nil
        }
        
        // Generate the expensive report
        report, err := rg.analytics.GenerateMonthlyReport(ctx, year, month)
        if err != nil {
            return nil, fmt.Errorf("generate report: %w", err)
        }
        
        // Store the generated report
        if err := rg.storage.SaveReport(ctx, reportKey, report); err != nil {
            return nil, fmt.Errorf("save report: %w", err)
        }
        
        return report, nil
    })
    
    if err != nil {
        return nil, err
    }
    
    return result.(*Report), nil
}
```

#### External API Rate Limiting

```go
package external

import (
    "context"
    "fmt"
    "sync"
    "time"
)

type RateLimitedClient struct {
    client       HTTPClient
    singleflight *Manager
    rateLimiter  *RateLimiter
}

func NewRateLimitedClient(client HTTPClient, requestsPerSecond int) *RateLimitedClient {
    return &RateLimitedClient{
        client:       client,
        singleflight: NewManager(NewPrometheusMetrics()),
        rateLimiter:  NewRateLimiter(requestsPerSecond),
    }
}

// GetExchangeRate prevents duplicate API calls for the same currency pair
func (rlc *RateLimitedClient) GetExchangeRate(ctx context.Context, from, to string) (*ExchangeRate, error) {
    key := fmt.Sprintf("exchange_rate:%s:%s", from, to)
    
    result, err := rlc.singleflight.Do(key, func() (interface{}, error) {
        // Wait for rate limiter
        if err := rlc.rateLimiter.Wait(ctx); err != nil {
            return nil, err
        }
        
        // Make the actual API call
        rate, err := rlc.client.GetExchangeRate(ctx, from, to)
        if err != nil {
            return nil, err
        }
        
        return rate, nil
    })
    
    if err != nil {
        return nil, err
    }
    
    return result.(*ExchangeRate), nil
}
```

### 5. Testing Singleflight Behavior

```go
package singleflight_test

import (
    "context"
    "sync"
    "sync/atomic"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestSingleflight_PreventsDuplicateCalls(t *testing.T) {
    manager := NewManager(NewNullMetrics())
    
    var callCount int64
    fn := func() (interface{}, error) {
        atomic.AddInt64(&callCount, 1)
        time.Sleep(100 * time.Millisecond) // Simulate work
        return "result", nil
    }
    
    // Start multiple goroutines calling the same function
    var wg sync.WaitGroup
    numGoroutines := 10
    results := make([]interface{}, numGoroutines)
    
    for i := 0; i < numGoroutines; i++ {
        wg.Add(1)
        go func(idx int) {
            defer wg.Done()
            result, err := manager.Do("test-key", fn)
            require.NoError(t, err)
            results[idx] = result
        }(i)
    }
    
    wg.Wait()
    
    // Verify function was called only once
    assert.Equal(t, int64(1), atomic.LoadInt64(&callCount))
    
    // Verify all goroutines got the same result
    for _, result := range results {
        assert.Equal(t, "result", result)
    }
}

func TestSingleflight_ContextCancellation(t *testing.T) {
    manager := NewContextManager()
    
    ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
    defer cancel()
    
    fn := func(ctx context.Context) (interface{}, error) {
        select {
        case <-time.After(200 * time.Millisecond):
            return "result", nil
        case <-ctx.Done():
            return nil, ctx.Err()
        }
    }
    
    result, err := manager.DoContext(ctx, "test-key", fn)
    assert.Nil(t, result)
    assert.ErrorIs(t, err, context.DeadlineExceeded)
}

func BenchmarkSingleflight(b *testing.B) {
    manager := NewManager(NewNullMetrics())
    
    fn := func() (interface{}, error) {
        time.Sleep(time.Millisecond) // Simulate work
        return "result", nil
    }
    
    b.ResetTimer()
    b.RunParallel(func(pb *testing.PB) {
        for pb.Next() {
            _, err := manager.Do("bench-key", fn)
            if err != nil {
                b.Fatal(err)
            }
        }
    })
}
```

### 6. Monitoring and Metrics

```go
package metrics

import (
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    singleflightCalls = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "singleflight_calls_total",
            Help: "Total number of singleflight calls",
        },
        []string{"key", "shared", "status"},
    )
    
    singleflightDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "singleflight_duration_seconds",
            Help:    "Duration of singleflight calls",
            Buckets: prometheus.DefBuckets,
        },
        []string{"key", "shared"},
    )
    
    singleflightWaiters = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "singleflight_waiters_current",
            Help: "Current number of goroutines waiting for singleflight calls",
        },
        []string{"key"},
    )
)

type PrometheusMetrics struct{}

func NewPrometheusMetrics() *PrometheusMetrics {
    return &PrometheusMetrics{}
}

func (pm *PrometheusMetrics) RecordSingleflight(key string, duration time.Duration, shared bool, failed bool) {
    sharedStr := "false"
    if shared {
        sharedStr = "true"
    }
    
    status := "success"
    if failed {
        status = "error"
    }
    
    singleflightCalls.WithLabelValues(key, sharedStr, status).Inc()
    singleflightDuration.WithLabelValues(key, sharedStr).Observe(duration.Seconds())
}
```

## Implementation Guidelines

### When to Use Singleflight

1. **Cache miss storms**: Multiple requests for the same uncached data
2. **Expensive computations**: Heavy CPU or I/O bound operations
3. **External API calls**: Rate-limited or expensive third-party services
4. **Database queries**: Complex queries or aggregations
5. **File operations**: Large file reads or generations

### Key Selection Strategy

```go
// ✅ Good: Specific, meaningful keys
func getUserCacheKey(userID string) string {
    return fmt.Sprintf("user:profile:%s", userID)
}

func getReportCacheKey(year, month int) string {
    return fmt.Sprintf("report:monthly:%d-%02d", year, month)
}

// ❌ Bad: Generic or overly broad keys  
func getBroadKey() string {
    return "all_users" // Too broad, prevents parallelism
}
```

### Error Handling

```go
// Handle errors appropriately - failed calls don't cache errors
result, err := singleflight.Do(key, func() (interface{}, error) {
    data, err := expensiveOperation()
    if err != nil {
        // This error will be returned to all waiters
        return nil, fmt.Errorf("expensive operation failed: %w", err)
    }
    return data, nil
})
```

## Consequences

### Positive
- **Resource efficiency**: Eliminates duplicate expensive operations
- **Improved performance**: Faster response times during high concurrency
- **System stability**: Prevents overload of downstream systems
- **Cost reduction**: Fewer external API calls and database queries

### Negative
- **Complexity**: Additional coordination logic and potential debugging complexity
- **Memory usage**: Storing results and coordination state
- **Failure amplification**: Single failure affects all waiting callers
- **Debugging challenges**: Harder to trace which goroutine initiated the call

## Best Practices

1. **Choose appropriate keys**: Use specific, meaningful keys that allow proper parallelism
2. **Handle errors gracefully**: Don't cache errors unless specifically desired
3. **Monitor metrics**: Track hit rates, sharing, and performance improvements
4. **Set timeouts**: Use context with timeouts for operations that might hang
5. **Consider TTL**: For cacheable results, use TTL-based singleflight
6. **Test thoroughly**: Verify behavior under high concurrency

## Anti-patterns to Avoid

```go
// ❌ Bad: Using same key for different operations
singleflight.Do("user_operation", func() (interface{}, error) {
    return updateUser(userID)
})
singleflight.Do("user_operation", func() (interface{}, error) {
    return deleteUser(userID) // Different operation, same key!
})

// ❌ Bad: Not handling context cancellation
singleflight.Do(key, func() (interface{}, error) {
    // Long operation without context checking
    return longRunningOperation()
})

// ❌ Bad: Caching errors unnecessarily
singleflight.Do(key, func() (interface{}, error) {
    result, err := operation()
    // This will cache the error for all waiters
    return result, err
})
```

## References

- [Go Singleflight Package](https://pkg.go.dev/golang.org/x/sync/singleflight)
- [Groupcache Implementation](https://github.com/golang/groupcache)
- [Cache Stampede Problem](https://en.wikipedia.org/wiki/Cache_stampede)
- [Thundering Herd Problem](https://en.wikipedia.org/wiki/Thundering_herd_problem)
