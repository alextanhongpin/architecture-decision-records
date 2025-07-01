# Multi-Cloud Cost Management

## Status
**Accepted** - 2024-02-01

## Context
Organizations increasingly adopt multi-cloud strategies to avoid vendor lock-in, improve resilience, and leverage best-of-breed services. However, managing costs across multiple cloud providers presents unique challenges: different pricing models, inconsistent billing formats, varying service offerings, and complex cost allocation across clouds.

## Problem Statement
Multi-cloud environments face several cost management challenges:
- Lack of unified cost visibility across cloud providers
- Inconsistent tagging and cost allocation strategies
- Different pricing models and billing cycles
- Complex data transfer costs between clouds
- Difficulty in comparing equivalent services across providers
- Absence of consolidated budgeting and forecasting
- Vendor-specific cost optimization tools that don't provide holistic insights

## Decision
Implement a comprehensive multi-cloud cost management platform that provides unified visibility, standardized cost allocation, automated optimization, and strategic cloud workload placement based on cost-performance analysis.

## Implementation

### 1. Unified Cost Data Collection

```go
// Multi-cloud cost aggregation system
package multicloud

import (
    "context"
    "fmt"
    "time"
    
    "github.com/aws/aws-sdk-go-v2/service/costexplorer"
    "github.com/Azure/azure-sdk-for-go/services/consumption"
    "google.golang.org/api/cloudbilling/v1"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

type CloudProvider string

const (
    AWS     CloudProvider = "aws"
    Azure   CloudProvider = "azure"
    GCP     CloudProvider = "gcp"
    Alibaba CloudProvider = "alibaba"
)

type UnifiedCostData struct {
    Provider      CloudProvider         `json:"provider"`
    Account       string                `json:"account"`
    Service       string                `json:"service"`
    Region        string                `json:"region"`
    ResourceType  string                `json:"resource_type"`
    ResourceID    string                `json:"resource_id"`
    Cost          float64               `json:"cost"`
    Currency      string                `json:"currency"`
    BillingPeriod string                `json:"billing_period"`
    UsageAmount   float64               `json:"usage_amount"`
    UsageUnit     string                `json:"usage_unit"`
    Tags          map[string]string     `json:"tags"`
    Timestamp     time.Time             `json:"timestamp"`
}

type ServiceMapping struct {
    AWSService    string `json:"aws_service"`
    AzureService  string `json:"azure_service"`
    GCPService    string `json:"gcp_service"`
    Category      string `json:"category"`        // compute, storage, network, database
    Subcategory   string `json:"subcategory"`     // vm, object-storage, cdn, sql
}

var (
    multiCloudCost = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "multicloud_cost_usd",
            Help: "Multi-cloud costs in USD",
        },
        []string{"provider", "account", "service", "region", "team", "environment"},
    )
    
    providerCostShare = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "provider_cost_share_percent",
            Help: "Cost share percentage by provider",
        },
        []string{"provider"},
    )
    
    serviceEquivalentCost = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "service_equivalent_cost_usd",
            Help: "Equivalent service costs across providers",
        },
        []string{"service_category", "provider", "region"},
    )
)

type MultiCloudCostManager struct {
    awsCostExplorer   *costexplorer.Client
    azureConsumption  *consumption.UsageDetailsClient
    gcpBilling        *cloudbilling.Service
    serviceMapping    map[string]ServiceMapping
    exchangeRates     map[string]float64
    costStorage       CostDataStorage
}

func NewMultiCloudCostManager() *MultiCloudCostManager {
    manager := &MultiCloudCostManager{
        serviceMapping: make(map[string]ServiceMapping),
        exchangeRates:  make(map[string]float64),
    }
    
    manager.initializeServiceMapping()
    manager.loadExchangeRates()
    
    return manager
}

func (mcm *MultiCloudCostManager) initializeServiceMapping() {
    mappings := []ServiceMapping{
        // Compute Services
        {"EC2-Instance", "Virtual Machines", "Compute Engine", "compute", "vm"},
        {"ECS", "Container Instances", "Cloud Run", "compute", "container"},
        {"Lambda", "Functions", "Cloud Functions", "compute", "serverless"},
        {"EKS", "Kubernetes Service", "GKE", "compute", "kubernetes"},
        
        // Storage Services
        {"S3", "Blob Storage", "Cloud Storage", "storage", "object"},
        {"EBS", "Managed Disks", "Persistent Disks", "storage", "block"},
        {"EFS", "Files", "Filestore", "storage", "file"},
        
        // Database Services
        {"RDS", "SQL Database", "Cloud SQL", "database", "relational"},
        {"DynamoDB", "Cosmos DB", "Firestore", "database", "nosql"},
        {"ElastiCache", "Cache for Redis", "Memorystore", "database", "cache"},
        
        // Network Services
        {"CloudFront", "CDN", "Cloud CDN", "network", "cdn"},
        {"VPC", "Virtual Network", "VPC", "network", "vpc"},
        {"ALB", "Load Balancer", "Load Balancer", "network", "load-balancer"},
        
        // Analytics Services
        {"Redshift", "Synapse Analytics", "BigQuery", "analytics", "data-warehouse"},
        {"Kinesis", "Event Hubs", "Pub/Sub", "analytics", "streaming"},
        {"EMR", "HDInsight", "Dataproc", "analytics", "big-data"},
    }
    
    for _, mapping := range mappings {
        key := fmt.Sprintf("%s-%s", mapping.Category, mapping.Subcategory)
        mcm.serviceMapping[key] = mapping
    }
}

func (mcm *MultiCloudCostManager) CollectCostData(ctx context.Context, 
    startDate, endDate time.Time) ([]UnifiedCostData, error) {
    
    var allCosts []UnifiedCostData
    
    // Collect AWS costs
    awsCosts, err := mcm.collectAWSCosts(ctx, startDate, endDate)
    if err != nil {
        return nil, fmt.Errorf("failed to collect AWS costs: %w", err)
    }
    allCosts = append(allCosts, awsCosts...)
    
    // Collect Azure costs
    azureCosts, err := mcm.collectAzureCosts(ctx, startDate, endDate)
    if err != nil {
        return nil, fmt.Errorf("failed to collect Azure costs: %w", err)
    }
    allCosts = append(allCosts, azureCosts...)
    
    // Collect GCP costs
    gcpCosts, err := mcm.collectGCPCosts(ctx, startDate, endDate)
    if err != nil {
        return nil, fmt.Errorf("failed to collect GCP costs: %w", err)
    }
    allCosts = append(allCosts, gcpCosts...)
    
    // Normalize and standardize data
    normalizedCosts := mcm.normalizeCostData(allCosts)
    
    // Update Prometheus metrics
    mcm.updateMetrics(normalizedCosts)
    
    // Store in database
    err = mcm.costStorage.StoreCostData(ctx, normalizedCosts)
    if err != nil {
        return nil, fmt.Errorf("failed to store cost data: %w", err)
    }
    
    return normalizedCosts, nil
}

func (mcm *MultiCloudCostManager) collectAWSCosts(ctx context.Context, 
    startDate, endDate time.Time) ([]UnifiedCostData, error) {
    
    var costs []UnifiedCostData
    
    input := &costexplorer.GetCostAndUsageInput{
        TimePeriod: &costexplorerTypes.DateInterval{
            Start: aws.String(startDate.Format("2006-01-02")),
            End:   aws.String(endDate.Format("2006-01-02")),
        },
        Granularity: costexplorerTypes.GranularityDaily,
        Metrics:     []string{"BlendedCost", "UsageQuantity"},
        GroupBy: []costexplorerTypes.GroupDefinition{
            {
                Type: costexplorerTypes.GroupDefinitionTypeDimension,
                Key:  aws.String("SERVICE"),
            },
            {
                Type: costexplorerTypes.GroupDefinitionTypeDimension,
                Key:  aws.String("REGION"),
            },
        },
    }
    
    result, err := mcm.awsCostExplorer.GetCostAndUsage(ctx, input)
    if err != nil {
        return nil, err
    }
    
    for _, resultByTime := range result.ResultsByTime {
        date, _ := time.Parse("2006-01-02", *resultByTime.TimePeriod.Start)
        
        for _, group := range resultByTime.Groups {
            service := group.Keys[0]
            region := group.Keys[1]
            
            cost, _ := strconv.ParseFloat(*group.Metrics["BlendedCost"].Amount, 64)
            usage, _ := strconv.ParseFloat(*group.Metrics["UsageQuantity"].Amount, 64)
            
            costData := UnifiedCostData{
                Provider:      AWS,
                Service:       service,
                Region:        region,
                Cost:          cost,
                Currency:      "USD",
                UsageAmount:   usage,
                BillingPeriod: date.Format("2006-01"),
                Timestamp:     date,
                Tags:          make(map[string]string),
            }
            
            costs = append(costs, costData)
        }
    }
    
    return costs, nil
}

func (mcm *MultiCloudCostManager) normalizeCostData(costs []UnifiedCostData) []UnifiedCostData {
    for i, cost := range costs {
        // Convert currency to USD
        if cost.Currency != "USD" {
            rate, exists := mcm.exchangeRates[cost.Currency]
            if exists {
                costs[i].Cost = cost.Cost * rate
                costs[i].Currency = "USD"
            }
        }
        
        // Standardize service names
        category, subcategory := mcm.categorizeService(cost.Provider, cost.Service)
        costs[i].Tags["service_category"] = category
        costs[i].Tags["service_subcategory"] = subcategory
        
        // Standardize region names
        costs[i].Region = mcm.normalizeRegion(cost.Provider, cost.Region)
    }
    
    return costs
}
```

