# Request Rate Monitoring and Management

## Status

`accepted`

## Context

Request rate is a fundamental metric in the RED (Rate, Errors, Duration) observability framework. It measures the frequency of requests within a system and serves as a critical indicator of system health, capacity utilization, and potential anomalies.

Traditional request counting approaches have limitations when dealing with weighted request importance, error severity, and complex system behaviors. A more sophisticated approach using budget-based measurements provides better insights into system health and enables more nuanced policy decisions.

## Decision

We will implement comprehensive request rate monitoring using both traditional counting and budget-based approaches, enabling sophisticated rate limiting, circuit breaking, and anomaly detection mechanisms.

## Implementation

### 1. Basic Request Rate Monitoring

```go
package requestrate

import (
    "context"
    "sync"
    "sync/atomic"
    "time"

    "github.com/prometheus/client_golang/prometheus"
)

// RequestRateMonitor tracks request rates and patterns
type RequestRateMonitor struct {
    // Basic counters
    totalRequests   int64
    successRequests int64
    errorRequests   int64
    
    // Time-based tracking
    windowSize      time.Duration
    windows         []RequestWindow
    currentWindow   int
    mu              sync.RWMutex
    
    // Metrics
    requestsTotal   prometheus.Counter
    requestsPerSec  prometheus.Gauge
    errorRate       prometheus.Gauge
}

// RequestWindow represents a time window of requests
type RequestWindow struct {
    StartTime time.Time
    Requests  int64
    Errors    int64
    Budget    int64 // Budget consumed in this window
}

// NewRequestRateMonitor creates a new request rate monitor
func NewRequestRateMonitor(windowSize time.Duration, windowCount int) *RequestRateMonitor {
    monitor := &RequestRateMonitor{
        windowSize: windowSize,
        windows:    make([]RequestWindow, windowCount),
        requestsTotal: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        }),
        requestsPerSec: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "http_requests_per_second",
            Help: "HTTP requests per second",
        }),
        errorRate: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "http_error_rate",
            Help: "HTTP error rate percentage",
        }),
    }
    
    // Initialize windows
    now := time.Now()
    for i := range monitor.windows {
        monitor.windows[i] = RequestWindow{
            StartTime: now.Add(-time.Duration(len(monitor.windows)-i) * windowSize),
        }
    }
    
    // Start background updater
    go monitor.updateMetrics()
    
    return monitor
}

// RecordRequest records a request with optional error
func (m *RequestRateMonitor) RecordRequest(isError bool, budgetCost int64) {
    atomic.AddInt64(&m.totalRequests, 1)
    m.requestsTotal.Inc()
    
    if isError {
        atomic.AddInt64(&m.errorRequests, 1)
    } else {
        atomic.AddInt64(&m.successRequests, 1)
    }
    
    // Update current window
    m.mu.Lock()
    currentWindow := &m.windows[m.currentWindow]
    currentWindow.Requests++
    if isError {
        currentWindow.Errors++
    }
    currentWindow.Budget += budgetCost
    m.mu.Unlock()
}

// GetCurrentRate returns the current request rate
func (m *RequestRateMonitor) GetCurrentRate() float64 {
    m.mu.RLock()
    defer m.mu.RUnlock()
    
    totalRequests := int64(0)
    validWindows := 0
    
    for _, window := range m.windows {
        if time.Since(window.StartTime) < m.windowSize*time.Duration(len(m.windows)) {
            totalRequests += window.Requests
            validWindows++
        }
    }
    
    if validWindows == 0 {
        return 0
    }
    
    timeSpan := m.windowSize * time.Duration(validWindows)
    return float64(totalRequests) / timeSpan.Seconds()
}

// GetErrorRate returns the current error rate
func (m *RequestRateMonitor) GetErrorRate() float64 {
    total := atomic.LoadInt64(&m.totalRequests)
    errors := atomic.LoadInt64(&m.errorRequests)
    
    if total == 0 {
        return 0
    }
    
    return float64(errors) / float64(total) * 100
}

// updateMetrics periodically updates metrics and rotates windows
func (m *RequestRateMonitor) updateMetrics() {
    ticker := time.NewTicker(m.windowSize)
    defer ticker.Stop()
    
    for range ticker.C {
        m.mu.Lock()
        
        // Rotate to next window
        m.currentWindow = (m.currentWindow + 1) % len(m.windows)
        m.windows[m.currentWindow] = RequestWindow{
            StartTime: time.Now(),
        }
        
        m.mu.Unlock()
        
        // Update Prometheus metrics
        m.requestsPerSec.Set(m.GetCurrentRate())
        m.errorRate.Set(m.GetErrorRate())
    }
}
```

