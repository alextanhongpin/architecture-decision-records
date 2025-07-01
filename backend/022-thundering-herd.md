# Thundering Herd Problem and Mitigation Strategies

## Status

`accepted`

## Context

The thundering herd problem occurs when a large number of clients simultaneously compete for the same resource, causing a massive spike in load that can overwhelm the system. This commonly happens during cache misses, service restarts, or when a shared resource becomes available after a period of unavailability.

Traditional solutions like request coalescing have limitations, and comprehensive strategies involving load shedding, traffic management, and intelligent client behavior are needed to handle this problem effectively.

## Decision

We will implement a multi-layered approach to handle thundering herd problems, including intelligent load shedding, traffic shaping, request coalescing, and client-side backoff strategies.

## Thundering Herd Problem

The thundering herd problem manifests in several scenarios:

1. **Cache Expiration**: When a popular cache key expires, multiple requests attempt to regenerate it simultaneously
2. **Service Restart**: When a service comes back online, all waiting clients attempt to connect at once
3. **Resource Availability**: When a limited resource becomes available, all waiting clients compete for it
4. **Database Failover**: When a database becomes available after failure, all clients attempt to connect

### Problem Characteristics

- **Spike in Load**: Sudden, massive increase in concurrent requests
- **Resource Contention**: Multiple clients competing for the same resource
- **Cascading Failures**: Overload can cause additional failures
- **Wasted Resources**: Most requests will fail, wasting CPU and memory
- **Poor User Experience**: High latency and failures for end users

## Implementation Strategies

### 1. Request Coalescing with Singleflight

```go
package coalescing

import (
    "context"
    "fmt"
    "sync"
    "time"
)

// Singleflight prevents duplicate function calls for the same key
type Singleflight struct {
    mu sync.Mutex
    calls map[string]*call
}

type call struct {
    wg  sync.WaitGroup
    val interface{}
    err error
}

// NewSingleflight creates a new singleflight instance
func NewSingleflight() *Singleflight {
    return &Singleflight{
        calls: make(map[string]*call),
    }
}

// Do executes fn only once for the same key, other calls wait for the result
func (sf *Singleflight) Do(key string, fn func() (interface{}, error)) (interface{}, error) {
    sf.mu.Lock()
    
    if c, ok := sf.calls[key]; ok {
        sf.mu.Unlock()
        c.wg.Wait()
        return c.val, c.err
    }
    
    c := &call{}
    c.wg.Add(1)
    sf.calls[key] = c
    sf.mu.Unlock()
    
    defer func() {
        sf.mu.Lock()
        delete(sf.calls, key)
        sf.mu.Unlock()
        c.wg.Done()
    }()
    
    c.val, c.err = fn()
    return c.val, c.err
}

// DoWithTimeout executes fn with a timeout
func (sf *Singleflight) DoWithTimeout(key string, timeout time.Duration, fn func() (interface{}, error)) (interface{}, error) {
    ctx, cancel := context.WithTimeout(context.Background(), timeout)
    defer cancel()
    
    resultChan := make(chan struct {
        val interface{}
        err error
    }, 1)
    
    go func() {
        val, err := sf.Do(key, fn)
        resultChan <- struct {
            val interface{}
            err error
        }{val, err}
    }()
    
    select {
    case result := <-resultChan:
        return result.val, result.err
    case <-ctx.Done():
        return nil, ctx.Err()
    }
}

// Example usage with cache
type CacheLoader struct {
    sf    *Singleflight
    cache map[string]interface{}
    mu    sync.RWMutex
}

func NewCacheLoader() *CacheLoader {
    return &CacheLoader{
        sf:    NewSingleflight(),
        cache: make(map[string]interface{}),
    }
}

func (cl *CacheLoader) Get(key string, loader func() (interface{}, error)) (interface{}, error) {
    // Try cache first
    cl.mu.RLock()
    if val, ok := cl.cache[key]; ok {
        cl.mu.RUnlock()
        return val, nil
    }
    cl.mu.RUnlock()
    
    // Use singleflight to prevent thundering herd
    val, err := cl.sf.Do(key, func() (interface{}, error) {
        data, err := loader()
        if err != nil {
            return nil, err
        }
        
        // Cache the result
        cl.mu.Lock()
        cl.cache[key] = data
        cl.mu.Unlock()
        
        return data, nil
    })
    
    return val, err
}
```

