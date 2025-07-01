# Fencing

## Status
Accepted

## Context
In distributed systems, particularly when using Redis for coordination primitives like locks, singleflight patterns, and idempotency tokens, we need mechanisms to prevent race conditions and ensure consistency. Fencing is a critical technique for preventing issues in distributed coordination.

## Problem
Without proper fencing mechanisms, distributed systems face several challenges:

1. **Split-brain scenarios**: Multiple processes believing they own a lock
2. **Stale operations**: Operations executing with outdated state
3. **Race conditions**: Concurrent access to shared resources
4. **Clock skew issues**: Time-based locks becoming unreliable

## Decision
We will implement fencing tokens for Redis-based coordination primitives including:

- Distributed locks
- Singleflight implementations
- Idempotency mechanisms
- Leader election

## Implementation

### Fencing Token Strategy

```go
package fencing

import (
    "context"
    "fmt"
    "strconv"
    "time"
    
    "github.com/go-redis/redis/v8"
)

type FencingToken struct {
    Token     int64
    Resource  string
    ExpiresAt time.Time
}

type FencedLock struct {
    client *redis.Client
    key    string
    token  int64
    ttl    time.Duration
}

// AcquireFencedLock acquires a lock with a fencing token
func AcquireFencedLock(ctx context.Context, client *redis.Client, resource string, ttl time.Duration) (*FencedLock, error) {
    script := `
        local key = KEYS[1]
        local token_key = KEYS[2]
        local ttl = ARGV[1]
        local current_time = ARGV[2]
        
        -- Increment the fencing token
        local token = redis.call('INCR', token_key)
        
        -- Try to acquire the lock with the token
        local acquired = redis.call('SET', key, token, 'PX', ttl, 'NX')
        
        if acquired then
            return {token, ttl}
        else
            return nil
        end
    `
    
    lockKey := fmt.Sprintf("lock:%s", resource)
    tokenKey := fmt.Sprintf("token:%s", resource)
    
    result, err := client.Eval(ctx, script, []string{lockKey, tokenKey}, 
        ttl.Milliseconds(), time.Now().Unix()).Result()
    
    if err != nil {
        return nil, fmt.Errorf("failed to acquire fenced lock: %w", err)
    }
    
    if result == nil {
        return nil, fmt.Errorf("lock already acquired")
    }
    
    values := result.([]interface{})
    token := values[0].(int64)
    
    return &FencedLock{
        client: client,
        key:    lockKey,
        token:  token,
        ttl:    ttl,
    }, nil
}

// ValidateToken validates that the operation is using the correct fencing token
func (f *FencedLock) ValidateToken(ctx context.Context) error {
    script := `
        local key = KEYS[1]
        local expected_token = ARGV[1]
        
        local current_token = redis.call('GET', key)
        if current_token == false then
            return 'LOCK_EXPIRED'
        end
        
        if current_token ~= expected_token then 
            return 'INVALID_TOKEN'
        end
        
        return 'VALID'
    `
    
    result, err := f.client.Eval(ctx, script, []string{f.key}, f.token).Result()
    if err != nil {
        return fmt.Errorf("failed to validate token: %w", err)
    }
    
    switch result.(string) {
    case "LOCK_EXPIRED":
        return fmt.Errorf("lock has expired")
    case "INVALID_TOKEN":
        return fmt.Errorf("invalid fencing token")
    case "VALID":
        return nil
    default:
        return fmt.Errorf("unexpected validation result: %s", result)
    }
}

// Release releases the fenced lock
func (f *FencedLock) Release(ctx context.Context) error {
    script := `
        local key = KEYS[1]
        local token = ARGV[1]
        
        local current_token = redis.call('GET', key)
        if current_token == token then
            return redis.call('DEL', key)
        else
            return 0
        end
    `
    
    _, err := f.client.Eval(ctx, script, []string{f.key}, f.token).Result()
    return err
}
```

### Fenced Singleflight Implementation

