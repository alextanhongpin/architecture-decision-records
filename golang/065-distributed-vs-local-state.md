# Distributed vs Local State Management

## Status

`accepted`

## Context

When designing distributed systems, a critical architectural decision is where to maintain state. State can be:

- **Local State**: Maintained within a single process/instance
- **Distributed State**: Shared across multiple processes/instances
- **Hybrid State**: Combining both local and distributed state for optimization

The choice affects consistency, performance, scalability, and complexity. Understanding when to use each approach is crucial for building robust, scalable systems.

## Decision

**Use a layered approach to state management based on consistency requirements and performance characteristics:**

### 1. Local State Patterns

#### Atomic Operations
```go
package counter

import (
    "sync/atomic"
    "time"
)

// LocalCounter maintains state within a single process
type LocalCounter struct {
    value    int64
    lastSeen int64 // Unix timestamp
}

func NewLocalCounter() *LocalCounter {
    return &LocalCounter{
        lastSeen: time.Now().Unix(),
    }
}

func (c *LocalCounter) Increment() int64 {
    atomic.StoreInt64(&c.lastSeen, time.Now().Unix())
    return atomic.AddInt64(&c.value, 1)
}

func (c *LocalCounter) Decrement() int64 {
    atomic.StoreInt64(&c.lastSeen, time.Now().Unix())
    return atomic.AddInt64(&c.value, -1)
}

func (c *LocalCounter) Get() int64 {
    return atomic.LoadInt64(&c.value)
}

func (c *LocalCounter) Reset() {
    atomic.StoreInt64(&c.value, 0)
    atomic.StoreInt64(&c.lastSeen, time.Now().Unix())
}

func (c *LocalCounter) LastActivity() time.Time {
    timestamp := atomic.LoadInt64(&c.lastSeen)
    return time.Unix(timestamp, 0)
}
```

#### Local Circuit Breaker
```go
package circuitbreaker

import (
    "context"
    "errors"
    "sync"
    "time"
)

type State int

const (
    StateClosed State = iota
    StateOpen
    StateHalfOpen
)

type LocalCircuitBreaker struct {
    mu                 sync.RWMutex
    state             State
    failures          int64
    successes         int64
    lastFailureTime   time.Time
    lastSuccessTime   time.Time
    
    // Configuration
    maxFailures       int64
    timeout           time.Duration
    resetTimeout      time.Duration
}

type Config struct {
    MaxFailures  int64
    Timeout      time.Duration
    ResetTimeout time.Duration
}

func NewLocalCircuitBreaker(config Config) *LocalCircuitBreaker {
    return &LocalCircuitBreaker{
        state:        StateClosed,
        maxFailures:  config.MaxFailures,
        timeout:      config.Timeout,
        resetTimeout: config.ResetTimeout,
    }
}

func (cb *LocalCircuitBreaker) Execute(ctx context.Context, fn func() error) error {
    if !cb.canExecute() {
        return errors.New("circuit breaker is open")
    }
    
    err := fn()
    cb.recordResult(err == nil)
    
    return err
}

func (cb *LocalCircuitBreaker) canExecute() bool {
    cb.mu.RLock()
    defer cb.mu.RUnlock()
    
    switch cb.state {
    case StateClosed:
        return true
    case StateOpen:
        return time.Since(cb.lastFailureTime) >= cb.resetTimeout
    case StateHalfOpen:
        return true
    default:
        return false
    }
}

func (cb *LocalCircuitBreaker) recordResult(success bool) {
    cb.mu.Lock()
    defer cb.mu.Unlock()
    
    if success {
        cb.successes++
        cb.lastSuccessTime = time.Now()
        
        if cb.state == StateHalfOpen {
            cb.state = StateClosed
            cb.failures = 0
        }
    } else {
        cb.failures++
        cb.lastFailureTime = time.Now()
        
        if cb.failures >= cb.maxFailures {
            cb.state = StateOpen
        }
    }
}

func (cb *LocalCircuitBreaker) GetState() State {
    cb.mu.RLock()
    defer cb.mu.RUnlock()
    return cb.state
}

func (cb *LocalCircuitBreaker) GetStats() (failures, successes int64, state State) {
    cb.mu.RLock()
    defer cb.mu.RUnlock()
    return cb.failures, cb.successes, cb.state
}
```

### 2. Distributed State Patterns