### 2. Intelligent Load Shedding

```go
package loadshedding

import (
    "context"
    "fmt"
    "math"
    "sync/atomic"
    "time"
)

// LoadShedder implements intelligent load shedding
type LoadShedder struct {
    // Metrics
    inFlightRequests int64
    totalRequests    int64
    droppedRequests  int64
    
    // Configuration
    maxInFlight      int64
    maxQueueSize     int64
    dropProbability  float64
    
    // Adaptive parameters
    latencyThreshold time.Duration
    errorThreshold   float64
    
    // State
    currentLatency   time.Duration
    errorRate        float64
    
    // Queue
    requestQueue chan *Request
}

type Request struct {
    ID        string
    Priority  int
    Timestamp time.Time
    Handler   func() error
    Response  chan error
}

// NewLoadShedder creates a new load shedder
func NewLoadShedder(maxInFlight, maxQueueSize int64, latencyThreshold time.Duration) *LoadShedder {
    ls := &LoadShedder{
        maxInFlight:      maxInFlight,
        maxQueueSize:     maxQueueSize,
        latencyThreshold: latencyThreshold,
        errorThreshold:   0.1, // 10% error rate
        requestQueue:     make(chan *Request, maxQueueSize),
    }
    
    // Start background worker
    go ls.processRequests()
    
    return ls
}

// ShouldDrop determines if a request should be dropped using Netflix's cubic function
func (ls *LoadShedder) ShouldDrop(priority int) bool {
    // Get current load percentage
    loadPercent := float64(atomic.LoadInt64(&ls.inFlightRequests)) / float64(ls.maxInFlight) * 100
    
    // Netflix cubic function: f(x) = -1/10000 * x^3 + 100
    // Where x is load percentage, output is priority threshold
    priorityThreshold := -math.Pow(loadPercent, 3)/10000 + 100
    
    // Drop if priority is below threshold
    return float64(priority) < priorityThreshold
}

// AdaptiveDropProbability calculates drop probability based on system health
func (ls *LoadShedder) AdaptiveDropProbability() float64 {
    latencyFactor := 0.0
    if ls.currentLatency > ls.latencyThreshold {
        latencyFactor = float64(ls.currentLatency) / float64(ls.latencyThreshold) - 1
    }
    
    errorFactor := 0.0
    if ls.errorRate > ls.errorThreshold {
        errorFactor = ls.errorRate/ls.errorThreshold - 1
    }
    
    // Combine factors (max 0.9 to always allow some requests)
    probability := math.Min(0.9, (latencyFactor+errorFactor)/2)
    return probability
}

// HandleRequest handles a request with load shedding
func (ls *LoadShedder) HandleRequest(ctx context.Context, req *Request) error {
    // Check if should drop based on priority
    if ls.ShouldDrop(req.Priority) {
        atomic.AddInt64(&ls.droppedRequests, 1)
        return fmt.Errorf("request dropped due to load shedding")
    }
    
    // Check adaptive drop probability
    if ls.AdaptiveDropProbability() > 0.5 {
        atomic.AddInt64(&ls.droppedRequests, 1)
        return fmt.Errorf("request dropped due to system overload")
    }
    
    // Check if queue is full
    select {
    case ls.requestQueue <- req:
        atomic.AddInt64(&ls.totalRequests, 1)
        return nil
    default:
        atomic.AddInt64(&ls.droppedRequests, 1)
        return fmt.Errorf("request queue full")
    }
}

// processRequests processes queued requests
func (ls *LoadShedder) processRequests() {
    for req := range ls.requestQueue {
        go ls.executeRequest(req)
    }
}

// executeRequest executes a single request
func (ls *LoadShedder) executeRequest(req *Request) {
    atomic.AddInt64(&ls.inFlightRequests, 1)
    defer atomic.AddInt64(&ls.inFlightRequests, -1)
    
    start := time.Now()
    err := req.Handler()
    duration := time.Since(start)
    
    // Update metrics
    ls.updateMetrics(duration, err != nil)
    
    // Send response
    select {
    case req.Response <- err:
    default:
        // Client gave up waiting
    }
}

// updateMetrics updates system metrics
func (ls *LoadShedder) updateMetrics(duration time.Duration, isError bool) {
    // Simple exponential moving average
    alpha := 0.1
    ls.currentLatency = time.Duration(float64(ls.currentLatency)*(1-alpha) + float64(duration)*alpha)
    
    if isError {
        ls.errorRate = ls.errorRate*(1-alpha) + alpha
    } else {
        ls.errorRate = ls.errorRate * (1 - alpha)
    }
}

// GetMetrics returns current metrics
func (ls *LoadShedder) GetMetrics() map[string]interface{} {
    return map[string]interface{}{
        "in_flight_requests": atomic.LoadInt64(&ls.inFlightRequests),
        "total_requests":     atomic.LoadInt64(&ls.totalRequests),
        "dropped_requests":   atomic.LoadInt64(&ls.droppedRequests),
        "current_latency":    ls.currentLatency,
        "error_rate":         ls.errorRate,
        "drop_probability":   ls.AdaptiveDropProbability(),
    }
}
```

