# Use Rate Limiting

## Status

`accepted`

## Context

Rate limiting is a critical component of microservice resiliency and system protection. Without proper rate limiting, clients can make unlimited requests, potentially causing distributed denial-of-service (DDoS) attacks and bringing down servers. Rate limiting helps maintain system stability, ensures fair resource allocation, and protects against abuse.

Rate limiting applications extend beyond simple request throttling. We can apply rate limiting to various units including:
- API requests per user/IP
- GMV (Gross Merchandise Value) limits
- Transaction counts and volumes
- Data transfer bytes
- Processing duration
- Error rates and failure counts

## Decision

Implement a comprehensive rate limiting strategy that includes multiple algorithms and patterns to handle different use cases:

1. **Token Bucket** for burst handling with sustained rates
2. **Fixed Window** for simple quota-based limiting
3. **Sliding Window** for smoother rate distribution
4. **GCRA (Generic Cell Rate Algorithm)** for precise traffic shaping
5. **Error Rate Limiting** for fault tolerance

## Rate Limiting Concepts

### Controlled vs Uncontrolled Operations

**Controlled Operations**: You have control over the rate of execution (e.g., batch processing, API client calls)
- Strategy: **Delay** the operation until the next allowed time
- Implementation: Load leveling with sleep/wait mechanisms

**Uncontrolled Operations**: External requests arrive unpredictably (e.g., user API requests)
- Strategy: **Reject** requests that exceed the rate limit
- Implementation: Immediate accept/reject decisions

### Time Windows and Burst Handling

Fixed time windows can create traffic spikes at window boundaries. Users might consume their entire quota at the end of one period and immediately at the start of the next period.

**Solutions:**
- **Sliding Windows**: Smooth out rate distribution over time
- **Minimum Intervals**: Enforce spacing between requests
- **Burst Capacity**: Allow short bursts while maintaining average rate

### Quota vs Limit Patterns

**Traditional Limits**: Define maximum requests allowed in a time window
**Quota-based**: Track remaining capacity that decreases over time

```go
// Limit-based: "5 requests per second"
if currentCount < maxRequests {
    allowRequest()
}

// Quota-based: "5 tokens, refilled at 1 token/200ms"
if tokensRemaining > 0 {
    tokensRemaining--
    allowRequest()
}
```

## Implementation Patterns

### 1. Token Bucket Algorithm

Ideal for handling burst traffic while maintaining average rate limits:

```go
package ratelimit

import (
    "sync"
    "time"
)

type TokenBucket struct {
    capacity     int64         // Maximum tokens
    tokens       int64         // Current tokens
    refillRate   int64         // Tokens per second
    lastRefill   time.Time     // Last refill time
    mutex        sync.Mutex
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
    return tb.AllowN(1)
}

func (tb *TokenBucket) AllowN(n int64) bool {
    tb.mutex.Lock()
    defer tb.mutex.Unlock()
    
    tb.refill()
    
    if tb.tokens >= n {
        tb.tokens -= n
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

func (tb *TokenBucket) TokensRemaining() int64 {
    tb.mutex.Lock()
    defer tb.mutex.Unlock()
    
    tb.refill()
    return tb.tokens
}
```

### 2. Fixed Window Counter

Simple and memory-efficient for basic rate limiting:

```go
type FixedWindowLimiter struct {
    limit      int
    window     time.Duration
    counters   map[string]*WindowState
    mutex      sync.RWMutex
}

type WindowState struct {
    count     int
    windowStart int64
}

func NewFixedWindowLimiter(limit int, window time.Duration) *FixedWindowLimiter {
    limiter := &FixedWindowLimiter{
        limit:    limit,
        window:   window,
        counters: make(map[string]*WindowState),
    }
    
    // Start cleanup goroutine
    go limiter.cleanup()
    return limiter
}

func (f *FixedWindowLimiter) Allow(key string) bool {
    return f.AllowN(key, 1)
}

func (f *FixedWindowLimiter) AllowN(key string, n int) bool {
    f.mutex.Lock()
    defer f.mutex.Unlock()
    
    now := time.Now().UnixNano()
    windowStart := now - (now % f.window.Nanoseconds())
    
    state, exists := f.counters[key]
    if !exists || state.windowStart != windowStart {
        state = &WindowState{
            count:       0,
            windowStart: windowStart,
        }
        f.counters[key] = state
    }
    
    if state.count+n <= f.limit {
        state.count += n
        return true
    }
    
    return false
}

func (f *FixedWindowLimiter) Remaining(key string) int {
    f.mutex.RLock()
    defer f.mutex.RUnlock()
    
    now := time.Now().UnixNano()
    windowStart := now - (now % f.window.Nanoseconds())
    
    state, exists := f.counters[key]
    if !exists || state.windowStart != windowStart {
        return f.limit
    }
    
    return f.limit - state.count
}

func (f *FixedWindowLimiter) cleanup() {
    ticker := time.NewTicker(f.window)
    defer ticker.Stop()
    
    for range ticker.C {
        f.mutex.Lock()
        now := time.Now().UnixNano()
        
        for key, state := range f.counters {
            if now-state.windowStart > f.window.Nanoseconds() {
                delete(f.counters, key)
            }
        }
        f.mutex.Unlock()
    }
}
```

