# A/B Testing Architecture

## Status

`draft`

## Context

A/B testing is a method of comparing two versions of a feature to determine which performs better. This requires careful architecture to ensure statistical validity, user consistency, and minimal performance impact.

Key requirements:
- Consistent user experience within test groups
- Statistical significance calculations
- Real-time metrics collection
- Feature flag integration
- Experiment management and rollout control

## Decisions

### Core A/B Testing Engine

```go
type ABTestEngine struct {
    experiments map[string]*Experiment
    userService UserService
    metrics     MetricsCollector
    hasher      ConsistentHasher
    mutex       sync.RWMutex
}

type Experiment struct {
    ID          string                 `json:"id"`
    Name        string                 `json:"name"`
    Status      ExperimentStatus       `json:"status"`
    Variants    []Variant              `json:"variants"`
    Targeting   TargetingRules         `json:"targeting"`
    StartDate   time.Time              `json:"start_date"`
    EndDate     time.Time              `json:"end_date"`
    SampleSize  int                    `json:"sample_size"`
    Metrics     []string               `json:"metrics"`
    CreatedAt   time.Time              `json:"created_at"`
    UpdatedAt   time.Time              `json:"updated_at"`
}

type Variant struct {
    ID          string                 `json:"id"`
    Name        string                 `json:"name"`
    Weight      float64                `json:"weight"` // 0.0 to 1.0
    Config      map[string]interface{} `json:"config"`
    IsControl   bool                   `json:"is_control"`
}

type ExperimentStatus string

const (
    ExperimentStatusDraft   ExperimentStatus = "draft"
    ExperimentStatusActive  ExperimentStatus = "active"
    ExperimentStatusPaused  ExperimentStatus = "paused"
    ExperimentStatusEnded   ExperimentStatus = "ended"
)

func NewABTestEngine(userService UserService, metrics MetricsCollector) *ABTestEngine {
    return &ABTestEngine{
        experiments: make(map[string]*Experiment),
        userService: userService,
        metrics:     metrics,
        hasher:      NewConsistentHasher(),
    }
}

func (engine *ABTestEngine) GetVariant(experimentID, userID string) (*Variant, error) {
    engine.mutex.RLock()
    experiment, exists := engine.experiments[experimentID]
    engine.mutex.RUnlock()
    
    if !exists {
        return nil, fmt.Errorf("experiment not found: %s", experimentID)
    }
    
    if experiment.Status != ExperimentStatusActive {
        return engine.getControlVariant(experiment), nil
    }
    
    // Check if user is eligible for experiment
    eligible, err := engine.isUserEligible(userID, experiment)
    if err != nil {
        return nil, err
    }
    
    if !eligible {
        return engine.getControlVariant(experiment), nil
    }
    
    // Use consistent hashing to assign variant
    hash := engine.hasher.Hash(fmt.Sprintf("%s:%s", experimentID, userID))
    
    // Determine variant based on weights
    variant := engine.selectVariantByWeight(experiment, hash)
    
    // Track assignment
    engine.trackAssignment(experimentID, userID, variant.ID)
    
    return variant, nil
}

func (engine *ABTestEngine) selectVariantByWeight(experiment *Experiment, hash uint32) *Variant {
    // Convert hash to 0-1 range
    hashFloat := float64(hash) / float64(^uint32(0))
    
    var cumulative float64
    for _, variant := range experiment.Variants {
        cumulative += variant.Weight
        if hashFloat <= cumulative {
            return &variant
        }
    }
    
    // Fallback to control
    return engine.getControlVariant(experiment)
}

func (engine *ABTestEngine) getControlVariant(experiment *Experiment) *Variant {
    for _, variant := range experiment.Variants {
        if variant.IsControl {
            return &variant
        }
    }
    // Return first variant if no control is explicitly marked
    if len(experiment.Variants) > 0 {
        return &experiment.Variants[0]
    }
    return nil
}

func (engine *ABTestEngine) isUserEligible(userID string, experiment *Experiment) (bool, error) {
    user, err := engine.userService.GetUser(userID)
    if err != nil {
        return false, err
    }
    
    // Check targeting rules
    return engine.evaluateTargeting(user, experiment.Targeting), nil
}

func (engine *ABTestEngine) trackAssignment(experimentID, userID, variantID string) {
    assignment := Assignment{
        ExperimentID: experimentID,
        UserID:       userID,
        VariantID:    variantID,
        AssignedAt:   time.Now(),
    }
    
    // Record assignment for analysis
    engine.metrics.RecordEvent("experiment_assignment", map[string]interface{}{
        "experiment_id": experimentID,
        "user_id":       userID,
        "variant_id":    variantID,
        "timestamp":     assignment.AssignedAt,
    })
}
```

