# Resiliency Patterns

## Status

`accepted`

## Context

In distributed systems, failures are inevitable. Services may become unavailable, network connections can fail, and external dependencies may experience issues. Without proper resiliency patterns, these failures can cascade throughout the system, leading to complete service outages.

### Problem Statement

Distributed systems face multiple failure modes:
- **Network failures**: Timeouts, connection drops, DNS issues
- **Service failures**: Crashes, overload, resource exhaustion
- **Dependency failures**: External API outages, database unavailability
- **Resource contention**: CPU, memory, or I/O limitations
- **Cascading failures**: One failure triggering multiple failures

### Business Impact

Poor resiliency leads to:
- **Customer dissatisfaction**: Service unavailability affects user experience
- **Revenue loss**: Downtime directly impacts business operations
- **Reputation damage**: Frequent outages harm brand trust
- **Operational overhead**: Manual intervention increases costs
- **Compliance issues**: SLA violations and regulatory concerns

## Decision

We will implement a comprehensive resiliency strategy using proven patterns to ensure system stability and graceful degradation during failures.

### Core Resiliency Patterns

#### 1. Retry Pattern

Automatically retry failed operations with intelligent backoff strategies.

```go
package retry

import (
    "context"
    "fmt"
    "math"
    "math/rand"
    "time"
)

type RetryConfig struct {
    MaxAttempts    int
    InitialDelay   time.Duration
    MaxDelay       time.Duration
    Multiplier     float64
    Jitter         bool
    RetryableFunc  func(error) bool
}

type RetryableOperation func() error

func WithRetry(ctx context.Context, config RetryConfig, operation RetryableOperation) error {
    var lastErr error
    
    for attempt := 1; attempt <= config.MaxAttempts; attempt++ {
        if attempt > 1 {
            delay := calculateDelay(config, attempt-1)
            select {
            case <-time.After(delay):
            case <-ctx.Done():
                return ctx.Err()
            }
        }
        
        if err := operation(); err != nil {
            lastErr = err
            
            // Check if error is retryable
            if config.RetryableFunc != nil && !config.RetryableFunc(err) {
                return err
            }
            
            // Last attempt, return error
            if attempt == config.MaxAttempts {
                return fmt.Errorf("operation failed after %d attempts: %w", config.MaxAttempts, err)
            }
            
            continue
        }
        
        // Success
        return nil
    }
    
    return lastErr
}

func calculateDelay(config RetryConfig, attempt int) time.Duration {
    delay := float64(config.InitialDelay) * math.Pow(config.Multiplier, float64(attempt))
    
    if delay > float64(config.MaxDelay) {
        delay = float64(config.MaxDelay)
    }
    
    if config.Jitter {
        jitter := rand.Float64() * 0.1 * delay
        delay += jitter
    }
    
    return time.Duration(delay)
}

// Example usage
func ExampleRetryHTTPCall() error {
    config := RetryConfig{
        MaxAttempts:   3,
        InitialDelay:  100 * time.Millisecond,
        MaxDelay:      5 * time.Second,
        Multiplier:    2.0,
        Jitter:        true,
        RetryableFunc: isRetryableHTTPError,
    }
    
    return WithRetry(context.Background(), config, func() error {
        resp, err := http.Get("https://api.example.com/data")
        if err != nil {
            return err
        }
        defer resp.Body.Close()
        
        if resp.StatusCode >= 500 {
            return fmt.Errorf("server error: %d", resp.StatusCode)
        }
        
        return nil
    })
}

func isRetryableHTTPError(err error) bool {
    // Retry on network errors and 5xx status codes
    if strings.Contains(err.Error(), "connection refused") ||
       strings.Contains(err.Error(), "timeout") ||
       strings.Contains(err.Error(), "server error") {
        return true
    }
    return false
}
```

#### 2. Circuit Breaker Pattern

Prevent cascading failures by failing fast when services are unhealthy.

```go
// See detailed implementation in 008-use-circuit-breaker.md
type CircuitBreaker struct {
    // Implementation from previous ADR
}

func (cb *CircuitBreaker) ExecuteWithFallback(operation func() (interface{}, error), fallback func() (interface{}, error)) (interface{}, error) {
    result, err := cb.Execute(operation)
    if err == ErrCircuitOpen && fallback != nil {
        return fallback()
    }
    return result, err
}
```