### 3. Sliding Window Log

Maintains precise request timestamps for accurate rate limiting:

```go
type SlidingWindowLog struct {
    limit    int
    window   time.Duration
    logs     map[string][]time.Time
    mutex    sync.RWMutex
}

func NewSlidingWindowLog(limit int, window time.Duration) *SlidingWindowLog {
    return &SlidingWindowLog{
        limit:  limit,
        window: window,
        logs:   make(map[string][]time.Time),
    }
}

func (s *SlidingWindowLog) Allow(key string) bool {
    s.mutex.Lock()
    defer s.mutex.Unlock()
    
    now := time.Now()
    cutoff := now.Add(-s.window)
    
    // Clean old entries
    log := s.logs[key]
    validIdx := 0
    for i, timestamp := range log {
        if timestamp.After(cutoff) {
            break
        }
        validIdx = i + 1
    }
    log = log[validIdx:]
    
    if len(log) < s.limit {
        log = append(log, now)
        s.logs[key] = log
        return true
    }
    
    return false
}

func (s *SlidingWindowLog) Remaining(key string) int {
    s.mutex.RLock()
    defer s.mutex.RUnlock()
    
    cutoff := time.Now().Add(-s.window)
    log := s.logs[key]
    
    count := 0
    for _, timestamp := range log {
        if timestamp.After(cutoff) {
            count++
        }
    }
    
    return s.limit - count
}
```

### 4. GCRA (Generic Cell Rate Algorithm)

Provides smooth traffic shaping with precise timing:

```go
type GCRALimiter struct {
    interval      time.Duration  // Time between allowed requests
    burstCapacity time.Duration  // Maximum burst allowance
    state         map[string]time.Time
    mutex         sync.RWMutex
}

func NewGCRALimiter(rate int, burstSize int) *GCRALimiter {
    interval := time.Second / time.Duration(rate)
    burstCapacity := time.Duration(burstSize) * interval
    
    return &GCRALimiter{
        interval:      interval,
        burstCapacity: burstCapacity,
        state:         make(map[string]time.Time),
    }
}

func (g *GCRALimiter) Allow(key string) bool {
    g.mutex.Lock()
    defer g.mutex.Unlock()
    
    now := time.Now()
    
    // Get theoretical arrival time
    tat, exists := g.state[key]
    if !exists {
        tat = now
    }
    
    // Update theoretical arrival time
    newTAT := maxTime(tat, now).Add(g.interval)
    
    // Check if request is within burst capacity
    if newTAT.Sub(now) <= g.burstCapacity {
        g.state[key] = newTAT
        return true
    }
    
    return false
}

func maxTime(a, b time.Time) time.Time {
    if a.After(b) {
        return a
    }
    return b
}
```

### 5. Error Rate Limiter

Limits operations based on error rates rather than request counts:

```go
type ErrorRateLimiter struct {
    maxErrors     int
    window        time.Duration
    errorThreshold float64
    successCount  *ExponentialCounter
    errorCount    *ExponentialCounter
    mutex         sync.RWMutex
}

type ExponentialCounter struct {
    value      float64
    lastUpdate time.Time
    decayRate  float64
}

func NewErrorRateLimiter(maxErrors int, window time.Duration, threshold float64) *ErrorRateLimiter {
    decayRate := 1.0 / window.Seconds()
    
    return &ErrorRateLimiter{
        maxErrors:      maxErrors,
        window:         window,
        errorThreshold: threshold,
        successCount:   &ExponentialCounter{decayRate: decayRate},
        errorCount:     &ExponentialCounter{decayRate: decayRate},
    }
}

func (e *ErrorRateLimiter) Allow() bool {
    e.mutex.RLock()
    defer e.mutex.RUnlock()
    
    e.updateCounters()
    
    totalCount := e.successCount.value + e.errorCount.value
    if totalCount == 0 {
        return true
    }
    
    errorRate := e.errorCount.value / totalCount
    return errorRate <= e.errorThreshold && e.errorCount.value < float64(e.maxErrors)
}

func (e *ErrorRateLimiter) RecordSuccess() {
    e.mutex.Lock()
    defer e.mutex.Unlock()
    
    e.updateCounters()
    e.successCount.increment(1.0)
}

func (e *ErrorRateLimiter) RecordError() {
    e.mutex.Lock()
    defer e.mutex.Unlock()
    
    e.updateCounters()
    e.errorCount.increment(1.0)
}

func (e *ErrorRateLimiter) updateCounters() {
    now := time.Now()
    e.successCount.decay(now)
    e.errorCount.decay(now)
}

func (ec *ExponentialCounter) decay(now time.Time) {
    if !ec.lastUpdate.IsZero() {
        elapsed := now.Sub(ec.lastUpdate).Seconds()
        ec.value *= math.Exp(-ec.decayRate * elapsed)
    }
    ec.lastUpdate = now
}

func (ec *ExponentialCounter) increment(delta float64) {
    ec.value += delta
}
```