#### Distributed Counter with Redis
```go
package counter

import (
    "context"
    "fmt"
    "time"
    
    "github.com/redis/go-redis/v9"
)

type DistributedCounter struct {
    client redis.Cmdable
    key    string
    ttl    time.Duration
}

func NewDistributedCounter(client redis.Cmdable, key string, ttl time.Duration) *DistributedCounter {
    return &DistributedCounter{
        client: client,
        key:    key,
        ttl:    ttl,
    }
}

func (c *DistributedCounter) Increment(ctx context.Context) (int64, error) {
    pipe := c.client.Pipeline()
    
    incrCmd := pipe.Incr(ctx, c.key)
    pipe.Expire(ctx, c.key, c.ttl)
    
    _, err := pipe.Exec(ctx)
    if err != nil {
        return 0, fmt.Errorf("incrementing counter: %w", err)
    }
    
    return incrCmd.Val(), nil
}

func (c *DistributedCounter) IncrementBy(ctx context.Context, value int64) (int64, error) {
    pipe := c.client.Pipeline()
    
    incrCmd := pipe.IncrBy(ctx, c.key, value)
    pipe.Expire(ctx, c.key, c.ttl)
    
    _, err := pipe.Exec(ctx)
    if err != nil {
        return 0, fmt.Errorf("incrementing counter by %d: %w", value, err)
    }
    
    return incrCmd.Val(), nil
}

func (c *DistributedCounter) Decrement(ctx context.Context) (int64, error) {
    return c.IncrementBy(ctx, -1)
}

func (c *DistributedCounter) Get(ctx context.Context) (int64, error) {
    result, err := c.client.Get(ctx, c.key).Int64()
    if err != nil {
        if errors.Is(err, redis.Nil) {
            return 0, nil
        }
        return 0, fmt.Errorf("getting counter: %w", err)
    }
    
    return result, nil
}

func (c *DistributedCounter) Reset(ctx context.Context) error {
    err := c.client.Del(ctx, c.key).Err()
    if err != nil {
        return fmt.Errorf("resetting counter: %w", err)
    }
    
    return nil
}

func (c *DistributedCounter) SetTTL(ctx context.Context, ttl time.Duration) error {
    err := c.client.Expire(ctx, c.key, ttl).Err()
    if err != nil {
        return fmt.Errorf("setting TTL: %w", err)
    }
    
    return nil
}
```

