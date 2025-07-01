# Metastability and Retry Budget Management

## Status

`accepted`

## Context

Metastability in distributed systems refers to a state where the system appears stable but is actually operating in a degraded mode that can persist indefinitely. This often occurs when retry mechanisms, intended to improve reliability, create feedback loops that keep the system in a perpetually overloaded state.

Understanding and preventing metastability is crucial for building resilient distributed systems that can recover from failures rather than getting stuck in degraded states.

## Decision

We will implement comprehensive metastability prevention strategies including retry budgets, adaptive algorithms, and system-wide coordination to ensure our distributed systems can recover from failures and avoid getting trapped in unstable states.

## Understanding Metastability

### What is Metastability?

Metastability occurs when a system gets stuck in a state that is:
- **Stable enough** not to completely fail
- **Degraded enough** to cause ongoing problems
- **Self-reinforcing** through feedback loops
- **Difficult to escape** without external intervention

### Common Causes

1. **Retry Amplification**: Retries creating more load than the original requests
2. **Resource Exhaustion**: Memory, CPU, or connection pool exhaustion
3. **Cascading Failures**: Failures in one component affecting others
4. **Cache Stampedes**: Multiple clients trying to regenerate the same cached data
5. **Queueing Theory Effects**: Queues becoming so full that they never drain

## Implementation

### 1. Retry Budget System

```go
package retrybudget

import (
    "context"
    "fmt"
    "sync"
    "sync/atomic"
    "time"
)

// RetryBudget manages the retry budget for a service
type RetryBudget struct {
    // Configuration
    maxRetryRatio    float64   // Maximum ratio of retries to requests
    windowSize       time.Duration
    minRequestsInWindow int64  // Minimum requests before budgeting applies
    
    // Tracking
    requests        int64     // Total requests in current window
    retries         int64     // Total retries in current window
    windowStart     time.Time
    
    // State
    budgetExhausted int32     // Atomic flag
    mu              sync.RWMutex
}

// NewRetryBudget creates a new retry budget
func NewRetryBudget(maxRetryRatio float64, windowSize time.Duration, minRequests int64) *RetryBudget {
    return &RetryBudget{
        maxRetryRatio:       maxRetryRatio,
        windowSize:          windowSize,
        minRequestsInWindow: minRequests,
        windowStart:         time.Now(),
    }
}

// CanRetry checks if a retry is allowed within the budget
func (rb *RetryBudget) CanRetry() bool {
    rb.mu.RLock()
    defer rb.mu.RUnlock()
    
    // Reset window if needed
    if time.Since(rb.windowStart) > rb.windowSize {
        rb.resetWindow()
    }
    
    // Allow retries if not enough requests to make a decision
    if atomic.LoadInt64(&rb.requests) < rb.minRequestsInWindow {
        return true
    }
    
    // Check if budget is exhausted
    if atomic.LoadInt32(&rb.budgetExhausted) == 1 {
        return false
    }
    
    // Calculate current retry ratio
    currentRequests := atomic.LoadInt64(&rb.requests)
    currentRetries := atomic.LoadInt64(&rb.retries)
    
    if currentRequests == 0 {
        return true
    }
    
    currentRatio := float64(currentRetries) / float64(currentRequests)
    return currentRatio < rb.maxRetryRatio
}

// RecordRequest records a new request
func (rb *RetryBudget) RecordRequest() {
    rb.mu.RLock()
    if time.Since(rb.windowStart) > rb.windowSize {
        rb.mu.RUnlock()
        rb.mu.Lock()
        rb.resetWindow()
        rb.mu.Unlock()
    } else {
        rb.mu.RUnlock()
    }
    
    atomic.AddInt64(&rb.requests, 1)
}

// RecordRetry records a retry attempt
func (rb *RetryBudget) RecordRetry() {
    atomic.AddInt64(&rb.retries, 1)
    
    // Check if budget should be exhausted
    rb.checkBudgetExhaustion()
}

// resetWindow resets the tracking window
func (rb *RetryBudget) resetWindow() {
    atomic.StoreInt64(&rb.requests, 0)
    atomic.StoreInt64(&rb.retries, 0)
    atomic.StoreInt32(&rb.budgetExhausted, 0)
    rb.windowStart = time.Now()
}

// checkBudgetExhaustion checks if budget should be marked as exhausted
func (rb *RetryBudget) checkBudgetExhaustion() {
    currentRequests := atomic.LoadInt64(&rb.requests)
    currentRetries := atomic.LoadInt64(&rb.retries)
    
    if currentRequests >= rb.minRequestsInWindow {
        currentRatio := float64(currentRetries) / float64(currentRequests)
        if currentRatio >= rb.maxRetryRatio {
            atomic.StoreInt32(&rb.budgetExhausted, 1)
        }
    }
}

// GetStats returns current retry budget statistics
func (rb *RetryBudget) GetStats() RetryBudgetStats {
    rb.mu.RLock()
    defer rb.mu.RUnlock()
    
    requests := atomic.LoadInt64(&rb.requests)
    retries := atomic.LoadInt64(&rb.retries)
    exhausted := atomic.LoadInt32(&rb.budgetExhausted) == 1
    
    var ratio float64
    if requests > 0 {
        ratio = float64(retries) / float64(requests)
    }
    
    return RetryBudgetStats{
        Requests:        requests,
        Retries:         retries,
        RetryRatio:      ratio,
        BudgetExhausted: exhausted,
        WindowStart:     rb.windowStart,
    }
}

// RetryBudgetStats contains retry budget statistics
type RetryBudgetStats struct {
    Requests        int64     `json:"requests"`
    Retries         int64     `json:"retries"`
    RetryRatio      float64   `json:"retry_ratio"`
    BudgetExhausted bool      `json:"budget_exhausted"`
    WindowStart     time.Time `json:"window_start"`
}
```