## HTTP Middleware Integration

### Rate Limiting Middleware

```go
package middleware

import (
    "encoding/json"
    "fmt"
    "net/http"
    "strconv"
    "time"
    
    "your-app/pkg/ratelimit"
)

type RateLimitMiddleware struct {
    limiter ratelimit.Limiter
    keyFunc KeyExtractor
}

type KeyExtractor func(*http.Request) string

func NewRateLimitMiddleware(limiter ratelimit.Limiter, keyFunc KeyExtractor) *RateLimitMiddleware {
    return &RateLimitMiddleware{
        limiter: limiter,
        keyFunc: keyFunc,
    }
}

func (m *RateLimitMiddleware) Handler(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        key := m.keyFunc(r)
        
        result := m.limiter.Check(key)
        
        // Set rate limit headers
        w.Header().Set("X-RateLimit-Limit", strconv.Itoa(result.Limit))
        w.Header().Set("X-RateLimit-Remaining", strconv.Itoa(result.Remaining))
        w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(result.ResetTime.Unix(), 10))
        
        if !result.Allowed {
            w.Header().Set("Retry-After", strconv.Itoa(int(result.RetryAfter.Seconds())))
            
            writeRateLimitError(w, result)
            return
        }
        
        next.ServeHTTP(w, r)
    })
}

// Key extraction strategies
func IPKeyExtractor(r *http.Request) string {
    forwarded := r.Header.Get("X-Forwarded-For")
    if forwarded != "" {
        return strings.Split(forwarded, ",")[0]
    }
    return r.RemoteAddr
}

func UserKeyExtractor(r *http.Request) string {
    userID := r.Header.Get("X-User-ID")
    if userID == "" {
        return IPKeyExtractor(r)
    }
    return fmt.Sprintf("user:%s", userID)
}

func APIKeyExtractor(r *http.Request) string {
    apiKey := r.Header.Get("X-API-Key")
    if apiKey == "" {
        return IPKeyExtractor(r)
    }
    return fmt.Sprintf("api:%s", apiKey)
}

func writeRateLimitError(w http.ResponseWriter, result *ratelimit.Result) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusTooManyRequests)
    
    response := map[string]interface{}{
        "error": map[string]interface{}{
            "code":    "RATE_LIMIT_EXCEEDED",
            "message": "Rate limit exceeded",
            "details": map[string]interface{}{
                "limit":      result.Limit,
                "remaining":  result.Remaining,
                "resetTime":  result.ResetTime.Unix(),
                "retryAfter": int(result.RetryAfter.Seconds()),
            },
        },
    }
    
    json.NewEncoder(w).Encode(response)
}
```

## Distributed Rate Limiting

### Redis-based Implementation

```go
package ratelimit

import (
    "context"
    "fmt"
    "strconv"
    "time"
    
    "github.com/go-redis/redis/v8"
)

type RedisRateLimiter struct {
    client *redis.Client
    limit  int
    window time.Duration
}

func NewRedisRateLimiter(client *redis.Client, limit int, window time.Duration) *RedisRateLimiter {
    return &RedisRateLimiter{
        client: client,
        limit:  limit,
        window: window,
    }
}

func (r *RedisRateLimiter) Allow(ctx context.Context, key string) (bool, error) {
    result, err := r.client.Eval(ctx, slidingWindowScript, []string{key}, 
        r.limit, r.window.Milliseconds(), time.Now().UnixMilli()).Result()
    
    if err != nil {
        return false, fmt.Errorf("redis rate limit check failed: %w", err)
    }
    
    return result.(int64) == 1, nil
}

// Lua script for atomic sliding window rate limiting
const slidingWindowScript = `
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

-- Remove expired entries
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)

-- Count current requests
local current = redis.call('ZCARD', key)

if current < limit then
    -- Add current request
    redis.call('ZADD', key, now, now)
    redis.call('EXPIRE', key, math.ceil(window / 1000))
    return 1
else
    return 0
end
`

// Token bucket implementation in Redis
func (r *RedisRateLimiter) TokenBucketAllow(ctx context.Context, key string, tokens int) (bool, error) {
    result, err := r.client.Eval(ctx, tokenBucketScript, []string{key},
        r.limit, tokens, time.Now().Unix()).Result()
        
    if err != nil {
        return false, err
    }
    
    return result.(int64) == 1, nil
}

const tokenBucketScript = `
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local requested = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local bucket = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(bucket[1]) or capacity
local last_refill = tonumber(bucket[2]) or now

-- Refill tokens based on elapsed time
local elapsed = now - last_refill
local new_tokens = math.min(capacity, tokens + elapsed)

