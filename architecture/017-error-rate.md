# Error Rate Calculation

## Status

`draft`

## Context

A more scalable approach to calculate the error rate instead of using fixed windows. Traditional sliding window approaches can be memory-intensive and complex to implement. We need a lightweight method that provides good approximations without the overhead of maintaining large data structures.

## Decisions

### Exponential Decay Approach

Instead of maintaining a fixed window of requests, use exponential decay to weight recent events more heavily:

```go
package main

import (
    "fmt"
    "math"
    "sync"
    "time"
)

type ErrorRateCalculator struct {
    success       float64
    failure       float64
    lastSuccess   time.Time
    lastFailure   time.Time
    decayPeriod   time.Duration
    mutex         sync.RWMutex
}

func NewErrorRateCalculator(decayPeriod time.Duration) *ErrorRateCalculator {
    return &ErrorRateCalculator{
        decayPeriod: decayPeriod,
        lastSuccess: time.Now(),
        lastFailure: time.Now(),
    }
}

func (erc *ErrorRateCalculator) RecordSuccess() {
    erc.mutex.Lock()
    defer erc.mutex.Unlock()
    
    erc.success = erc.decayCount(erc.lastSuccess, erc.success)
    erc.success++
    erc.lastSuccess = time.Now()
}

func (erc *ErrorRateCalculator) RecordFailure() {
    erc.mutex.Lock()
    defer erc.mutex.Unlock()
    
    erc.failure = erc.decayCount(erc.lastFailure, erc.failure)
    erc.failure++
    erc.lastFailure = time.Now()
}

func (erc *ErrorRateCalculator) GetErrorRate() float64 {
    erc.mutex.RLock()
    defer erc.mutex.RUnlock()
    
    // Apply decay to both counters
    currentSuccess := erc.decayCount(erc.lastSuccess, erc.success)
    currentFailure := erc.decayCount(erc.lastFailure, erc.failure)
    
    total := currentSuccess + currentFailure
    if total == 0 {
        return 0
    }
    
    return currentFailure / total
}

func (erc *ErrorRateCalculator) decayCount(lastUpdate time.Time, count float64) float64 {
    if count == 0 {
        return 0
    }
    
    elapsed := time.Since(lastUpdate)
    decayRate := float64(elapsed) / float64(erc.decayPeriod)
    decayRate = math.Min(1.0, decayRate) // Cap at 1.0
    
    // Exponential decay: new_count = old_count * e^(-decay_rate)
    return count * math.Exp(-decayRate)
}

func (erc *ErrorRateCalculator) GetCounts() (success, failure float64) {
    erc.mutex.RLock()
    defer erc.mutex.RUnlock()
    
    return erc.decayCount(erc.lastSuccess, erc.success),
           erc.decayCount(erc.lastFailure, erc.failure)
}
```

### Advanced Error Rate with Multiple Metrics

```go
type MetricType string

const (
    MetricHTTPErrors    MetricType = "http_errors"
    MetricTimeouts      MetricType = "timeouts"  
    MetricDatabaseError MetricType = "db_errors"
)

type MultiMetricErrorRate struct {
    metrics     map[MetricType]*ErrorRateCalculator
    globalRate  *ErrorRateCalculator
    mutex       sync.RWMutex
}

func NewMultiMetricErrorRate(decayPeriod time.Duration) *MultiMetricErrorRate {
    return &MultiMetricErrorRate{
        metrics:    make(map[MetricType]*ErrorRateCalculator),
        globalRate: NewErrorRateCalculator(decayPeriod),
    }
}

func (mmer *MultiMetricErrorRate) RecordSuccess(metricType MetricType) {
    mmer.mutex.Lock()
    if _, exists := mmer.metrics[metricType]; !exists {
        mmer.metrics[metricType] = NewErrorRateCalculator(10 * time.Second)
    }
    mmer.metrics[metricType].RecordSuccess()
    mmer.mutex.Unlock()
    
    mmer.globalRate.RecordSuccess()
}

func (mmer *MultiMetricErrorRate) RecordFailure(metricType MetricType) {
    mmer.mutex.Lock()
    if _, exists := mmer.metrics[metricType]; !exists {
        mmer.metrics[metricType] = NewErrorRateCalculator(10 * time.Second)
    }
    mmer.metrics[metricType].RecordFailure()
    mmer.mutex.Unlock()
    
    mmer.globalRate.RecordFailure()
}

func (mmer *MultiMetricErrorRate) GetErrorRate(metricType MetricType) float64 {
    mmer.mutex.RLock()
    defer mmer.mutex.RUnlock()
    
    if calc, exists := mmer.metrics[metricType]; exists {
        return calc.GetErrorRate()
    }
    return 0
}

func (mmer *MultiMetricErrorRate) GetGlobalErrorRate() float64 {
    return mmer.globalRate.GetErrorRate()
}

func (mmer *MultiMetricErrorRate) GetAllErrorRates() map[MetricType]float64 {
    mmer.mutex.RLock()
    defer mmer.mutex.RUnlock()
    
    rates := make(map[MetricType]float64)
    for metricType, calc := range mmer.metrics {
        rates[metricType] = calc.GetErrorRate()
    }
    
    return rates
}
```