#### 3. Rate Limiting Pattern

Control the rate of requests to prevent resource exhaustion.

```go
package ratelimit

import (
    "context"
    "fmt"
    "time"
    
    "golang.org/x/time/rate"
)

type RateLimiter struct {
    limiter *rate.Limiter
    name    string
}

func NewRateLimiter(requestsPerSecond float64, burst int, name string) *RateLimiter {
    return &RateLimiter{
        limiter: rate.NewLimiter(rate.Limit(requestsPerSecond), burst),
        name:    name,
    }
}

func (rl *RateLimiter) Allow() bool {
    return rl.limiter.Allow()
}

func (rl *RateLimiter) Wait(ctx context.Context) error {
    return rl.limiter.Wait(ctx)
}

// Middleware for HTTP rate limiting
func (rl *RateLimiter) HTTPMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if !rl.Allow() {
            http.Error(w, "Rate limit exceeded", http.StatusTooManyRequests)
            return
        }
        next.ServeHTTP(w, r)
    })
}
```

#### 4. Timeout Pattern

Set boundaries on operation duration to prevent resource hogging.

```go
package timeout

import (
    "context"
    "time"
)

type TimeoutConfig struct {
    Operation time.Duration
    Total     time.Duration
}

func WithTimeout(ctx context.Context, config TimeoutConfig, operation func(context.Context) error) error {
    // Create timeout context
    timeoutCtx, cancel := context.WithTimeout(ctx, config.Operation)
    defer cancel()
    
    // Execute operation with timeout
    done := make(chan error, 1)
    go func() {
        done <- operation(timeoutCtx)
    }()
    
    select {
    case err := <-done:
        return err
    case <-timeoutCtx.Done():
        return timeoutCtx.Err()
    }
}

// HTTP client with timeout
func NewHTTPClientWithTimeout(timeout time.Duration) *http.Client {
    return &http.Client{
        Timeout: timeout,
        Transport: &http.Transport{
            DialContext: (&net.Dialer{
                Timeout:   5 * time.Second,
                KeepAlive: 30 * time.Second,
            }).DialContext,
            TLSHandshakeTimeout:   10 * time.Second,
            ResponseHeaderTimeout: 10 * time.Second,
            IdleConnTimeout:       90 * time.Second,
        },
    }
}
```

#### 5. Bulkhead Pattern

Isolate resources to prevent failure in one area from affecting others.

```go
package bulkhead

import (
    "context"
    "fmt"
)

type ResourcePool struct {
    name      string
    semaphore chan struct{}
    active    int64
    total     int64
}

func NewResourcePool(name string, size int) *ResourcePool {
    return &ResourcePool{
        name:      name,
        semaphore: make(chan struct{}, size),
        total:     int64(size),
    }
}

func (rp *ResourcePool) Acquire(ctx context.Context) error {
    select {
    case rp.semaphore <- struct{}{}:
        atomic.AddInt64(&rp.active, 1)
        return nil
    case <-ctx.Done():
        return ctx.Err()
    }
}

func (rp *ResourcePool) Release() {
    select {
    case <-rp.semaphore:
        atomic.AddInt64(&rp.active, -1)
    default:
        // Should not happen in normal operation
        panic("bulkhead: release called without acquire")
    }
}

func (rp *ResourcePool) Execute(ctx context.Context, operation func() error) error {
    if err := rp.Acquire(ctx); err != nil {
        return fmt.Errorf("bulkhead %s: failed to acquire resource: %w", rp.name, err)
    }
    defer rp.Release()
    
    return operation()
}

// Thread pool bulkhead
type ThreadPoolBulkhead struct {
    pools map[string]*ResourcePool
}

func NewThreadPoolBulkhead() *ThreadPoolBulkhead {
    return &ThreadPoolBulkhead{
        pools: make(map[string]*ResourcePool),
    }
}

func (tpb *ThreadPoolBulkhead) AddPool(name string, size int) {
    tpb.pools[name] = NewResourcePool(name, size)
}

func (tpb *ThreadPoolBulkhead) Execute(ctx context.Context, poolName string, operation func() error) error {
    pool, exists := tpb.pools[poolName]
    if !exists {
        return fmt.Errorf("thread pool %s not found", poolName)
    }
    
    return pool.Execute(ctx, operation)
}
```

