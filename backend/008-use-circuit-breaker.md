# Use Circuit Breaker

## Status

`accepted`

## Context

When calling external services or resources, failures are inevitable. Without proper protection mechanisms, cascading failures can occur when a failing service receives continuous requests, potentially overwhelming the system and preventing recovery.

### Problem Statement

External service calls face several challenges:
- **Cascading failures**: One failing service can bring down dependent services
- **Resource exhaustion**: Continued calls to failing services waste resources
- **Thundering herd**: Mass retry attempts can prevent service recovery
- **Delayed failure detection**: Systems may not detect failures quickly enough
- **User experience**: Long timeouts provide poor user experience

### Solution Overview

A circuit breaker acts as an electrical circuit breaker for service calls, automatically stopping requests to failing services and allowing them time to recover. It provides:
- **Fail-fast behavior**: Quick failure detection and response
- **Service protection**: Prevents overwhelming failing services
- **Automatic recovery**: Tests service health and resumes normal operation
- **Graceful degradation**: Enables fallback mechanisms

## Decision

We will implement circuit breakers for all external service calls to provide fail-fast behavior and prevent cascading failures.

### Circuit Breaker States

A circuit breaker operates in three states:

1. **Closed**: Normal operation, requests pass through
2. **Open**: Circuit is tripped, requests fail immediately
3. **Half-Open**: Testing phase, limited requests allowed to test recovery

### Implementation Strategy

#### Basic Circuit Breaker

```go
package circuitbreaker

import (
    "errors"
    "sync"
    "time"
)

var (
    ErrCircuitOpen     = errors.New("circuit breaker is open")
    ErrTooManyRequests = errors.New("too many requests")
)

type State int

const (
    StateClosed State = iota
    StateHalfOpen
    StateOpen
)

type CircuitBreaker struct {
    mutex           sync.RWMutex
    maxRequests     uint32
    interval        time.Duration
    timeout         time.Duration
    readyToTrip     func(counts Counts) bool
    onStateChange   func(name string, from State, to State)
    
    name     string
    state    State
    counts   Counts
    expiry   time.Time
}

type Counts struct {
    Requests             uint32
    TotalSuccesses       uint32
    TotalFailures        uint32
    ConsecutiveSuccesses uint32
    ConsecutiveFailures  uint32
}

func NewCircuitBreaker(settings Settings) *CircuitBreaker {
    cb := &CircuitBreaker{
        name:        settings.Name,
        maxRequests: settings.MaxRequests,
        interval:    settings.Interval,
        timeout:     settings.Timeout,
        readyToTrip: settings.ReadyToTrip,
        onStateChange: settings.OnStateChange,
    }
    
    cb.toNewGeneration(time.Now())
    return cb
}

func (cb *CircuitBreaker) Execute(req func() (interface{}, error)) (interface{}, error) {
    generation, err := cb.beforeRequest()
    if err != nil {
        return nil, err
    }
    
    defer func() {
        e := recover()
        if e != nil {
            cb.afterRequest(generation, false)
            panic(e)
        }
    }()
    
    result, err := req()
    cb.afterRequest(generation, err == nil)
    return result, err
}

func (cb *CircuitBreaker) beforeRequest() (uint64, error) {
    cb.mutex.Lock()
    defer cb.mutex.Unlock()
    
    now := time.Now()
    state, generation := cb.currentState(now)
    
    if state == StateOpen {
        return generation, ErrCircuitOpen
    } else if state == StateHalfOpen && cb.counts.Requests >= cb.maxRequests {
        return generation, ErrTooManyRequests
    }
    
    cb.counts.onRequest()
    return generation, nil
}

func (cb *CircuitBreaker) afterRequest(before uint64, success bool) {
    cb.mutex.Lock()
    defer cb.mutex.Unlock()
    
    now := time.Now()
    state, generation := cb.currentState(now)
    if generation != before {
        return
    }
    
    if success {
        cb.onSuccess(state, now)
    } else {
        cb.onFailure(state, now)
    }
}

func (cb *CircuitBreaker) onSuccess(state State, now time.Time) {
    cb.counts.onSuccess()
    
    if state == StateHalfOpen {
        cb.setState(StateClosed, now)
    }
}

func (cb *CircuitBreaker) onFailure(state State, now time.Time) {
    cb.counts.onFailure()
    
    if cb.readyToTrip(cb.counts) {
        cb.setState(StateOpen, now)
    }
}

func (cb *CircuitBreaker) setState(state State, now time.Time) {
    if cb.state == state {
        return
    }
    
    prev := cb.state
    cb.state = state
    cb.toNewGeneration(now)
    
    if cb.onStateChange != nil {
        cb.onStateChange(cb.name, prev, state)
    }
}
```

