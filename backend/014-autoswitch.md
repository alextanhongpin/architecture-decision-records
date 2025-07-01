# Automatic Provider Switching

## Status

`accepted`

## Context

In distributed systems with multiple service providers, businesses often need to balance cost optimization with reliability. Rather than statically choosing a single provider, automatic switching allows systems to dynamically select the best provider based on real-time performance, cost, and availability metrics.

### Business Use Cases

Common scenarios requiring automatic switching:
- **Payment processors**: Switch between Stripe, PayPal, and others based on fees and success rates
- **Cloud providers**: Route traffic between AWS, GCP, and Azure based on latency and cost
- **CDN providers**: Select optimal content delivery network based on geographic performance
- **Email services**: Switch between SendGrid, Mailgun, and SES based on deliverability rates
- **SMS providers**: Route messages through Twilio, AWS SNS, or local providers based on cost and reliability

### Business Requirements

- **Cost optimization**: Prefer lower-cost providers when performance is acceptable
- **Reliability**: Automatically failover when primary provider experiences issues
- **Performance**: Route to fastest provider based on current conditions
- **Geographic optimization**: Select regional providers for better latency
- **Compliance**: Ensure data residency and regulatory requirements are met

### Current Challenges

- **Manual switching**: Requires human intervention during provider outages
- **Suboptimal cost**: Always using expensive providers for reliability
- **Performance degradation**: Slow response times when providers are overloaded
- **Complex failover**: Difficult to coordinate switching across multiple services
- **Monitoring overhead**: Need to track performance across all providers

## Decision

We will implement an intelligent automatic switching system that combines circuit breakers, load balancing, and business rules to optimize provider selection based on cost, performance, and reliability metrics.

### Architecture Overview

```go
package autoswitch

import (
    "context"
    "fmt"
    "sort"
    "sync"
    "time"
)

type Provider interface {
    Execute(ctx context.Context, request interface{}) (interface{}, error)
    Name() string
    Cost() float64
    Priority() int
}

type ProviderMetrics struct {
    SuccessRate     float64
    AverageLatency  time.Duration
    ErrorCount      int64
    TotalRequests   int64
    LastSuccess     time.Time
    LastFailure     time.Time
    CircuitOpen     bool
}

type AutoSwitcher struct {
    providers       []Provider
    metrics         map[string]*ProviderMetrics
    circuitBreakers map[string]*CircuitBreaker
    rules           []SwitchingRule
    selector        ProviderSelector
    monitor         *MetricsMonitor
    mutex           sync.RWMutex
    
    // Configuration
    config *AutoSwitchConfig
}

type AutoSwitchConfig struct {
    // Provider selection strategy
    Strategy              SelectionStrategy
    
    // Circuit breaker settings
    FailureThreshold      int
    RecoveryTimeout       time.Duration
    
    // Performance thresholds
    MaxLatency           time.Duration
    MinSuccessRate       float64
    
    // Cost optimization
    CostWeight           float64
    PerformanceWeight    float64
    ReliabilityWeight    float64
    
    // Monitoring
    MetricsWindow        time.Duration
    HealthCheckInterval  time.Duration
}

type SelectionStrategy string

const (
    StrategyCostOptimized      SelectionStrategy = "cost_optimized"
    StrategyPerformanceFirst   SelectionStrategy = "performance_first"
    StrategyReliabilityFirst   SelectionStrategy = "reliability_first"
    StrategyWeightedRoundRobin SelectionStrategy = "weighted_round_robin"
    StrategyGeographicFirst    SelectionStrategy = "geographic_first"
)
```

### Core Implementation