### 3. Traffic Shaping and Selective Routing

```go
package traffic

import (
    "crypto/md5"
    "fmt"
    "hash/fnv"
    "math"
    "sync"
    "time"
)

// TrafficShaper manages traffic flow during high load
type TrafficShaper struct {
    // Configuration
    maxRPS           int
    rampUpDuration   time.Duration
    userSegmentation bool
    
    // State
    currentRPS    int
    rampUpStart   time.Time
    isRampingUp   bool
    
    // Rate limiting
    tokenBucket   chan struct{}
    mu            sync.RWMutex
}

// NewTrafficShaper creates a new traffic shaper
func NewTrafficShaper(maxRPS int, rampUpDuration time.Duration) *TrafficShaper {
    ts := &TrafficShaper{
        maxRPS:         maxRPS,
        rampUpDuration: rampUpDuration,
        tokenBucket:    make(chan struct{}, maxRPS),
    }
    
    // Start token bucket filler
    go ts.fillTokenBucket()
    
    return ts
}

// StartRampUp begins gradual traffic ramp-up
func (ts *TrafficShaper) StartRampUp() {
    ts.mu.Lock()
    defer ts.mu.Unlock()
    
    ts.isRampingUp = true
    ts.rampUpStart = time.Now()
    ts.currentRPS = 1 // Start with 1 RPS
}

// StopRampUp stops ramp-up and allows full traffic
func (ts *TrafficShaper) StopRampUp() {
    ts.mu.Lock()
    defer ts.mu.Unlock()
    
    ts.isRampingUp = false
    ts.currentRPS = ts.maxRPS
}

// getCurrentRPS calculates current RPS during ramp-up
func (ts *TrafficShaper) getCurrentRPS() int {
    ts.mu.RLock()
    defer ts.mu.RUnlock()
    
    if !ts.isRampingUp {
        return ts.maxRPS
    }
    
    elapsed := time.Since(ts.rampUpStart)
    if elapsed >= ts.rampUpDuration {
        return ts.maxRPS
    }
    
    // Linear ramp-up
    progress := float64(elapsed) / float64(ts.rampUpDuration)
    rps := int(float64(ts.maxRPS) * progress)
    
    if rps < 1 {
        rps = 1
    }
    
    return rps
}

// fillTokenBucket fills the token bucket at current rate
func (ts *TrafficShaper) fillTokenBucket() {
    ticker := time.NewTicker(time.Second)
    defer ticker.Stop()
    
    for range ticker.C {
        currentRPS := ts.getCurrentRPS()
        
        // Fill bucket with current RPS tokens
        for i := 0; i < currentRPS; i++ {
            select {
            case ts.tokenBucket <- struct{}{}:
            default:
                // Bucket is full
            }
        }
    }
}

// AllowRequest checks if request should be allowed
func (ts *TrafficShaper) AllowRequest(userID string) bool {
    // Try to get token
    select {
    case <-ts.tokenBucket:
        return true
    default:
        return false
    }
}

// UserSegmentation provides user-based traffic control
type UserSegmentation struct {
    allowedPercentage int
    isPaidUsersOnly   bool
    mu                sync.RWMutex
}

// NewUserSegmentation creates user segmentation
func NewUserSegmentation() *UserSegmentation {
    return &UserSegmentation{
        allowedPercentage: 100,
        isPaidUsersOnly:   false,
    }
}

// SetAllowedPercentage sets the percentage of users allowed
func (us *UserSegmentation) SetAllowedPercentage(percentage int) {
    us.mu.Lock()
    defer us.mu.Unlock()
    us.allowedPercentage = percentage
}

// SetPaidUsersOnly restricts to paid users only
func (us *UserSegmentation) SetPaidUsersOnly(paidOnly bool) {
    us.mu.Lock()
    defer us.mu.Unlock()
    us.isPaidUsersOnly = paidOnly
}

// AllowUser determines if a user should be allowed
func (us *UserSegmentation) AllowUser(userID string, isPaidUser bool) bool {
    us.mu.RLock()
    defer us.mu.RUnlock()
    
    // Check paid user restriction
    if us.isPaidUsersOnly && !isPaidUser {
        return false
    }
    
    // Check percentage allowance
    if us.allowedPercentage >= 100 {
        return true
    }
    
    // Hash user ID and check if within allowed percentage
    hasher := fnv.New32a()
    hasher.Write([]byte(userID))
    hash := hasher.Sum32()
    
    return int(hash%100) < us.allowedPercentage
}

// GradualRampUp gradually increases allowed percentage
func (us *UserSegmentation) GradualRampUp(duration time.Duration, steps int) {
    increment := 100 / steps
    interval := duration / time.Duration(steps)
    
    go func() {
        for i := 0; i < steps; i++ {
            time.Sleep(interval)
            newPercentage := (i + 1) * increment
            if newPercentage > 100 {
                newPercentage = 100
            }
            us.SetAllowedPercentage(newPercentage)
        }
    }()
}
```