#### 6. Fallback Pattern

Provide alternative responses when primary operations fail.

```go
package fallback

import (
    "context"
    "log"
)

type FallbackChain struct {
    operations []func(context.Context) (interface{}, error)
    name       string
}

func NewFallbackChain(name string) *FallbackChain {
    return &FallbackChain{
        name: name,
    }
}

func (fc *FallbackChain) AddOperation(op func(context.Context) (interface{}, error)) *FallbackChain {
    fc.operations = append(fc.operations, op)
    return fc
}

func (fc *FallbackChain) Execute(ctx context.Context) (interface{}, error) {
    var lastErr error
    
    for i, operation := range fc.operations {
        result, err := operation(ctx)
        if err == nil {
            if i > 0 {
                log.Printf("fallback chain %s: succeeded with fallback %d", fc.name, i)
            }
            return result, nil
        }
        
        lastErr = err
        log.Printf("fallback chain %s: operation %d failed: %v", fc.name, i, err)
    }
    
    return nil, fmt.Errorf("all fallback operations failed, last error: %w", lastErr)
}

// Example usage
func GetUserProfileWithFallback(ctx context.Context, userID string) (*UserProfile, error) {
    chain := NewFallbackChain("user-profile").
        AddOperation(func(ctx context.Context) (interface{}, error) {
            // Primary: Get from main database
            return mainDB.GetUserProfile(ctx, userID)
        }).
        AddOperation(func(ctx context.Context) (interface{}, error) {
            // Fallback 1: Get from cache
            return cache.GetUserProfile(ctx, userID)
        }).
        AddOperation(func(ctx context.Context) (interface{}, error) {
            // Fallback 2: Get from replica database
            return replicaDB.GetUserProfile(ctx, userID)
        }).
        AddOperation(func(ctx context.Context) (interface{}, error) {
            // Fallback 3: Return default profile
            return &UserProfile{
                ID:   userID,
                Name: "Guest User",
            }, nil
        })
    
    result, err := chain.Execute(ctx)
    if err != nil {
        return nil, err
    }
    
    return result.(*UserProfile), nil
}
```

### Composite Resiliency Pattern

Combine multiple patterns for comprehensive protection:

```go
package resiliency

type ResiliencyWrapper struct {
    circuitBreaker *CircuitBreaker
    rateLimiter    *RateLimiter
    retryConfig    RetryConfig
    timeout        time.Duration
    bulkhead       *ResourcePool
}

func NewResiliencyWrapper(config ResiliencyConfig) *ResiliencyWrapper {
    return &ResiliencyWrapper{
        circuitBreaker: NewCircuitBreaker(config.CircuitBreaker),
        rateLimiter:    NewRateLimiter(config.RateLimit.RPS, config.RateLimit.Burst, config.Name),
        retryConfig:    config.Retry,
        timeout:        config.Timeout,
        bulkhead:       NewResourcePool(config.Name+"-pool", config.BulkheadSize),
    }
}

func (rw *ResiliencyWrapper) Execute(ctx context.Context, operation func(context.Context) (interface{}, error)) (interface{}, error) {
    // Apply rate limiting
    if !rw.rateLimiter.Allow() {
        return nil, errors.New("rate limit exceeded")
    }
    
    // Apply bulkhead isolation
    return rw.bulkhead.Execute(ctx, func() error {
        var result interface{}
        var err error
        
        // Apply circuit breaker and retry
        result, err = rw.circuitBreaker.Execute(func() (interface{}, error) {
            return WithRetry(ctx, rw.retryConfig, func() error {
                // Apply timeout
                timeoutCtx, cancel := context.WithTimeout(ctx, rw.timeout)
                defer cancel()
                
                var operationErr error
                result, operationErr = operation(timeoutCtx)
                return operationErr
            })
        })
        
        return err
    })
}
```

### Configuration and Monitoring

