# Infrastructure Right-Sizing

## Status
**Accepted** - 2024-01-25

## Context
Infrastructure over-provisioning is one of the leading causes of cloud waste, with studies showing that 30-50% of cloud resources are oversized for their actual workloads. Organizations often provision for peak capacity or worst-case scenarios, leading to significant underutilization during normal operations.

## Problem Statement
Teams struggle with:
- Determining optimal instance sizes without performance impact
- Understanding actual resource utilization patterns
- Balancing cost optimization with performance requirements
- Implementing right-sizing decisions across complex multi-service architectures
- Measuring the impact of right-sizing changes on application performance

## Decision
Implement comprehensive infrastructure right-sizing through continuous monitoring, automated analysis, and intelligent recommendations with safety guardrails.

## Implementation

### 1. Resource Utilization Monitoring

```go
// Infrastructure monitoring and analysis system
package rightsizing

import (
    "context"
    "fmt"
    "math"
    "sort"
    "time"
    
    "github.com/aws/aws-sdk-go-v2/service/cloudwatch"
    "github.com/aws/aws-sdk-go-v2/service/ec2"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

type ResourceType string

const (
    EC2Instance ResourceType = "ec2"
    RDSInstance ResourceType = "rds"
    ECSService  ResourceType = "ecs"
    EKSPod      ResourceType = "eks"
    Lambda      ResourceType = "lambda"
)

type UtilizationMetrics struct {
    ResourceID       string                 `json:"resource_id"`
    ResourceType     ResourceType           `json:"resource_type"`
    InstanceType     string                 `json:"instance_type"`
    CPUUtilization   UtilizationStats       `json:"cpu_utilization"`
    MemoryUtilization UtilizationStats      `json:"memory_utilization"`
    NetworkUtilization UtilizationStats     `json:"network_utilization"`
    DiskUtilization  UtilizationStats       `json:"disk_utilization"`
    CurrentCost      float64                `json:"current_monthly_cost"`
    Tags             map[string]string      `json:"tags"`
    MonitoringPeriod int                    `json:"monitoring_period_days"`
    LastUpdated      time.Time              `json:"last_updated"`
}

type UtilizationStats struct {
    Average    float64   `json:"average"`
    Max        float64   `json:"max"`
    Min        float64   `json:"min"`
    P95        float64   `json:"p95"`
    P99        float64   `json:"p99"`
    StdDev     float64   `json:"std_dev"`
    DataPoints []float64 `json:"data_points,omitempty"`
}

var (
    resourceUtilization = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "resource_utilization_percent",
            Help: "Resource utilization percentage",
        },
        []string{"resource_id", "resource_type", "metric_type", "statistic"},
    )
    
    rightsizingOpportunity = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "rightsizing_potential_savings_usd",
            Help: "Potential monthly savings from right-sizing",
        },
        []string{"resource_id", "resource_type", "current_type", "recommended_type"},
    )
    
    resourceEfficiency = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "resource_efficiency_score",
            Help: "Resource efficiency score (0-100)",
        },
        []string{"resource_id", "resource_type", "team", "environment"},
    )
)

type ResourceMonitor struct {
    cloudwatchClient *cloudwatch.Client
    ec2Client       *ec2.Client
    pricingData     map[string]InstancePricing
}

type InstancePricing struct {
    InstanceType    string  `json:"instance_type"`
    vCPUs          int     `json:"vcpus"`
    MemoryGB       float64 `json:"memory_gb"`
    NetworkPerf    string  `json:"network_performance"`
    HourlyPrice    float64 `json:"hourly_price"`
    MonthlyPrice   float64 `json:"monthly_price"`
}

func NewResourceMonitor(cwClient *cloudwatch.Client, ec2Client *ec2.Client) *ResourceMonitor {
    monitor := &ResourceMonitor{
        cloudwatchClient: cwClient,
        ec2Client:       ec2Client,
        pricingData:     make(map[string]InstancePricing),
    }
    
    // Load pricing data
    monitor.loadPricingData()
    return monitor
}

func (rm *ResourceMonitor) loadPricingData() {
    // Sample EC2 pricing data (US East 1, On-Demand, as of 2024)
    pricing := []InstancePricing{
        // General Purpose
        {"t3.nano", 2, 0.5, "Low to Moderate", 0.0052, 3.796},
        {"t3.micro", 2, 1, "Low to Moderate", 0.0104, 7.592},
        {"t3.small", 2, 2, "Low to Moderate", 0.0208, 15.184},
        {"t3.medium", 2, 4, "Low to Moderate", 0.0416, 30.368},
        {"t3.large", 2, 8, "Low to Moderate", 0.0832, 60.736},
        {"t3.xlarge", 4, 16, "Low to Moderate", 0.1664, 121.472},
        {"t3.2xlarge", 8, 32, "Low to Moderate", 0.3328, 242.944},
        
        {"m5.large", 2, 8, "Up to 10 Gbps", 0.096, 70.08},
        {"m5.xlarge", 4, 16, "Up to 10 Gbps", 0.192, 140.16},
        {"m5.2xlarge", 8, 32, "Up to 10 Gbps", 0.384, 280.32},
        {"m5.4xlarge", 16, 64, "Up to 10 Gbps", 0.768, 560.64},
        {"m5.8xlarge", 32, 128, "10 Gbps", 1.536, 1121.28},
        {"m5.12xlarge", 48, 192, "12 Gbps", 2.304, 1681.92},
        {"m5.16xlarge", 64, 256, "20 Gbps", 3.072, 2242.56},
        {"m5.24xlarge", 96, 384, "25 Gbps", 4.608, 3363.84},
        
        // Compute Optimized
        {"c5.large", 2, 4, "Up to 10 Gbps", 0.085, 62.05},
        {"c5.xlarge", 4, 8, "Up to 10 Gbps", 0.17, 124.1},
        {"c5.2xlarge", 8, 16, "Up to 10 Gbps", 0.34, 248.2},
        {"c5.4xlarge", 16, 32, "Up to 10 Gbps", 0.68, 496.4},
        {"c5.9xlarge", 36, 72, "10 Gbps", 1.53, 1117.9},
        {"c5.12xlarge", 48, 96, "12 Gbps", 2.04, 1489.2},
        
        // Memory Optimized
        {"r5.large", 2, 16, "Up to 10 Gbps", 0.126, 91.98},
        {"r5.xlarge", 4, 32, "Up to 10 Gbps", 0.252, 183.96},
        {"r5.2xlarge", 8, 64, "Up to 10 Gbps", 0.504, 367.92},
        {"r5.4xlarge", 16, 128, "Up to 10 Gbps", 1.008, 735.84},
        {"r5.8xlarge", 32, 256, "10 Gbps", 2.016, 1471.68},
        {"r5.12xlarge", 48, 384, "12 Gbps", 3.024, 2207.52},
    }
    
    for _, p := range pricing {
        rm.pricingData[p.InstanceType] = p
    }
}

func (rm *ResourceMonitor) CollectUtilizationMetrics(ctx context.Context, resourceID string, 
    resourceType ResourceType, days int) (*UtilizationMetrics, error) {
    
    endTime := time.Now()
    startTime := endTime.AddDate(0, 0, -days)
    
    metrics := &UtilizationMetrics{
        ResourceID:       resourceID,
        ResourceType:     resourceType,
        MonitoringPeriod: days,
        LastUpdated:      time.Now(),
    }
    
    // Get instance details for cost calculation
    if resourceType == EC2Instance {
        instanceDetails, err := rm.getInstanceDetails(ctx, resourceID)
        if err != nil {
            return nil, fmt.Errorf("failed to get instance details: %w", err)
        }
        
        metrics.InstanceType = instanceDetails.InstanceType
        metrics.Tags = instanceDetails.Tags
        
        if pricing, exists := rm.pricingData[instanceDetails.InstanceType]; exists {
            metrics.CurrentCost = pricing.MonthlyPrice
        }
    }
    
    // Collect CPU utilization
    cpuStats, err := rm.getMetricStatistics(ctx, resourceID, resourceType, "CPUUtilization", startTime, endTime)
    if err != nil {
        return nil, fmt.Errorf("failed to get CPU metrics: %w", err)
    }
    metrics.CPUUtilization = rm.calculateStats(cpuStats)
    
    // Collect Memory utilization (requires CloudWatch agent)
    memoryStats, err := rm.getMetricStatistics(ctx, resourceID, resourceType, "MemoryUtilization", startTime, endTime)
    if err == nil {
        metrics.MemoryUtilization = rm.calculateStats(memoryStats)
    }
    
    // Collect Network utilization
    networkInStats, err := rm.getMetricStatistics(ctx, resourceID, resourceType, "NetworkIn", startTime, endTime)
    if err == nil {
        networkOutStats, _ := rm.getMetricStatistics(ctx, resourceID, resourceType, "NetworkOut", startTime, endTime)
        networkStats := append(networkInStats, networkOutStats...)
        metrics.NetworkUtilization = rm.calculateStats(networkStats)
    }
    
    // Update Prometheus metrics
    rm.updatePrometheusMetrics(metrics)
    
    return metrics, nil
}

func (rm *ResourceMonitor) calculateStats(dataPoints []float64) UtilizationStats {
    if len(dataPoints) == 0 {
        return UtilizationStats{}
    }
    
    sort.Float64s(dataPoints)
    
    // Calculate basic statistics
    sum := 0.0
    for _, v := range dataPoints {
        sum += v
    }
    
    avg := sum / float64(len(dataPoints))
    min := dataPoints[0]
    max := dataPoints[len(dataPoints)-1]
    
    // Calculate percentiles
    p95Index := int(float64(len(dataPoints)) * 0.95)
    p99Index := int(float64(len(dataPoints)) * 0.99)
    
    p95 := dataPoints[p95Index]
    p99 := dataPoints[p99Index]
    
    // Calculate standard deviation
    variance := 0.0
    for _, v := range dataPoints {
        variance += math.Pow(v-avg, 2)
    }
    stdDev := math.Sqrt(variance / float64(len(dataPoints)))
    
    return UtilizationStats{
        Average: avg,
        Max:     max,
        Min:     min,
        P95:     p95,
        P99:     p99,
        StdDev:  stdDev,
    }
}
```