### 2. Metastability Detection

```go
package metastability

import (
    "context"
    "math"
    "sync"
    "time"
)

// MetastabilityDetector detects when the system is in a metastable state
type MetastabilityDetector struct {
    // Configuration
    latencyThreshold      time.Duration
    errorRateThreshold    float64
    throughputDropThreshold float64
    detectionWindow       time.Duration
    
    // Metrics tracking
    metrics              *SystemMetrics
    baselineMetrics      *SystemMetrics
    lastDetectionTime    time.Time
    
    // State
    isMetastable         bool
    metastableStartTime  time.Time
    mu                   sync.RWMutex
}

// SystemMetrics represents system performance metrics
type SystemMetrics struct {
    Latency           time.Duration `json:"latency"`
    ErrorRate         float64       `json:"error_rate"`
    Throughput        float64       `json:"throughput"`
    ActiveConnections int64         `json:"active_connections"`
    QueueDepth        int64         `json:"queue_depth"`
    CPUUtilization    float64       `json:"cpu_utilization"`
    MemoryUtilization float64       `json:"memory_utilization"`
    Timestamp         time.Time     `json:"timestamp"`
}

// NewMetastabilityDetector creates a new detector
func NewMetastabilityDetector(config DetectorConfig) *MetastabilityDetector {
    return &MetastabilityDetector{
        latencyThreshold:        config.LatencyThreshold,
        errorRateThreshold:      config.ErrorRateThreshold,
        throughputDropThreshold: config.ThroughputDropThreshold,
        detectionWindow:         config.DetectionWindow,
        metrics:                 &SystemMetrics{},
        baselineMetrics:         &SystemMetrics{},
    }
}

// DetectorConfig configures the metastability detector
type DetectorConfig struct {
    LatencyThreshold         time.Duration
    ErrorRateThreshold       float64
    ThroughputDropThreshold  float64
    DetectionWindow          time.Duration
}

// UpdateMetrics updates the current system metrics
func (md *MetastabilityDetector) UpdateMetrics(metrics *SystemMetrics) {
    md.mu.Lock()
    defer md.mu.Unlock()
    
    md.metrics = metrics
    
    // Update baseline during healthy periods
    if !md.isMetastable && md.isHealthyMetrics(metrics) {
        md.updateBaseline(metrics)
    }
    
    // Check for metastability
    md.checkMetastability()
}

// isHealthyMetrics checks if metrics indicate a healthy system
func (md *MetastabilityDetector) isHealthyMetrics(metrics *SystemMetrics) bool {
    return metrics.ErrorRate < 0.01 && // Less than 1% error rate
           metrics.Latency < 100*time.Millisecond && // Low latency
           metrics.CPUUtilization < 0.7 // CPU not over-utilized
}

// updateBaseline updates the baseline metrics
func (md *MetastabilityDetector) updateBaseline(metrics *SystemMetrics) {
    // Use exponential moving average
    alpha := 0.1
    if md.baselineMetrics.Timestamp.IsZero() {
        *md.baselineMetrics = *metrics
    } else {
        md.baselineMetrics.Latency = time.Duration(
            float64(md.baselineMetrics.Latency)*(1-alpha) + 
            float64(metrics.Latency)*alpha)
        md.baselineMetrics.ErrorRate = 
            md.baselineMetrics.ErrorRate*(1-alpha) + 
            metrics.ErrorRate*alpha
        md.baselineMetrics.Throughput = 
            md.baselineMetrics.Throughput*(1-alpha) + 
            metrics.Throughput*alpha
    }
    md.baselineMetrics.Timestamp = metrics.Timestamp
}

// checkMetastability checks if the system is in a metastable state
func (md *MetastabilityDetector) checkMetastability() {
    if md.baselineMetrics.Timestamp.IsZero() {
        return // No baseline yet
    }
    
    isCurrentlyMetastable := md.detectMetastabilitySignals()
    
    if !md.isMetastable && isCurrentlyMetastable {
        // Entering metastable state
        md.isMetastable = true
        md.metastableStartTime = time.Now()
        md.onMetastabilityDetected()
    } else if md.isMetastable && !isCurrentlyMetastable {
        // Exiting metastable state
        duration := time.Since(md.metastableStartTime)
        md.isMetastable = false
        md.onMetastabilityResolved(duration)
    }
}

// detectMetastabilitySignals detects signals of metastability
func (md *MetastabilityDetector) detectMetastabilitySignals() bool {
    signals := 0
    
    // Signal 1: High latency compared to baseline
    if md.metrics.Latency > md.baselineMetrics.Latency*2 &&
       md.metrics.Latency > md.latencyThreshold {
        signals++
    }
    
    // Signal 2: High error rate
    if md.metrics.ErrorRate > md.errorRateThreshold {
        signals++
    }
    
    // Signal 3: Throughput drop
    if md.baselineMetrics.Throughput > 0 {
        throughputDrop := (md.baselineMetrics.Throughput - md.metrics.Throughput) / 
                         md.baselineMetrics.Throughput
        if throughputDrop > md.throughputDropThreshold {
            signals++
        }
    }
    
    // Signal 4: Resource exhaustion patterns
    if md.metrics.CPUUtilization > 0.9 || md.metrics.MemoryUtilization > 0.9 {
        signals++
    }
    
    // Signal 5: Growing queue depth
    if md.metrics.QueueDepth > 1000 && md.metrics.QueueDepth > md.baselineMetrics.QueueDepth*5 {
        signals++
    }
    
    // Require multiple signals to avoid false positives
    return signals >= 3
}

// onMetastabilityDetected handles metastability detection
func (md *MetastabilityDetector) onMetastabilityDetected() {
    // Log the detection
    fmt.Printf("Metastability detected at %v\n", time.Now())
    
    // Trigger mitigation strategies
    md.triggerMitigation()
}

// onMetastabilityResolved handles metastability resolution
func (md *MetastabilityResolved(duration time.Duration) {
    fmt.Printf("Metastability resolved after %v\n", duration)
}

// triggerMitigation triggers mitigation strategies
func (md *MetastabilityDetector) triggerMitigation() {
    // This would trigger various mitigation strategies
    // such as load shedding, circuit breaking, etc.
}

// IsMetastable returns whether the system is currently metastable
func (md *MetastabilityDetector) IsMetastable() bool {
    md.mu.RLock()
    defer md.mu.RUnlock()
    return md.isMetastable
}

// GetMetastabilityDuration returns how long the system has been metastable
func (md *MetastabilityDetector) GetMetastabilityDuration() time.Duration {
    md.mu.RLock()
    defer md.mu.RUnlock()
    
    if !md.isMetastable {
        return 0
    }
    
    return time.Since(md.metastableStartTime)
}
```