### Targeting and Segmentation System

```go
type TargetingRules struct {
    IncludeRules []Rule `json:"include_rules"`
    ExcludeRules []Rule `json:"exclude_rules"`
}

type Rule struct {
    Field     string      `json:"field"`
    Operator  string      `json:"operator"`
    Value     interface{} `json:"value"`
    Values    []interface{} `json:"values,omitempty"`
}

type User struct {
    ID         string                 `json:"id"`
    Email      string                 `json:"email"`
    Country    string                 `json:"country"`
    Platform   string                 `json:"platform"`
    Version    string                 `json:"version"`
    Attributes map[string]interface{} `json:"attributes"`
    CreatedAt  time.Time              `json:"created_at"`
}

func (engine *ABTestEngine) evaluateTargeting(user *User, targeting TargetingRules) bool {
    // Must satisfy all include rules
    for _, rule := range targeting.IncludeRules {
        if !engine.evaluateRule(user, rule) {
            return false
        }
    }
    
    // Must not satisfy any exclude rules
    for _, rule := range targeting.ExcludeRules {
        if engine.evaluateRule(user, rule) {
            return false
        }
    }
    
    return true
}

func (engine *ABTestEngine) evaluateRule(user *User, rule Rule) bool {
    var fieldValue interface{}
    
    // Get field value from user
    switch rule.Field {
    case "country":
        fieldValue = user.Country
    case "platform":
        fieldValue = user.Platform
    case "version":
        fieldValue = user.Version
    case "created_at":
        fieldValue = user.CreatedAt
    default:
        if val, exists := user.Attributes[rule.Field]; exists {
            fieldValue = val
        } else {
            return false
        }
    }
    
    // Evaluate based on operator
    switch rule.Operator {
    case "equals":
        return fieldValue == rule.Value
    case "not_equals":
        return fieldValue != rule.Value
    case "in":
        for _, val := range rule.Values {
            if fieldValue == val {
                return true
            }
        }
        return false
    case "not_in":
        for _, val := range rule.Values {
            if fieldValue == val {
                return false
            }
        }
        return true
    case "greater_than":
        return compareValues(fieldValue, rule.Value) > 0
    case "less_than":
        return compareValues(fieldValue, rule.Value) < 0
    case "contains":
        str, ok := fieldValue.(string)
        if !ok {
            return false
        }
        searchStr, ok := rule.Value.(string)
        if !ok {
            return false
        }
        return strings.Contains(str, searchStr)
    }
    
    return false
}
```

### Metrics Collection and Analysis