### 2. Right-Sizing Recommendation Engine

```go
// Intelligent right-sizing recommendation system
type RightSizingEngine struct {
    monitor     *ResourceMonitor
    rules       []RightSizingRule
    constraints RightSizingConstraints
}

type RightSizingRule struct {
    Name        string                `json:"name"`
    ResourceType ResourceType         `json:"resource_type"`
    Conditions  []RuleCondition       `json:"conditions"`
    Action      RecommendationAction  `json:"action"`
    Priority    int                   `json:"priority"`
    Enabled     bool                  `json:"enabled"`
}

type RuleCondition struct {
    Metric    string  `json:"metric"`     // cpu_avg, memory_p95, etc.
    Operator  string  `json:"operator"`   // <, >, <=, >=, ==
    Threshold float64 `json:"threshold"`
    Duration  int     `json:"duration"`   // days
}

type RecommendationAction struct {
    Type       string                 `json:"type"`        // downsize, upsize, change_family
    Parameters map[string]interface{} `json:"parameters"`
}

type RightSizingConstraints struct {
    MinCPUUtilization    float64           `json:"min_cpu_utilization"`
    MaxCPUUtilization    float64           `json:"max_cpu_utilization"`
    MinMemoryUtilization float64           `json:"min_memory_utilization"`
    MaxMemoryUtilization float64           `json:"max_memory_utilization"`
    MinSavingsThreshold  float64           `json:"min_savings_threshold"`
    PerformanceBuffer    float64           `json:"performance_buffer"`
    ExcludedInstanceTypes []string         `json:"excluded_instance_types"`
    RequiredTags         map[string]string `json:"required_tags"`
}

type RightSizingRecommendation struct {
    ResourceID          string            `json:"resource_id"`
    ResourceType        ResourceType      `json:"resource_type"`
    CurrentInstanceType string            `json:"current_instance_type"`
    RecommendedInstanceType string        `json:"recommended_instance_type"`
    CurrentSpecs        InstanceSpecs     `json:"current_specs"`
    RecommendedSpecs    InstanceSpecs     `json:"recommended_specs"`
    UtilizationAnalysis UtilizationAnalysis `json:"utilization_analysis"`
    CostImpact          CostImpact        `json:"cost_impact"`
    RiskAssessment      RiskAssessment    `json:"risk_assessment"`
    RecommendationReason string           `json:"recommendation_reason"`
    Confidence          float64           `json:"confidence"`
    Priority            int               `json:"priority"`
    CreatedAt           time.Time         `json:"created_at"`
}

type InstanceSpecs struct {
    vCPUs      int     `json:"vcpus"`
    MemoryGB   float64 `json:"memory_gb"`
    NetworkPerf string  `json:"network_performance"`
    StorageType string  `json:"storage_type"`
}

type UtilizationAnalysis struct {
    CPUEfficiency     float64 `json:"cpu_efficiency"`     // 0-100
    MemoryEfficiency  float64 `json:"memory_efficiency"`  // 0-100
    NetworkEfficiency float64 `json:"network_efficiency"` // 0-100
    OverallEfficiency float64 `json:"overall_efficiency"` // 0-100
    Trend            string  `json:"trend"`              // increasing, stable, decreasing
}

type CostImpact struct {
    CurrentMonthlyCost    float64 `json:"current_monthly_cost"`
    RecommendedMonthlyCost float64 `json:"recommended_monthly_cost"`
    MonthlySavings        float64 `json:"monthly_savings"`
    AnnualSavings         float64 `json:"annual_savings"`
    SavingsPercentage     float64 `json:"savings_percentage"`
}

type RiskAssessment struct {
    RiskLevel          string   `json:"risk_level"`           // low, medium, high
    PerformanceRisk    float64  `json:"performance_risk"`     // 0-100
    AvailabilityRisk   float64  `json:"availability_risk"`    // 0-100
    RiskFactors        []string `json:"risk_factors"`
    MitigationSteps    []string `json:"mitigation_steps"`
}

func NewRightSizingEngine(monitor *ResourceMonitor) *RightSizingEngine {
    engine := &RightSizingEngine{
        monitor: monitor,
        constraints: RightSizingConstraints{
            MinCPUUtilization:    10.0,  // 10%
            MaxCPUUtilization:    70.0,  // 70%
            MinMemoryUtilization: 20.0,  // 20%
            MaxMemoryUtilization: 80.0,  // 80%
            MinSavingsThreshold:  5.0,   // $5/month
            PerformanceBuffer:    20.0,  // 20% buffer
        },
    }
    
    engine.loadRightSizingRules()
    return engine
}

func (rse *RightSizingEngine) loadRightSizingRules() {
    rse.rules = []RightSizingRule{
        {
            Name:         "CPU-Underutilized-Downsize",
            ResourceType: EC2Instance,
            Conditions: []RuleCondition{
                {Metric: "cpu_avg", Operator: "<", Threshold: 10.0, Duration: 14},
                {Metric: "cpu_p95", Operator: "<", Threshold: 30.0, Duration: 14},
            },
            Action: RecommendationAction{
                Type: "downsize",
                Parameters: map[string]interface{}{
                    "factor": 0.5, // Downsize by 50%
                },
            },
            Priority: 1,
            Enabled:  true,
        },
        {
            Name:         "Memory-Underutilized-Downsize",
            ResourceType: EC2Instance,
            Conditions: []RuleCondition{
                {Metric: "memory_avg", Operator: "<", Threshold: 20.0, Duration: 14},
                {Metric: "memory_p95", Operator: "<", Threshold: 50.0, Duration: 14},
            },
            Action: RecommendationAction{
                Type: "change_family",
                Parameters: map[string]interface{}{
                    "target_family": "compute_optimized",
                },
            },
            Priority: 2,
            Enabled:  true,
        },
        {
            Name:         "CPU-Overutilized-Upsize",
            ResourceType: EC2Instance,
            Conditions: []RuleCondition{
                {Metric: "cpu_avg", Operator: ">", Threshold: 70.0, Duration: 7},
                {Metric: "cpu_p95", Operator: ">", Threshold: 90.0, Duration: 7},
            },
            Action: RecommendationAction{
                Type: "upsize",
                Parameters: map[string]interface{}{
                    "factor": 2.0, // Double the capacity
                },
            },
            Priority: 3,
            Enabled:  true,
        },
    }
}

func (rse *RightSizingEngine) GenerateRecommendations(ctx context.Context, 
    resourceIDs []string, resourceType ResourceType) ([]RightSizingRecommendation, error) {
    
    var recommendations []RightSizingRecommendation
    
    for _, resourceID := range resourceIDs {
        // Collect utilization metrics
        metrics, err := rse.monitor.CollectUtilizationMetrics(ctx, resourceID, resourceType, 30)
        if err != nil {
            log.Printf("Failed to collect metrics for %s: %v", resourceID, err)
            continue
        }
        
        // Check if resource meets analysis criteria
        if !rse.shouldAnalyze(metrics) {
            continue
        }
        
        // Generate recommendation
        recommendation := rse.analyzeResource(metrics)
        if recommendation != nil {
            recommendations = append(recommendations, *recommendation)
        }
    }
    
    // Sort by potential savings
    sort.Slice(recommendations, func(i, j int) bool {
        return recommendations[i].CostImpact.MonthlySavings > recommendations[j].CostImpact.MonthlySavings
    })
    
    return recommendations, nil
}

func (rse *RightSizingEngine) analyzeResource(metrics *UtilizationMetrics) *RightSizingRecommendation {
    // Calculate efficiency scores
    analysis := rse.calculateUtilizationAnalysis(metrics)
    
    // Find matching rules
    var applicableRules []RightSizingRule
    for _, rule := range rse.rules {
        if rule.ResourceType == metrics.ResourceType && rule.Enabled {
            if rse.evaluateRuleConditions(rule.Conditions, metrics) {
                applicableRules = append(applicableRules, rule)
            }
        }
    }
    
    if len(applicableRules) == 0 {
        return nil // No recommendations
    }
    
    // Sort by priority and take the highest priority rule
    sort.Slice(applicableRules, func(i, j int) bool {
        return applicableRules[i].Priority < applicableRules[j].Priority
    })
    
    selectedRule := applicableRules[0]
    
    // Generate instance type recommendation
    currentType, recommendedType := rse.findOptimalInstanceType(metrics, selectedRule)
    if currentType == recommendedType {
        return nil // No change needed
    }
    
    // Calculate cost impact
    costImpact := rse.calculateCostImpact(currentType, recommendedType)
    
    // Check minimum savings threshold
    if costImpact.MonthlySavings < rse.constraints.MinSavingsThreshold {
        return nil
    }
    
    // Assess risk
    riskAssessment := rse.assessRisk(metrics, currentType, recommendedType)
    
    recommendation := &RightSizingRecommendation{
        ResourceID:              metrics.ResourceID,
        ResourceType:            metrics.ResourceType,
        CurrentInstanceType:     currentType,
        RecommendedInstanceType: recommendedType,
        CurrentSpecs:            rse.getInstanceSpecs(currentType),
        RecommendedSpecs:        rse.getInstanceSpecs(recommendedType),
        UtilizationAnalysis:     analysis,
        CostImpact:              costImpact,
        RiskAssessment:          riskAssessment,
        RecommendationReason:    selectedRule.Name,
        Confidence:              rse.calculateConfidence(metrics, selectedRule),
        Priority:                selectedRule.Priority,
        CreatedAt:               time.Now(),
    }
    
    return recommendation
}

func (rse *RightSizingEngine) findOptimalInstanceType(metrics *UtilizationMetrics, 
    rule RightSizingRule) (current, recommended string) {
    
    current = metrics.InstanceType
    currentSpecs := rse.getInstanceSpecs(current)
    
    switch rule.Action.Type {
    case "downsize":
        factor := rule.Action.Parameters["factor"].(float64)
        targetvCPUs := int(float64(currentSpecs.vCPUs) * factor)
        targetMemory := currentSpecs.MemoryGB * factor
        
        recommended = rse.findInstanceBySpecs(targetvCPUs, targetMemory, currentSpecs.NetworkPerf)
        
    case "upsize":
        factor := rule.Action.Parameters["factor"].(float64)
        targetvCPUs := int(float64(currentSpecs.vCPUs) * factor)
        targetMemory := currentSpecs.MemoryGB * factor
        
        recommended = rse.findInstanceBySpecs(targetvCPUs, targetMemory, currentSpecs.NetworkPerf)
        
    case "change_family":
        targetFamily := rule.Action.Parameters["target_family"].(string)
        recommended = rse.findInstanceInFamily(targetFamily, currentSpecs.vCPUs, currentSpecs.MemoryGB)
        
    default:
        recommended = current
    }
    
    return current, recommended
}

func (rse *RightSizingEngine) findInstanceBySpecs(targetvCPUs int, targetMemory float64, 
    networkPerf string) string {
    
    bestMatch := ""
    bestScore := math.MaxFloat64
    
    for instanceType, pricing := range rse.monitor.pricingData {
        // Skip if specs are too small
        if pricing.vCPUs < targetvCPUs || pricing.MemoryGB < targetMemory {
            continue
        }
        
        // Calculate score (lower is better)
        cpuDiff := math.Abs(float64(pricing.vCPUs - targetvCPUs))
        memoryDiff := math.Abs(pricing.MemoryGB - targetMemory)
        priceWeight := pricing.MonthlyPrice / 100.0 // Normalize price
        
        score := cpuDiff + memoryDiff + priceWeight
        
        if score < bestScore {
            bestScore = score
            bestMatch = instanceType
        }
    }
    
    return bestMatch
}
```