```go
type ResiliencyConfig struct {
    Name           string
    CircuitBreaker CircuitBreakerSettings
    RateLimit      RateLimitSettings
    Retry          RetryConfig
    Timeout        time.Duration
    BulkheadSize   int
}

type RateLimitSettings struct {
    RPS   float64
    Burst int
}

// Service-specific configurations
var ServiceConfigs = map[string]ResiliencyConfig{
    "payment-service": {
        Name: "payment-service",
        CircuitBreaker: CircuitBreakerSettings{
            FailureThreshold: 5,
            RecoveryTimeout:  30 * time.Second,
        },
        RateLimit: RateLimitSettings{
            RPS:   100,
            Burst: 200,
        },
        Retry: RetryConfig{
            MaxAttempts:  3,
            InitialDelay: 100 * time.Millisecond,
            MaxDelay:     1 * time.Second,
            Multiplier:   2.0,
        },
        Timeout:      5 * time.Second,
        BulkheadSize: 10,
    },
    "notification-service": {
        Name: "notification-service",
        CircuitBreaker: CircuitBreakerSettings{
            FailureThreshold: 10,
            RecoveryTimeout:  60 * time.Second,
        },
        RateLimit: RateLimitSettings{
            RPS:   50,
            Burst: 100,
        },
        Retry: RetryConfig{
            MaxAttempts:  5,
            InitialDelay: 200 * time.Millisecond,
            MaxDelay:     10 * time.Second,
            Multiplier:   1.5,
        },
        Timeout:      10 * time.Second,
        BulkheadSize: 5,
    },
}
```

## Consequences

### Positive
- **Improved reliability**: System continues operating during partial failures
- **Better user experience**: Graceful degradation instead of complete failures
- **Faster recovery**: Quick detection and isolation of problems
- **Resource protection**: Prevents resource exhaustion and cascading failures
- **Operational visibility**: Better monitoring and alerting capabilities

### Negative
- **Increased complexity**: More moving parts to configure and monitor
- **Performance overhead**: Additional latency from pattern implementations
- **Configuration challenges**: Requires careful tuning for optimal results
- **False positives**: Overly aggressive patterns may block legitimate requests

### Mitigation Strategies
- **Start simple**: Implement patterns incrementally
- **Monitor extensively**: Track pattern effectiveness and false positives
- **Test thoroughly**: Validate behavior under various failure scenarios
- **Regular tuning**: Adjust configurations based on operational data

## Implementation Guidelines

### Pattern Selection Matrix

| Failure Type | Recommended Patterns | Priority |
|-------------|---------------------|----------|
| Network timeouts | Retry + Timeout + Circuit Breaker | High |
| Service overload | Rate Limiting + Bulkhead | High |
| Dependency failures | Circuit Breaker + Fallback | High |
| Resource contention | Bulkhead + Rate Limiting | Medium |
| Transient errors | Retry + Jitter | Medium |

### Testing Strategies

```go
func TestResiliencyPatterns(t *testing.T) {
    // Test circuit breaker
    t.Run("circuit breaker opens on failures", func(t *testing.T) {
        // Simulate consecutive failures
        // Verify circuit opens
        // Test recovery behavior
    })
    
    // Test retry logic
    t.Run("retry with exponential backoff", func(t *testing.T) {
        // Mock transient failures
        // Verify retry attempts
        // Check backoff timing
    })
    
    // Test bulkhead isolation
    t.Run("bulkhead prevents resource exhaustion", func(t *testing.T) {
        // Simulate resource contention
        // Verify isolation effectiveness
    })
}
```

## References

- [Release It! - Michael Nygard](https://pragprog.com/titles/mnee2/release-it-second-edition/)
- [Building Microservices - Sam Newman](https://samnewman.io/books/building_microservices_2nd_edition/)
- [Site Reliability Engineering - Google](https://sre.google/sre-book/table-of-contents/)
- [Netflix Hystrix Documentation](https://github.com/Netflix/Hystrix/wiki)
- [Microsoft Azure Resiliency Patterns](https://docs.microsoft.com/en-us/azure/architecture/patterns/category/resiliency)
- [AWS Well-Architected Reliability Pillar](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html)