#### Distributed Circuit Breaker
```go
package circuitbreaker

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/redis/go-redis/v9"
)

type DistributedCircuitBreaker struct {
    client       redis.Cmdable
    key          string
    config       Config
    instanceID   string
}

type CircuitBreakerState struct {
    State           State     `json:"state"`
    Failures        int64     `json:"failures"`
    Successes       int64     `json:"successes"`
    LastFailureTime time.Time `json:"last_failure_time"`
    LastSuccessTime time.Time `json:"last_success_time"`
    UpdatedBy       string    `json:"updated_by"`
    UpdatedAt       time.Time `json:"updated_at"`
}

func NewDistributedCircuitBreaker(
    client redis.Cmdable,
    key string,
    instanceID string,
    config Config,
) *DistributedCircuitBreaker {
    return &DistributedCircuitBreaker{
        client:     client,
        key:        key,
        config:     config,
        instanceID: instanceID,
    }
}

func (cb *DistributedCircuitBreaker) Execute(ctx context.Context, fn func() error) error {
    canExecute, err := cb.canExecute(ctx)
    if err != nil {
        return fmt.Errorf("checking circuit breaker state: %w", err)
    }
    
    if !canExecute {
        return errors.New("circuit breaker is open")
    }
    
    err = fn()
    if err := cb.recordResult(ctx, err == nil); err != nil {
        // Log error but don't fail the original operation
        fmt.Printf("Failed to record circuit breaker result: %v\n", err)
    }
    
    return err
}

func (cb *DistributedCircuitBreaker) canExecute(ctx context.Context) (bool, error) {
    state, err := cb.getState(ctx)
    if err != nil {
        return false, err
    }
    
    switch state.State {
    case StateClosed:
        return true, nil
    case StateOpen:
        return time.Since(state.LastFailureTime) >= cb.config.ResetTimeout, nil
    case StateHalfOpen:
        return true, nil
    default:
        return false, nil
    }
}

func (cb *DistributedCircuitBreaker) recordResult(ctx context.Context, success bool) error {
    script := `
        local key = KEYS[1]
        local success = ARGV[1] == "true"
        local maxFailures = tonumber(ARGV[2])
        local instanceID = ARGV[3]
        local now = ARGV[4]
        
        local stateData = redis.call('GET', key)
        local state = {
            state = 0,
            failures = 0,
            successes = 0,
            last_failure_time = now,
            last_success_time = now,
            updated_by = instanceID,
            updated_at = now
        }
        
        if stateData then
            state = cjson.decode(stateData)
        end
        
        if success then
            state.successes = state.successes + 1
            state.last_success_time = now
            
            if state.state == 2 then -- StateHalfOpen
                state.state = 0 -- StateClosed
                state.failures = 0
            end
        else
            state.failures = state.failures + 1
            state.last_failure_time = now
            
            if state.failures >= maxFailures then
                state.state = 1 -- StateOpen
            elseif state.state == 0 then -- StateClosed
                state.state = 2 -- StateHalfOpen
            end
        end
        
        state.updated_by = instanceID
        state.updated_at = now
        
        redis.call('SET', key, cjson.encode(state), 'EX', 3600)
        return cjson.encode(state)
    `
    
    now := time.Now().Format(time.RFC3339)
    successStr := "false"
    if success {
        successStr = "true"
    }
    
    _, err := cb.client.Eval(ctx, script, []string{cb.key},
        successStr, cb.config.MaxFailures, cb.instanceID, now).Result()
    
    if err != nil {
        return fmt.Errorf("recording circuit breaker result: %w", err)
    }
    
    return nil
}

func (cb *DistributedCircuitBreaker) getState(ctx context.Context) (*CircuitBreakerState, error) {
    data, err := cb.client.Get(ctx, cb.key).Result()
    if err != nil {
        if errors.Is(err, redis.Nil) {
            // Return default state
            return &CircuitBreakerState{
                State:           StateClosed,
                Failures:        0,
                Successes:       0,
                LastFailureTime: time.Now(),
                LastSuccessTime: time.Now(),
                UpdatedBy:       cb.instanceID,
                UpdatedAt:       time.Now(),
            }, nil
        }
        return nil, fmt.Errorf("getting circuit breaker state: %w", err)
    }
    
    var state CircuitBreakerState
    if err := json.Unmarshal([]byte(data), &state); err != nil {
        return nil, fmt.Errorf("unmarshaling circuit breaker state: %w", err)
    }
    
    return &state, nil
}

func (cb *DistributedCircuitBreaker) GetState(ctx context.Context) (*CircuitBreakerState, error) {
    return cb.getState(ctx)
}

func (cb *DistributedCircuitBreaker) Reset(ctx context.Context) error {
    err := cb.client.Del(ctx, cb.key).Err()
    if err != nil {
        return fmt.Errorf("resetting circuit breaker: %w", err)
    }
    
    return nil
}
```

### 3. Hybrid State Patterns

#### Hybrid Circuit Breaker
```go
package circuitbreaker

import (
    "context"
    "sync"
    "time"
)

// HybridCircuitBreaker combines local and distributed state
type HybridCircuitBreaker struct {
    local       *LocalCircuitBreaker
    distributed *DistributedCircuitBreaker
    
    // Local optimization
    lastDistributedCheck time.Time
    distributedCheckInterval time.Duration
    
    mu sync.RWMutex
}

func NewHybridCircuitBreaker(
    localConfig Config,
    distributed *DistributedCircuitBreaker,
    checkInterval time.Duration,
) *HybridCircuitBreaker {
    return &HybridCircuitBreaker{
        local:                    NewLocalCircuitBreaker(localConfig),
        distributed:             distributed,
        distributedCheckInterval: checkInterval,
        lastDistributedCheck:     time.Now(),
    }
}

func (cb *HybridCircuitBreaker) Execute(ctx context.Context, fn func() error) error {
    // Check local state first (fast path)
    if !cb.canExecuteLocal() {
        return errors.New("circuit breaker is open (local)")
    }
    
    // Periodically sync with distributed state
    if cb.shouldCheckDistributed() {
        if err := cb.syncWithDistributed(ctx); err != nil {
            // Log error but continue with local state
            fmt.Printf("Failed to sync with distributed circuit breaker: %v\n", err)
        }
    }
    
    // Execute function
    err := fn()
    
    // Record result in both local and distributed state
    cb.local.recordResult(err == nil)
    
    go func() {
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        _ = cb.distributed.recordResult(ctx, err == nil)
    }()
    
    return err
}

func (cb *HybridCircuitBreaker) canExecuteLocal() bool {
    return cb.local.canExecute()
}

func (cb *HybridCircuitBreaker) shouldCheckDistributed() bool {
    cb.mu.RLock()
    defer cb.mu.RUnlock()
    
    return time.Since(cb.lastDistributedCheck) >= cb.distributedCheckInterval
}

func (cb *HybridCircuitBreaker) syncWithDistributed(ctx context.Context) error {
    cb.mu.Lock()
    defer cb.mu.Unlock()
    
    distributedState, err := cb.distributed.GetState(ctx)
    if err != nil {
        return err
    }
    
    // Update local state based on distributed state
    cb.local.mu.Lock()
    
    // If distributed circuit breaker is open, force local to open
    if distributedState.State == StateOpen {
        cb.local.state = StateOpen
        cb.local.failures = distributedState.Failures
        cb.local.lastFailureTime = distributedState.LastFailureTime
    }
    
    cb.local.mu.Unlock()
    cb.lastDistributedCheck = time.Now()
    
    return nil
}

func (cb *HybridCircuitBreaker) GetStats() (local, distributed interface{}, err error) {
    localFailures, localSuccesses, localState := cb.local.GetStats()
    
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()
    
    distributedState, err := cb.distributed.GetState(ctx)
    if err != nil {
        return map[string]interface{}{
            "failures":  localFailures,
            "successes": localSuccesses,
            "state":     localState,
        }, nil, err
    }
    
    return map[string]interface{}{
            "failures":  localFailures,
            "successes": localSuccesses,
            "state":     localState,
        }, map[string]interface{}{
            "failures":          distributedState.Failures,
            "successes":         distributedState.Successes,
            "state":             distributedState.State,
            "last_failure_time": distributedState.LastFailureTime,
            "last_success_time": distributedState.LastSuccessTime,
            "updated_by":        distributedState.UpdatedBy,
        }, nil
}
```