### 3. Automated Right-Sizing Execution

```go
// Automated right-sizing execution with safety controls
type RightSizingExecutor struct {
    ec2Client     *ec2.Client
    ecsClient     *ecs.Client
    constraints   ExecutionConstraints
    notifications NotificationService
}

type ExecutionConstraints struct {
    MaxInstancesPerDay     int                   `json:"max_instances_per_day"`
    RequiredApprovals      []string              `json:"required_approvals"`
    BlackoutWindows        []BlackoutWindow      `json:"blackout_windows"`
    RollbackThreshold      float64               `json:"rollback_threshold"`
    MonitoringPeriod       time.Duration         `json:"monitoring_period"`
    AutoRollbackEnabled    bool                  `json:"auto_rollback_enabled"`
    DryRunMode             bool                  `json:"dry_run_mode"`
}

type BlackoutWindow struct {
    StartTime time.Time `json:"start_time"`
    EndTime   time.Time `json:"end_time"`
    Reason    string    `json:"reason"`
}

type ExecutionPlan struct {
    ID                string                      `json:"id"`
    Recommendations   []RightSizingRecommendation `json:"recommendations"`
    ExecutionOrder    []string                    `json:"execution_order"`
    EstimatedDuration time.Duration               `json:"estimated_duration"`
    TotalSavings      float64                     `json:"total_savings"`
    RiskScore         float64                     `json:"risk_score"`
    ApprovalStatus    string                      `json:"approval_status"`
    CreatedAt         time.Time                   `json:"created_at"`
    ScheduledAt       time.Time                   `json:"scheduled_at"`
}

func (rse *RightSizingExecutor) CreateExecutionPlan(recommendations []RightSizingRecommendation) *ExecutionPlan {
    plan := &ExecutionPlan{
        ID:              generateUUID(),
        Recommendations: recommendations,
        CreatedAt:       time.Now(),
        ApprovalStatus:  "pending",
    }
    
    // Calculate total savings
    for _, rec := range recommendations {
        plan.TotalSavings += rec.CostImpact.MonthlySavings
    }
    
    // Sort by risk level (low risk first)
    sort.Slice(plan.Recommendations, func(i, j int) bool {
        riskOrder := map[string]int{"low": 1, "medium": 2, "high": 3}
        return riskOrder[plan.Recommendations[i].RiskAssessment.RiskLevel] < 
               riskOrder[plan.Recommendations[j].RiskAssessment.RiskLevel]
    })
    
    // Create execution order
    for _, rec := range plan.Recommendations {
        plan.ExecutionOrder = append(plan.ExecutionOrder, rec.ResourceID)
    }
    
    // Calculate overall risk score
    plan.RiskScore = rse.calculatePlanRiskScore(plan.Recommendations)
    
    // Estimate duration
    plan.EstimatedDuration = time.Duration(len(recommendations)) * 10 * time.Minute
    
    return plan
}

func (rse *RightSizingExecutor) ExecutePlan(ctx context.Context, plan *ExecutionPlan) error {
    if plan.ApprovalStatus != "approved" {
        return fmt.Errorf("execution plan %s is not approved", plan.ID)
    }
    
    // Check blackout windows
    if rse.isBlackoutPeriod() {
        return fmt.Errorf("execution blocked: within blackout window")
    }
    
    executed := 0
    failed := 0
    
    for _, resourceID := range plan.ExecutionOrder {
        // Find the recommendation for this resource
        var recommendation *RightSizingRecommendation
        for _, rec := range plan.Recommendations {
            if rec.ResourceID == resourceID {
                recommendation = &rec
                break
            }
        }
        
        if recommendation == nil {
            continue
        }
        
        // Check daily limits
        if executed >= rse.constraints.MaxInstancesPerDay {
            log.Printf("Daily execution limit reached: %d", rse.constraints.MaxInstancesPerDay)
            break
        }
        
        // Execute the right-sizing
        err := rse.executeRecommendation(ctx, *recommendation)
        if err != nil {
            log.Printf("Failed to execute recommendation for %s: %v", resourceID, err)
            failed++
            
            // Send notification
            rse.notifications.SendAlert(ctx, fmt.Sprintf(
                "Right-sizing failed for %s: %v", resourceID, err))
            continue
        }
        
        executed++
        log.Printf("Successfully executed right-sizing for %s: %s -> %s", 
            resourceID, recommendation.CurrentInstanceType, recommendation.RecommendedInstanceType)
        
        // Wait between executions to avoid overwhelming systems
        time.Sleep(30 * time.Second)
    }
    
    // Send summary notification
    rse.notifications.SendSummary(ctx, fmt.Sprintf(
        "Right-sizing execution completed: %d successful, %d failed", executed, failed))
    
    return nil
}

func (rse *RightSizingExecutor) executeRecommendation(ctx context.Context, 
    recommendation RightSizingRecommendation) error {
    
    if rse.constraints.DryRunMode {
        log.Printf("DRY RUN: Would resize %s from %s to %s", 
            recommendation.ResourceID,
            recommendation.CurrentInstanceType,
            recommendation.RecommendedInstanceType)
        return nil
    }
    
    switch recommendation.ResourceType {
    case EC2Instance:
        return rse.resizeEC2Instance(ctx, recommendation)
    case ECSService:
        return rse.resizeECSService(ctx, recommendation)
    default:
        return fmt.Errorf("unsupported resource type: %s", recommendation.ResourceType)
    }
}

func (rse *RightSizingExecutor) resizeEC2Instance(ctx context.Context, 
    recommendation RightSizingRecommendation) error {
    
    instanceID := recommendation.ResourceID
    
    // Stop the instance
    log.Printf("Stopping instance %s", instanceID)
    _, err := rse.ec2Client.StopInstances(ctx, &ec2.StopInstancesInput{
        InstanceIds: []string{instanceID},
    })
    if err != nil {
        return fmt.Errorf("failed to stop instance: %w", err)
    }
    
    // Wait for instance to stop
    waiter := ec2.NewInstanceStoppedWaiter(rse.ec2Client)
    err = waiter.Wait(ctx, &ec2.DescribeInstancesInput{
        InstanceIds: []string{instanceID},
    }, 5*time.Minute)
    if err != nil {
        return fmt.Errorf("failed to wait for instance to stop: %w", err)
    }
    
    // Modify instance type
    log.Printf("Changing instance type from %s to %s", 
        recommendation.CurrentInstanceType, recommendation.RecommendedInstanceType)
    _, err = rse.ec2Client.ModifyInstanceAttribute(ctx, &ec2.ModifyInstanceAttributeInput{
        InstanceId: &instanceID,
        InstanceType: &ec2Types.AttributeValue{
            Value: &recommendation.RecommendedInstanceType,
        },
    })
    if err != nil {
        return fmt.Errorf("failed to modify instance type: %w", err)
    }
    
    // Start the instance
    log.Printf("Starting instance %s", instanceID)
    _, err = rse.ec2Client.StartInstances(ctx, &ec2.StartInstancesInput{
        InstanceIds: []string{instanceID},
    })
    if err != nil {
        return fmt.Errorf("failed to start instance: %w", err)
    }
    
    // Wait for instance to start
    runningWaiter := ec2.NewInstanceRunningWaiter(rse.ec2Client)
    err = runningWaiter.Wait(ctx, &ec2.DescribeInstancesInput{
        InstanceIds: []string{instanceID},
    }, 5*time.Minute)
    if err != nil {
        return fmt.Errorf("failed to wait for instance to start: %w", err)
    }
    
    // Schedule monitoring for rollback if needed
    if rse.constraints.AutoRollbackEnabled {
        go rse.monitorForRollback(ctx, recommendation)
    }
    
    return nil
}
```

