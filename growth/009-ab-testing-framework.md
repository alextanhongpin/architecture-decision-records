# A/B Testing Framework

## Status

`production`

## Context

A/B testing is the cornerstone of data-driven product development, enabling teams to make evidence-based decisions about features, user experience, and growth strategies. A robust A/B testing framework provides statistical rigor, reduces risk, and accelerates learning cycles.

This framework establishes standards for experiment design, execution, and analysis to ensure reliable results and actionable insights.

## Framework Architecture

### Core Components

```
Experiment Lifecycle: Design → Setup → Execution → Analysis → Decision → Implementation
```

### Statistical Foundation

```go
package abtesting

import (
    "context"
    "fmt"
    "math"
    "time"
    "encoding/json"
    "database/sql"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

type ExperimentStatus string

const (
    StatusDraft     ExperimentStatus = "draft"
    StatusActive    ExperimentStatus = "active"
    StatusPaused    ExperimentStatus = "paused"
    StatusCompleted ExperimentStatus = "completed"
    StatusStopped   ExperimentStatus = "stopped"
)

type ExperimentType string

const (
    TypeAB       ExperimentType = "ab"
    TypeMultivariate ExperimentType = "multivariate"
    TypeBandit   ExperimentType = "bandit"
    TypeFeatureFlag ExperimentType = "feature_flag"
)

type Experiment struct {
    ID                string                 `json:"id"`
    Name              string                 `json:"name"`
    Description       string                 `json:"description"`
    Type              ExperimentType         `json:"type"`
    Status            ExperimentStatus       `json:"status"`
    Hypothesis        string                 `json:"hypothesis"`
    SuccessMetrics    []Metric              `json:"success_metrics"`
    GuardrailMetrics  []Metric              `json:"guardrail_metrics"`
    Variants          []Variant             `json:"variants"`
    TrafficAllocation TrafficAllocation     `json:"traffic_allocation"`
    TargetAudience    TargetAudience        `json:"target_audience"`
    StartDate         time.Time             `json:"start_date"`
    EndDate           time.Time             `json:"end_date"`
    CreatedBy         string                `json:"created_by"`
    CreatedAt         time.Time             `json:"created_at"`
    UpdatedAt         time.Time             `json:"updated_at"`
    Results           *ExperimentResults    `json:"results,omitempty"`
}

type Metric struct {
    Name        string  `json:"name"`
    Type        string  `json:"type"`         // conversion, revenue, engagement, retention
    Description string  `json:"description"`
    Query       string  `json:"query"`        // SQL query or tracking event
    Direction   string  `json:"direction"`    // increase, decrease, neutral
    Threshold   float64 `json:"threshold"`    // minimum detectable effect
}

type Variant struct {
    ID           string                 `json:"id"`
    Name         string                 `json:"name"`
    Description  string                 `json:"description"`
    IsControl    bool                   `json:"is_control"`
    Config       map[string]interface{} `json:"config"`
    Weight       float64                `json:"weight"`       // 0-100
}

type TrafficAllocation struct {
    Percentage     float64           `json:"percentage"`      // % of total traffic
    Strategy       string            `json:"strategy"`        // random, sticky, geographic
    Filters        []AudienceFilter  `json:"filters"`
    Exclusions     []string          `json:"exclusions"`      // experiment IDs to exclude
}

type TargetAudience struct {
    Segments      []string          `json:"segments"`
    Countries     []string          `json:"countries"`
    DeviceTypes   []string          `json:"device_types"`
    UserTypes     []string          `json:"user_types"`     // new, returning, premium
    MinDaysActive int               `json:"min_days_active"`
    Filters       []AudienceFilter  `json:"filters"`
}

type AudienceFilter struct {
    Field     string      `json:"field"`
    Operator  string      `json:"operator"`
    Value     interface{} `json:"value"`
}

var (
    experimentsActive = promauto.NewGauge(prometheus.GaugeOpts{
        Name: "experiments_active_total",
        Help: "Number of active experiments",
    })
    
    experimentParticipants = promauto.NewGaugeVec(prometheus.GaugeOpts{
        Name: "experiment_participants_total",
        Help: "Number of participants in each experiment",
    }, []string{"experiment_id", "variant_id"})
    
    experimentConversions = promauto.NewCounterVec(prometheus.CounterOpts{
        Name: "experiment_conversions_total",
        Help: "Number of conversions by experiment and variant",
    }, []string{"experiment_id", "variant_id", "metric"})
)

type ABTestingFramework struct {
    db              *sql.DB
    assignmentStore AssignmentStore
    eventTracker    EventTracker
    statisticalEngine StatisticalEngine
    logger          Logger
}

func NewABTestingFramework(db *sql.DB) *ABTestingFramework {
    return &ABTestingFramework{
        db:                db,
        assignmentStore:   NewRedisAssignmentStore(),
        eventTracker:      NewEventTracker(),
        statisticalEngine: NewBayesianEngine(),
        logger:           NewLogger(),
    }
}

func (f *ABTestingFramework) CreateExperiment(ctx context.Context, experiment *Experiment) error {
    // Validate experiment design
    if err := f.validateExperiment(experiment); err != nil {
        return fmt.Errorf("experiment validation failed: %w", err)
    }
    
    // Check for overlapping experiments
    if err := f.checkExperimentOverlap(ctx, experiment); err != nil {
        return fmt.Errorf("experiment overlap detected: %w", err)
    }
    
    // Calculate required sample size
    sampleSize, err := f.calculateSampleSize(experiment)
    if err != nil {
        return fmt.Errorf("sample size calculation failed: %w", err)
    }
    
    experiment.ID = generateExperimentID()
    experiment.CreatedAt = time.Now()
    experiment.Status = StatusDraft
    
    // Store experiment
    query := `
        INSERT INTO experiments (id, name, description, type, status, hypothesis, 
                               success_metrics, guardrail_metrics, variants, 
                               traffic_allocation, target_audience, created_by, created_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
    `
    
    successMetrics, _ := json.Marshal(experiment.SuccessMetrics)
    guardrailMetrics, _ := json.Marshal(experiment.GuardrailMetrics)
    variants, _ := json.Marshal(experiment.Variants)
    trafficAllocation, _ := json.Marshal(experiment.TrafficAllocation)
    targetAudience, _ := json.Marshal(experiment.TargetAudience)
    
    _, err = f.db.ExecContext(ctx, query,
        experiment.ID, experiment.Name, experiment.Description, experiment.Type,
        experiment.Status, experiment.Hypothesis, successMetrics, guardrailMetrics,
        variants, trafficAllocation, targetAudience, experiment.CreatedBy, experiment.CreatedAt)
    
    if err != nil {
        return fmt.Errorf("failed to create experiment: %w", err)
    }
    
    f.logger.Info("experiment created", "experiment_id", experiment.ID, 
                  "sample_size_required", sampleSize)
    
    return nil
}

func (f *ABTestingFramework) AssignUserToVariant(ctx context.Context, 
    userID string, experimentID string) (*Assignment, error) {
    
    // Check if user already assigned
    if assignment := f.assignmentStore.GetAssignment(userID, experimentID); assignment != nil {
        return assignment, nil
    }
    
    // Get experiment
    experiment, err := f.getExperiment(ctx, experimentID)
    if err != nil {
        return nil, fmt.Errorf("failed to get experiment: %w", err)
    }
    
    // Check if experiment is active
    if experiment.Status != StatusActive {
        return nil, fmt.Errorf("experiment is not active")
    }
    
    // Check if user qualifies for experiment
    qualifies, err := f.userQualifies(ctx, userID, experiment)
    if err != nil {
        return nil, fmt.Errorf("failed to check user qualification: %w", err)
    }
    
    if !qualifies {
        return nil, fmt.Errorf("user does not qualify for experiment")
    }
    
    // Assign variant using consistent hashing
    variantID := f.assignVariant(userID, experiment)
    
    assignment := &Assignment{
        UserID:       userID,
        ExperimentID: experimentID,
        VariantID:    variantID,
        AssignedAt:   time.Now(),
    }
    
    // Store assignment
    f.assignmentStore.StoreAssignment(assignment)
    
    // Track assignment event
    f.eventTracker.Track(AssignmentEvent{
        UserID:       userID,
        ExperimentID: experimentID,
        VariantID:    variantID,
        Timestamp:    time.Now(),
    })
    
    // Update metrics
    experimentParticipants.WithLabelValues(experimentID, variantID).Inc()
    
    return assignment, nil
}

func (f *ABTestingFramework) assignVariant(userID string, experiment *Experiment) string {
    // Use consistent hashing for stable assignments
    hash := f.hashUser(userID, experiment.ID)
    
    // Convert hash to percentage (0-100)
    percentage := float64(hash%10000) / 100.0
    
    // Find variant based on cumulative weights
    cumulative := 0.0
    for _, variant := range experiment.Variants {
        cumulative += variant.Weight
        if percentage <= cumulative {
            return variant.ID
        }
    }
    
    // Fallback to control
    for _, variant := range experiment.Variants {
        if variant.IsControl {
            return variant.ID
        }
    }
    
    return experiment.Variants[0].ID
}

type Assignment struct {
    UserID       string    `json:"user_id"`
    ExperimentID string    `json:"experiment_id"`
    VariantID    string    `json:"variant_id"`
    AssignedAt   time.Time `json:"assigned_at"`
}

type AssignmentEvent struct {
    UserID       string    `json:"user_id"`
    ExperimentID string    `json:"experiment_id"`
    VariantID    string    `json:"variant_id"`
    Timestamp    time.Time `json:"timestamp"`
}

type ConversionEvent struct {
    UserID       string    `json:"user_id"`
    ExperimentID string    `json:"experiment_id"`
    VariantID    string    `json:"variant_id"`
    MetricName   string    `json:"metric_name"`
    Value        float64   `json:"value"`
    Timestamp    time.Time `json:"timestamp"`
}
```

### Statistical Analysis Engine

```go
type StatisticalEngine interface {
    CalculateResults(ctx context.Context, experimentID string) (*ExperimentResults, error)
    CheckSignificance(results *ExperimentResults) bool
    EstimateRemainingTime(results *ExperimentResults, targetPower float64) time.Duration
}

type ExperimentResults struct {
    ExperimentID     string                    `json:"experiment_id"`
    AnalysisDate     time.Time                 `json:"analysis_date"`
    SampleSizes      map[string]int64          `json:"sample_sizes"`
    MetricResults    map[string]*MetricResult  `json:"metric_results"`
    Significance     bool                      `json:"significance"`
    Confidence       float64                   `json:"confidence"`
    Effect           float64                   `json:"effect"`
    PValue           float64                   `json:"p_value"`
    EstimatedEndDate time.Time                 `json:"estimated_end_date"`
    Recommendation   string                    `json:"recommendation"`
}

type MetricResult struct {
    MetricName      string                        `json:"metric_name"`
    VariantResults  map[string]*VariantResult     `json:"variant_results"`
    Winner          string                        `json:"winner"`
    Significance    bool                          `json:"significance"`
    EffectSize      float64                       `json:"effect_size"`
    ConfidenceInterval ConfidenceInterval         `json:"confidence_interval"`
}

type VariantResult struct {
    VariantID      string  `json:"variant_id"`
    SampleSize     int64   `json:"sample_size"`
    Conversions    int64   `json:"conversions"`
    ConversionRate float64 `json:"conversion_rate"`
    Revenue        float64 `json:"revenue"`
    RevenuePerUser float64 `json:"revenue_per_user"`
    StandardError  float64 `json:"standard_error"`
}

type ConfidenceInterval struct {
    Lower float64 `json:"lower"`
    Upper float64 `json:"upper"`
}

type BayesianEngine struct {
    db     *sql.DB
    logger Logger
}

func (e *BayesianEngine) CalculateResults(ctx context.Context, 
    experimentID string) (*ExperimentResults, error) {
    
    // Get experiment data
    experiment, err := e.getExperiment(ctx, experimentID)
    if err != nil {
        return nil, fmt.Errorf("failed to get experiment: %w", err)
    }
    
    results := &ExperimentResults{
        ExperimentID:  experimentID,
        AnalysisDate:  time.Now(),
        SampleSizes:   make(map[string]int64),
        MetricResults: make(map[string]*MetricResult),
    }
    
    // Calculate results for each success metric
    for _, metric := range experiment.SuccessMetrics {
        metricResult, err := e.calculateMetricResult(ctx, experimentID, metric)
        if err != nil {
            e.logger.Error("failed to calculate metric result", 
                          "metric", metric.Name, "error", err)
            continue
        }
        
        results.MetricResults[metric.Name] = metricResult
    }
    
    // Determine overall significance
    results.Significance = e.isStatisticallySignificant(results.MetricResults)
    
    // Generate recommendation
    results.Recommendation = e.generateRecommendation(results)
    
    return results, nil
}

func (e *BayesianEngine) calculateMetricResult(ctx context.Context, 
    experimentID string, metric Metric) (*MetricResult, error) {
    
    variantResults := make(map[string]*VariantResult)
    
    // Query data for each variant
    query := `
        SELECT 
            v.variant_id,
            COUNT(DISTINCT a.user_id) as sample_size,
            COUNT(e.user_id) as conversions,
            COALESCE(SUM(e.value), 0) as total_revenue
        FROM assignments a
        JOIN variants v ON a.variant_id = v.id
        LEFT JOIN conversion_events e ON a.user_id = e.user_id 
            AND e.experiment_id = a.experiment_id 
            AND e.metric_name = $2
        WHERE a.experiment_id = $1
        GROUP BY v.variant_id
    `
    
    rows, err := e.db.QueryContext(ctx, query, experimentID, metric.Name)
    if err != nil {
        return nil, fmt.Errorf("failed to query metric data: %w", err)
    }
    defer rows.Close()
    
    for rows.Next() {
        var variantID string
        var sampleSize, conversions int64
        var totalRevenue float64
        
        err := rows.Scan(&variantID, &sampleSize, &conversions, &totalRevenue)
        if err != nil {
            return nil, fmt.Errorf("failed to scan variant data: %w", err)
        }
        
        conversionRate := 0.0
        revenuePerUser := 0.0
        
        if sampleSize > 0 {
            conversionRate = float64(conversions) / float64(sampleSize)
            revenuePerUser = totalRevenue / float64(sampleSize)
        }
        
        variantResults[variantID] = &VariantResult{
            VariantID:      variantID,
            SampleSize:     sampleSize,
            Conversions:    conversions,
            ConversionRate: conversionRate,
            Revenue:        totalRevenue,
            RevenuePerUser: revenuePerUser,
            StandardError:  e.calculateStandardError(conversionRate, sampleSize),
        }
    }
    
    metricResult := &MetricResult{
        MetricName:     metric.Name,
        VariantResults: variantResults,
    }
    
    // Calculate significance using Bayesian methods
    metricResult.Significance = e.calculateBayesianSignificance(variantResults)
    metricResult.Winner = e.determineWinner(variantResults)
    metricResult.EffectSize = e.calculateEffectSize(variantResults)
    metricResult.ConfidenceInterval = e.calculateConfidenceInterval(variantResults)
    
    return metricResult, nil
}

func (e *BayesianEngine) calculateBayesianSignificance(variants map[string]*VariantResult) bool {
    // Implement Bayesian significance testing
    // This is a simplified example - real implementation would use proper Bayesian methods
    
    var control, treatment *VariantResult
    
    for _, variant := range variants {
        if variant.VariantID == "control" {
            control = variant
        } else {
            treatment = variant
        }
    }
    
    if control == nil || treatment == nil {
        return false
    }
    
    // Simple z-test for demonstration
    // Real implementation should use Bayesian posterior distributions
    if control.SampleSize < 100 || treatment.SampleSize < 100 {
        return false // Insufficient sample size
    }
    
    pooledSE := math.Sqrt(
        (control.ConversionRate*(1-control.ConversionRate))/float64(control.SampleSize) +
        (treatment.ConversionRate*(1-treatment.ConversionRate))/float64(treatment.SampleSize),
    )
    
    if pooledSE == 0 {
        return false
    }
    
    zScore := math.Abs(treatment.ConversionRate-control.ConversionRate) / pooledSE
    
    // Z-score > 1.96 corresponds to 95% confidence
    return zScore > 1.96
}
```

### Experiment Management Interface

```go
type ExperimentManager struct {
    framework *ABTestingFramework
    scheduler *ExperimentScheduler
    alerting  *AlertingService
}

func (m *ExperimentManager) StartExperiment(ctx context.Context, experimentID string) error {
    experiment, err := m.framework.getExperiment(ctx, experimentID)
    if err != nil {
        return fmt.Errorf("failed to get experiment: %w", err)
    }
    
    // Pre-flight checks
    if err := m.preFlightChecks(ctx, experiment); err != nil {
        return fmt.Errorf("pre-flight checks failed: %w", err)
    }
    
    // Update status to active
    experiment.Status = StatusActive
    experiment.StartDate = time.Now()
    
    err = m.framework.updateExperiment(ctx, experiment)
    if err != nil {
        return fmt.Errorf("failed to update experiment: %w", err)
    }
    
    // Set up monitoring
    m.setupMonitoring(experiment)
    
    // Schedule analysis
    m.scheduler.ScheduleAnalysis(experiment)
    
    experimentsActive.Inc()
    
    m.framework.logger.Info("experiment started", 
                           "experiment_id", experimentID)
    
    return nil
}

func (m *ExperimentManager) StopExperiment(ctx context.Context, 
    experimentID string, reason string) error {
    
    experiment, err := m.framework.getExperiment(ctx, experimentID)
    if err != nil {
        return fmt.Errorf("failed to get experiment: %w", err)
    }
    
    // Generate final results
    results, err := m.framework.statisticalEngine.CalculateResults(ctx, experimentID)
    if err != nil {
        m.framework.logger.Error("failed to generate final results", 
                                "experiment_id", experimentID, "error", err)
    } else {
        experiment.Results = results
    }
    
    // Update status
    experiment.Status = StatusCompleted
    experiment.EndDate = time.Now()
    
    err = m.framework.updateExperiment(ctx, experiment)
    if err != nil {
        return fmt.Errorf("failed to update experiment: %w", err)
    }
    
    // Clean up monitoring
    m.cleanupMonitoring(experiment)
    
    experimentsActive.Dec()
    
    m.framework.logger.Info("experiment stopped", 
                           "experiment_id", experimentID, "reason", reason)
    
    return nil
}

func (m *ExperimentManager) preFlightChecks(ctx context.Context, 
    experiment *Experiment) error {
    
    // Check for overlapping experiments
    overlaps, err := m.findOverlappingExperiments(ctx, experiment)
    if err != nil {
        return fmt.Errorf("failed to check overlaps: %w", err)
    }
    
    if len(overlaps) > 0 {
        return fmt.Errorf("experiment overlaps with: %v", overlaps)
    }
    
    // Validate tracking setup
    if err := m.validateTracking(experiment); err != nil {
        return fmt.Errorf("tracking validation failed: %w", err)
    }
    
    // Check traffic allocation
    totalWeight := 0.0
    for _, variant := range experiment.Variants {
        totalWeight += variant.Weight
    }
    
    if totalWeight > 100.0 {
        return fmt.Errorf("total variant weight exceeds 100%%: %.2f", totalWeight)
    }
    
    return nil
}
```

## Best Practices

### Experiment Design

1. **Clear Hypothesis**: State measurable, testable predictions
2. **Single Variable**: Test one change at a time (for A/B tests)
3. **Sufficient Sample Size**: Calculate required participants before starting
4. **Guard Rails**: Define metrics that shouldn't degrade

### Statistical Rigor

1. **Pre-Registration**: Define success criteria before starting
2. **Multiple Testing**: Adjust for multiple comparisons
3. **Minimum Effect Size**: Set meaningful thresholds
4. **Power Analysis**: Ensure adequate statistical power

### Operational Excellence

1. **Monitoring**: Track experiment health and data quality
2. **Early Stopping**: Define conditions for stopping experiments
3. **Segmented Analysis**: Analyze results by user segments
4. **Documentation**: Record decisions and learnings

## Common Pitfalls

1. **Peeking**: Stopping experiments based on preliminary results
2. **HARKing**: Hypothesizing after results are known
3. **Selection Bias**: Non-representative user samples
4. **Novelty Effect**: Temporary behavior changes from new features

## Implementation Checklist

- [ ] Statistical framework implementation
- [ ] User assignment system
- [ ] Event tracking infrastructure
- [ ] Analysis and reporting tools
- [ ] Monitoring and alerting
- [ ] Documentation and training

## Success Metrics

- **Experiment Velocity**: Number of experiments per quarter
- **Statistical Power**: Percentage of experiments with sufficient power
- **Learning Rate**: Insights generated per experiment
- **Implementation Rate**: Percentage of winning variants implemented

## Consequences

**Benefits:**
- Data-driven decision making
- Reduced risk of feature failures
- Continuous product optimization
- Quantified user impact

**Challenges:**
- Complex technical infrastructure
- Statistical expertise requirements
- Longer development cycles
- Potential for analysis paralysis

**Trade-offs:**
- Speed vs. statistical rigor
- Simple vs. sophisticated analysis
- Resource investment vs. learning value