### 2. Cross-Cloud Cost Comparison

```go
// Cross-cloud service cost comparison engine
type CrossCloudComparator struct {
    costManager    *MultiCloudCostManager
    pricingModels  map[string]PricingModel
    workloadProfiles map[string]WorkloadProfile
}

type PricingModel struct {
    Provider      CloudProvider         `json:"provider"`
    Service       string                `json:"service"`
    Region        string                `json:"region"`
    PricingTiers  []PricingTier         `json:"pricing_tiers"`
    BillingModel  string                `json:"billing_model"` // hourly, monthly, pay-per-use
    MinimumCharge float64               `json:"minimum_charge"`
    FreeTrierLimit float64              `json:"free_tier_limit"`
    Discounts     []VolumeDiscount      `json:"discounts"`
}

type PricingTier struct {
    Name        string  `json:"name"`
    MinUsage    float64 `json:"min_usage"`
    MaxUsage    float64 `json:"max_usage"`
    PricePerUnit float64 `json:"price_per_unit"`
    Unit        string  `json:"unit"`
}

type VolumeDiscount struct {
    MinVolume     float64 `json:"min_volume"`
    DiscountPercent float64 `json:"discount_percent"`
}

type WorkloadProfile struct {
    ServiceCategory    string                 `json:"service_category"`
    ServiceSubcategory string                 `json:"service_subcategory"`
    UsagePattern      UsagePattern           `json:"usage_pattern"`
    PerformanceReqs   PerformanceRequirements `json:"performance_requirements"`
    ComplianceReqs    []string               `json:"compliance_requirements"`
    DataSensitivity   string                 `json:"data_sensitivity"`
}

type UsagePattern struct {
    AverageUsage   float64             `json:"average_usage"`
    PeakUsage      float64             `json:"peak_usage"`
    UsageUnit      string              `json:"usage_unit"`
    PeakHours      []int               `json:"peak_hours"`
    Seasonality    map[string]float64  `json:"seasonality"` // month -> multiplier
}

type PerformanceRequirements struct {
    CPU            int     `json:"cpu_cores"`
    Memory         int     `json:"memory_gb"`
    Storage        int     `json:"storage_gb"`
    IOPS           int     `json:"iops"`
    NetworkBandwidth int   `json:"network_mbps"`
    Latency        int     `json:"max_latency_ms"`
    Availability   float64 `json:"availability_sla"`
}

type CostComparison struct {
    ServiceCategory    string                    `json:"service_category"`
    WorkloadProfile    WorkloadProfile           `json:"workload_profile"`
    ProviderOptions    []ProviderOption          `json:"provider_options"`
    Recommendation     string                    `json:"recommendation"`
    PotentialSavings   float64                   `json:"potential_savings"`
    RiskAssessment     CrossCloudRiskAssessment  `json:"risk_assessment"`
    CreatedAt          time.Time                 `json:"created_at"`
}

type ProviderOption struct {
    Provider         CloudProvider       `json:"provider"`
    Service          string              `json:"service"`
    Region           string              `json:"region"`
    Configuration    ServiceConfiguration `json:"configuration"`
    MonthlyCost      float64             `json:"monthly_cost"`
    AnnualCost       float64             `json:"annual_cost"`
    PerformanceScore float64             `json:"performance_score"`
    ComplianceScore  float64             `json:"compliance_score"`
    TotalScore       float64             `json:"total_score"`
    Pros             []string            `json:"pros"`
    Cons             []string            `json:"cons"`
}

type ServiceConfiguration struct {
    InstanceType     string            `json:"instance_type"`
    CPU              int               `json:"cpu"`
    Memory           int               `json:"memory_gb"`
    Storage          int               `json:"storage_gb"`
    AdditionalFeatures map[string]bool `json:"additional_features"`
}

func (ccc *CrossCloudComparator) CompareServices(ctx context.Context, 
    workloadProfile WorkloadProfile) (*CostComparison, error) {
    
    var providerOptions []ProviderOption
    
    // Get equivalent services across providers
    equivalentServices := ccc.findEquivalentServices(workloadProfile.ServiceCategory, 
        workloadProfile.ServiceSubcategory)
    
    for _, service := range equivalentServices {
        option, err := ccc.calculateProviderOption(ctx, service, workloadProfile)
        if err != nil {
            log.Printf("Failed to calculate option for %s %s: %v", 
                service.Provider, service.Service, err)
            continue
        }
        
        providerOptions = append(providerOptions, *option)
    }
    
    // Sort by total score (cost + performance + compliance)
    sort.Slice(providerOptions, func(i, j int) bool {
        return providerOptions[i].TotalScore > providerOptions[j].TotalScore
    })
    
    comparison := &CostComparison{
        ServiceCategory: workloadProfile.ServiceCategory,
        WorkloadProfile: workloadProfile,
        ProviderOptions: providerOptions,
        CreatedAt:       time.Now(),
    }
    
    // Generate recommendation
    if len(providerOptions) > 0 {
        best := providerOptions[0]
        comparison.Recommendation = fmt.Sprintf("%s %s in %s", 
            best.Provider, best.Service, best.Region)
        
        // Calculate potential savings compared to most expensive option
        if len(providerOptions) > 1 {
            mostExpensive := providerOptions[len(providerOptions)-1]
            comparison.PotentialSavings = mostExpensive.MonthlyCost - best.MonthlyCost
        }
    }
    
    // Assess risks
    comparison.RiskAssessment = ccc.assessCrossCloudRisks(providerOptions)
    
    return comparison, nil
}

func (ccc *CrossCloudComparator) calculateProviderOption(ctx context.Context, 
    service ServiceInfo, workload WorkloadProfile) (*ProviderOption, error) {
    
    // Get pricing model for the service
    pricingKey := fmt.Sprintf("%s-%s", service.Provider, service.Service)
    pricingModel, exists := ccc.pricingModels[pricingKey]
    if !exists {
        return nil, fmt.Errorf("pricing model not found for %s", pricingKey)
    }
    
    // Calculate monthly cost based on usage pattern
    monthlyCost := ccc.calculateCost(pricingModel, workload.UsagePattern)
    
    // Calculate performance score
    perfScore := ccc.calculatePerformanceScore(service, workload.PerformanceReqs)
    
    // Calculate compliance score
    complianceScore := ccc.calculateComplianceScore(service, workload.ComplianceReqs)
    
    // Calculate total score (weighted)
    totalScore := (0.4 * (100 - (monthlyCost/1000)*10)) + // Cost weight (40%)
                 (0.4 * perfScore) +                      // Performance weight (40%)
                 (0.2 * complianceScore)                  // Compliance weight (20%)
    
    option := &ProviderOption{
        Provider:         service.Provider,
        Service:          service.Service,
        Region:           service.Region,
        MonthlyCost:      monthlyCost,
        AnnualCost:       monthlyCost * 12,
        PerformanceScore: perfScore,
        ComplianceScore:  complianceScore,
        TotalScore:       totalScore,
        Configuration:    ccc.generateConfiguration(service, workload),
        Pros:             ccc.getServicePros(service),
        Cons:             ccc.getServiceCons(service),
    }
    
    return option, nil
}

func (ccc *CrossCloudComparator) calculateCost(pricing PricingModel, 
    usage UsagePattern) float64 {
    
    cost := 0.0
    
    // Calculate base cost using pricing tiers
    remainingUsage := usage.AverageUsage * 730 // Monthly hours
    
    for _, tier := range pricing.PricingTiers {
        if remainingUsage <= 0 {
            break
        }
        
        tierUsage := math.Min(remainingUsage, tier.MaxUsage-tier.MinUsage)
        cost += tierUsage * tier.PricePerUnit
        remainingUsage -= tierUsage
    }
    
    // Apply volume discounts
    for _, discount := range pricing.Discounts {
        if usage.AverageUsage >= discount.MinVolume {
            cost *= (1 - discount.DiscountPercent/100)
        }
    }
    
    // Apply minimum charge
    if cost < pricing.MinimumCharge {
        cost = pricing.MinimumCharge
    }
    
    return cost
}
```