### 4. Intelligent Client Backoff

```go
package backoff

import (
    "context"
    "fmt"
    "math"
    "math/rand"
    "net/http"
    "time"
)

// BackoffStrategy defines different backoff strategies
type BackoffStrategy int

const (
    ExponentialBackoff BackoffStrategy = iota
    LinearBackoff
    FixedBackoff
    ExponentialBackoffWithJitter
)

// BackoffConfig configures backoff behavior
type BackoffConfig struct {
    Strategy     BackoffStrategy
    InitialDelay time.Duration
    MaxDelay     time.Duration
    MaxRetries   int
    Multiplier   float64
    Jitter       bool
}

// RetryableClient implements intelligent retry logic
type RetryableClient struct {
    client       *http.Client
    config       BackoffConfig
    circuitBreaker *CircuitBreaker
}

// NewRetryableClient creates a new retryable client
func NewRetryableClient(config BackoffConfig) *RetryableClient {
    return &RetryableClient{
        client: &http.Client{Timeout: 30 * time.Second},
        config: config,
        circuitBreaker: NewCircuitBreaker(CircuitBreakerConfig{
            MaxFailures:    5,
            ResetTimeout:   30 * time.Second,
            HalfOpenMaxRequests: 3,
        }),
    }
}

// Do executes HTTP request with intelligent retry
func (rc *RetryableClient) Do(ctx context.Context, req *http.Request) (*http.Response, error) {
    var lastErr error
    
    for attempt := 0; attempt <= rc.config.MaxRetries; attempt++ {
        // Check circuit breaker
        if !rc.circuitBreaker.AllowRequest() {
            return nil, fmt.Errorf("circuit breaker open")
        }
        
        // Execute request
        resp, err := rc.client.Do(req.WithContext(ctx))
        
        // Check if request was successful
        if err == nil && rc.isSuccessfulResponse(resp) {
            rc.circuitBreaker.RecordSuccess()
            return resp, nil
        }
        
        // Record failure
        rc.circuitBreaker.RecordFailure()
        lastErr = err
        
        // Check if we should retry
        if !rc.shouldRetry(resp, err) || attempt == rc.config.MaxRetries {
            if resp != nil {
                return resp, nil
            }
            break
        }
        
        // Calculate backoff delay
        delay := rc.calculateBackoff(attempt)
        
        // Wait before retry
        select {
        case <-ctx.Done():
            return nil, ctx.Err()
        case <-time.After(delay):
            continue
        }
    }
    
    return nil, fmt.Errorf("max retries reached: %w", lastErr)
}

// isSuccessfulResponse checks if response is successful
func (rc *RetryableClient) isSuccessfulResponse(resp *http.Response) bool {
    return resp.StatusCode >= 200 && resp.StatusCode < 300
}

// shouldRetry determines if request should be retried
func (rc *RetryableClient) shouldRetry(resp *http.Response, err error) bool {
    // Network errors should be retried
    if err != nil {
        return true
    }
    
    // Retry based on status code
    switch resp.StatusCode {
    case http.StatusRequestTimeout:       // 408
        return true
    case http.StatusTooManyRequests:      // 429 - Don't retry immediately
        return false
    case http.StatusInternalServerError:  // 500 - Don't retry
        return false
    case http.StatusBadGateway:          // 502
        return true
    case http.StatusServiceUnavailable:  // 503
        return true
    case http.StatusGatewayTimeout:      // 504
        return true
    default:
        return false
    }
}

// calculateBackoff calculates backoff delay
func (rc *RetryableClient) calculateBackoff(attempt int) time.Duration {
    var delay time.Duration
    
    switch rc.config.Strategy {
    case ExponentialBackoff:
        delay = time.Duration(float64(rc.config.InitialDelay) * math.Pow(rc.config.Multiplier, float64(attempt)))
    case LinearBackoff:
        delay = rc.config.InitialDelay * time.Duration(attempt+1)
    case FixedBackoff:
        delay = rc.config.InitialDelay
    case ExponentialBackoffWithJitter:
        exponentialDelay := time.Duration(float64(rc.config.InitialDelay) * math.Pow(rc.config.Multiplier, float64(attempt)))
        jitter := time.Duration(rand.Float64() * float64(exponentialDelay))
        delay = exponentialDelay + jitter
    }
    
    // Apply jitter if configured
    if rc.config.Jitter && rc.config.Strategy != ExponentialBackoffWithJitter {
        jitter := time.Duration(rand.Float64() * float64(delay) * 0.1) // 10% jitter
        delay += jitter
    }
    
    // Ensure delay doesn't exceed maximum
    if delay > rc.config.MaxDelay {
        delay = rc.config.MaxDelay
    }
    
    return delay
}

// CircuitBreaker implements circuit breaker pattern
type CircuitBreaker struct {
    config       CircuitBreakerConfig
    state        CircuitState
    failures     int
    lastFailTime time.Time
    halfOpenRequests int
    mu           sync.RWMutex
}

type CircuitBreakerConfig struct {
    MaxFailures         int
    ResetTimeout        time.Duration
    HalfOpenMaxRequests int
}

type CircuitState int

const (
    StateClosed CircuitState = iota
    StateOpen
    StateHalfOpen
)

// NewCircuitBreaker creates a new circuit breaker
func NewCircuitBreaker(config CircuitBreakerConfig) *CircuitBreaker {
    return &CircuitBreaker{
        config: config,
        state:  StateClosed,
    }
}

// AllowRequest checks if request should be allowed
func (cb *CircuitBreaker) AllowRequest() bool {
    cb.mu.Lock()
    defer cb.mu.Unlock()
    
    switch cb.state {
    case StateClosed:
        return true
    case StateOpen:
        if time.Since(cb.lastFailTime) > cb.config.ResetTimeout {
            cb.state = StateHalfOpen
            cb.halfOpenRequests = 0
            return true
        }
        return false
    case StateHalfOpen:
        if cb.halfOpenRequests < cb.config.HalfOpenMaxRequests {
            cb.halfOpenRequests++
            return true
        }
        return false
    }
    
    return false
}

// RecordSuccess records a successful request
func (cb *CircuitBreaker) RecordSuccess() {
    cb.mu.Lock()
    defer cb.mu.Unlock()
    
    cb.failures = 0
    if cb.state == StateHalfOpen {
        cb.state = StateClosed
    }
}

// RecordFailure records a failed request
func (cb *CircuitBreaker) RecordFailure() {
    cb.mu.Lock()
    defer cb.mu.Unlock()
    
    cb.failures++
    cb.lastFailTime = time.Now()
    
    if cb.failures >= cb.config.MaxFailures {
        cb.state = StateOpen
    }
}
```