#### Advanced Circuit Breaker with Error Budget

```go
type ErrorBudgetCircuitBreaker struct {
    mutex       sync.RWMutex
    name        string
    budget      int
    window      time.Duration
    timeout     time.Duration
    
    state      State
    tokens     int
    windowStart time.Time
    expiry     time.Time
}

func (cb *ErrorBudgetCircuitBreaker) Execute(req func() (interface{}, error)) (interface{}, error) {
    if !cb.allowRequest() {
        return nil, ErrCircuitOpen
    }
    
    start := time.Now()
    result, err := req()
    duration := time.Since(start)
    
    cb.recordResult(err, duration)
    return result, err
}

func (cb *ErrorBudgetCircuitBreaker) recordResult(err error, duration time.Duration) {
    cb.mutex.Lock()
    defer cb.mutex.Unlock()
    
    tokens := cb.calculateTokens(err, duration)
    cb.tokens += tokens
    
    if cb.tokens >= cb.budget {
        cb.state = StateOpen
        cb.expiry = time.Now().Add(cb.timeout)
    }
}

func (cb *ErrorBudgetCircuitBreaker) calculateTokens(err error, duration time.Duration) int {
    if err == nil {
        return 0
    }
    
    tokens := 1 // Base error cost
    
    // Add duration penalty for slow calls
    if duration > 5*time.Second {
        tokens += int(duration.Seconds() / 5)
    }
    
    // Add penalty based on error type
    switch {
    case isTimeoutError(err):
        tokens += 10 // Timeout errors are expensive
    case isServerError(err):
        tokens += 5  // 5xx errors indicate service issues
    }
    
    return tokens
}
```

#### Distributed Circuit Breaker

```go
type DistributedCircuitBreaker struct {
    local  *CircuitBreaker
    redis  redis.Client
    pubsub redis.PubSub
    
    serviceName string
    nodeID      string
}

func NewDistributedCircuitBreaker(serviceName, nodeID string, redisClient redis.Client) *DistributedCircuitBreaker {
    dcb := &DistributedCircuitBreaker{
        serviceName: serviceName,
        nodeID:      nodeID,
        redis:       redisClient,
    }
    
    // Subscribe to circuit breaker events
    dcb.pubsub = redisClient.Subscribe(fmt.Sprintf("cb:%s", serviceName))
    go dcb.listenForStateChanges()
    
    return dcb
}

func (dcb *DistributedCircuitBreaker) Execute(req func() (interface{}, error)) (interface{}, error) {
    // Check distributed state first
    if dcb.isOpenDistributed() {
        return nil, ErrCircuitOpen
    }
    
    return dcb.local.Execute(func() (interface{}, error) {
        result, err := req()
        
        // If local circuit trips, notify other nodes
        if dcb.local.state == StateOpen {
            dcb.notifyStateChange(StateOpen)
        }
        
        return result, err
    })
}

func (dcb *DistributedCircuitBreaker) isOpenDistributed() bool {
    key := fmt.Sprintf("cb:%s:state", dcb.serviceName)
    ttl := dcb.redis.TTL(context.Background(), key).Val()
    return ttl > 0
}

func (dcb *DistributedCircuitBreaker) notifyStateChange(state State) {
    if state == StateOpen {
        // Set distributed state
        key := fmt.Sprintf("cb:%s:state", dcb.serviceName)
        dcb.redis.SetEX(context.Background(), key, "open", 30*time.Second)
        
        // Notify other nodes
        message := fmt.Sprintf("%s:%s:open", dcb.nodeID, time.Now().Format(time.RFC3339))
        dcb.redis.Publish(context.Background(), fmt.Sprintf("cb:%s", dcb.serviceName), message)
    }
}

func (dcb *DistributedCircuitBreaker) listenForStateChanges() {
    for msg := range dcb.pubsub.Channel() {
        parts := strings.Split(msg.Payload, ":")
        if len(parts) >= 3 && parts[2] == "open" && parts[0] != dcb.nodeID {
            // Another node tripped the circuit, sync local state
            dcb.local.setState(StateOpen, time.Now())
        }
    }
}
```