### 3. Adaptive Retry Strategy

```go
package adaptive

import (
    "context"
    "math"
    "sync"
    "time"
)

// AdaptiveRetryStrategy implements adaptive retry logic that responds to system state
type AdaptiveRetryStrategy struct {
    retryBudget           *RetryBudget
    metastabilityDetector *MetastabilityDetector
    
    // Configuration
    baseBackoffMs         int
    maxBackoffMs          int
    backoffMultiplier     float64
    
    // Adaptive parameters
    systemHealthFactor    float64
    metastabilityPenalty  float64
    
    mu sync.RWMutex
}

// NewAdaptiveRetryStrategy creates a new adaptive retry strategy
func NewAdaptiveRetryStrategy(
    retryBudget *RetryBudget,
    detector *MetastabilityDetector,
    config AdaptiveRetryConfig,
) *AdaptiveRetryStrategy {
    return &AdaptiveRetryStrategy{
        retryBudget:           retryBudget,
        metastabilityDetector: detector,
        baseBackoffMs:         config.BaseBackoffMs,
        maxBackoffMs:          config.MaxBackoffMs,
        backoffMultiplier:     config.BackoffMultiplier,
        systemHealthFactor:    1.0,
        metastabilityPenalty:  5.0, // 5x penalty during metastability
    }
}

// AdaptiveRetryConfig configures adaptive retry behavior
type AdaptiveRetryConfig struct {
    BaseBackoffMs     int
    MaxBackoffMs      int
    BackoffMultiplier float64
}

// ShouldRetry determines if a request should be retried
func (ars *AdaptiveRetryStrategy) ShouldRetry(attempt int, err error) bool {
    // Check retry budget first
    if !ars.retryBudget.CanRetry() {
        return false
    }
    
    // Don't retry during metastability unless it's the first attempt
    if ars.metastabilityDetector.IsMetastable() && attempt > 0 {
        return false
    }
    
    // Check if error is retryable
    if !ars.isRetryableError(err) {
        return false
    }
    
    // Limit total attempts
    maxAttempts := 3
    if ars.metastabilityDetector.IsMetastable() {
        maxAttempts = 1 // Reduce attempts during metastability
    }
    
    return attempt < maxAttempts
}

// CalculateBackoff calculates the backoff duration for a retry
func (ars *AdaptiveRetryStrategy) CalculateBackoff(attempt int) time.Duration {
    // Base exponential backoff
    backoffMs := float64(ars.baseBackoffMs) * math.Pow(ars.backoffMultiplier, float64(attempt))
    
    // Apply system health factor
    ars.mu.RLock()
    backoffMs *= ars.systemHealthFactor
    ars.mu.RUnlock()
    
    // Apply metastability penalty
    if ars.metastabilityDetector.IsMetastable() {
        backoffMs *= ars.metastabilityPenalty
    }
    
    // Add jitter (±25%)
    jitter := 0.5 * (0.5 - math.Mod(float64(time.Now().UnixNano()), 1.0))
    backoffMs *= (1.0 + jitter)
    
    // Enforce maximum
    if backoffMs > float64(ars.maxBackoffMs) {
        backoffMs = float64(ars.maxBackoffMs)
    }
    
    return time.Duration(backoffMs) * time.Millisecond
}

// UpdateSystemHealth updates the system health factor
func (ars *AdaptiveRetryStrategy) UpdateSystemHealth(healthScore float64) {
    ars.mu.Lock()
    defer ars.mu.Unlock()
    
    // Health score ranges from 0 (unhealthy) to 1 (healthy)
    // Convert to backoff factor: healthy = 1.0, unhealthy = 10.0
    ars.systemHealthFactor = 1.0 + (1.0-healthScore)*9.0
}

// isRetryableError determines if an error is retryable
func (ars *AdaptiveRetryStrategy) isRetryableError(err error) bool {
    // Implement error classification logic
    // This would typically check error types, HTTP status codes, etc.
    return true // Simplified for example
}

// RetryWithBackoff executes a function with adaptive retry logic
func (ars *AdaptiveRetryStrategy) RetryWithBackoff(
    ctx context.Context,
    operation func() error,
) error {
    var lastErr error
    
    for attempt := 0; ; attempt++ {
        // Record the request
        ars.retryBudget.RecordRequest()
        
        // Execute the operation
        err := operation()
        if err == nil {
            return nil // Success
        }
        
        lastErr = err
        
        // Check if we should retry
        if !ars.ShouldRetry(attempt, err) {
            break
        }
        
        // Record the retry
        ars.retryBudget.RecordRetry()
        
        // Calculate and wait for backoff
        backoff := ars.CalculateBackoff(attempt)
        
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-time.After(backoff):
            continue
        }
    }
    
    return lastErr
}
```