### 5. Monitoring and Metrics

```go
package monitoring

import (
    "context"
    "fmt"
    "sync/atomic"
    "time"

    "github.com/prometheus/client_golang/prometheus"
)

// ThunderingHerdMetrics tracks thundering herd related metrics
type ThunderingHerdMetrics struct {
    // Request metrics
    totalRequests     prometheus.Counter
    coalescedRequests prometheus.Counter
    droppedRequests   prometheus.Counter
    
    // Latency metrics
    requestLatency    prometheus.Histogram
    queueLatency      prometheus.Histogram
    
    // System metrics
    inFlightRequests  prometheus.Gauge
    queueSize         prometheus.Gauge
    dropRate          prometheus.Gauge
    
    // Circuit breaker metrics
    circuitBreakerState prometheus.Gauge
    circuitBreakerTrips prometheus.Counter
}

// NewThunderingHerdMetrics creates new metrics
func NewThunderingHerdMetrics() *ThunderingHerdMetrics {
    return &ThunderingHerdMetrics{
        totalRequests: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "thundering_herd_total_requests",
            Help: "Total number of requests",
        }),
        coalescedRequests: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "thundering_herd_coalesced_requests",
            Help: "Number of coalesced requests",
        }),
        droppedRequests: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "thundering_herd_dropped_requests",
            Help: "Number of dropped requests",
        }),
        requestLatency: prometheus.NewHistogram(prometheus.HistogramOpts{
            Name:    "thundering_herd_request_latency_seconds",
            Help:    "Request latency in seconds",
            Buckets: prometheus.DefBuckets,
        }),
        queueLatency: prometheus.NewHistogram(prometheus.HistogramOpts{
            Name:    "thundering_herd_queue_latency_seconds",
            Help:    "Queue latency in seconds",
            Buckets: prometheus.DefBuckets,
        }),
        inFlightRequests: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "thundering_herd_in_flight_requests",
            Help: "Number of in-flight requests",
        }),
        queueSize: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "thundering_herd_queue_size",
            Help: "Current queue size",
        }),
        dropRate: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "thundering_herd_drop_rate",
            Help: "Current drop rate",
        }),
        circuitBreakerState: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "thundering_herd_circuit_breaker_state",
            Help: "Circuit breaker state (0=closed, 1=open, 2=half-open)",
        }),
        circuitBreakerTrips: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "thundering_herd_circuit_breaker_trips",
            Help: "Number of circuit breaker trips",
        }),
    }
}

// AlertingRules defines alerting rules for thundering herd
type AlertingRules struct {
    HighDropRate        float64 // Alert if drop rate > threshold
    HighQueueLatency    time.Duration
    CircuitBreakerOpen  bool
    HighInFlightRequests int64
}

// MonitoringDashboard provides dashboard queries
type MonitoringDashboard struct {
    metrics *ThunderingHerdMetrics
}

// GetDashboardQueries returns Prometheus queries for dashboard
func (md *MonitoringDashboard) GetDashboardQueries() map[string]string {
    return map[string]string{
        "request_rate": `rate(thundering_herd_total_requests[5m])`,
        "drop_rate": `rate(thundering_herd_dropped_requests[5m]) / rate(thundering_herd_total_requests[5m])`,
        "coalescing_rate": `rate(thundering_herd_coalesced_requests[5m]) / rate(thundering_herd_total_requests[5m])`,
        "p95_latency": `histogram_quantile(0.95, rate(thundering_herd_request_latency_seconds_bucket[5m]))`,
        "p99_latency": `histogram_quantile(0.99, rate(thundering_herd_request_latency_seconds_bucket[5m]))`,
        "in_flight_requests": `thundering_herd_in_flight_requests`,
        "queue_size": `thundering_herd_queue_size`,
        "circuit_breaker_state": `thundering_herd_circuit_breaker_state`,
    }
}

// GetAlertRules returns alerting rules
func (md *MonitoringDashboard) GetAlertRules() map[string]string {
    return map[string]string{
        "high_drop_rate": `rate(thundering_herd_dropped_requests[5m]) / rate(thundering_herd_total_requests[5m]) > 0.1`,
        "high_latency": `histogram_quantile(0.95, rate(thundering_herd_request_latency_seconds_bucket[5m])) > 1.0`,
        "circuit_breaker_open": `thundering_herd_circuit_breaker_state == 1`,
        "high_queue_size": `thundering_herd_queue_size > 1000`,
    }
}
```