### 3. Data Transfer Cost Optimization

```go
// Multi-cloud data transfer cost optimization
type DataTransferOptimizer struct {
    costManager     *MultiCloudCostManager
    networkTopology NetworkTopology
    transferPatterns map[string]TransferPattern
}

type NetworkTopology struct {
    Regions        []RegionInfo      `json:"regions"`
    Connections    []RegionConnection `json:"connections"`
    DataCenters    []DataCenterInfo   `json:"data_centers"`
}

type RegionInfo struct {
    Provider     CloudProvider `json:"provider"`
    Region       string        `json:"region"`
    Location     GeoLocation   `json:"location"`
    Services     []string      `json:"services"`
    Compliance   []string      `json:"compliance"`
}

type RegionConnection struct {
    FromRegion  string  `json:"from_region"`
    ToRegion    string  `json:"to_region"`
    Provider    CloudProvider `json:"provider"`
    Latency     int     `json:"latency_ms"`
    Bandwidth   int     `json:"bandwidth_mbps"`
    CostPerGB   float64 `json:"cost_per_gb"`
}

type TransferPattern struct {
    Source        string    `json:"source"`        // region or service
    Destination   string    `json:"destination"`   // region or service
    DataType      string    `json:"data_type"`     // api, files, database, backup
    Volume        float64   `json:"volume_gb"`
    Frequency     string    `json:"frequency"`     // hourly, daily, weekly
    Criticality   string    `json:"criticality"`   // low, medium, high
    LastTransfer  time.Time `json:"last_transfer"`
}

type TransferOptimization struct {
    CurrentPattern      TransferPattern           `json:"current_pattern"`
    OptimizedPattern    TransferPattern           `json:"optimized_pattern"`
    OptimizationStrategy string                   `json:"optimization_strategy"`
    CostSavings         float64                   `json:"monthly_cost_savings"`
    LatencyImpact       int                       `json:"latency_impact_ms"`
    ImplementationSteps []string                  `json:"implementation_steps"`
    RiskLevel           string                    `json:"risk_level"`
}

func (dto *DataTransferOptimizer) AnalyzeTransferPatterns(ctx context.Context, 
    days int) ([]TransferPattern, error) {
    
    // Collect transfer data from all providers
    transferData, err := dto.collectTransferData(ctx, days)
    if err != nil {
        return nil, fmt.Errorf("failed to collect transfer data: %w", err)
    }
    
    // Analyze patterns
    patterns := dto.identifyTransferPatterns(transferData)
    
    // Calculate costs
    for i, pattern := range patterns {
        patterns[i] = dto.enrichWithCostData(pattern)
    }
    
    return patterns, nil
}

func (dto *DataTransferOptimizer) OptimizeTransfers(ctx context.Context, 
    patterns []TransferPattern) ([]TransferOptimization, error) {
    
    var optimizations []TransferOptimization
    
    for _, pattern := range patterns {
        optimization := dto.optimizePattern(pattern)
        if optimization != nil {
            optimizations = append(optimizations, *optimization)
        }
    }
    
    // Sort by cost savings
    sort.Slice(optimizations, func(i, j int) bool {
        return optimizations[i].CostSavings > optimizations[j].CostSavings
    })
    
    return optimizations, nil
}

func (dto *DataTransferOptimizer) optimizePattern(pattern TransferPattern) *TransferOptimization {
    // Strategy 1: Regional optimization
    regionalOpt := dto.optimizeRegionalPlacement(pattern)
    
    // Strategy 2: CDN optimization
    cdnOpt := dto.optimizeCDNUsage(pattern)
    
    // Strategy 3: Compression optimization
    compressionOpt := dto.optimizeCompression(pattern)
    
    // Strategy 4: Scheduling optimization
    schedulingOpt := dto.optimizeScheduling(pattern)
    
    // Choose best optimization
    optimizations := []*TransferOptimization{
        regionalOpt, cdnOpt, compressionOpt, schedulingOpt,
    }
    
    var bestOpt *TransferOptimization
    maxSavings := 0.0
    
    for _, opt := range optimizations {
        if opt != nil && opt.CostSavings > maxSavings {
            maxSavings = opt.CostSavings
            bestOpt = opt
        }
    }
    
    return bestOpt
}

func (dto *DataTransferOptimizer) optimizeRegionalPlacement(pattern TransferPattern) *TransferOptimization {
    // Find cheaper route through different regions
    currentCost := dto.calculateTransferCost(pattern.Source, pattern.Destination, pattern.Volume)
    
    // Try alternative routes
    alternatives := dto.findAlternativeRoutes(pattern.Source, pattern.Destination)
    
    bestCost := currentCost
    bestRoute := ""
    
    for _, route := range alternatives {
        routeCost := dto.calculateRouteCost(route, pattern.Volume)
        if routeCost < bestCost {
            bestCost = routeCost
            bestRoute = route.Description
        }
    }
    
    if bestCost < currentCost {
        optimizedPattern := pattern
        optimizedPattern.Source = dto.getRouteSource(bestRoute)
        optimizedPattern.Destination = dto.getRouteDestination(bestRoute)
        
        return &TransferOptimization{
            CurrentPattern:       pattern,
            OptimizedPattern:     optimizedPattern,
            OptimizationStrategy: "Regional Route Optimization",
            CostSavings:          currentCost - bestCost,
            LatencyImpact:        dto.calculateLatencyImpact(bestRoute),
            ImplementationSteps:  dto.getRegionalOptimizationSteps(bestRoute),
            RiskLevel:           "medium",
        }
    }
    
    return nil
}

func (dto *DataTransferOptimizer) optimizeCDNUsage(pattern TransferPattern) *TransferOptimization {
    // Check if CDN can reduce costs for this transfer pattern
    if pattern.DataType != "files" && pattern.DataType != "api" {
        return nil // CDN not suitable
    }
    
    currentCost := dto.calculateTransferCost(pattern.Source, pattern.Destination, pattern.Volume)
    
    // Calculate CDN costs across providers
    cdnOptions := []struct {
        Provider CloudProvider
        Service  string
        Cost     float64
    }{
        {AWS, "CloudFront", dto.calculateCDNCost(AWS, pattern.Volume)},
        {Azure, "CDN", dto.calculateCDNCost(Azure, pattern.Volume)},
        {GCP, "Cloud CDN", dto.calculateCDNCost(GCP, pattern.Volume)},
    }
    
    // Find cheapest CDN option
    bestCDN := cdnOptions[0]
    for _, cdn := range cdnOptions[1:] {
        if cdn.Cost < bestCDN.Cost {
            bestCDN = cdn
        }
    }
    
    if bestCDN.Cost < currentCost {
        optimizedPattern := pattern
        optimizedPattern.Source = fmt.Sprintf("%s-cdn", bestCDN.Provider)
        
        return &TransferOptimization{
            CurrentPattern:       pattern,
            OptimizedPattern:     optimizedPattern,
            OptimizationStrategy: fmt.Sprintf("%s CDN Implementation", bestCDN.Provider),
            CostSavings:          currentCost - bestCDN.Cost,
            LatencyImpact:        -50, // CDN typically reduces latency
            ImplementationSteps:  dto.getCDNImplementationSteps(bestCDN),
            RiskLevel:           "low",
        }
    }
    
    return nil
}
```