### 4. Rate Limiter Comparison

#### Local Rate Limiter
```go
package ratelimiter

import (
    "sync"
    "time"
)

// TokenBucket implements a local token bucket rate limiter
type TokenBucket struct {
    capacity   int64
    tokens     int64
    refillRate int64 // tokens per second
    lastRefill time.Time
    mu         sync.Mutex
}

func NewTokenBucket(capacity, refillRate int64) *TokenBucket {
    return &TokenBucket{
        capacity:   capacity,
        tokens:     capacity,
        refillRate: refillRate,
        lastRefill: time.Now(),
    }
}

func (tb *TokenBucket) Allow() bool {
    tb.mu.Lock()
    defer tb.mu.Unlock()
    
    tb.refill()
    
    if tb.tokens > 0 {
        tb.tokens--
        return true
    }
    
    return false
}

func (tb *TokenBucket) refill() {
    now := time.Now()
    elapsed := now.Sub(tb.lastRefill)
    
    tokensToAdd := int64(elapsed.Seconds()) * tb.refillRate
    if tokensToAdd > 0 {
        tb.tokens = min(tb.capacity, tb.tokens+tokensToAdd)
        tb.lastRefill = now
    }
}

func min(a, b int64) int64 {
    if a < b {
        return a
    }
    return b
}
```

#### Distributed Rate Limiter
```go
package ratelimiter

import (
    "context"
    "fmt"
    "time"
    
    "github.com/redis/go-redis/v9"
)

type DistributedTokenBucket struct {
    client     redis.Cmdable
    key        string
    capacity   int64
    refillRate int64
}

func NewDistributedTokenBucket(
    client redis.Cmdable,
    key string,
    capacity, refillRate int64,
) *DistributedTokenBucket {
    return &DistributedTokenBucket{
        client:     client,
        key:        key,
        capacity:   capacity,
        refillRate: refillRate,
    }
}

func (tb *DistributedTokenBucket) Allow(ctx context.Context) (bool, error) {
    script := `
        local key = KEYS[1]
        local capacity = tonumber(ARGV[1])
        local refillRate = tonumber(ARGV[2])
        local now = tonumber(ARGV[3])
        
        local bucket = redis.call('HMGET', key, 'tokens', 'lastRefill')
        local tokens = tonumber(bucket[1]) or capacity
        local lastRefill = tonumber(bucket[2]) or now
        
        -- Calculate tokens to add
        local elapsed = now - lastRefill
        local tokensToAdd = math.floor(elapsed * refillRate)
        
        if tokensToAdd > 0 then
            tokens = math.min(capacity, tokens + tokensToAdd)
            lastRefill = now
        end
        
        -- Check if we can consume a token
        local allowed = 0
        if tokens > 0 then
            tokens = tokens - 1
            allowed = 1
        end
        
        -- Update state
        redis.call('HMSET', key, 'tokens', tokens, 'lastRefill', lastRefill)
        redis.call('EXPIRE', key, 3600) -- 1 hour TTL
        
        return {allowed, tokens}
    `
    
    now := float64(time.Now().UnixNano()) / 1e9
    result, err := tb.client.Eval(ctx, script, []string{tb.key},
        tb.capacity, tb.refillRate, now).Result()
    
    if err != nil {
        return false, fmt.Errorf("executing rate limiter script: %w", err)
    }
    
    resultSlice, ok := result.([]interface{})
    if !ok || len(resultSlice) != 2 {
        return false, fmt.Errorf("unexpected script result format")
    }
    
    allowed, ok := resultSlice[0].(int64)
    if !ok {
        return false, fmt.Errorf("unexpected allowed value type")
    }
    
    return allowed == 1, nil
}

func (tb *DistributedTokenBucket) GetTokens(ctx context.Context) (int64, error) {
    result, err := tb.client.HGet(ctx, tb.key, "tokens").Int64()
    if err != nil {
        if errors.Is(err, redis.Nil) {
            return tb.capacity, nil
        }
        return 0, fmt.Errorf("getting tokens: %w", err)
    }
    
    return result, nil
}
```