if new_tokens >= requested then
    new_tokens = new_tokens - requested
    redis.call('HMSET', key, 'tokens', new_tokens, 'last_refill', now)
    redis.call('EXPIRE', key, 3600)
    return 1
else
    redis.call('HMSET', key, 'tokens', new_tokens, 'last_refill', now)
    redis.call('EXPIRE', key, 3600)
    return 0
end
`
```

## Advanced Patterns

### Adaptive Rate Limiting

Adjusts limits based on system load and error rates:

```go
type AdaptiveRateLimiter struct {
    baseLimiter   Limiter
    baseLimit     int
    currentLimit  int
    errorRate     *ExponentialCounter
    latencyP99    *LatencyTracker
    mutex         sync.RWMutex
}

func (a *AdaptiveRateLimiter) updateLimits() {
    a.mutex.Lock()
    defer a.mutex.Unlock()
    
    errorRate := a.errorRate.getValue()
    latencyP99 := a.latencyP99.getP99()
    
    // Reduce limit if error rate is high or latency is high
    var factor float64 = 1.0
    
    if errorRate > 0.05 { // 5% error rate
        factor *= 0.8
    }
    
    if latencyP99 > 500*time.Millisecond {
        factor *= 0.9
    }
    
    // Gradually increase limit if system is healthy
    if errorRate < 0.01 && latencyP99 < 100*time.Millisecond {
        factor = math.Min(1.2, factor*1.1)
    }
    
    newLimit := int(float64(a.baseLimit) * factor)
    a.currentLimit = max(1, min(a.baseLimit*2, newLimit))
    
    a.baseLimiter.UpdateLimit(a.currentLimit)
}
```

### Hierarchical Rate Limiting

Different limits for different user tiers:

```go
type HierarchicalLimiter struct {
    limiters map[string]Limiter
    fallback Limiter
}

func (h *HierarchicalLimiter) Allow(key string, tier string) bool {
    if limiter, exists := h.limiters[tier]; exists {
        return limiter.Allow(key)
    }
    return h.fallback.Allow(key)
}

// Usage
limiter := &HierarchicalLimiter{
    limiters: map[string]Limiter{
        "premium": NewTokenBucket(1000, 100), // 1000 burst, 100/sec
        "basic":   NewTokenBucket(100, 10),   // 100 burst, 10/sec
        "free":    NewTokenBucket(10, 1),     // 10 burst, 1/sec
    },
    fallback: NewTokenBucket(5, 1), // Default limits
}
```

## Monitoring and Observability

### Metrics Collection

```go
type RateLimitMetrics struct {
    requestsTotal     prometheus.Counter
    requestsAllowed   prometheus.Counter
    requestsBlocked   prometheus.Counter
    limitUtilization  prometheus.Histogram
}

func (m *RateLimitMetrics) RecordRequest(key string, allowed bool, utilization float64) {
    labels := prometheus.Labels{"key": key}
    
    m.requestsTotal.With(labels).Inc()
    
    if allowed {
        m.requestsAllowed.With(labels).Inc()
    } else {
        m.requestsBlocked.With(labels).Inc()
    }
    
    m.limitUtilization.With(labels).Observe(utilization)
}
```

## Testing Strategies

### Load Testing Rate Limiters

```go
func TestRateLimiterUnderLoad(t *testing.T) {
    limiter := NewTokenBucket(100, 10) // 100 burst, 10/sec
    
    var allowed, blocked int64
    var wg sync.WaitGroup
    
    // Simulate concurrent requests
    for i := 0; i < 1000; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            
            if limiter.Allow() {
                atomic.AddInt64(&allowed, 1)
            } else {
                atomic.AddInt64(&blocked, 1)
            }
        }()
    }
    
    wg.Wait()
    
    // Verify rate limiting behavior
    assert.True(t, allowed <= 100) // Should not exceed burst capacity
    assert.True(t, blocked > 0)    // Some requests should be blocked
}
```

## Best Practices

### Configuration Guidelines

1. **Start Conservative**: Begin with lower limits and increase based on monitoring
2. **Monitor Key Metrics**: Track allow/deny ratios, latency impact, and error rates
3. **Provide Clear Error Messages**: Include retry-after information in responses
4. **Use Appropriate Headers**: Follow HTTP standards for rate limit headers
5. **Implement Graceful Degradation**: Have fallback mechanisms when rate limiting fails

### Performance Considerations

1. **Memory Management**: Clean up expired rate limit state regularly
2. **Lock Contention**: Use fine-grained locking or lock-free data structures
3. **Redis Optimization**: Use Lua scripts for atomic operations
4. **Caching**: Cache rate limit decisions for short periods when appropriate

## Consequences

### Positive

- **System Protection**: Prevents resource exhaustion and maintains availability
- **Fair Resource Allocation**: Ensures equitable access across users/clients
- **Cost Control**: Limits usage-based costs in cloud environments
- **Quality of Service**: Maintains performance under high load
- **Security**: Helps prevent abuse and attacks