```go
package singleflight

import (
    "context"
    "fmt"
    "sync"
    "time"
    
    "github.com/go-redis/redis/v8"
)

type FencedGroup struct {
    mu     sync.Mutex
    calls  map[string]*call
    client *redis.Client
}

type call struct {
    wg  sync.WaitGroup
    val interface{}
    err error
    token int64
}

func NewFencedGroup(client *redis.Client) *FencedGroup {
    return &FencedGroup{
        calls:  make(map[string]*call),
        client: client,
    }
}

func (g *FencedGroup) Do(ctx context.Context, key string, fn func() (interface{}, error)) (interface{}, error, bool) {
    g.mu.Lock()
    if c, ok := g.calls[key]; ok {
        g.mu.Unlock()
        c.wg.Wait()
        return c.val, c.err, true
    }
    
    c := new(call)
    c.wg.Add(1)
    g.calls[key] = c
    g.mu.Unlock()
    
    // Acquire fencing token
    token, err := g.acquireToken(ctx, key)
    if err != nil {
        g.mu.Lock()
        delete(g.calls, key)
        g.mu.Unlock()
        c.wg.Done()
        return nil, err, false
    }
    
    c.token = token
    
    // Execute function with fencing validation
    c.val, c.err = g.executeWithFencing(ctx, key, token, fn)
    c.wg.Done()
    
    g.mu.Lock()
    delete(g.calls, key)
    g.mu.Unlock()
    
    return c.val, c.err, false
}

func (g *FencedGroup) acquireToken(ctx context.Context, key string) (int64, error) {
    script := `
        local token_key = KEYS[1]
        local lock_key = KEYS[2]
        local ttl = ARGV[1]
        
        local token = redis.call('INCR', token_key)
        local acquired = redis.call('SET', lock_key, token, 'PX', ttl, 'NX')
        
        if acquired then
            return token
        else
            return nil
        end
    `
    
    tokenKey := fmt.Sprintf("sf:token:%s", key)
    lockKey := fmt.Sprintf("sf:lock:%s", key)
    
    result, err := g.client.Eval(ctx, script, []string{tokenKey, lockKey}, 30000).Result()
    if err != nil {
        return 0, err
    }
    
    if result == nil {
        return 0, fmt.Errorf("failed to acquire singleflight token")
    }
    
    return result.(int64), nil
}

func (g *FencedGroup) executeWithFencing(ctx context.Context, key string, token int64, fn func() (interface{}, error)) (interface{}, error) {
    // Validate token before execution
    if err := g.validateToken(ctx, key, token); err != nil {
        return nil, err
    }
    
    result, err := fn()
    
    // Release the token
    g.releaseToken(ctx, key, token)
    
    return result, err
}

func (g *FencedGroup) validateToken(ctx context.Context, key string, token int64) error {
    lockKey := fmt.Sprintf("sf:lock:%s", key)
    
    current, err := g.client.Get(ctx, lockKey).Int64()
    if err == redis.Nil {
        return fmt.Errorf("singleflight token expired")
    }
    if err != nil {
        return err
    }
    
    if current != token {
        return fmt.Errorf("invalid singleflight token")
    }
    
    return nil
}

func (g *FencedGroup) releaseToken(ctx context.Context, key string, token int64) {
    script := `
        local lock_key = KEYS[1]
        local token = ARGV[1]
        
        local current = redis.call('GET', lock_key)
        if current == token then
            return redis.call('DEL', lock_key)
        end
        return 0
    `
    
    lockKey := fmt.Sprintf("sf:lock:%s", key)
    g.client.Eval(ctx, script, []string{lockKey}, token)
}
```

### Fenced Idempotency