```go
func NewAutoSwitcher(providers []Provider, config *AutoSwitchConfig) *AutoSwitcher {
    as := &AutoSwitcher{
        providers:       providers,
        metrics:         make(map[string]*ProviderMetrics),
        circuitBreakers: make(map[string]*CircuitBreaker),
        config:          config,
        monitor:         NewMetricsMonitor(config.MetricsWindow),
    }
    
    // Initialize metrics and circuit breakers for each provider
    for _, provider := range providers {
        as.metrics[provider.Name()] = &ProviderMetrics{
            SuccessRate:   1.0, // Start optimistic
            TotalRequests: 0,
        }
        
        as.circuitBreakers[provider.Name()] = NewCircuitBreaker(CircuitBreakerConfig{
            FailureThreshold: config.FailureThreshold,
            RecoveryTimeout:  config.RecoveryTimeout,
        })
    }
    
    // Initialize provider selector based on strategy
    as.selector = as.createSelector(config.Strategy)
    
    // Start background monitoring
    go as.startMonitoring()
    
    return as
}

func (as *AutoSwitcher) Execute(ctx context.Context, request interface{}) (interface{}, error) {
    attempts := 0
    maxAttempts := len(as.providers)
    
    for attempts < maxAttempts {
        provider := as.selectProvider(ctx)
        if provider == nil {
            return nil, fmt.Errorf("no available providers")
        }
        
        // Check circuit breaker
        cb := as.circuitBreakers[provider.Name()]
        if cb.IsOpen() {
            as.recordFailure(provider.Name(), fmt.Errorf("circuit breaker open"))
            attempts++
            continue
        }
        
        // Execute request
        start := time.Now()
        result, err := provider.Execute(ctx, request)
        duration := time.Since(start)
        
        // Record metrics
        if err != nil {
            as.recordFailure(provider.Name(), err)
            // Try next provider if this one failed
            attempts++
            continue
        }
        
        as.recordSuccess(provider.Name(), duration)
        return result, nil
    }
    
    return nil, fmt.Errorf("all providers failed")
}

func (as *AutoSwitcher) selectProvider(ctx context.Context) Provider {
    as.mutex.RLock()
    defer as.mutex.RUnlock()
    
    availableProviders := as.getAvailableProviders()
    if len(availableProviders) == 0 {
        return nil
    }
    
    return as.selector.Select(ctx, availableProviders, as.metrics)
}

func (as *AutoSwitcher) getAvailableProviders() []Provider {
    var available []Provider
    
    for _, provider := range as.providers {
        cb := as.circuitBreakers[provider.Name()]
        if !cb.IsOpen() {
            available = append(available, provider)
        }
    }
    
    return available
}
```

### Provider Selection Strategies

```go
type ProviderSelector interface {
    Select(ctx context.Context, providers []Provider, metrics map[string]*ProviderMetrics) Provider
}

// Cost-optimized selector - prefer cheapest provider with acceptable performance
type CostOptimizedSelector struct {
    minSuccessRate float64
    maxLatency     time.Duration
}

func (cos *CostOptimizedSelector) Select(ctx context.Context, providers []Provider, metrics map[string]*ProviderMetrics) Provider {
    // Filter providers meeting minimum performance criteria
    var eligible []Provider
    
    for _, provider := range providers {
        metric := metrics[provider.Name()]
        if metric.SuccessRate >= cos.minSuccessRate && 
           metric.AverageLatency <= cos.maxLatency {
            eligible = append(eligible, provider)
        }
    }
    
    if len(eligible) == 0 {
        // Fallback to best performing provider if none meet criteria
        return cos.selectBestPerforming(providers, metrics)
    }
    
    // Sort by cost (cheapest first)
    sort.Slice(eligible, func(i, j int) bool {
        return eligible[i].Cost() < eligible[j].Cost()
    })
    
    return eligible[0]
}

// Weighted selector - balance cost, performance, and reliability
type WeightedSelector struct {
    costWeight        float64
    performanceWeight float64
    reliabilityWeight float64
}

func (ws *WeightedSelector) Select(ctx context.Context, providers []Provider, metrics map[string]*ProviderMetrics) Provider {
    type scoredProvider struct {
        provider Provider
        score    float64
    }
    
    var scored []scoredProvider
    
    for _, provider := range providers {
        metric := metrics[provider.Name()]
        
        // Calculate normalized scores (0-1 range)
        costScore := ws.calculateCostScore(provider, providers)
        performanceScore := ws.calculatePerformanceScore(metric, metrics)
        reliabilityScore := metric.SuccessRate
        
        // Calculate weighted total score
        totalScore := ws.costWeight*costScore + 
                     ws.performanceWeight*performanceScore + 
                     ws.reliabilityWeight*reliabilityScore
        
        scored = append(scored, scoredProvider{
            provider: provider,
            score:    totalScore,
        })
    }
    
    // Sort by score (highest first)
    sort.Slice(scored, func(i, j int) bool {
        return scored[i].score > scored[j].score
    })
    
    return scored[0].provider
}

func (ws *WeightedSelector) calculateCostScore(provider Provider, allProviders []Provider) float64 {
    // Higher score for lower cost (inverted)
    maxCost := 0.0
    for _, p := range allProviders {
        if p.Cost() > maxCost {
            maxCost = p.Cost()
        }
    }
    
    if maxCost == 0 {
        return 1.0
    }
    
    return 1.0 - (provider.Cost() / maxCost)
}

func (ws *WeightedSelector) calculatePerformanceScore(metric *ProviderMetrics, allMetrics map[string]*ProviderMetrics) float64 {
    // Higher score for lower latency (inverted and normalized)
    maxLatency := time.Duration(0)
    for _, m := range allMetrics {
        if m.AverageLatency > maxLatency {
            maxLatency = m.AverageLatency
        }
    }
    
    if maxLatency == 0 {
        return 1.0
    }
    
    return 1.0 - (float64(metric.AverageLatency) / float64(maxLatency))
}
```