### Negative

- **Legitimate Traffic Blocking**: May reject valid requests during traffic spikes
- **Complexity**: Adds operational complexity and potential failure points
- **Latency**: Introduces processing overhead for rate limit checks
- **State Management**: Requires careful handling of distributed state
- **False Positives**: Shared IP addresses or aggressive legitimate usage may be limited

### Trade-offs

- **Accuracy vs Performance**: More precise algorithms (sliding window) vs faster checks (fixed window)
- **Memory vs CPU**: Storing more state vs computing limits on-demand
- **Centralized vs Distributed**: Single point of control vs eventual consistency
- **Static vs Dynamic**: Fixed limits vs adaptive based on system health

### Throttle

For some operations, we just care about not hitting the limit, rather than processing it at a constant rate.

One such example is fraud monitoring. We want to limit the amount of daily transaction to a value imposed by the user. The transactions can be done at any time.

### Quota vs limit

Most rate limiter defines a limit, the maximum amount of calls that can be made. However, they suffer from one issue. Imagine a rate limiter that allows 5 request per second.

If a user make requests continuously at 0.9s, we will have a spike at the end of the time window.

Quota defines the number of available requests that can be made and decreases over time at the end of the time window.

At time 0.2s, user will have 4 requests remaining. At 0.8s, user will have 1 request remaining.

### Capacity and refill rate

Another concept is that capacity and refill rate does not have to be equal. For example, if the capacity is 5 request, then the refill rate does not have to be 5req/s, or 200ms each request. It can be lower, e.g. 100ms per request as long as it doesn't hit the limit.

### Time window

A naive way to define the time window is to just divide them evenly. In reality, this will always lead to burst at the start or end of the time window.

Take for example 5 request per second. If the operation is controlled, we can just fire the request at the end of the interval, every 200ms.

However, if the operation is uncontrolled, it is possible for user to make request at the end of the first interval, and at the start of the next interval, leading to sudden burst.

A better approach is to divide the period over twice the requests, and check if the operation is done at even boundaries. For some use cases, it might not make sense, so setting a min interval between requests is simpler.

## Decisions

Implementing the right rate limit requires understanding the usecase.

The most naive implementation will just require:

- limit: the number of max request
- period: the time window where the limit is applied too

For more advance usecase, we can also configure the following:

- min interval: the minimum interval before each request. The maximum can be calculated using period/limit. Setting this to 0 is not recommended for high traffic application
- quota: can replace limit
- burst: allow burst request


## Rate Limit Header

https://datatracker.ietf.org/doc/html/rfc6585#section-4

We should only return Retry-After. We don't need to expose internal rate limiting policy to client. However, if we are serving the clients, we can return additional headers.

Most rate limit algo like leaky bucket doesnt gave a concept of remaining, it just aims to keep the flow constant.

## Rate limit rollout

Hash based, percentage rollout.

## Rate Limit Config

https://www.slashid.dev/blog/id-based-rate-limiting/

## Separate Threshold

Use a rate limit with separate rate and separate limit, e.g. 10 per second, but limit to 5 per second.

## Implementation 

- by frequency
- by duration
- by error rate
- by throttle
- combination

- wait: cron style, waits for the next execution. can just use for loop?
- nowait: immediately fails. this should be default implementation...


### Example: Fixed Window

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
	rl := New(10, time.Second)
	for i := range 100 {
		time.Sleep(50 * time.Millisecond)
		fmt.Println(i, rl.Remaining(), rl.Allow(), rl.Remaining(), rl.RetryAt(), time.Now())
	}
	fmt.Println("Hello, 世界")
}

func New(limit int, period time.Duration) *RateLimiter {
	return &RateLimiter{
		limit:  limit,
		period: period.Nanoseconds(),
		Now:    time.Now,
	}
}

type RateLimiter struct {
	// Config
	limit  int
	period int64
	Now    func() time.Time

	// State
	mu    sync.RWMutex
	count int
	last  int64
}

func (r *RateLimiter) Allow() bool {
	return r.AllowN(1)
}

func (r *RateLimiter) AllowN(n int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.remaining()-n >= 0 {
		r.count += n
		return true
	}
	return false
}

func (r *RateLimiter) Remaining() int {
	r.mu.RLock()
	n := r.remaining()
	r.mu.RUnlock()
	return n
}

func (r *RateLimiter) remaining() int {
	now := r.Now().UnixNano()
	if r.last+r.period <= now {
		r.last = now
		r.count = 0
	}
	return r.limit - r.count
}