```go
type MetricsCollector interface {
    RecordEvent(eventName string, properties map[string]interface{})
    RecordConversion(experimentID, userID, variantID, metric string, value float64)
    GetExperimentResults(experimentID string) (*ExperimentResults, error)
}

type ExperimentResults struct {
    ExperimentID string                    `json:"experiment_id"`
    Status       ExperimentStatus          `json:"status"`
    Variants     []VariantResults          `json:"variants"`
    StartDate    time.Time                 `json:"start_date"`
    EndDate      time.Time                 `json:"end_date"`
    TotalUsers   int                       `json:"total_users"`
    Confidence   float64                   `json:"confidence"`
    Winner       string                    `json:"winner,omitempty"`
}

type VariantResults struct {
    VariantID       string              `json:"variant_id"`
    Name            string              `json:"name"`
    Users           int                 `json:"users"`
    Conversions     int                 `json:"conversions"`
    ConversionRate  float64             `json:"conversion_rate"`
    Revenue         float64             `json:"revenue"`
    Metrics         map[string]float64  `json:"metrics"`
    StatSignificant bool                `json:"statistically_significant"`
}

type RedisMetricsCollector struct {
    client redis.Client
    db     *sql.DB
}

func (rmc *RedisMetricsCollector) RecordConversion(experimentID, userID, variantID, metric string, value float64) {
    // Real-time tracking in Redis
    pipe := rmc.client.Pipeline()
    
    // Increment conversion count
    conversionKey := fmt.Sprintf("exp:%s:variant:%s:conversions:%s", experimentID, variantID, metric)
    pipe.Incr(context.Background(), conversionKey)
    
    // Add to conversion value
    valueKey := fmt.Sprintf("exp:%s:variant:%s:value:%s", experimentID, variantID, metric)
    pipe.IncrByFloat(context.Background(), valueKey, value)
    
    // Track unique users
    userKey := fmt.Sprintf("exp:%s:variant:%s:users", experimentID, variantID)
    pipe.SAdd(context.Background(), userKey, userID)
    
    pipe.Exec(context.Background())
    
    // Also store in database for long-term analysis
    go rmc.storeConversionEvent(experimentID, userID, variantID, metric, value)
}

func (rmc *RedisMetricsCollector) GetExperimentResults(experimentID string) (*ExperimentResults, error) {
    // Get experiment metadata
    experiment, err := rmc.getExperiment(experimentID)
    if err != nil {
        return nil, err
    }
    
    results := &ExperimentResults{
        ExperimentID: experimentID,
        Status:       experiment.Status,
        StartDate:    experiment.StartDate,
        EndDate:      experiment.EndDate,
        Variants:     make([]VariantResults, 0, len(experiment.Variants)),
    }
    
    var totalUsers int
    
    for _, variant := range experiment.Variants {
        variantResult, err := rmc.getVariantResults(experimentID, variant.ID)
        if err != nil {
            return nil, err
        }
        
        results.Variants = append(results.Variants, *variantResult)
        totalUsers += variantResult.Users
    }
    
    results.TotalUsers = totalUsers
    
    // Calculate statistical significance
    if len(results.Variants) >= 2 {
        results.Confidence, results.Winner = rmc.calculateStatisticalSignificance(results.Variants)
    }
    
    return results, nil
}

func (rmc *RedisMetricsCollector) getVariantResults(experimentID, variantID string) (*VariantResults, error) {
    ctx := context.Background()
    
    // Get user count
    userKey := fmt.Sprintf("exp:%s:variant:%s:users", experimentID, variantID)
    userCount := rmc.client.SCard(ctx, userKey).Val()
    
    // Get conversion metrics
    conversionKey := fmt.Sprintf("exp:%s:variant:%s:conversions:primary", experimentID, variantID)
    conversions := rmc.client.Get(ctx, conversionKey).Val()
    
    valueKey := fmt.Sprintf("exp:%s:variant:%s:value:revenue", experimentID, variantID)
    revenue := rmc.client.Get(ctx, valueKey).Val()
    
    conversionCount, _ := strconv.Atoi(conversions)
    revenueValue, _ := strconv.ParseFloat(revenue, 64)
    
    var conversionRate float64
    if userCount > 0 {
        conversionRate = float64(conversionCount) / float64(userCount)
    }
    
    return &VariantResults{
        VariantID:      variantID,
        Users:          int(userCount),
        Conversions:    conversionCount,
        ConversionRate: conversionRate,
        Revenue:        revenueValue,
        Metrics:        make(map[string]float64),
    }, nil
}
```

### Statistical Significance Calculation