### 4. System-Wide Coordination

```go
package coordination

import (
    "context"
    "encoding/json"
    "fmt"
    "sync"
    "time"
    
    "github.com/go-redis/redis/v8"
)

// SystemCoordinator coordinates metastability responses across services
type SystemCoordinator struct {
    redis       *redis.Client
    serviceName string
    
    // Local state
    localState  *ServiceState
    globalState *GlobalSystemState
    
    // Configuration
    coordinationTTL time.Duration
    updateInterval  time.Duration
    
    mu sync.RWMutex
}

// ServiceState represents the state of a single service
type ServiceState struct {
    ServiceName       string            `json:"service_name"`
    IsMetastable      bool              `json:"is_metastable"`
    MetricsSummary    SystemMetrics     `json:"metrics_summary"`
    LastUpdate        time.Time         `json:"last_update"`
    MitigationActions []string          `json:"mitigation_actions"`
}

// GlobalSystemState represents the state of the entire system
type GlobalSystemState struct {
    Services          map[string]*ServiceState `json:"services"`
    SystemMetastable  bool                     `json:"system_metastable"`
    LastUpdate        time.Time                `json:"last_update"`
}

// NewSystemCoordinator creates a new system coordinator
func NewSystemCoordinator(redis *redis.Client, serviceName string) *SystemCoordinator {
    sc := &SystemCoordinator{
        redis:           redis,
        serviceName:     serviceName,
        localState:      &ServiceState{ServiceName: serviceName},
        globalState:     &GlobalSystemState{Services: make(map[string]*ServiceState)},
        coordinationTTL: 30 * time.Second,
        updateInterval:  5 * time.Second,
    }
    
    // Start coordination loop
    go sc.coordinationLoop()
    
    return sc
}

// UpdateLocalState updates the local service state
func (sc *SystemCoordinator) UpdateLocalState(
    isMetastable bool,
    metrics SystemMetrics,
    actions []string,
) {
    sc.mu.Lock()
    defer sc.mu.Unlock()
    
    sc.localState.IsMetastable = isMetastable
    sc.localState.MetricsSummary = metrics
    sc.localState.MitigationActions = actions
    sc.localState.LastUpdate = time.Now()
}

// coordinationLoop runs the coordination loop
func (sc *SystemCoordinator) coordinationLoop() {
    ticker := time.NewTicker(sc.updateInterval)
    defer ticker.Stop()
    
    for range ticker.C {
        sc.publishLocalState()
        sc.fetchGlobalState()
        sc.analyzeSystemState()
    }
}

// publishLocalState publishes local state to Redis
func (sc *SystemCoordinator) publishLocalState() {
    sc.mu.RLock()
    state := *sc.localState
    sc.mu.RUnlock()
    
    key := fmt.Sprintf("metastability:service:%s", sc.serviceName)
    data, err := json.Marshal(state)
    if err != nil {
        return
    }
    
    sc.redis.Set(context.Background(), key, data, sc.coordinationTTL)
}

// fetchGlobalState fetches global system state from Redis
func (sc *SystemCoordinator) fetchGlobalState() {
    ctx := context.Background()
    pattern := "metastability:service:*"
    
    keys, err := sc.redis.Keys(ctx, pattern).Result()
    if err != nil {
        return
    }
    
    sc.mu.Lock()
    defer sc.mu.Unlock()
    
    // Clear old services
    sc.globalState.Services = make(map[string]*ServiceState)
    
    // Fetch all service states
    for _, key := range keys {
        data, err := sc.redis.Get(ctx, key).Result()
        if err != nil {
            continue
        }
        
        var state ServiceState
        if err := json.Unmarshal([]byte(data), &state); err != nil {
            continue
        }
        
        sc.globalState.Services[state.ServiceName] = &state
    }
    
    sc.globalState.LastUpdate = time.Now()
}

// analyzeSystemState analyzes the global system state
func (sc *SystemCoordinator) analyzeSystemState() {
    sc.mu.Lock()
    defer sc.mu.Unlock()
    
    metastableServices := 0
    totalServices := len(sc.globalState.Services)
    
    for _, service := range sc.globalState.Services {
        if service.IsMetastable {
            metastableServices++
        }
    }
    
    // System is metastable if more than 30% of services are metastable
    threshold := float64(totalServices) * 0.3
    sc.globalState.SystemMetastable = float64(metastableServices) > threshold
    
    // Trigger system-wide coordination if needed
    if sc.globalState.SystemMetastable {
        sc.triggerSystemWideMitigation()
    }
}

// triggerSystemWideMitigation triggers system-wide mitigation
func (sc *SystemCoordinator) triggerSystemWideMitigation() {
    // Publish system-wide mitigation signal
    signal := map[string]interface{}{
        "action":    "system_wide_mitigation",
        "timestamp": time.Now(),
        "services":  len(sc.globalState.Services),
        "metastable_services": sc.countMetastableServices(),
    }
    
    data, _ := json.Marshal(signal)
    sc.redis.Publish(context.Background(), "metastability:coordination", data)
}

// countMetastableServices counts metastable services
func (sc *SystemCoordinator) countMetastableServices() int {
    count := 0
    for _, service := range sc.globalState.Services {
        if service.IsMetastable {
            count++
        }
    }
    return count
}

// IsSystemMetastable returns whether the system is metastable
func (sc *SystemCoordinator) IsSystemMetastable() bool {
    sc.mu.RLock()
    defer sc.mu.RUnlock()
    return sc.globalState.SystemMetastable
}

// GetGlobalState returns the current global system state
func (sc *SystemCoordinator) GetGlobalState() *GlobalSystemState {
    sc.mu.RLock()
    defer sc.mu.RUnlock()
    
    // Return a copy to avoid data races
    stateCopy := *sc.globalState
    stateCopy.Services = make(map[string]*ServiceState)
    for k, v := range sc.globalState.Services {
        serviceCopy := *v
        stateCopy.Services[k] = &serviceCopy
    }
    
    return &stateCopy
}
```