### 2. Budget-Based Request Tracking

```go
// BudgetBasedMonitor implements sophisticated request tracking using budget weights
type BudgetBasedMonitor struct {
    totalBudget     int64
    consumedBudget  int64
    budgetLimit     int64
    resetInterval   time.Duration
    lastReset       time.Time
    
    // Error severity mapping
    errorBudgets    map[ErrorType]int64
    
    // Time windows for budget tracking
    windows         []BudgetWindow
    currentWindow   int
    mu              sync.RWMutex
}

// ErrorType represents different types of errors with different severities
type ErrorType int

const (
    NoError ErrorType = iota
    TimeoutError
    RateLimitError
    InternalServerError
    DependencyError
    ValidationError
)

// BudgetWindow tracks budget consumption over time
type BudgetWindow struct {
    StartTime       time.Time
    ConsumedBudget  int64
    RequestCount    int64
    ErrorCount      int64
}

// NewBudgetBasedMonitor creates a budget-based monitor
func NewBudgetBasedMonitor(budgetLimit int64, resetInterval time.Duration) *BudgetBasedMonitor {
    return &BudgetBasedMonitor{
        budgetLimit:   budgetLimit,
        resetInterval: resetInterval,
        lastReset:     time.Now(),
        errorBudgets: map[ErrorType]int64{
            NoError:             1,  // Successful request costs 1 budget unit
            TimeoutError:        5,  // Timeout costs 5 units
            RateLimitError:      3,  // Rate limit costs 3 units
            InternalServerError: 10, // Internal error costs 10 units
            DependencyError:     7,  // Dependency error costs 7 units
            ValidationError:     2,  // Validation error costs 2 units
        },
        windows: make([]BudgetWindow, 60), // 1 minute of 1-second windows
    }
}

// ConsumeRequest consumes budget based on request outcome
func (m *BudgetBasedMonitor) ConsumeRequest(errorType ErrorType) bool {
    budgetCost := m.errorBudgets[errorType]
    
    m.mu.Lock()
    defer m.mu.Unlock()
    
    // Check if budget reset is needed
    if time.Since(m.lastReset) >= m.resetInterval {
        m.consumedBudget = 0
        m.lastReset = time.Now()
    }
    
    // Check if we can consume the budget
    if m.consumedBudget+budgetCost > m.budgetLimit {
        return false // Budget exhausted
    }
    
    // Consume budget
    m.consumedBudget += budgetCost
    atomic.AddInt64(&m.totalBudget, budgetCost)
    
    // Update current window
    currentWindow := &m.windows[m.currentWindow]
    currentWindow.ConsumedBudget += budgetCost
    currentWindow.RequestCount++
    if errorType != NoError {
        currentWindow.ErrorCount++
    }
    
    return true
}

// GetBudgetUtilization returns current budget utilization percentage
func (m *BudgetBasedMonitor) GetBudgetUtilization() float64 {
    m.mu.RLock()
    defer m.mu.RUnlock()
    
    return float64(m.consumedBudget) / float64(m.budgetLimit) * 100
}

// GetWeightedErrorRate returns error rate weighted by budget consumption
func (m *BudgetBasedMonitor) GetWeightedErrorRate() float64 {
    m.mu.RLock()
    defer m.mu.RUnlock()
    
    totalBudget := int64(0)
    errorBudget := int64(0)
    
    for _, window := range m.windows {
        if time.Since(window.StartTime) < time.Minute {
            totalBudget += window.ConsumedBudget
            // Calculate error budget (total - successful requests)
            successBudget := (window.RequestCount - window.ErrorCount) * m.errorBudgets[NoError]
            errorBudget += window.ConsumedBudget - successBudget
        }
    }
    
    if totalBudget == 0 {
        return 0
    }
    
    return float64(errorBudget) / float64(totalBudget) * 100
}
```