### 4. Performance Impact Monitoring

```go
// Performance monitoring and rollback system
type PerformanceMonitor struct {
    cloudwatchClient *cloudwatch.Client
    baseline         map[string]PerformanceBaseline
    thresholds       PerformanceThresholds
}

type PerformanceBaseline struct {
    ResourceID      string    `json:"resource_id"`
    AvgResponseTime float64   `json:"avg_response_time"`
    ErrorRate       float64   `json:"error_rate"`
    Throughput      float64   `json:"throughput"`
    CPUUsage        float64   `json:"cpu_usage"`
    MemoryUsage     float64   `json:"memory_usage"`
    RecordedAt      time.Time `json:"recorded_at"`
}

type PerformanceThresholds struct {
    MaxResponseTimeIncrease float64 `json:"max_response_time_increase"` // %
    MaxErrorRateIncrease    float64 `json:"max_error_rate_increase"`    // %
    MinThroughputDecrease   float64 `json:"min_throughput_decrease"`    // %
    MaxCPUIncrease         float64 `json:"max_cpu_increase"`           // %
    MaxMemoryIncrease      float64 `json:"max_memory_increase"`        // %
}

func (pm *PerformanceMonitor) EstablishBaseline(ctx context.Context, resourceID string, 
    days int) error {
    
    endTime := time.Now()
    startTime := endTime.AddDate(0, 0, -days)
    
    // Collect baseline metrics
    responseTime, err := pm.getAverageMetric(ctx, resourceID, "ResponseTime", startTime, endTime)
    if err != nil {
        return fmt.Errorf("failed to get response time baseline: %w", err)
    }
    
    errorRate, err := pm.getAverageMetric(ctx, resourceID, "ErrorRate", startTime, endTime)
    if err != nil {
        return fmt.Errorf("failed to get error rate baseline: %w", err)
    }
    
    throughput, err := pm.getAverageMetric(ctx, resourceID, "RequestCount", startTime, endTime)
    if err != nil {
        return fmt.Errorf("failed to get throughput baseline: %w", err)
    }
    
    cpuUsage, err := pm.getAverageMetric(ctx, resourceID, "CPUUtilization", startTime, endTime)
    if err != nil {
        return fmt.Errorf("failed to get CPU baseline: %w", err)
    }
    
    memoryUsage, err := pm.getAverageMetric(ctx, resourceID, "MemoryUtilization", startTime, endTime)
    if err != nil {
        return fmt.Errorf("failed to get memory baseline: %w", err)
    }
    
    baseline := PerformanceBaseline{
        ResourceID:      resourceID,
        AvgResponseTime: responseTime,
        ErrorRate:       errorRate,
        Throughput:      throughput,
        CPUUsage:        cpuUsage,
        MemoryUsage:     memoryUsage,
        RecordedAt:      time.Now(),
    }
    
    pm.baseline[resourceID] = baseline
    return nil
}

func (pm *PerformanceMonitor) MonitorPerformance(ctx context.Context, resourceID string, 
    duration time.Duration) (*PerformanceComparison, error) {
    
    baseline, exists := pm.baseline[resourceID]
    if !exists {
        return nil, fmt.Errorf("no baseline found for resource %s", resourceID)
    }
    
    // Monitor for the specified duration
    time.Sleep(duration)
    
    // Collect current metrics
    endTime := time.Now()
    startTime := endTime.Add(-duration)
    
    currentResponseTime, _ := pm.getAverageMetric(ctx, resourceID, "ResponseTime", startTime, endTime)
    currentErrorRate, _ := pm.getAverageMetric(ctx, resourceID, "ErrorRate", startTime, endTime)
    currentThroughput, _ := pm.getAverageMetric(ctx, resourceID, "RequestCount", startTime, endTime)
    currentCPU, _ := pm.getAverageMetric(ctx, resourceID, "CPUUtilization", startTime, endTime)
    currentMemory, _ := pm.getAverageMetric(ctx, resourceID, "MemoryUtilization", startTime, endTime)
    
    comparison := &PerformanceComparison{
        ResourceID:        resourceID,
        Baseline:          baseline,
        Current: PerformanceBaseline{
            ResourceID:      resourceID,
            AvgResponseTime: currentResponseTime,
            ErrorRate:       currentErrorRate,
            Throughput:      currentThroughput,
            CPUUsage:        currentCPU,
            MemoryUsage:     currentMemory,
            RecordedAt:      time.Now(),
        },
    }
    
    // Calculate percentage changes
    comparison.ResponseTimeChange = ((currentResponseTime - baseline.AvgResponseTime) / baseline.AvgResponseTime) * 100
    comparison.ErrorRateChange = ((currentErrorRate - baseline.ErrorRate) / baseline.ErrorRate) * 100
    comparison.ThroughputChange = ((currentThroughput - baseline.Throughput) / baseline.Throughput) * 100
    comparison.CPUChange = ((currentCPU - baseline.CPUUsage) / baseline.CPUUsage) * 100
    comparison.MemoryChange = ((currentMemory - baseline.MemoryUsage) / baseline.MemoryUsage) * 100
    
    // Determine if rollback is needed
    comparison.RollbackRecommended = pm.shouldRollback(comparison)
    
    return comparison, nil
}

type PerformanceComparison struct {
    ResourceID           string              `json:"resource_id"`
    Baseline             PerformanceBaseline `json:"baseline"`
    Current              PerformanceBaseline `json:"current"`
    ResponseTimeChange   float64             `json:"response_time_change"`
    ErrorRateChange      float64             `json:"error_rate_change"`
    ThroughputChange     float64             `json:"throughput_change"`
    CPUChange           float64             `json:"cpu_change"`
    MemoryChange        float64             `json:"memory_change"`
    RollbackRecommended bool                `json:"rollback_recommended"`
}

func (pm *PerformanceMonitor) shouldRollback(comparison *PerformanceComparison) bool {
    return comparison.ResponseTimeChange > pm.thresholds.MaxResponseTimeIncrease ||
           comparison.ErrorRateChange > pm.thresholds.MaxErrorRateIncrease ||
           comparison.ThroughputChange < -pm.thresholds.MinThroughputDecrease ||
           comparison.CPUChange > pm.thresholds.MaxCPUIncrease ||
           comparison.MemoryChange > pm.thresholds.MaxMemoryIncrease
}
```