### 5. Integration Example

```go
package main

import (
    "context"
    "fmt"
    "log"
    "net/http"
    "time"
)

// MetastabilityManager integrates all metastability prevention components
type MetastabilityManager struct {
    retryBudget      *RetryBudget
    detector         *MetastabilityDetector
    adaptiveRetry    *AdaptiveRetryStrategy
    coordinator      *SystemCoordinator
    
    // Metrics
    requestsTotal    int64
    requestsSuccess  int64
    requestsFailure  int64
}

// NewMetastabilityManager creates a new manager
func NewMetastabilityManager(serviceName string, redis *redis.Client) *MetastabilityManager {
    // Create retry budget (10% retry ratio, 1-minute window, min 100 requests)
    retryBudget := NewRetryBudget(0.1, time.Minute, 100)
    
    // Create metastability detector
    detector := NewMetastabilityDetector(DetectorConfig{
        LatencyThreshold:        500 * time.Millisecond,
        ErrorRateThreshold:      0.05, // 5%
        ThroughputDropThreshold: 0.5,  // 50% drop
        DetectionWindow:         5 * time.Minute,
    })
    
    // Create adaptive retry strategy
    adaptiveRetry := NewAdaptiveRetryStrategy(
        retryBudget,
        detector,
        AdaptiveRetryConfig{
            BaseBackoffMs:     100,
            MaxBackoffMs:      30000,
            BackoffMultiplier: 2.0,
        },
    )
    
    // Create system coordinator
    coordinator := NewSystemCoordinator(redis, serviceName)
    
    return &MetastabilityManager{
        retryBudget:   retryBudget,
        detector:      detector,
        adaptiveRetry: adaptiveRetry,
        coordinator:   coordinator,
    }
}

// HandleRequest handles an HTTP request with metastability protection
func (mm *MetastabilityManager) HandleRequest(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    start := time.Now()
    
    // Update metrics
    atomic.AddInt64(&mm.requestsTotal, 1)
    
    // Check if system is metastable
    if mm.detector.IsMetastable() {
        // Apply aggressive load shedding during metastability
        if mm.shouldShedLoad() {
            http.Error(w, "Service temporarily overloaded", http.StatusServiceUnavailable)
            return
        }
    }
    
    // Execute request with adaptive retry
    err := mm.adaptiveRetry.RetryWithBackoff(ctx, func() error {
        return mm.processRequest(ctx, r)
    })
    
    duration := time.Since(start)
    
    if err != nil {
        atomic.AddInt64(&mm.requestsFailure, 1)
        http.Error(w, err.Error(), http.StatusInternalServerError)
    } else {
        atomic.AddInt64(&mm.requestsSuccess, 1)
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("Request processed successfully"))
    }
    
    // Update system metrics
    mm.updateSystemMetrics(duration, err != nil)
}

// processRequest processes a single request
func (mm *MetastabilityManager) processRequest(ctx context.Context, r *http.Request) error {
    // Simulate request processing
    time.Sleep(50 * time.Millisecond)
    
    // Simulate occasional failures
    if time.Now().UnixNano()%10 == 0 {
        return fmt.Errorf("simulated failure")
    }
    
    return nil
}

// shouldShedLoad determines if load should be shed
func (mm *MetastabilityManager) shouldShedLoad() bool {
    // Shed 50% of load during metastability
    return time.Now().UnixNano()%2 == 0
}

// updateSystemMetrics updates system metrics for metastability detection
func (mm *MetastabilityManager) updateSystemMetrics(latency time.Duration, isError bool) {
    totalRequests := atomic.LoadInt64(&mm.requestsTotal)
    failedRequests := atomic.LoadInt64(&mm.requestsFailure)
    
    errorRate := 0.0
    if totalRequests > 0 {
        errorRate = float64(failedRequests) / float64(totalRequests)
    }
    
    // Calculate throughput (simplified)
    throughput := float64(totalRequests) / time.Since(time.Now().Add(-time.Minute)).Seconds()
    
    metrics := &SystemMetrics{
        Latency:           latency,
        ErrorRate:         errorRate,
        Throughput:        throughput,
        ActiveConnections: 100, // Placeholder
        QueueDepth:        10,  // Placeholder
        CPUUtilization:    0.5, // Placeholder
        MemoryUtilization: 0.6, // Placeholder
        Timestamp:         time.Now(),
    }
    
    // Update detector
    mm.detector.UpdateMetrics(metrics)
    
    // Update coordinator
    actions := []string{}
    if mm.detector.IsMetastable() {
        actions = append(actions, "load_shedding", "reduced_retries")
    }
    
    mm.coordinator.UpdateLocalState(mm.detector.IsMetastable(), *metrics, actions)
}

func main() {
    // Initialize Redis client (configuration omitted)
    var redisClient *redis.Client
    
    // Create metastability manager
    manager := NewMetastabilityManager("example-service", redisClient)
    
    // Set up HTTP handler
    http.HandleFunc("/api/example", manager.HandleRequest)
    
    // Start metrics reporting
    go func() {
        ticker := time.NewTicker(30 * time.Second)
        defer ticker.Stop()
        
        for range ticker.C {
            stats := manager.retryBudget.GetStats()
            fmt.Printf("Retry Budget Stats: %+v\n", stats)
            
            if manager.detector.IsMetastable() {
                duration := manager.detector.GetMetastabilityDuration()
                fmt.Printf("System metastable for %v\n", duration)
            }
        }
    }()
    
    log.Println("Server starting on :8080")
    log.Fatal(http.ListenAndServe(":8080", nil))
}
```