### 3. Advanced Circuit Breaker with Budget-Based Logic

```go
// BudgetCircuitBreaker implements circuit breaker with budget-based decisions
type BudgetCircuitBreaker struct {
    budgetMonitor   *BudgetBasedMonitor
    state           CircuitState
    failureThreshold float64  // Budget utilization threshold
    errorThreshold   float64  // Weighted error rate threshold
    minRequests     int64    // Minimum requests before evaluation
    recoveryTimeout time.Duration
    lastFailureTime time.Time
    consecutiveSuccesses int64
    mu              sync.RWMutex
}

type CircuitState int

const (
    StateClosed CircuitState = iota
    StateOpen
    StateHalfOpen
)

// NewBudgetCircuitBreaker creates a budget-based circuit breaker
func NewBudgetCircuitBreaker(budgetLimit int64, failureThreshold, errorThreshold float64, minRequests int64, recoveryTimeout time.Duration) *BudgetCircuitBreaker {
    return &BudgetCircuitBreaker{
        budgetMonitor:    NewBudgetBasedMonitor(budgetLimit, time.Minute),
        state:           StateClosed,
        failureThreshold: failureThreshold,
        errorThreshold:   errorThreshold,
        minRequests:     minRequests,
        recoveryTimeout: recoveryTimeout,
    }
}

// Call executes a function with circuit breaker protection
func (cb *BudgetCircuitBreaker) Call(ctx context.Context, fn func() error) error {
    if !cb.AllowRequest() {
        return fmt.Errorf("circuit breaker is open")
    }
    
    err := fn()
    cb.RecordResult(err)
    
    return err
}

// AllowRequest determines if a request should be allowed
func (cb *BudgetCircuitBreaker) AllowRequest() bool {
    cb.mu.RLock()
    defer cb.mu.RUnlock()
    
    switch cb.state {
    case StateClosed:
        return true
    case StateOpen:
        return time.Since(cb.lastFailureTime) >= cb.recoveryTimeout
    case StateHalfOpen:
        return true // Allow limited requests in half-open state
    default:
        return false
    }
}

// RecordResult records the result of a request
func (cb *BudgetCircuitBreaker) RecordResult(err error) {
    errorType := classifyError(err)
    
    // Consume budget
    if !cb.budgetMonitor.ConsumeRequest(errorType) {
        cb.tripCircuit("budget exhausted")
        return
    }
    
    cb.mu.Lock()
    defer cb.mu.Unlock()
    
    if err == nil {
        cb.onSuccess()
    } else {
        cb.onFailure()
    }
    
    // Evaluate circuit state
    cb.evaluateState()
}

func (cb *BudgetCircuitBreaker) onSuccess() {
    cb.consecutiveSuccesses++
    
    if cb.state == StateHalfOpen && cb.consecutiveSuccesses >= 5 {
        cb.state = StateClosed
        cb.consecutiveSuccesses = 0
    }
}

func (cb *BudgetCircuitBreaker) onFailure() {
    cb.lastFailureTime = time.Now()
    cb.consecutiveSuccesses = 0
    
    if cb.state == StateHalfOpen {
        cb.state = StateOpen
    }
}

func (cb *BudgetCircuitBreaker) evaluateState() {
    if cb.state != StateClosed {
        return
    }
    
    // Check budget utilization
    budgetUtil := cb.budgetMonitor.GetBudgetUtilization()
    errorRate := cb.budgetMonitor.GetWeightedErrorRate()
    
    // Trip circuit if thresholds exceeded
    if budgetUtil >= cb.failureThreshold || errorRate >= cb.errorThreshold {
        cb.tripCircuit(fmt.Sprintf("budget: %.2f%%, error rate: %.2f%%", budgetUtil, errorRate))
    }
}

func (cb *BudgetCircuitBreaker) tripCircuit(reason string) {
    cb.mu.Lock()
    defer cb.mu.Unlock()
    
    cb.state = StateOpen
    cb.lastFailureTime = time.Now()
    cb.consecutiveSuccesses = 0
    
    // Log circuit trip
    fmt.Printf("Circuit breaker tripped: %s\n", reason)
}

func classifyError(err error) ErrorType {
    if err == nil {
        return NoError
    }
    
    // Classify errors based on type/message
    errMsg := err.Error()
    switch {
    case strings.Contains(errMsg, "timeout"):
        return TimeoutError
    case strings.Contains(errMsg, "rate limit"):
        return RateLimitError
    case strings.Contains(errMsg, "internal server error"):
        return InternalServerError
    case strings.Contains(errMsg, "dependency"):
        return DependencyError
    case strings.Contains(errMsg, "validation"):
        return ValidationError
    default:
        return InternalServerError
    }
}
```