```go
package idempotency

import (
    "context"
    "crypto/sha256"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/go-redis/redis/v8"
)

type FencedIdempotencyManager struct {
    client *redis.Client
    ttl    time.Duration
}

type IdempotencyKey struct {
    Key     string
    Token   int64
    Payload interface{}
    Hash    string
}

func NewFencedIdempotencyManager(client *redis.Client, ttl time.Duration) *FencedIdempotencyManager {
    return &FencedIdempotencyManager{
        client: client,
        ttl:    ttl,
    }
}

func (m *FencedIdempotencyManager) ProcessWithIdempotency(ctx context.Context, key string, payload interface{}, fn func() (interface{}, error)) (interface{}, error) {
    // Create idempotency key with payload hash
    idempKey, err := m.createIdempotencyKey(key, payload)
    if err != nil {
        return nil, err
    }
    
    // Try to acquire idempotency lock
    acquired, result, err := m.tryAcquire(ctx, idempKey)
    if err != nil {
        return nil, err
    }
    
    if !acquired {
        // Return cached result
        return result, nil
    }
    
    // Execute function with fencing
    return m.executeWithFencing(ctx, idempKey, fn)
}

func (m *FencedIdempotencyManager) createIdempotencyKey(key string, payload interface{}) (*IdempotencyKey, error) {
    payloadBytes, err := json.Marshal(payload)
    if err != nil {
        return nil, err
    }
    
    hash := fmt.Sprintf("%x", sha256.Sum256(payloadBytes))
    
    return &IdempotencyKey{
        Key:     key,
        Payload: payload,
        Hash:    hash,
    }, nil
}

func (m *FencedIdempotencyManager) tryAcquire(ctx context.Context, idempKey *IdempotencyKey) (bool, interface{}, error) {
    script := `
        local key = KEYS[1]
        local token_key = KEYS[2]
        local hash = ARGV[1]
        local ttl = ARGV[2]
        
        -- Check if result already exists
        local existing = redis.call('HGETALL', key)
        if #existing > 0 then
            local stored_hash = existing[2]
            local stored_result = existing[4]
            
            if stored_hash == hash then
                return {'EXISTS', stored_result}
            else
                return {'CONFLICT', nil}
            end
        end
        
        -- Acquire new token
        local token = redis.call('INCR', token_key)
        
        -- Set processing state
        redis.call('HSET', key, 'hash', hash, 'token', token, 'status', 'PROCESSING')
        redis.call('EXPIRE', key, ttl)
        
        return {'ACQUIRED', token}
    `
    
    lockKey := fmt.Sprintf("idem:%s", idempKey.Key)
    tokenKey := fmt.Sprintf("idem:token:%s", idempKey.Key)
    
    result, err := m.client.Eval(ctx, script, []string{lockKey, tokenKey}, 
        idempKey.Hash, int(m.ttl.Seconds())).Result()
    
    if err != nil {
        return false, nil, err
    }
    
    values := result.([]interface{})
    status := values[0].(string)
    
    switch status {
    case "EXISTS":
        var cachedResult interface{}
        if values[1] != nil {
            json.Unmarshal([]byte(values[1].(string)), &cachedResult)
        }
        return false, cachedResult, nil
    case "CONFLICT":
        return false, nil, fmt.Errorf("idempotency conflict: different payload for same key")
    case "ACQUIRED":
        idempKey.Token = values[1].(int64)
        return true, nil, nil
    default:
        return false, nil, fmt.Errorf("unexpected status: %s", status)
    }
}

func (m *FencedIdempotencyManager) executeWithFencing(ctx context.Context, idempKey *IdempotencyKey, fn func() (interface{}, error)) (interface{}, error) {
    // Validate token before execution
    if err := m.validateToken(ctx, idempKey); err != nil {
        return nil, err
    }
    
    result, err := fn()
    if err != nil {
        m.markFailed(ctx, idempKey, err)
        return nil, err
    }
    
    // Store successful result
    if err := m.storeResult(ctx, idempKey, result); err != nil {
        return nil, err
    }
    
    return result, nil
}

func (m *FencedIdempotencyManager) validateToken(ctx context.Context, idempKey *IdempotencyKey) error {
    key := fmt.Sprintf("idem:%s", idempKey.Key)
    
    token, err := m.client.HGet(ctx, key, "token").Int64()
    if err == redis.Nil {
        return fmt.Errorf("idempotency key expired")
    }
    if err != nil {
        return err
    }
    
    if token != idempKey.Token {
        return fmt.Errorf("invalid idempotency token")
    }
    
    return nil
}

func (m *FencedIdempotencyManager) storeResult(ctx context.Context, idempKey *IdempotencyKey, result interface{}) error {
    resultBytes, err := json.Marshal(result)
    if err != nil {
        return err
    }
    
    key := fmt.Sprintf("idem:%s", idempKey.Key)
    
    return m.client.HSet(ctx, key, 
        "result", string(resultBytes), 
        "status", "COMPLETED",
        "completed_at", time.Now().Unix()).Err()
}

func (m *FencedIdempotencyManager) markFailed(ctx context.Context, idempKey *IdempotencyKey, err error) {
    key := fmt.Sprintf("idem:%s", idempKey.Key)
    
    m.client.HSet(ctx, key,
        "status", "FAILED",
        "error", err.Error(),
        "failed_at", time.Now().Unix())
}
```