## Benefits

1. **System Stability**: Prevents systems from getting stuck in degraded states
2. **Automatic Recovery**: Enables systems to recover from metastable states
3. **Resource Protection**: Prevents resource exhaustion through intelligent budgeting
4. **Coordinated Response**: Enables system-wide coordination during crises
5. **Adaptive Behavior**: Adjusts retry behavior based on system health

## Consequences

### Positive

- **Improved Resilience**: Systems can recover from degraded states
- **Better Resource Utilization**: Prevents wasted resources on futile retries
- **System-Wide Visibility**: Better understanding of distributed system health
- **Automated Mitigation**: Reduces need for manual intervention
- **Predictable Behavior**: More predictable system behavior under stress

### Negative

- **Increased Complexity**: Additional complexity in system design and operation
- **Configuration Overhead**: Requires careful tuning of parameters
- **Potential Service Degradation**: May require degrading service to maintain stability
- **Monitoring Requirements**: Requires comprehensive monitoring and alerting
- **Coordination Overhead**: Additional network overhead for coordination

## Implementation Checklist

- [ ] Implement retry budget system with configurable parameters
- [ ] Create metastability detection with multiple signal analysis
- [ ] Develop adaptive retry strategies that respond to system state
- [ ] Set up system-wide coordination for distributed responses
- [ ] Implement comprehensive monitoring and alerting
- [ ] Create load shedding mechanisms for metastable periods
- [ ] Add circuit breakers with metastability awareness
- [ ] Set up automated mitigation triggers
- [ ] Create operational runbooks for metastability incidents
- [ ] Implement gradual recovery mechanisms
- [ ] Add performance testing for metastability scenarios
- [ ] Create dashboards for metastability monitoring

## Best Practices

1. **Multiple Signals**: Use multiple signals to detect metastability
2. **Gradual Response**: Apply mitigation gradually to avoid shock
3. **System-Wide Coordination**: Coordinate responses across all services
4. **Budget Management**: Strictly enforce retry budgets
5. **Monitoring**: Maintain comprehensive monitoring and alerting
6. **Testing**: Regularly test metastability scenarios
7. **Documentation**: Document all parameters and their effects
8. **Automation**: Automate responses to reduce human error

## References

- [Metastability in Distributed Systems](https://brooker.co.za/blog/2021/05/24/metastable.html)
- [DoorDash Aperture Framework](https://careers.doordash.com/blog/failure-mitigation-for-microservices-an-intro-to-aperture/)
- [Facebook TAO Paper](https://sigops.org/s/conferences/hotos/2021/papers/hotos21-s11-bronson.pdf)
- [USENIX OSDI Paper](https://www.usenix.org/conference/osdi22/presentation/huang-lexiang)
- [Google SRE Book - Handling Overload](https://sre.google/sre-book/handling-overload/)