### Configuration Guidelines

#### Threshold Settings

```go
type Settings struct {
    Name        string
    MaxRequests uint32        // Max requests in half-open state
    Interval    time.Duration // Reset interval for closed state
    Timeout     time.Duration // Open state timeout
    ReadyToTrip func(counts Counts) bool
}

// Conservative settings for critical services
func ConservativeSettings(name string) Settings {
    return Settings{
        Name:        name,
        MaxRequests: 1, // Only one test request in half-open
        Interval:    60 * time.Second,
        Timeout:     30 * time.Second,
        ReadyToTrip: func(counts Counts) bool {
            return counts.ConsecutiveFailures >= 5 || 
                   (counts.Requests >= 10 && counts.TotalFailures*100/counts.Requests >= 60)
        },
    }
}

// Aggressive settings for non-critical services
func AggressiveSettings(name string) Settings {
    return Settings{
        Name:        name,
        MaxRequests: 3,
        Interval:    30 * time.Second,
        Timeout:     10 * time.Second,
        ReadyToTrip: func(counts Counts) bool {
            return counts.ConsecutiveFailures >= 3 || 
                   (counts.Requests >= 5 && counts.TotalFailures*100/counts.Requests >= 80)
        },
    }
}
```

We decided to fail fast using a circuit breaker.


### Metrics and Monitoring

Track circuit breaker effectiveness with these key metrics:

```go
type CircuitBreakerMetrics struct {
    name string
    prometheus.CounterVec
    prometheus.GaugeVec
    prometheus.HistogramVec
}

func NewCircuitBreakerMetrics(name string) *CircuitBreakerMetrics {
    return &CircuitBreakerMetrics{
        name: name,
        CounterVec: prometheus.NewCounterVec(prometheus.CounterOpts{
            Name: "circuit_breaker_requests_total",
            Help: "Total circuit breaker requests",
        }, []string{"name", "state", "result"}),
        
        GaugeVec: prometheus.NewGaugeVec(prometheus.GaugeOpts{
            Name: "circuit_breaker_state",
            Help: "Current circuit breaker state (0=closed, 1=half-open, 2=open)",
        }, []string{"name"}),
        
        HistogramVec: prometheus.NewHistogramVec(prometheus.HistogramOpts{
            Name: "circuit_breaker_request_duration_seconds",
            Help: "Circuit breaker request duration",
        }, []string{"name", "state"}),
    }
}

func (m *CircuitBreakerMetrics) RecordRequest(state State, duration time.Duration, success bool) {
    stateStr := stateToString(state)
    result := "success"
    if !success {
        result = "failure"
    }
    
    m.CounterVec.WithLabelValues(m.name, stateStr, result).Inc()
    m.HistogramVec.WithLabelValues(m.name, stateStr).Observe(duration.Seconds())
}

func (m *CircuitBreakerMetrics) SetState(state State) {
    m.GaugeVec.WithLabelValues(m.name).Set(float64(state))
}
```

#### Key Metrics to Track

1. **State transitions**: How often circuit opens/closes
2. **Failure rate**: Percentage of failed requests
3. **Recovery time**: Time spent in open state
4. **Request volume**: Total requests processed
5. **Error budget consumption**: Rate of budget depletion

#### Alerting Rules

```yaml
# Prometheus alerting rules
groups:
- name: circuit_breaker
  rules:
  - alert: CircuitBreakerOpen
    expr: circuit_breaker_state == 2
    for: 1m
    labels:
      severity: warning
    annotations:
      summary: "Circuit breaker {{ $labels.name }} is open"
      
  - alert: CircuitBreakerFlapping
    expr: increase(circuit_breaker_state_changes_total[5m]) > 5
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "Circuit breaker {{ $labels.name }} is flapping"
```