### 4. Multi-Cloud Budget Management

```go
// Multi-cloud budget and forecasting system
type MultiCloudBudgetManager struct {
    costManager *MultiCloudCostManager
    budgets     map[string]MultiCloudBudget
    forecaster  *CostForecaster
}

type MultiCloudBudget struct {
    ID               string                    `json:"id"`
    Name             string                    `json:"name"`
    TotalAmount      float64                   `json:"total_amount"`
    Period           string                    `json:"period"`
    StartDate        time.Time                 `json:"start_date"`
    EndDate          time.Time                 `json:"end_date"`
    ProviderLimits   map[CloudProvider]float64 `json:"provider_limits"`
    ServiceLimits    map[string]float64        `json:"service_limits"`
    RegionLimits     map[string]float64        `json:"region_limits"`
    AlertThresholds  []AlertThreshold          `json:"alert_thresholds"`
    SpentAmounts     BudgetSpent               `json:"spent_amounts"`
    ForecastedSpend  float64                   `json:"forecasted_spend"`
    Status           string                    `json:"status"`
    CreatedAt        time.Time                 `json:"created_at"`
}

type BudgetSpent struct {
    Total      float64                   `json:"total"`
    ByProvider map[CloudProvider]float64 `json:"by_provider"`
    ByService  map[string]float64        `json:"by_service"`
    ByRegion   map[string]float64        `json:"by_region"`
    LastUpdated time.Time                `json:"last_updated"`
}

type AlertThreshold struct {
    Percentage float64  `json:"percentage"`
    Recipients []string `json:"recipients"`
    Actions    []string `json:"actions"`
    Triggered  bool     `json:"triggered"`
}

type CostForecast struct {
    Period           string                    `json:"period"`
    TotalForecast    float64                   `json:"total_forecast"`
    ProviderForecast map[CloudProvider]float64 `json:"provider_forecast"`
    ServiceForecast  map[string]float64        `json:"service_forecast"`
    Confidence       float64                   `json:"confidence"`
    ForecastModel    string                    `json:"forecast_model"`
    CreatedAt        time.Time                 `json:"created_at"`
}

func (mcbm *MultiCloudBudgetManager) CreateBudget(budget MultiCloudBudget) error {
    // Validate budget constraints
    if err := mcbm.validateBudget(budget); err != nil {
        return fmt.Errorf("budget validation failed: %w", err)
    }
    
    // Set initial spent amounts
    budget.SpentAmounts = BudgetSpent{
        ByProvider: make(map[CloudProvider]float64),
        ByService:  make(map[string]float64),
        ByRegion:   make(map[string]float64),
    }
    
    budget.Status = "active"
    budget.CreatedAt = time.Now()
    
    mcbm.budgets[budget.ID] = budget
    
    return nil
}

func (mcbm *MultiCloudBudgetManager) UpdateBudgetSpend(ctx context.Context) error {
    // Get recent cost data
    endTime := time.Now()
    startTime := endTime.AddDate(0, 0, -1) // Yesterday
    
    costs, err := mcbm.costManager.CollectCostData(ctx, startTime, endTime)
    if err != nil {
        return fmt.Errorf("failed to collect cost data: %w", err)
    }
    
    // Update each budget
    for budgetID, budget := range mcbm.budgets {
        updatedBudget := mcbm.updateBudgetWithCosts(budget, costs)
        
        // Check alert thresholds
        mcbm.checkAlertThresholds(ctx, updatedBudget)
        
        // Update forecast
        forecast, err := mcbm.forecaster.GenerateForecast(ctx, budgetID, 30)
        if err == nil {
            updatedBudget.ForecastedSpend = forecast.TotalForecast
        }
        
        mcbm.budgets[budgetID] = updatedBudget
    }
    
    return nil
}

func (mcbm *MultiCloudBudgetManager) checkAlertThresholds(ctx context.Context, 
    budget MultiCloudBudget) {
    
    spentPercentage := (budget.SpentAmounts.Total / budget.TotalAmount) * 100
    
    for i, threshold := range budget.AlertThresholds {
        if !threshold.Triggered && spentPercentage >= threshold.Percentage {
            // Trigger alert
            alert := BudgetAlert{
                BudgetID:        budget.ID,
                BudgetName:      budget.Name,
                Threshold:       threshold.Percentage,
                SpentPercentage: spentPercentage,
                SpentAmount:     budget.SpentAmounts.Total,
                BudgetAmount:    budget.TotalAmount,
                Period:          budget.Period,
                ForecastedSpend: budget.ForecastedSpend,
                Timestamp:       time.Now(),
            }
            
            mcbm.sendBudgetAlert(ctx, alert, threshold)
            
            // Mark as triggered
            budget.AlertThresholds[i].Triggered = true
            
            // Execute actions
            for _, action := range threshold.Actions {
                mcbm.executeBudgetAction(ctx, action, budget)
            }
        }
    }
}

type BudgetAlert struct {
    BudgetID        string    `json:"budget_id"`
    BudgetName      string    `json:"budget_name"`
    Threshold       float64   `json:"threshold"`
    SpentPercentage float64   `json:"spent_percentage"`
    SpentAmount     float64   `json:"spent_amount"`
    BudgetAmount    float64   `json:"budget_amount"`
    Period          string    `json:"period"`
    ForecastedSpend float64   `json:"forecasted_spend"`
    Timestamp       time.Time `json:"timestamp"`
}

func (mcbm *MultiCloudBudgetManager) GenerateMultiCloudReport(ctx context.Context, 
    period string) (*MultiCloudCostReport, error) {
    
    report := &MultiCloudCostReport{
        Period:    period,
        CreatedAt: time.Now(),
    }
    
    // Collect cost data for the period
    startDate, endDate := mcbm.getPeriodDates(period)
    costs, err := mcbm.costManager.CollectCostData(ctx, startDate, endDate)
    if err != nil {
        return nil, fmt.Errorf("failed to collect cost data: %w", err)
    }
    
    // Aggregate by provider
    providerCosts := make(map[CloudProvider]float64)
    serviceCosts := make(map[string]float64)
    regionCosts := make(map[string]float64)
    
    for _, cost := range costs {
        providerCosts[cost.Provider] += cost.Cost
        serviceCosts[cost.Service] += cost.Cost
        regionCosts[cost.Region] += cost.Cost
        report.TotalCost += cost.Cost
    }
    
    report.CostByProvider = providerCosts
    report.CostByService = serviceCosts
    report.CostByRegion = regionCosts
    
    // Calculate provider percentages
    report.ProviderShare = make(map[CloudProvider]float64)
    for provider, cost := range providerCosts {
        report.ProviderShare[provider] = (cost / report.TotalCost) * 100
    }
    
    // Generate cost optimization recommendations
    report.OptimizationOpportunities = mcbm.generateOptimizationRecommendations(costs)
    
    // Calculate efficiency metrics
    report.EfficiencyMetrics = mcbm.calculateEfficiencyMetrics(costs)
    
    return report, nil
}

type MultiCloudCostReport struct {
    Period                     string                         `json:"period"`
    TotalCost                  float64                        `json:"total_cost"`
    CostByProvider             map[CloudProvider]float64      `json:"cost_by_provider"`
    CostByService              map[string]float64             `json:"cost_by_service"`
    CostByRegion               map[string]float64             `json:"cost_by_region"`
    ProviderShare              map[CloudProvider]float64      `json:"provider_share"`
    OptimizationOpportunities  []OptimizationOpportunity     `json:"optimization_opportunities"`
    EfficiencyMetrics          EfficiencyMetrics              `json:"efficiency_metrics"`
    CreatedAt                  time.Time                      `json:"created_at"`
}

type OptimizationOpportunity struct {
    Type                string                    `json:"type"`
    Description         string                    `json:"description"`
    PotentialSavings    float64                   `json:"potential_savings"`
    ImplementationEffort string                   `json:"implementation_effort"`
    RiskLevel           string                    `json:"risk_level"`
    Providers           []CloudProvider           `json:"providers"`
}

type EfficiencyMetrics struct {
    CostPerUser         float64 `json:"cost_per_user"`
    CostPerTransaction  float64 `json:"cost_per_transaction"`
    CostPerGB           float64 `json:"cost_per_gb"`
    WastePercentage     float64 `json:"waste_percentage"`
    OptimizationScore   float64 `json:"optimization_score"`
}
```