func (r *RateLimiter) RetryAt() time.Time {
	if r.Remaining() > 0 {
		return r.Now()
	}

	r.mu.RLock()
	last, period := r.last, r.period
	r.mu.RUnlock()
	return time.Unix(0, last+period)
}
```

### Example: Fixed window key 

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
	k := "key"
	rl := New(10, time.Second)
	stop := rl.Clear()
	defer stop()
	for i := range 100 {
		time.Sleep(50 * time.Millisecond)
		fmt.Println(i, rl.Remaining(k), rl.Allow(k), rl.Remaining(k), rl.RetryAt(k))
	}
	k = "val"
	for i := range 11 {
		fmt.Println(i, rl.Remaining(k), rl.Allow(k), rl.Remaining(k), rl.RetryAt(k))
	}
	fmt.Println("Hello, 世界", rl)
	time.Sleep(2 * time.Second)
	fmt.Println("Hello, 世界", rl)
	time.Sleep(time.Second)
}

func New(limit int, period time.Duration) *RateLimiter {
	return &RateLimiter{
		limit:  limit,
		period: period.Nanoseconds(),
		Now:    time.Now,
		vals:   make(map[string]*State),
	}
}

type RateLimiter struct {
	// Config
	limit  int
	period int64
	Now    func() time.Time

	// State
	mu   sync.RWMutex
	vals map[string]*State
}

type State struct {
	count int
	last  int64
}

func (r *RateLimiter) Allow(key string) bool {
	return r.AllowN(key, 1)
}

func (r *RateLimiter) AllowN(key string, n int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.vals[key]; !ok {
		r.vals[key] = new(State)
	}
	if r.remaining(key)-n >= 0 {
		r.vals[key].count += n
		return true
	}
	return false
}

func (r *RateLimiter) Remaining(key string) int {
	r.mu.RLock()
	n := r.remaining(key)
	r.mu.RUnlock()
	return n
}

func (r *RateLimiter) remaining(key string) int {
	v, ok := r.vals[key]
	if !ok {
		return r.limit
	}

	now := r.Now().UnixNano()
	if v.last+r.period <= now {
		v.last = now
		v.count = 0
	}

	return r.limit - v.count
}

func (r *RateLimiter) RetryAt(key string) time.Time {
	if r.Remaining(key) > 0 {
		return r.Now()
	}

	r.mu.RLock()
	v, ok := r.vals[key]
	if !ok {
		r.mu.RUnlock()
		return r.Now()
	}
	last, period := v.last, r.period
	r.mu.RUnlock()
	return time.Unix(0, last+period)
}

func (r *RateLimiter) Clear() func() {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)

	go func() {
		defer wg.Done()

		t := time.NewTicker(time.Duration(r.period))
		defer t.Stop()

		for {
			select {
			case <-done:
				return
			case ts := <-t.C:
				now := ts.UnixNano()
				r.mu.Lock()
				for k, v := range r.vals {
					if v.last+r.period <= now {
						delete(r.vals, k)
					}
				}
				r.mu.Unlock()
			}
		}
	}()

	return sync.OnceFunc(func() {
		close(done)
		wg.Wait()
	})
}
```

## Example: Sliding window key

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"math"
	"sync"
	"time"
)

func main() {
	k := "key"
	rl := New(10, time.Second)
	stop := rl.Clear()
	defer stop()
	for i := range 50 {
		time.Sleep(50 * time.Millisecond)
		fmt.Println(i, rl.Remaining(k), rl.Allow(k), rl.Remaining(k), rl.RetryAt(k))
	}
	k = "val"
	for i := range 11 {
		fmt.Println(i, rl.Remaining(k), rl.Allow(k), rl.Remaining(k), rl.RetryAt(k))
	}
	fmt.Println("Hello, 世界", rl)
	time.Sleep(2 * time.Second)
	fmt.Println("Hello, 世界", rl)
	time.Sleep(time.Second)
}

func New(limit int, period time.Duration) *RateLimiter {
	return &RateLimiter{
		limit:  limit,
		period: period.Nanoseconds(),
		Now:    time.Now,
		vals:   make(map[string]*State),
	}
}

type RateLimiter struct {
	// Config
	limit  int
	period int64
	Now    func() time.Time

	// State
	mu   sync.RWMutex
	vals map[string]*State
}

type State struct {
	prev int
	curr int
	last int64
}

func (r *RateLimiter) Allow(key string) bool {
	return r.AllowN(key, 1)
}

func (r *RateLimiter) AllowN(key string, n int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.vals[key]; !ok {
		r.vals[key] = new(State)
	}
	if r.remaining(key)-n >= 0 {
		r.vals[key].curr += n
		return true
	}
	return false
}

func (r *RateLimiter) Remaining(key string) int {
	r.mu.RLock()
	n := r.remaining(key)
	r.mu.RUnlock()
	return n
}

func (r *RateLimiter) remaining(key string) int {
	v, ok := r.vals[key]
	if !ok {
		return r.limit
	}

	now := r.Now().UnixNano()
	curr := now - now%r.period
	prev := curr - r.period
	if v.last == prev {
		v.prev = v.curr
		v.curr = 0
		v.last = curr
	} else if v.last != curr {
		v.prev = 0
		v.curr = 0
		v.last = curr
	}

	ratio := 1.0 - float64(now%r.period)/float64(r.period)
	count := int(math.Floor(float64(v.prev)*ratio + float64(v.curr)))
	return r.limit - count
}