### 6. Integration Example

```go
package main

import (
    "context"
    "fmt"
    "log"
    "net/http"
    "time"
)

// ThunderingHerdHandler integrates all mitigation strategies
type ThunderingHerdHandler struct {
    singleflight    *Singleflight
    loadShedder     *LoadShedder
    trafficShaper   *TrafficShaper
    userSegmentation *UserSegmentation
    metrics         *ThunderingHerdMetrics
}

// NewThunderingHerdHandler creates integrated handler
func NewThunderingHerdHandler() *ThunderingHerdHandler {
    return &ThunderingHerdHandler{
        singleflight:    NewSingleflight(),
        loadShedder:     NewLoadShedder(1000, 5000, 100*time.Millisecond),
        trafficShaper:   NewTrafficShaper(1000, 5*time.Minute),
        userSegmentation: NewUserSegmentation(),
        metrics:         NewThunderingHerdMetrics(),
    }
}

// HandleRequest processes request with all protections
func (thh *ThunderingHerdHandler) HandleRequest(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    userID := r.Header.Get("X-User-ID")
    isPaidUser := r.Header.Get("X-Paid-User") == "true"
    
    // Metrics
    thh.metrics.totalRequests.Inc()
    start := time.Now()
    defer func() {
        thh.metrics.requestLatency.Observe(time.Since(start).Seconds())
    }()
    
    // User segmentation check
    if !thh.userSegmentation.AllowUser(userID, isPaidUser) {
        thh.metrics.droppedRequests.Inc()
        http.Error(w, "Service temporarily unavailable", http.StatusServiceUnavailable)
        return
    }
    
    // Traffic shaping
    if !thh.trafficShaper.AllowRequest(userID) {
        thh.metrics.droppedRequests.Inc()
        http.Error(w, "Rate limit exceeded", http.StatusTooManyRequests)
        return
    }
    
    // Load shedding
    priority := thh.calculatePriority(userID, isPaidUser)
    req := &Request{
        ID:        fmt.Sprintf("%s-%d", userID, time.Now().UnixNano()),
        Priority:  priority,
        Timestamp: time.Now(),
        Handler: func() error {
            return thh.processBusinessLogic(ctx, r)
        },
        Response: make(chan error, 1),
    }
    
    if err := thh.loadShedder.HandleRequest(ctx, req); err != nil {
        thh.metrics.droppedRequests.Inc()
        http.Error(w, err.Error(), http.StatusServiceUnavailable)
        return
    }
    
    // Wait for response
    select {
    case err := <-req.Response:
        if err != nil {
            http.Error(w, err.Error(), http.StatusInternalServerError)
            return
        }
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("Request processed successfully"))
    case <-ctx.Done():
        http.Error(w, "Request timeout", http.StatusRequestTimeout)
    }
}

// calculatePriority calculates request priority
func (thh *ThunderingHerdHandler) calculatePriority(userID string, isPaidUser bool) int {
    priority := 50 // Base priority
    
    if isPaidUser {
        priority += 30 // Higher priority for paid users
    }
    
    // Add randomness to prevent synchronization
    priority += int(time.Now().UnixNano() % 20)
    
    return priority
}

// processBusinessLogic processes the actual business logic
func (thh *ThunderingHerdHandler) processBusinessLogic(ctx context.Context, r *http.Request) error {
    // Use singleflight for expensive operations
    cacheKey := fmt.Sprintf("expensive_operation_%s", r.URL.Path)
    
    result, err := thh.singleflight.DoWithTimeout(cacheKey, 30*time.Second, func() (interface{}, error) {
        // Simulate expensive operation
        time.Sleep(100 * time.Millisecond)
        return "expensive_result", nil
    })
    
    if err != nil {
        return fmt.Errorf("failed to process request: %w", err)
    }
    
    thh.metrics.coalescedRequests.Inc()
    log.Printf("Processed request with result: %v", result)
    return nil
}

func main() {
    handler := NewThunderingHerdHandler()
    
    // Start gradual ramp-up after deployment
    handler.trafficShaper.StartRampUp()
    handler.userSegmentation.GradualRampUp(5*time.Minute, 10)
    
    http.HandleFunc("/api/endpoint", handler.HandleRequest)
    log.Println("Server starting on :8080")
    log.Fatal(http.ListenAndServe(":8080", nil))
}
```