### Switching Rules Engine

```go
type SwitchingRule interface {
    ShouldSwitch(ctx context.Context, currentProvider Provider, metrics *ProviderMetrics, allMetrics map[string]*ProviderMetrics) bool
    Priority() int
    Name() string
}

// Performance degradation rule
type PerformanceDegradationRule struct {
    latencyThreshold   time.Duration
    successRateThreshold float64
    priority           int
}

func (pdr *PerformanceDegradationRule) ShouldSwitch(ctx context.Context, currentProvider Provider, metrics *ProviderMetrics, allMetrics map[string]*ProviderMetrics) bool {
    return metrics.AverageLatency > pdr.latencyThreshold || 
           metrics.SuccessRate < pdr.successRateThreshold
}

func (pdr *PerformanceDegradationRule) Priority() int { return pdr.priority }
func (pdr *PerformanceDegradationRule) Name() string { return "performance_degradation" }

// Cost optimization rule
type CostOptimizationRule struct {
    costSavingsThreshold float64
    minPerformanceDiff   float64
    priority            int
}

func (cor *CostOptimizationRule) ShouldSwitch(ctx context.Context, currentProvider Provider, metrics *ProviderMetrics, allMetrics map[string]*ProviderMetrics) bool {
    for _, otherMetrics := range allMetrics {
        // Skip current provider
        if otherMetrics == metrics {
            continue
        }
        
        // Find cheaper provider with similar performance
        for _, provider := range getAllProviders() {
            if provider.Name() == currentProvider.Name() {
                continue
            }
            
            providerMetrics := allMetrics[provider.Name()]
            if providerMetrics == nil {
                continue
            }
            
            costSavings := currentProvider.Cost() - provider.Cost()
            performanceDiff := metrics.SuccessRate - providerMetrics.SuccessRate
            
            if costSavings > cor.costSavingsThreshold && 
               performanceDiff < cor.minPerformanceDiff {
                return true
            }
        }
    }
    
    return false
}

// Geographic optimization rule
type GeographicRule struct {
    preferredRegion string
    latencyThreshold time.Duration
    priority        int
}

func (gr *GeographicRule) ShouldSwitch(ctx context.Context, currentProvider Provider, metrics *ProviderMetrics, allMetrics map[string]*ProviderMetrics) bool {
    userRegion := getUserRegion(ctx)
    if userRegion == "" {
        return false
    }
    
    // Check if there's a regional provider with better latency
    for providerName, providerMetrics := range allMetrics {
        if providerName == currentProvider.Name() {
            continue
        }
        
        if isProviderInRegion(providerName, userRegion) && 
           providerMetrics.AverageLatency < metrics.AverageLatency-gr.latencyThreshold {
            return true
        }
    }
    
    return false
}
```

### Real-World Provider Implementations