## Usage Examples

### Distributed Lock with Fencing

```go
func performCriticalOperation(ctx context.Context, client *redis.Client) error {
    lock, err := AcquireFencedLock(ctx, client, "critical-resource", 30*time.Second)
    if err != nil {
        return err
    }
    defer lock.Release(ctx)
    
    // Validate token before each critical operation
    if err := lock.ValidateToken(ctx); err != nil {
        return err
    }
    
    // Perform operation...
    return performOperation()
}
```

### Singleflight with Fencing

```go
func expensiveOperation(ctx context.Context, key string) {
    group := NewFencedGroup(redisClient)
    
    result, err, shared := group.Do(ctx, key, func() (interface{}, error) {
        // This will only run once even with concurrent calls
        return fetchDataFromDatabase(key)
    })
    
    if err != nil {
        log.Printf("Error: %v", err)
        return
    }
    
    log.Printf("Result: %v, Shared: %v", result, shared)
}
```

## Monitoring and Alerting

### Metrics to Track

```go
// Fencing-related metrics
var (
    FencingTokenConflicts = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "fencing_token_conflicts_total",
            Help: "Total number of fencing token conflicts",
        },
        []string{"resource", "operation"},
    )
    
    FencingValidationLatency = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "fencing_validation_duration_seconds",
            Help: "Time taken to validate fencing tokens",
        },
        []string{"resource", "operation"},
    )
    
    ActiveFencedOperations = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "active_fenced_operations",
            Help: "Number of currently active fenced operations",
        },
        []string{"resource", "operation"},
    )
)
```

### Dashboard Queries

```promql
# Fencing token conflict rate
rate(fencing_token_conflicts_total[5m])

# Average fencing validation latency
rate(fencing_validation_duration_seconds_sum[5m]) / rate(fencing_validation_duration_seconds_count[5m])

# Active fenced operations by resource
sum by (resource) (active_fenced_operations)
```

## Best Practices

1. **Always validate tokens**: Check fencing tokens before performing any critical operation
2. **Use monotonic tokens**: Ensure tokens always increase to prevent replay attacks
3. **Set appropriate TTLs**: Balance between availability and consistency
4. **Handle token conflicts gracefully**: Implement proper error handling and retry logic
5. **Monitor token usage**: Track conflicts and validation failures
6. **Test failure scenarios**: Verify behavior during network partitions and clock skew

## Consequences

### Advantages
- **Prevents split-brain scenarios**: Fencing tokens ensure only one valid operation at a time
- **Strong consistency**: Eliminates race conditions in distributed coordination
- **Debugging aid**: Token validation provides clear error messages
- **Audit trail**: Tokens provide a record of operation ordering

### Disadvantages
- **Increased complexity**: Additional logic for token management
- **Performance overhead**: Extra Redis operations for token validation
- **Potential bottleneck**: Token generation can become a single point of contention
- **Storage overhead**: Additional data stored for tokens

## References
- [Fencing in Distributed Systems](https://brooker.co.za/blog/2024/04/25/memorydb.html)
- [The Chubby Lock Service](https://research.google/pubs/pub27897/)
- [Redis Distributed Locking](https://redis.io/docs/manual/patterns/distributed-locks/)