### 5. Monitoring and Alerting

```yaml
# Multi-cloud monitoring dashboard
apiVersion: v1
kind: ConfigMap
metadata:
  name: multicloud-dashboard
data:
  dashboard.json: |
    {
      "dashboard": {
        "title": "Multi-Cloud Cost Management",
        "panels": [
          {
            "title": "Total Multi-Cloud Spend",
            "type": "stat",
            "targets": [
              {
                "expr": "sum(multicloud_cost_usd)",
                "legendFormat": "Total Cost"
              }
            ]
          },
          {
            "title": "Cost by Provider",
            "type": "piechart",
            "targets": [
              {
                "expr": "sum by (provider) (multicloud_cost_usd)",
                "legendFormat": "{{provider}}"
              }
            ]
          },
          {
            "title": "Provider Cost Share",
            "type": "graph",
            "targets": [
              {
                "expr": "provider_cost_share_percent",
                "legendFormat": "{{provider}}"
              }
            ]
          },
          {
            "title": "Service Cost Comparison",
            "type": "table",
            "targets": [
              {
                "expr": "service_equivalent_cost_usd",
                "format": "table"
              }
            ]
          },
          {
            "title": "Regional Cost Distribution",
            "type": "worldmap",
            "targets": [
              {
                "expr": "sum by (region) (multicloud_cost_usd)",
                "legendFormat": "{{region}}"
              }
            ]
          }
        ]
      }
    }

---
# Prometheus alerting rules
apiVersion: v1
kind: ConfigMap
metadata:
  name: multicloud-alerts
data:
  alerts.yml: |
    groups:
    - name: multicloud-cost-alerts
      rules:
      - alert: MultiCloudBudgetExceeded
        expr: multicloud_budget_spent_percent > 100
        for: 5m
        labels:
          severity: critical
          team: finops
        annotations:
          summary: "Multi-cloud budget exceeded"
          description: "Budget {{ $labels.budget_name }} has exceeded 100% of allocated amount"
          
      - alert: ProviderCostImbalance
        expr: max(provider_cost_share_percent) - min(provider_cost_share_percent) > 70
        for: 30m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Significant cost imbalance between providers"
          description: "Cost distribution is heavily skewed towards one provider"
          
      - alert: DataTransferCostSpike
        expr: increase(multicloud_cost_usd{service=~".*transfer.*"}[1h]) > 500
        for: 15m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "High data transfer costs detected"
          description: "Data transfer costs increased by ${{ $value }} in the last hour"
```