```go
// Payment provider example
type StripeProvider struct {
    client stripe.Client
    cost   float64
}

func (sp *StripeProvider) Execute(ctx context.Context, request interface{}) (interface{}, error) {
    paymentReq := request.(*PaymentRequest)
    
    // Execute Stripe payment
    payment, err := sp.client.CreatePayment(ctx, &stripe.PaymentParams{
        Amount:   paymentReq.Amount,
        Currency: paymentReq.Currency,
        Source:   paymentReq.Source,
    })
    
    if err != nil {
        return nil, fmt.Errorf("stripe payment failed: %w", err)
    }
    
    return &PaymentResponse{
        ID:     payment.ID,
        Status: payment.Status,
        Amount: payment.Amount,
    }, nil
}

func (sp *StripeProvider) Name() string { return "stripe" }
func (sp *StripeProvider) Cost() float64 { return sp.cost }
func (sp *StripeProvider) Priority() int { return 1 }

// PayPal provider example
type PayPalProvider struct {
    client paypal.Client
    cost   float64
}

func (pp *PayPalProvider) Execute(ctx context.Context, request interface{}) (interface{}, error) {
    paymentReq := request.(*PaymentRequest)
    
    // Execute PayPal payment
    payment, err := pp.client.CreatePayment(ctx, &paypal.Payment{
        Amount:   paymentReq.Amount,
        Currency: paymentReq.Currency,
    })
    
    if err != nil {
        return nil, fmt.Errorf("paypal payment failed: %w", err)
    }
    
    return &PaymentResponse{
        ID:     payment.ID,
        Status: payment.State,
        Amount: payment.Amount.Total,
    }, nil
}

func (pp *PayPalProvider) Name() string { return "paypal" }
func (pp *PayPalProvider) Cost() float64 { return pp.cost }
func (pp *PayPalProvider) Priority() int { return 2 }
```

### Monitoring and Metrics

```go
type MetricsMonitor struct {
    window     time.Duration
    dataPoints map[string][]*DataPoint
    mutex      sync.RWMutex
}

type DataPoint struct {
    Timestamp time.Time
    Success   bool
    Latency   time.Duration
    Error     error
}

func (mm *MetricsMonitor) RecordDataPoint(providerName string, success bool, latency time.Duration, err error) {
    mm.mutex.Lock()
    defer mm.mutex.Unlock()
    
    dataPoint := &DataPoint{
        Timestamp: time.Now(),
        Success:   success,
        Latency:   latency,
        Error:     err,
    }
    
    mm.dataPoints[providerName] = append(mm.dataPoints[providerName], dataPoint)
    
    // Clean old data points outside the window
    mm.cleanOldDataPoints(providerName)
}

func (mm *MetricsMonitor) CalculateMetrics(providerName string) *ProviderMetrics {
    mm.mutex.RLock()
    defer mm.mutex.RUnlock()
    
    dataPoints := mm.dataPoints[providerName]
    if len(dataPoints) == 0 {
        return &ProviderMetrics{}
    }
    
    var totalLatency time.Duration
    var successCount, totalCount int64
    var lastSuccess, lastFailure time.Time
    
    for _, dp := range dataPoints {
        totalCount++
        totalLatency += dp.Latency
        
        if dp.Success {
            successCount++
            if dp.Timestamp.After(lastSuccess) {
                lastSuccess = dp.Timestamp
            }
        } else {
            if dp.Timestamp.After(lastFailure) {
                lastFailure = dp.Timestamp
            }
        }
    }
    
    successRate := float64(successCount) / float64(totalCount)
    averageLatency := totalLatency / time.Duration(totalCount)
    
    return &ProviderMetrics{
        SuccessRate:    successRate,
        AverageLatency: averageLatency,
        ErrorCount:     totalCount - successCount,
        TotalRequests:  totalCount,
        LastSuccess:    lastSuccess,
        LastFailure:    lastFailure,
    }
}
```

### Configuration Examples