func (r *RateLimiter) RetryAt(key string) time.Time {
	if r.Remaining(key) > 0 {
		return r.Now()
	}

	r.mu.RLock()
	v, ok := r.vals[key]
	if !ok {
		r.mu.RUnlock()
		return r.Now()
	}
	last, period := v.last, r.period
	r.mu.RUnlock()
	return time.Unix(0, last+period)
}

func (r *RateLimiter) Clear() func() {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)

	go func() {
		defer wg.Done()

		t := time.NewTicker(time.Duration(r.period))
		defer t.Stop()

		for {
			select {
			case <-done:
				return
			case <-t.C:
				r.mu.Lock()
				now := r.Now().UnixNano()
				for k, v := range r.vals {
					if v.last+r.period <= now {
						delete(r.vals, k)
					}
				}
				r.mu.Unlock()
			}
		}
	}()

	return sync.OnceFunc(func() {
		close(done)
		wg.Wait()
	})
}

```


## GCRA Keys

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
	k := "key"
	rl := New(10, time.Second, 3)
	stop := rl.Clear()
	defer stop()
	for i := range 50 {
		time.Sleep(10 * time.Millisecond)
		fmt.Println(i, rl.Allow(k))
	}
	k = "val"
	for i := range 11 {
		fmt.Println(i, rl.Allow(k))
	}
	fmt.Println("Hello, 世界", rl)
	time.Sleep(2 * time.Second)
	fmt.Println("Hello, 世界", rl)
	time.Sleep(time.Second)
}

func New(limit int, period time.Duration, burst int) *RateLimiter {
	return &RateLimiter{
		burst:    int64(burst),
		limit:    limit,
		period:   period.Nanoseconds(),
		interval: period.Nanoseconds() / int64(limit),
		Now:      time.Now,
		vals:     make(map[string]int64),
	}
}

type RateLimiter struct {
	// Config
	burst    int64
	limit    int
	period   int64
	interval int64
	Now      func() time.Time

	// State
	mu   sync.RWMutex
	vals map[string]int64
}

func (r *RateLimiter) Allow(key string) bool {
	return r.AllowN(key, 1)
}

func (r *RateLimiter) AllowN(key string, n int64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := r.Now().UnixNano()
	t := max(r.vals[key], now)
	if t-r.burst*r.interval <= now {
		r.vals[key] = t + n*r.interval
		return true
	}

	return false
}

func (r *RateLimiter) Clear() func() {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)

	go func() {
		defer wg.Done()

		t := time.NewTicker(time.Duration(r.period))
		defer t.Stop()

		for {
			select {
			case <-done:
				return
			case <-t.C:
				r.mu.Lock()
				now := r.Now().UnixNano()
				for k, v := range r.vals {
					if v+r.period <= now {
						delete(r.vals, k)
					}
				}
				r.mu.Unlock()
			}
		}
	}()

	return sync.OnceFunc(func() {
		close(done)
		wg.Wait()
	})
}
```

### Error Limiter

Stops when the error exceeds the limit. Forgiving by allowing the tries to be increment for each successes.

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"math/rand/v2"
)

func main() {
	l := New(3)
	var fail int
	var ok int
	for range 100 {
		allow := l.Allow()
		fmt.Println(allow, l.count)
		if !allow {
			continue
		}
		ok++
		if rand.Float64() < 0.5 {
			fail++
			l.fail()
		} else {
			l.ok()
		}
	}
	fmt.Println("Hello, 世界", ok, fail, l)
}

type ErrorLimiter struct {
	limit int
	count float64
}

func New(limit int) *ErrorLimiter {
	return &ErrorLimiter{
		limit: limit,
	}
}

func (l *ErrorLimiter) fail() {
	l.count = min(l.count+1.0, float64(l.limit))
}
func (l *ErrorLimiter) ok() {
	l.count = max(l.count-0.5, 0)
}
func (l *ErrorLimiter) Allow() bool {
	return int(l.count) < l.limit
}
```

We can modify it to include decay ... that is, the errors dissipates over time and can be retried later.


```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"math/rand/v2"
	"time"
)

func main() {
	l := New(3, time.Second)
	var fail int
	var ok int
	for range 100 {
		time.Sleep(100 * time.Millisecond)
		allow := l.Allow()
		fmt.Println(allow, l.count)
		if !allow {
			continue
		}
		ok++
		if rand.Float64() < 0.5 {
			fail++
			l.fail()
		} else {
			l.ok()
		}
	}
	fmt.Println("Hello, 世界", ok, fail, l)
}

type ErrorLimiter struct {
	limit  int
	count  float64
	period int64
	last   int64
	Now    func() time.Time
}

func New(limit int, period time.Duration) *ErrorLimiter {
	return &ErrorLimiter{
		limit:  limit,
		period: period.Nanoseconds(),
		Now:    time.Now,
	}
}