## Best Practices

### 1. Cost Allocation Strategy
- Implement consistent tagging across all cloud providers
- Use standardized cost allocation keys (team, project, environment)
- Create mapping tables for equivalent services across clouds
- Regular auditing of tag compliance

### 2. Data Transfer Optimization
- Minimize cross-cloud data transfers where possible
- Use CDN services to reduce origin data transfer costs
- Implement data compression for large transfers
- Schedule non-critical transfers during off-peak hours

### 3. Service Selection Criteria
- Evaluate total cost of ownership, not just compute costs
- Consider data egress costs in service selection
- Factor in operational complexity and learning curve
- Assess compliance and security requirements

### 4. Multi-Cloud Governance
- Establish clear policies for cloud service selection
- Implement approval workflows for new services
- Regular cross-cloud cost reviews and optimization
- Maintain service catalog with cost comparisons

## Success Metrics

- **Cost Visibility**: 100% of multi-cloud spend tracked and allocated
- **Cost Optimization**: 15-25% reduction through cross-cloud optimization
- **Budget Adherence**: 95% of budgets maintained within thresholds
- **Data Transfer Efficiency**: 30-50% reduction in transfer costs
- **Decision Speed**: <24 hours for cloud service selection decisions

## Consequences

### Positive
- **Unified Visibility**: Complete picture of multi-cloud spending
- **Optimized Placement**: Workloads placed on most cost-effective platforms
- **Reduced Transfer Costs**: Optimized data movement between clouds
- **Better Negotiations**: Leverage multiple providers for better pricing

### Negative
- **Increased Complexity**: More systems and processes to manage
- **Integration Challenges**: Complex data collection and normalization
- **Skill Requirements**: Need expertise across multiple cloud platforms
- **Vendor Management**: More relationships and contracts to manage

## References

- [AWS Multi-Account Cost Management](https://docs.aws.amazon.com/cost-management/)
- [Azure Cost Management](https://docs.microsoft.com/en-us/azure/cost-management-billing/)
- [Google Cloud Cost Management](https://cloud.google.com/cost-management)
- [Multi-Cloud Cost Optimization Best Practices](https://www.finops.org/framework/)

## Related ADRs

- [001-rationality](./001-rationality.md) - General FinOps principles
- [003-storage-cost-optimization](./003-storage-cost-optimization.md) - Storage optimization across clouds
- [004-infrastructure-rightsizing](./004-infrastructure-rightsizing.md) - Right-sizing in multi-cloud environments