### 5. Decision Matrix

| Pattern | Consistency | Performance | Complexity | Use Cases |
|---------|-------------|-------------|------------|-----------|
| **Local State** | Eventual | Highest | Lowest | Single instance, non-critical coordination |
| **Distributed State** | Strong | Lowest | Highest | Multi-instance coordination, critical consistency |
| **Hybrid State** | Tunable | Medium | Medium | Performance-critical with coordination needs |

### 6. Testing Strategies

```go
func TestStateManagementPatterns(t *testing.T) {
    t.Run("local counter performance", func(t *testing.T) {
        counter := NewLocalCounter()
        
        // Test concurrent access
        var wg sync.WaitGroup
        iterations := 1000
        goroutines := 10
        
        start := time.Now()
        
        for i := 0; i < goroutines; i++ {
            wg.Add(1)
            go func() {
                defer wg.Done()
                for j := 0; j < iterations; j++ {
                    counter.Increment()
                }
            }()
        }
        
        wg.Wait()
        duration := time.Since(start)
        
        expected := int64(goroutines * iterations)
        assert.Equal(t, expected, counter.Get())
        
        t.Logf("Local counter: %d operations in %v", expected, duration)
    })
    
    t.Run("distributed counter consistency", func(t *testing.T) {
        // Setup Redis test container
        mr := miniredis.RunT(t)
        client := redis.NewClient(&redis.Options{Addr: mr.Addr()})
        
        counter1 := NewDistributedCounter(client, "test:counter", time.Hour)
        counter2 := NewDistributedCounter(client, "test:counter", time.Hour)
        
        ctx := context.Background()
        
        // Increment from both instances
        val1, err := counter1.Increment(ctx)
        require.NoError(t, err)
        assert.Equal(t, int64(1), val1)
        
        val2, err := counter2.Increment(ctx)
        require.NoError(t, err)
        assert.Equal(t, int64(2), val2)
        
        // Both should see same value
        get1, err := counter1.Get(ctx)
        require.NoError(t, err)
        
        get2, err := counter2.Get(ctx)
        require.NoError(t, err)
        
        assert.Equal(t, get1, get2)
        assert.Equal(t, int64(2), get1)
    })
}
```

## Consequences

**Benefits:**
- **Flexibility**: Choose appropriate consistency/performance trade-offs
- **Scalability**: Local state provides high performance, distributed enables coordination
- **Resilience**: Hybrid approaches provide fallback mechanisms
- **Testing**: Clear patterns enable comprehensive testing strategies

**Trade-offs:**
- **Complexity**: Multiple state management approaches increase system complexity
- **Network dependency**: Distributed state requires reliable network connectivity
- **Debugging**: Hybrid systems can be challenging to debug and monitor

**Guidelines:**
1. **Start local**: Begin with local state unless distributed coordination is required
2. **Measure performance**: Profile the impact of distributed state operations
3. **Plan for failure**: Design fallback mechanisms for distributed state failures
4. **Monitor state**: Implement observability for state synchronization
5. **Test extensively**: Verify behavior under various failure scenarios

## References

- [Redis Patterns](https://redis.io/docs/manual/patterns/)
- [Distributed Systems Patterns](https://martinfowler.com/articles/patterns-of-distributed-systems/)
- [Go Memory Model](https://golang.org/ref/mem) 