### 5. Monitoring and Reporting

```yaml
# Kubernetes deployment for right-sizing system
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rightsizing-analyzer
spec:
  replicas: 2
  selector:
    matchLabels:
      app: rightsizing-analyzer
  template:
    metadata:
      labels:
        app: rightsizing-analyzer
    spec:
      containers:
      - name: analyzer
        image: rightsizing-analyzer:latest
        env:
        - name: AWS_REGION
          value: "us-east-1"
        - name: MONITORING_PERIOD_DAYS
          value: "30"
        - name: MIN_SAVINGS_THRESHOLD
          value: "10.0"
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "1Gi"
            cpu: "500m"

---
# CronJob for daily right-sizing analysis
apiVersion: batch/v1
kind: CronJob
metadata:
  name: rightsizing-daily-analysis
spec:
  schedule: "0 6 * * *"  # Daily at 6 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: analyzer
            image: rightsizing-analyzer:latest
            command: ["/app/rightsizing-analyzer"]
            args: ["--mode", "analyze", "--output", "/reports/"]
            env:
            - name: ANALYSIS_MODE
              value: "full"
          restartPolicy: OnFailure

---
# Grafana Dashboard
apiVersion: v1
kind: ConfigMap
metadata:
  name: rightsizing-dashboard
data:
  dashboard.json: |
    {
      "dashboard": {
        "title": "Infrastructure Right-Sizing",
        "panels": [
          {
            "title": "Resource Efficiency Score",
            "type": "stat",
            "targets": [
              {
                "expr": "avg(resource_efficiency_score)",
                "legendFormat": "Overall Efficiency"
              }
            ]
          },
          {
            "title": "Right-Sizing Opportunities",
            "type": "table",
            "targets": [
              {
                "expr": "topk(10, rightsizing_potential_savings_usd)",
                "format": "table"
              }
            ]
          },
          {
            "title": "Resource Utilization by Type",
            "type": "graph",
            "targets": [
              {
                "expr": "avg by (resource_type) (resource_utilization_percent{metric_type=\"cpu\"})",
                "legendFormat": "{{resource_type}} CPU"
              },
              {
                "expr": "avg by (resource_type) (resource_utilization_percent{metric_type=\"memory\"})",
                "legendFormat": "{{resource_type}} Memory"
              }
            ]
          }
        ]
      }
    }
```