```yaml
# Production configuration
autoswitch:
  strategy: "weighted"
  
  # Circuit breaker settings
  failure_threshold: 5
  recovery_timeout: "30s"
  
  # Performance thresholds
  max_latency: "5s"
  min_success_rate: 0.95
  
  # Weighting for selection
  cost_weight: 0.3
  performance_weight: 0.4
  reliability_weight: 0.3
  
  # Monitoring
  metrics_window: "5m"
  health_check_interval: "30s"
  
  # Provider configurations
  providers:
    - name: "stripe"
      cost: 2.9  # percentage fee
      priority: 1
      config:
        api_key: "${STRIPE_API_KEY}"
        
    - name: "paypal"
      cost: 3.4  # percentage fee
      priority: 2
      config:
        client_id: "${PAYPAL_CLIENT_ID}"
        client_secret: "${PAYPAL_CLIENT_SECRET}"
        
    - name: "square"
      cost: 2.6  # percentage fee
      priority: 3
      config:
        access_token: "${SQUARE_ACCESS_TOKEN}"
```

### Usage Example

```go
func main() {
    // Initialize providers
    providers := []Provider{
        NewStripeProvider(stripeConfig),
        NewPayPalProvider(paypalConfig),
        NewSquareProvider(squareConfig),
    }
    
    // Configure auto-switcher
    config := &AutoSwitchConfig{
        Strategy:              StrategyCostOptimized,
        FailureThreshold:      5,
        RecoveryTimeout:       30 * time.Second,
        MaxLatency:           5 * time.Second,
        MinSuccessRate:       0.95,
        CostWeight:           0.3,
        PerformanceWeight:    0.4,
        ReliabilityWeight:    0.3,
        MetricsWindow:        5 * time.Minute,
        HealthCheckInterval:  30 * time.Second,
    }
    
    // Create auto-switcher
    switcher := NewAutoSwitcher(providers, config)
    
    // Process payment with automatic provider selection
    paymentRequest := &PaymentRequest{
        Amount:   1000, // $10.00
        Currency: "USD",
        Source:   "tok_visa",
    }
    
    result, err := switcher.Execute(context.Background(), paymentRequest)
    if err != nil {
        log.Printf("Payment failed: %v", err)
        return
    }
    
    payment := result.(*PaymentResponse)
    log.Printf("Payment successful: %s", payment.ID)
}
```

## Consequences

### Positive
- **Cost optimization**: Automatically uses cheapest provider when performance is acceptable
- **High availability**: Seamless failover when providers experience issues
- **Performance optimization**: Routes to fastest provider based on current conditions
- **Reduced manual intervention**: Automatic switching eliminates need for manual failover
- **Business intelligence**: Rich metrics for provider performance analysis

### Negative
- **Complexity**: Additional logic and monitoring infrastructure required
- **Potential instability**: Frequent switching could cause system instability
- **Debugging difficulty**: Harder to troubleshoot issues across multiple providers
- **Provider lock-in concerns**: May reduce negotiating power with individual providers
- **Configuration overhead**: Requires careful tuning of thresholds and weights

### Mitigation Strategies
- **Gradual rollout**: Start with simple switching rules and add complexity gradually
- **Comprehensive monitoring**: Track switching decisions and their outcomes
- **Fallback mechanisms**: Always have a reliable provider as ultimate fallback
- **Rate limiting**: Prevent excessive switching through minimum dwell times
- **Testing**: Thoroughly test switching logic under various failure scenarios

## Best Practices

1. **Start simple**: Begin with basic circuit breaker and add intelligence gradually
2. **Monitor extensively**: Track all provider metrics and switching decisions
3. **Test failure scenarios**: Simulate provider outages and validate switching behavior
4. **Document decisions**: Log why switches occurred for post-incident analysis
5. **Regular review**: Analyze switching patterns and optimize rules
6. **Provider diversity**: Ensure providers are sufficiently different to avoid correlated failures
7. **Business alignment**: Ensure switching logic aligns with business priorities
8. **Security considerations**: Validate that switching doesn't introduce security vulnerabilities

## References

- [Netflix Hystrix Circuit Breaker](https://github.com/Netflix/Hystrix)
- [AWS Multi-Region Architecture](https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-options-in-the-cloud.html)
- [Google SRE Load Balancing](https://sre.google/sre-book/load-balancing-frontend/)
- [Microsoft Failover Patterns](https://docs.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker)
- [Envoy Proxy Load Balancing](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/load_balancing)