### Scalability Considerations

#### Dynamic Thresholds

```go
type AdaptiveCircuitBreaker struct {
    base            *CircuitBreaker
    baselineLatency time.Duration
    baselineError   float64
    
    // Adaptive thresholds
    currentLatency time.Duration
    currentError   float64
    adaptationRate float64
}

func (acb *AdaptiveCircuitBreaker) updateThresholds() {
    // Adjust thresholds based on recent performance
    if acb.currentLatency > 2*acb.baselineLatency {
        // Increase sensitivity to slow responses
        acb.base.timeout = acb.base.timeout / 2
    }
    
    if acb.currentError > 1.5*acb.baselineError {
        // Lower failure threshold
        acb.base.readyToTrip = func(counts Counts) bool {
            return counts.ConsecutiveFailures >= 3
        }
    }
}
```

#### Granularity Levels

Choose appropriate granularity based on service characteristics:

```go
// Service-level circuit breaker
type ServiceCircuitBreaker struct {
    breakers map[string]*CircuitBreaker // keyed by service name
}

// Endpoint-level circuit breaker  
type EndpointCircuitBreaker struct {
    breakers map[string]*CircuitBreaker // keyed by service:endpoint
}

// User-level circuit breaker (for rate limiting specific users)
type UserCircuitBreaker struct {
    breakers map[string]*CircuitBreaker // keyed by user_id:service
}

func (scb *ServiceCircuitBreaker) GetBreaker(serviceName string) *CircuitBreaker {
    if breaker, exists := scb.breakers[serviceName]; exists {
        return breaker
    }
    
    // Create new breaker with service-specific settings
    settings := getServiceSettings(serviceName)
    breaker := NewCircuitBreaker(settings)
    scb.breakers[serviceName] = breaker
    
    return breaker
}
```

### Integration Patterns

#### HTTP Client Integration

```go
type CircuitBreakerHTTPClient struct {
    client  *http.Client
    breaker *CircuitBreaker
}

func NewCircuitBreakerHTTPClient(client *http.Client, breaker *CircuitBreaker) *CircuitBreakerHTTPClient {
    return &CircuitBreakerHTTPClient{
        client:  client,
        breaker: breaker,
    }
}

func (c *CircuitBreakerHTTPClient) Do(req *http.Request) (*http.Response, error) {
    result, err := c.breaker.Execute(func() (interface{}, error) {
        return c.client.Do(req)
    })
    
    if err != nil {
        return nil, err
    }
    
    resp := result.(*http.Response)
    
    // Consider 5xx responses as failures
    if resp.StatusCode >= 500 {
        return resp, errors.New("server error")
    }
    
    return resp, nil
}
```

#### Database Connection Integration

```go
type CircuitBreakerDB struct {
    db      *sql.DB
    breaker *CircuitBreaker
}

func (cbd *CircuitBreakerDB) Query(query string, args ...interface{}) (*sql.Rows, error) {
    result, err := cbd.breaker.Execute(func() (interface{}, error) {
        return cbd.db.Query(query, args...)
    })
    
    if err != nil {
        return nil, err
    }
    
    return result.(*sql.Rows), nil
}

func (cbd *CircuitBreakerDB) Ping() error {
    _, err := cbd.breaker.Execute(func() (interface{}, error) {
        return nil, cbd.db.Ping()
    })
    return err
}
```

### Fallback Strategies

When circuit breaker is open, implement graceful degradation:

```go
type ServiceWithFallback struct {
    primary   ServiceClient
    secondary ServiceClient
    breaker   *CircuitBreaker
    cache     Cache
}

func (s *ServiceWithFallback) GetData(id string) (*Data, error) {
    // Try primary service
    result, err := s.breaker.Execute(func() (interface{}, error) {
        return s.primary.GetData(id)
    })
    
    if err == nil {
        data := result.(*Data)
        s.cache.Set(id, data) // Cache successful response
        return data, nil
    }
    
    // Circuit breaker strategies
    if err == ErrCircuitOpen {
        // Strategy 1: Try cache
        if cachedData, found := s.cache.Get(id); found {
            return cachedData.(*Data), nil
        }
        
        // Strategy 2: Try secondary service
        if s.secondary != nil {
            return s.secondary.GetData(id)
        }
        
        // Strategy 3: Return default/degraded response
        return s.getDefaultData(id), nil
    }
    
    return nil, err
}
```