```go
import (
    "math"
    "gonum.org/v1/gonum/stat/distuv"
)

func (rmc *RedisMetricsCollector) calculateStatisticalSignificance(variants []VariantResults) (float64, string) {
    if len(variants) < 2 {
        return 0, ""
    }
    
    // Find control and treatment
    var control, treatment *VariantResults
    for i := range variants {
        if variants[i].VariantID == "control" || i == 0 {
            control = &variants[i]
        } else {
            treatment = &variants[i]
            break
        }
    }
    
    if control == nil || treatment == nil {
        return 0, ""
    }
    
    // Two-proportion z-test
    p1 := control.ConversionRate
    p2 := treatment.ConversionRate
    n1 := float64(control.Users)
    n2 := float64(treatment.Users)
    
    if n1 == 0 || n2 == 0 {
        return 0, ""
    }
    
    // Pooled proportion
    pPooled := (p1*n1 + p2*n2) / (n1 + n2)
    
    // Standard error
    se := math.Sqrt(pPooled * (1 - pPooled) * (1/n1 + 1/n2))
    
    if se == 0 {
        return 0, ""
    }
    
    // Z-score
    z := (p2 - p1) / se
    
    // P-value (two-tailed test)
    normal := distuv.Normal{Mu: 0, Sigma: 1}
    pValue := 2 * (1 - normal.CDF(math.Abs(z)))
    
    confidence := (1 - pValue) * 100
    
    var winner string
    if pValue < 0.05 { // 95% confidence
        if p2 > p1 {
            winner = treatment.VariantID
        } else {
            winner = control.VariantID
        }
    }
    
    return confidence, winner
}

// Sample size calculation
func CalculateRequiredSampleSize(baseConversionRate, minimumDetectableEffect, alpha, beta float64) int {
    // Standard normal distribution critical values
    zAlpha := 1.96  // For alpha = 0.05 (95% confidence)
    zBeta := 0.84   // For beta = 0.2 (80% power)
    
    p1 := baseConversionRate
    p2 := baseConversionRate * (1 + minimumDetectableEffect)
    
    pAvg := (p1 + p2) / 2
    
    numerator := math.Pow(zAlpha*math.Sqrt(2*pAvg*(1-pAvg)) + zBeta*math.Sqrt(p1*(1-p1)+p2*(1-p2)), 2)
    denominator := math.Pow(p2-p1, 2)
    
    return int(math.Ceil(numerator / denominator))
}
```

### Integration with Feature Flags

```go
type FeatureFlagABTestEngine struct {
    abEngine    *ABTestEngine
    flagService FeatureFlagService
}

func (engine *FeatureFlagABTestEngine) IsFeatureEnabled(featureName, userID string) bool {
    // Check if there's an active experiment for this feature
    experimentID := fmt.Sprintf("feature_%s", featureName)
    
    variant, err := engine.abEngine.GetVariant(experimentID, userID)
    if err != nil {
        // Fallback to feature flag service
        return engine.flagService.IsEnabled(featureName, userID)
    }
    
    // Check variant configuration
    if enabled, ok := variant.Config["enabled"].(bool); ok {
        return enabled
    }
    
    return false
}

func (engine *FeatureFlagABTestEngine) GetFeatureConfig(featureName, userID string) map[string]interface{} {
    experimentID := fmt.Sprintf("feature_%s", featureName)
    
    variant, err := engine.abEngine.GetVariant(experimentID, userID)
    if err != nil {
        return engine.flagService.GetConfig(featureName, userID)
    }
    
    return variant.Config
}
```

## Consequences

### Benefits
- **Statistical rigor**: Proper significance testing ensures reliable results
- **Consistent user experience**: Users see same variant throughout experiment
- **Real-time insights**: Immediate feedback on experiment performance
- **Flexible targeting**: Can target specific user segments
- **Integration ready**: Works with existing feature flag systems

### Challenges
- **Complexity**: Statistical analysis requires domain expertise
- **Performance**: Additional latency for variant assignment
- **Data quality**: Requires careful event tracking and data validation
- **Sample size**: Need sufficient traffic for statistical significance

### Best Practices
- Define success metrics before starting experiments
- Ensure statistical significance before making decisions
- Run experiments for full business cycles
- Monitor for novelty effects and external factors
- Document experiment hypotheses and learnings
- Use proper randomization techniques
- Implement proper tracking and attribution
- Consider interaction effects between experiments

### References
- https://vanity.labnotes.org/ab_testing.html
- https://www.refurbed.org/posts/refbwebd-cache/
- https://www.algolia.com/blog/engineering/a-b-testing-metrics-evaluating-the-best-metrics-for-your-search/
- https://vwo.com/ab-testing/
- https://www.optimizely.com/insights/blog/how-to-calculate-sample-size-of-ab-tests/