### 4. Adaptive Rate Limiting with Budget

```go
// AdaptiveRateLimiter implements rate limiting with budget-based adjustments
type AdaptiveRateLimiter struct {
    budgetMonitor   *BudgetBasedMonitor
    baseRate        int64   // Base requests per second
    currentRate     int64   // Current adapted rate
    minRate         int64   // Minimum allowed rate
    maxRate         int64   // Maximum allowed rate
    adaptationWindow time.Duration
    lastAdaptation  time.Time
    mu              sync.RWMutex
}

// NewAdaptiveRateLimiter creates an adaptive rate limiter
func NewAdaptiveRateLimiter(baseRate, minRate, maxRate int64, budgetLimit int64) *AdaptiveRateLimiter {
    return &AdaptiveRateLimiter{
        budgetMonitor:   NewBudgetBasedMonitor(budgetLimit, time.Minute),
        baseRate:        baseRate,
        currentRate:     baseRate,
        minRate:         minRate,
        maxRate:         maxRate,
        adaptationWindow: 30 * time.Second,
        lastAdaptation:  time.Now(),
    }
}

// AllowRequest checks if a request should be allowed
func (rl *AdaptiveRateLimiter) AllowRequest(errorType ErrorType) bool {
    // Adapt rate if needed
    rl.adaptRate()
    
    // Check if request can consume budget
    if !rl.budgetMonitor.ConsumeRequest(errorType) {
        return false
    }
    
    // Additional rate limiting logic here...
    return true
}

// adaptRate adjusts the rate limit based on system health
func (rl *AdaptiveRateLimiter) adaptRate() {
    rl.mu.Lock()
    defer rl.mu.Unlock()
    
    if time.Since(rl.lastAdaptation) < rl.adaptationWindow {
        return
    }
    
    budgetUtil := rl.budgetMonitor.GetBudgetUtilization()
    errorRate := rl.budgetMonitor.GetWeightedErrorRate()
    
    // Calculate adjustment factor
    var adjustmentFactor float64 = 1.0
    
    if budgetUtil > 80 || errorRate > 10 {
        // System under stress, reduce rate
        adjustmentFactor = 0.8
    } else if budgetUtil < 50 && errorRate < 2 {
        // System healthy, increase rate
        adjustmentFactor = 1.2
    }
    
    // Apply adjustment
    newRate := int64(float64(rl.currentRate) * adjustmentFactor)
    
    // Enforce bounds
    if newRate < rl.minRate {
        newRate = rl.minRate
    } else if newRate > rl.maxRate {
        newRate = rl.maxRate
    }
    
    rl.currentRate = newRate
    rl.lastAdaptation = time.Now()
    
    fmt.Printf("Rate adapted: %d -> %d (budget: %.2f%%, error: %.2f%%)\n", 
        rl.currentRate, newRate, budgetUtil, errorRate)
}
```