### Testing Circuit Breakers

```go
func TestCircuitBreakerStates(t *testing.T) {
    breaker := NewCircuitBreaker(Settings{
        Name:        "test",
        MaxRequests: 1,
        Interval:    time.Minute,
        Timeout:     10 * time.Second,
        ReadyToTrip: func(counts Counts) bool {
            return counts.ConsecutiveFailures >= 3
        },
    })
    
    // Test closed state
    for i := 0; i < 2; i++ {
        _, err := breaker.Execute(func() (interface{}, error) {
            return "success", nil
        })
        assert.NoError(t, err)
    }
    
    // Test opening circuit
    for i := 0; i < 3; i++ {
        _, err := breaker.Execute(func() (interface{}, error) {
            return nil, errors.New("failure")
        })
        if i < 2 {
            assert.Error(t, err)
            assert.NotEqual(t, ErrCircuitOpen, err)
        }
    }
    
    // Test open state
    _, err := breaker.Execute(func() (interface{}, error) {
        return "should not execute", nil
    })
    assert.Equal(t, ErrCircuitOpen, err)
    
    // Test half-open state after timeout
    time.Sleep(11 * time.Second)
    _, err = breaker.Execute(func() (interface{}, error) {
        return "recovery", nil
    })
    assert.NoError(t, err)
}
```

## Consequences

### Positive
- **Fail-fast behavior**: Prevents resource waste on failing services
- **System stability**: Protects against cascading failures
- **Better user experience**: Quick error responses instead of timeouts
- **Service recovery**: Allows failing services time to recover
- **Monitoring insights**: Provides visibility into service health
- **Configurable thresholds**: Adaptable to different service characteristics

### Negative
- **Additional complexity**: Requires careful configuration and monitoring
- **False positives**: May block requests during temporary issues
- **State management**: Distributed systems require coordination
- **Configuration overhead**: Multiple services need individual tuning

### Mitigation Strategies
- **Gradual rollout**: Start with non-critical services
- **Conservative thresholds**: Begin with lenient settings and tighten gradually
- **Comprehensive monitoring**: Track all metrics and state changes
- **Fallback mechanisms**: Always provide graceful degradation options
- **Regular review**: Adjust thresholds based on operational experience

### Performance Impact
- **Minimal overhead**: State checks are O(1) operations
- **Memory usage**: Small footprint for counters and timers
- **Lock contention**: Use atomic operations where possible
- **Network calls**: Distributed breakers require Redis/coordination service

## Best Practices

1. **Start conservative**: Begin with higher thresholds and lower sensitivity
2. **Monitor extensively**: Track all state transitions and metrics
3. **Test failure scenarios**: Validate circuit breaker behavior under load
4. **Document thresholds**: Record rationale for configuration choices
5. **Regular reviews**: Adjust settings based on operational data
6. **Fallback planning**: Always have graceful degradation strategies
7. **Error classification**: Weight different error types appropriately
8. **Distributed coordination**: Use lightweight mechanisms for multi-instance coordination

## References

- [Circuit Breaker Pattern (Martin Fowler)](https://martinfowler.com/bliki/CircuitBreaker.html)
- [Release It! Design Patterns](https://pragprog.com/titles/mnee2/release-it-second-edition/)
- [Hystrix: Latency and Fault Tolerance](https://github.com/Netflix/Hystrix/wiki)
- [Go Circuit Breaker Libraries](https://github.com/sony/gobreaker)
- [SRE Error Budgets](https://sre.google/sre-book/embracing-risk/)
- [Circuit Breaker Research](https://brooker.co.za/blog/2022/02/16/circuit-breakers.html)
- [Distributed Circuit Breakers](https://dl.acm.org/doi/pdf/10.1145/3542929.3563466)