### Sliding Window Implementation

For more precise calculations when memory isn't a concern:

```go
type SlidingWindowErrorRate struct {
    events     []Event
    windowSize time.Duration
    maxEvents  int
    mutex      sync.RWMutex
}

type Event struct {
    Timestamp time.Time
    IsError   bool
}

func NewSlidingWindowErrorRate(windowSize time.Duration, maxEvents int) *SlidingWindowErrorRate {
    return &SlidingWindowErrorRate{
        events:     make([]Event, 0, maxEvents),
        windowSize: windowSize,
        maxEvents:  maxEvents,
    }
}

func (swer *SlidingWindowErrorRate) RecordEvent(isError bool) {
    swer.mutex.Lock()
    defer swer.mutex.Unlock()
    
    event := Event{
        Timestamp: time.Now(),
        IsError:   isError,
    }
    
    swer.events = append(swer.events, event)
    
    // Remove old events
    swer.removeOldEvents()
    
    // Limit size to prevent memory issues
    if len(swer.events) > swer.maxEvents {
        swer.events = swer.events[len(swer.events)-swer.maxEvents:]
    }
}

func (swer *SlidingWindowErrorRate) GetErrorRate() float64 {
    swer.mutex.RLock()
    defer swer.mutex.RUnlock()
    
    swer.removeOldEvents()
    
    if len(swer.events) == 0 {
        return 0
    }
    
    var errorCount int
    for _, event := range swer.events {
        if event.IsError {
            errorCount++
        }
    }
    
    return float64(errorCount) / float64(len(swer.events))
}

func (swer *SlidingWindowErrorRate) removeOldEvents() {
    cutoff := time.Now().Add(-swer.windowSize)
    
    // Find first event within window
    start := 0
    for i, event := range swer.events {
        if event.Timestamp.After(cutoff) {
            start = i
            break
        }
    }
    
    if start > 0 {
        swer.events = swer.events[start:]
    }
}
```

### Circuit Breaker Integration

Use error rates to trigger circuit breakers:

```go
type CircuitBreakerState int

const (
    StateClosed CircuitBreakerState = iota
    StateOpen
    StateHalfOpen
)

type CircuitBreaker struct {
    errorRate        *ErrorRateCalculator
    state            CircuitBreakerState
    failureThreshold float64
    recoveryTimeout  time.Duration
    lastFailureTime  time.Time
    mutex           sync.RWMutex
}

func NewCircuitBreaker(failureThreshold float64, recoveryTimeout time.Duration) *CircuitBreaker {
    return &CircuitBreaker{
        errorRate:        NewErrorRateCalculator(30 * time.Second),
        state:            StateClosed,
        failureThreshold: failureThreshold,
        recoveryTimeout:  recoveryTimeout,
    }
}

func (cb *CircuitBreaker) Call(fn func() error) error {
    cb.mutex.RLock()
    state := cb.state
    cb.mutex.RUnlock()
    
    switch state {
    case StateOpen:
        if cb.shouldAttemptRecovery() {
            cb.mutex.Lock()
            cb.state = StateHalfOpen
            cb.mutex.Unlock()
        } else {
            return fmt.Errorf("circuit breaker is open")
        }
    case StateHalfOpen:
        // Allow limited calls through
    case StateClosed:
        // Normal operation
    }
    
    err := fn()
    
    if err != nil {
        cb.errorRate.RecordFailure()
        cb.mutex.Lock()
        cb.lastFailureTime = time.Now()
        cb.mutex.Unlock()
        
        // Check if we should open the circuit
        if cb.errorRate.GetErrorRate() >= cb.failureThreshold {
            cb.mutex.Lock()
            cb.state = StateOpen
            cb.mutex.Unlock()
        }
    } else {
        cb.errorRate.RecordSuccess()
        
        // If in half-open state and success, close the circuit
        if state == StateHalfOpen {
            cb.mutex.Lock()
            cb.state = StateClosed
            cb.mutex.Unlock()
        }
    }
    
    return err
}

func (cb *CircuitBreaker) shouldAttemptRecovery() bool {
    cb.mutex.RLock()
    defer cb.mutex.RUnlock()
    
    return time.Since(cb.lastFailureTime) >= cb.recoveryTimeout
}

func (cb *CircuitBreaker) GetState() CircuitBreakerState {
    cb.mutex.RLock()
    defer cb.mutex.RUnlock()
    return cb.state
}
```

### Rate Limiting Based on Error Rate