## Best Practices

### 1. Monitoring and Analysis
- Collect at least 2-4 weeks of utilization data before making recommendations
- Consider workload patterns (daily, weekly, seasonal variations)
- Monitor multiple metrics (CPU, memory, network, disk)
- Use percentile-based analysis (P95, P99) not just averages

### 2. Safety and Risk Management
- Always establish performance baselines before changes
- Implement gradual rollout strategies
- Maintain rollback procedures and automation
- Use canary deployments for critical services

### 3. Right-Sizing Strategy
- Start with development and staging environments
- Focus on the highest savings opportunities first
- Consider burstable instances (T3/T4g) for variable workloads
- Use Reserved Instances or Savings Plans after right-sizing

### 4. Automation Guidelines
- Implement approval workflows for production changes
- Set daily/weekly limits on automated changes
- Use blackout windows during critical business periods
- Monitor and alert on performance degradation

## Success Metrics

- **Cost Reduction**: 15-30% reduction in compute costs
- **Resource Efficiency**: >60% average CPU utilization
- **Right-Sizing Coverage**: >90% of resources analyzed
- **Performance Impact**: <5% degradation in key metrics
- **Automation Rate**: >80% of recommendations executed automatically

## Consequences

### Positive
- **Significant Cost Savings**: 15-30% reduction in infrastructure costs
- **Improved Resource Utilization**: Better performance per dollar spent
- **Operational Efficiency**: Automated optimization reduces manual effort
- **Performance Insights**: Better understanding of application resource needs

### Negative
- **Implementation Complexity**: Requires sophisticated monitoring and automation
- **Performance Risk**: Potential impact on application performance
- **Operational Overhead**: Need to monitor and maintain optimization systems
- **False Positives**: Some recommendations may not be suitable

## References

- [AWS Right Sizing Guide](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/right-size.html)
- [Azure VM Right-Sizing](https://docs.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-opt-recommendations)
- [GCP Compute Recommendations](https://cloud.google.com/compute/docs/instances/apply-machine-type-recommendations-for-instances)
- [CloudWatch Metrics](https://docs.aws.amazon.com/cloudwatch/latest/monitoring/)

## Related ADRs

- [001-rationality](./001-rationality.md) - General FinOps principles
- [012-use-metrics](../backend/012-use-metrics.md) - Metrics collection and monitoring
- [026-red-monitoring](../backend/026-red-monitoring.md) - Performance monitoring strategies