### 5. HTTP Middleware Integration

```go
// RequestRateMiddleware integrates request rate monitoring with HTTP handlers
func RequestRateMiddleware(monitor *RequestRateMonitor, budgetMonitor *BudgetBasedMonitor) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            start := time.Now()
            
            // Wrap ResponseWriter to capture status code
            ww := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
            
            // Process request
            next.ServeHTTP(ww, r)
            
            // Calculate metrics
            duration := time.Since(start)
            isError := ww.statusCode >= 400
            errorType := classifyHTTPError(ww.statusCode)
            
            // Record in monitors
            budgetCost := budgetMonitor.errorBudgets[errorType]
            monitor.RecordRequest(isError, budgetCost)
            budgetMonitor.ConsumeRequest(errorType)
            
            // Add headers for debugging
            w.Header().Set("X-Request-Rate", fmt.Sprintf("%.2f", monitor.GetCurrentRate()))
            w.Header().Set("X-Error-Rate", fmt.Sprintf("%.2f", monitor.GetErrorRate()))
            w.Header().Set("X-Budget-Utilization", fmt.Sprintf("%.2f", budgetMonitor.GetBudgetUtilization()))
        })
    }
}

type responseWriter struct {
    http.ResponseWriter
    statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
    rw.statusCode = code
    rw.ResponseWriter.WriteHeader(code)
}

func classifyHTTPError(statusCode int) ErrorType {
    switch {
    case statusCode < 400:
        return NoError
    case statusCode == 408 || statusCode == 504:
        return TimeoutError
    case statusCode == 429:
        return RateLimitError
    case statusCode >= 500:
        return InternalServerError
    case statusCode == 400 || statusCode == 422:
        return ValidationError
    default:
        return InternalServerError
    }
}
```

## Monitoring and Alerting

```go
// RequestRateAlerting provides alerting based on request rate patterns
type RequestRateAlerting struct {
    monitor        *RequestRateMonitor
    budgetMonitor  *BudgetBasedMonitor
    alertThresholds AlertThresholds
    alertChannel   chan Alert
}

type AlertThresholds struct {
    HighRequestRate     float64 // Requests per second
    LowRequestRate      float64 // Requests per second
    HighErrorRate       float64 // Percentage
    HighBudgetUtil      float64 // Percentage
    SuddenRateChange    float64 // Percentage change
}

type Alert struct {
    Type        string    `json:"type"`
    Message     string    `json:"message"`
    Severity    string    `json:"severity"`
    Timestamp   time.Time `json:"timestamp"`
    Metrics     map[string]float64 `json:"metrics"`
}

// CheckAlerts evaluates current metrics against thresholds
func (a *RequestRateAlerting) CheckAlerts() {
    currentRate := a.monitor.GetCurrentRate()
    errorRate := a.monitor.GetErrorRate()
    budgetUtil := a.budgetMonitor.GetBudgetUtilization()
    
    // High request rate alert
    if currentRate > a.alertThresholds.HighRequestRate {
        a.sendAlert(Alert{
            Type:      "high_request_rate",
            Message:   fmt.Sprintf("Request rate is high: %.2f req/s", currentRate),
            Severity:  "warning",
            Timestamp: time.Now(),
            Metrics: map[string]float64{
                "current_rate": currentRate,
                "threshold":    a.alertThresholds.HighRequestRate,
            },
        })
    }
    
    // Low request rate alert (potential system issue)
    if currentRate < a.alertThresholds.LowRequestRate {
        a.sendAlert(Alert{
            Type:      "low_request_rate",
            Message:   fmt.Sprintf("Request rate is unusually low: %.2f req/s", currentRate),
            Severity:  "warning",
            Timestamp: time.Now(),
            Metrics: map[string]float64{
                "current_rate": currentRate,
                "threshold":    a.alertThresholds.LowRequestRate,
            },
        })
    }
    
    // High error rate alert
    if errorRate > a.alertThresholds.HighErrorRate {
        a.sendAlert(Alert{
            Type:      "high_error_rate",
            Message:   fmt.Sprintf("Error rate is high: %.2f%%", errorRate),
            Severity:  "critical",
            Timestamp: time.Now(),
            Metrics: map[string]float64{
                "error_rate": errorRate,
                "threshold":  a.alertThresholds.HighErrorRate,
            },
        })
    }
    
    // High budget utilization alert
    if budgetUtil > a.alertThresholds.HighBudgetUtil {
        a.sendAlert(Alert{
            Type:      "high_budget_utilization",
            Message:   fmt.Sprintf("Budget utilization is high: %.2f%%", budgetUtil),
            Severity:  "critical",
            Timestamp: time.Now(),
            Metrics: map[string]float64{
                "budget_utilization": budgetUtil,
                "threshold":          a.alertThresholds.HighBudgetUtil,
            },
        })
    }
}

func (a *RequestRateAlerting) sendAlert(alert Alert) {
    select {
    case a.alertChannel <- alert:
    default:
        // Alert channel is full, log error
        fmt.Printf("Alert channel full, dropping alert: %+v\n", alert)
    }
}
```