```go
type AdaptiveRateLimiter struct {
    errorRate     *ErrorRateCalculator
    baseLimiter   *rate.Limiter
    currentRate   rate.Limit
    errorThreshold float64
    recoveryFactor float64
    mutex         sync.RWMutex
}

func NewAdaptiveRateLimiter(baseRate rate.Limit, burst int, errorThreshold float64) *AdaptiveRateLimiter {
    return &AdaptiveRateLimiter{
        errorRate:      NewErrorRateCalculator(30 * time.Second),
        baseLimiter:    rate.NewLimiter(baseRate, burst),
        currentRate:    baseRate,
        errorThreshold: errorThreshold,
        recoveryFactor: 0.1,
    }
}

func (arl *AdaptiveRateLimiter) Allow() bool {
    arl.adjustRate()
    return arl.baseLimiter.Allow()
}

func (arl *AdaptiveRateLimiter) adjustRate() {
    currentErrorRate := arl.errorRate.GetErrorRate()
    
    arl.mutex.Lock()
    defer arl.mutex.Unlock()
    
    if currentErrorRate > arl.errorThreshold {
        // Reduce rate when error rate is high
        newRate := arl.currentRate * rate.Limit(1.0-currentErrorRate)
        if newRate < arl.currentRate*0.1 { // Don't reduce below 10% of current
            newRate = arl.currentRate * 0.1
        }
        arl.currentRate = newRate
        arl.baseLimiter.SetLimit(newRate)
    } else {
        // Gradually recover to base rate
        baseRate := rate.Limit(100) // Your base rate
        if arl.currentRate < baseRate {
            newRate := arl.currentRate * rate.Limit(1.0+arl.recoveryFactor)
            if newRate > baseRate {
                newRate = baseRate
            }
            arl.currentRate = newRate
            arl.baseLimiter.SetLimit(newRate)
        }
    }
}

func (arl *AdaptiveRateLimiter) RecordSuccess() {
    arl.errorRate.RecordSuccess()
}

func (arl *AdaptiveRateLimiter) RecordError() {
    arl.errorRate.RecordFailure()
}
```

### Monitoring and Alerting

```go
type ErrorRateMonitor struct {
    errorRate     *ErrorRateCalculator
    alertThreshold float64
    alertCooldown  time.Duration
    lastAlert     time.Time
    mutex         sync.RWMutex
}

func NewErrorRateMonitor(alertThreshold float64, cooldown time.Duration) *ErrorRateMonitor {
    return &ErrorRateMonitor{
        errorRate:      NewErrorRateCalculator(60 * time.Second),
        alertThreshold: alertThreshold,
        alertCooldown:  cooldown,
    }
}

func (erm *ErrorRateMonitor) RecordEvent(isError bool) {
    if isError {
        erm.errorRate.RecordFailure()
    } else {
        erm.errorRate.RecordSuccess()
    }
    
    // Check if we should send an alert
    if erm.shouldAlert() {
        erm.sendAlert()
    }
}

func (erm *ErrorRateMonitor) shouldAlert() bool {
    erm.mutex.RLock()
    defer erm.mutex.RUnlock()
    
    if time.Since(erm.lastAlert) < erm.alertCooldown {
        return false
    }
    
    return erm.errorRate.GetErrorRate() > erm.alertThreshold
}

func (erm *ErrorRateMonitor) sendAlert() {
    erm.mutex.Lock()
    erm.lastAlert = time.Now()
    erm.mutex.Unlock()
    
    rate := erm.errorRate.GetErrorRate()
    success, failure := erm.errorRate.GetCounts()
    
    alert := fmt.Sprintf("Error rate alert: %.2f%% (%.1f errors, %.1f successes)", 
        rate*100, failure, success)
    
    // Send to your alerting system
    log.Printf("ALERT: %s", alert)
    // sendToSlack(alert)
    // sendToPagerDuty(alert)
}
```

## Consequences

### Benefits
- **Memory efficient**: Exponential decay approach uses constant memory
- **Real-time**: Provides immediate feedback on error rates
- **Flexible**: Can be tuned for different time sensitivities
- **Scalable**: Works well with high-frequency events
- **Integration ready**: Easily integrates with circuit breakers and rate limiters

### Challenges
- **Approximation**: Exponential decay is an approximation, not exact
- **Tuning**: Requires careful tuning of decay parameters
- **Clock dependency**: Sensitive to system clock changes
- **Burst sensitivity**: May not capture short bursts of errors well

### Best Practices
- Use distributed cache (Redis) sparingly - consider in-memory for non-revenue critical metrics
- Most rate limiting is to prevent resource abuse, not for perfect accuracy
- When limits are reached, increment counters to track how often limits are hit
- Use SQLite or in-memory storage for lightweight metrics
- Implement exponential backoff for failed requests
- Monitor error rate distributions across different time windows
- Set appropriate decay periods based on your traffic patterns
- Combine with other metrics for comprehensive monitoring

### Use Cases
- **Circuit breakers**: Automatically open circuit when error rate exceeds threshold
- **Adaptive rate limiting**: Reduce traffic when errors increase
- **Health monitoring**: Track service health over time
- **Alerting**: Trigger alerts when error rates spike
- **Load balancing**: Route traffic away from failing instances