func (l *ErrorLimiter) fail() {
	l.decay()
	l.count = min(l.count+1.0, float64(l.limit)+1)
}
func (l *ErrorLimiter) ok() {
	l.decay()
	l.count = max(l.count-0.5, 0)
}

func (l *ErrorLimiter) decay() {
	now := l.Now().UnixNano()
	elapsed := min(now-l.last, l.period)
	ratio := 1.0 - float64(elapsed)/float64(l.period)
	l.count *= ratio
	l.last = now
}

func (l *ErrorLimiter) Allow() bool {
	l.decay()
	return int(l.count) < l.limit
}
```

### Rate

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"math"
	"math/rand/v2"
	"time"
)

func main() {
	r := New(10, time.Second)
	for range 1 {
		time.Sleep(100 * time.Millisecond)
		fmt.Println(r.Remaining(), r.Allow(), r.Remaining(), r.Count(), r.Rate())
	}
	er := NewErrorRate(30, time.Second, 0.5)
	for range 100 {
		time.Sleep(5 * time.Millisecond)
		fmt.Print(er.Allow(), er.Ratio())
		fmt.Println(er.Counts())
		if rand.Float64() < 0.8 {
			er.Fail()
		} else {
			er.Success()
		}
	}
	fmt.Println("Hello, 世界")
}

type Rate struct {
	count  float64
	period int64
	last   int64
	Now    func() time.Time
}

func NewRate(period time.Duration) *Rate {
	return &Rate{
		period: period.Nanoseconds(),
		Now:    time.Now,
	}
}

func (r *Rate) Count() float64 {
	now := r.Now().UnixNano()
	elapsed := min(now-r.last, r.period)
	return r.count * (1.0 - float64(elapsed)/float64(r.period))
}

func (r *Rate) Inc(n float64) float64 {
	r.count = r.Count() + n
	r.last = r.Now().UnixNano()
	return r.count
}

type Flow struct {
	limit int
	rate  *Rate
}

func New(limit int, period time.Duration) *Flow {
	return &Flow{
		limit: limit,
		rate:  NewRate(period),
	}
}

func (r *Flow) Rate() float64 {
	return r.rate.Count()
}

func (r *Flow) Count() int {
	return int(math.Ceil(r.Rate()))
}

func (r *Flow) Remaining() int {
	return r.limit - r.Count()
}

func (r *Flow) Inc(n int) float64 {
	return r.rate.Inc(float64(n))
}

func (r *Flow) AllowN(n int) bool {
	if r.Remaining()-n >= 0 {
		r.Inc(n)
		return true
	}

	return false
}

func (r *Flow) Allow() bool {
	return r.AllowN(1)
}

type ErrorRate struct {
	success *Rate
	failure *Rate
	limit   int
	ratio   float64
}

func NewErrorRate(limit int, period time.Duration, ratio float64) *ErrorRate {
	return &ErrorRate{
		success: NewRate(period),
		failure: NewRate(period),
		limit:   limit,
		ratio:   ratio,
	}
}

func (r *ErrorRate) Fail() {
	r.failure.Inc(1)
	r.success.Inc(0)
}

func (r *ErrorRate) Success() {
	r.failure.Inc(0)
	r.success.Inc(1)
}

func (r *ErrorRate) Counts() (float64, float64) {
	return r.success.Inc(0), r.failure.Inc(0)
}

func (r *ErrorRate) Ratio() float64 {
	f := r.failure.Inc(0)
	s := r.success.Inc(0)
	if s == 0 {
		return 0
	}
	return f / (s + f)
}

func (r *ErrorRate) Allow() bool {
	f := r.failure.Inc(0)
	s := r.success.Inc(0)
	if s == 0 {
		return !(f+s > float64(r.limit))
	}
	return !(f+s > float64(r.limit) && f/(s+f) > r.ratio)
}
```


### Error limiting

Note that we try to explore the rate limiter usage for limiting errors too. However, that should be left to circuit breaker.

Rate limit limits request, circuit breaker prevents excessive errors.

We can have still have event based rate limiter, where the event can be an error. Notice the difference in request based:


In the allow, we immediately increment the count and check the count is less than the lilmit.

In the error based, we can have two implementation
- fail fast
- self healing

In fail fast, we check the count is less than limit. No increment happens here. We lnly increment when there is an error. Optionally we can decrement when there is success, or multiply when there is a continous errror (in this scenario, we are not counting total errors quota, but rather an error score that is specific to the application.

In self healing mode, we have two options, with the latter less preferable

- retry after sleep duration
- decay count
- allow every n request, and decrement on success
- auto recover through events or signals elsewhere e,g, health check


It all depends on use case. For example, you may want to fail fast for a retry operation, when there are too many errors in retries (permanent error). Or if you have a batch process, and you have specific error quota, e.g. if first 10 fails out of 1000 (could have terminated on first failure, but maybe we want some leeway).

Self healing can be implemented for external request, or when the ererors are expected to be intermittent.

## Consequences

Rate limiting protects your server from DDOS.