## Benefits

1. **System Stability**: Prevents system overload during traffic spikes
2. **Graceful Degradation**: Maintains service availability under high load
3. **Resource Efficiency**: Reduces wasted computational resources
4. **User Experience**: Provides better experience through intelligent traffic management
5. **Operational Control**: Allows fine-tuned control over system behavior

## Consequences

### Positive

- **Improved Reliability**: System remains stable under high load
- **Better Resource Utilization**: More efficient use of system resources
- **Faster Recovery**: Quicker recovery from overload situations
- **Operational Flexibility**: Multiple knobs to control system behavior
- **Enhanced Monitoring**: Better visibility into system performance

### Negative

- **Increased Complexity**: More complex system with multiple components
- **Configuration Overhead**: Requires careful tuning of parameters
- **Potential User Impact**: Some users may experience degraded service
- **Debugging Complexity**: More difficult to debug with multiple layers
- **Development Overhead**: Additional code and testing required

## Implementation Checklist

- [ ] Implement request coalescing with singleflight pattern
- [ ] Set up intelligent load shedding with adaptive algorithms
- [ ] Create traffic shaping and gradual ramp-up mechanisms
- [ ] Implement user segmentation for selective access
- [ ] Add intelligent client-side backoff and circuit breakers
- [ ] Set up comprehensive monitoring and alerting
- [ ] Create operational dashboards for system visibility
- [ ] Implement graceful degradation strategies
- [ ] Add performance testing for thundering herd scenarios
- [ ] Document operational procedures and troubleshooting guides
- [ ] Set up automated recovery mechanisms
- [ ] Create load testing scenarios to validate effectiveness

## Best Practices

1. **Layered Defense**: Use multiple strategies in combination
2. **Gradual Rollout**: Implement changes gradually with monitoring
3. **Operational Visibility**: Maintain comprehensive monitoring and alerting
4. **Testing**: Regularly test thundering herd scenarios
5. **Documentation**: Document all configuration parameters and their effects
6. **Automation**: Automate response to common overload scenarios
7. **User Communication**: Communicate with users during degraded service
8. **Continuous Improvement**: Regularly review and improve strategies based on incidents

## References

- [Netflix Hystrix Circuit Breaker](https://github.com/Netflix/Hystrix)
- [Google SRE Book - Handling Overload](https://sre.google/sre-book/handling-overload/)
- [Thundering Herd Problem](https://en.wikipedia.org/wiki/Thundering_herd_problem)
- [Load Shedding Techniques](https://aws.amazon.com/builders-library/using-load-shedding-to-avoid-overload/)
- [Circuit Breaker Pattern](https://martinfowler.com/bliki/CircuitBreaker.html)