## Benefits

1. **Comprehensive Monitoring**: Multi-dimensional view of system health and performance
2. **Intelligent Decision Making**: Budget-based approach provides nuanced policy decisions
3. **Anomaly Detection**: Detect traffic patterns and system anomalies early
4. **Adaptive Behavior**: Systems can adapt to changing conditions automatically
5. **Better Resource Utilization**: More efficient use of system resources based on actual impact

## Consequences

### Positive

- **Enhanced Observability**: Better understanding of system behavior and health
- **Proactive Problem Detection**: Early detection of issues before they become critical
- **Intelligent Rate Limiting**: More sophisticated rate limiting based on actual system impact
- **Improved Reliability**: Better circuit breaker decisions based on weighted metrics
- **Cost Optimization**: More efficient resource allocation based on actual usage patterns

### Negative

- **Increased Complexity**: More complex monitoring and alerting systems
- **Configuration Overhead**: Need to tune thresholds and budget weights
- **Storage Requirements**: Additional storage for detailed metrics and time series data
- **Performance Impact**: Monitoring overhead on system performance
- **Learning Curve**: Team needs to understand budget-based concepts

## Implementation Checklist

- [ ] Implement basic request rate monitoring with time windows
- [ ] Set up budget-based request tracking with error severity mapping
- [ ] Integrate circuit breakers with budget-based logic
- [ ] Implement adaptive rate limiting based on system health
- [ ] Add HTTP middleware for automatic request tracking
- [ ] Set up comprehensive monitoring dashboards
- [ ] Configure alerting thresholds and notification channels
- [ ] Implement proper error classification and budget assignment
- [ ] Add performance testing for monitoring overhead
- [ ] Document budget allocation and threshold tuning guidelines

## Best Practices

1. **Budget Allocation**: Carefully assign budget costs based on actual system impact
2. **Threshold Tuning**: Regularly review and adjust thresholds based on system behavior
3. **Time Window Selection**: Choose appropriate time windows for different metrics
4. **Error Classification**: Implement comprehensive error classification for accurate budget assignment
5. **Monitoring Overhead**: Keep monitoring overhead minimal to avoid performance impact
6. **Alerting Hygiene**: Avoid alert fatigue with proper threshold setting and alert routing
7. **Dashboard Design**: Create clear, actionable dashboards for different stakeholders
8. **Documentation**: Maintain clear documentation for budget weights and threshold meanings

## References

- [RED Method for Monitoring](https://www.weave.works/blog/the-red-method-key-metrics-for-microservices-architecture/)
- [Google SRE Book - Monitoring](https://sre.google/sre-book/monitoring-distributed-systems/)
- [Circuit Breaker Pattern](https://martinfowler.com/bliki/CircuitBreaker.html)
- [Adaptive Rate Limiting](https://blog.cloudflare.com/counting-things-a-lot-of-different-things/)







