# Cloud Storage Cost Optimization

## Status
**Accepted** - 2024-01-20

## Context
Cloud storage costs can represent 20-40% of total cloud spend, yet many organizations lack proper storage lifecycle management, data tiering strategies, and cost optimization practices. With data growth rates often exceeding 50% annually, unmanaged storage costs can quickly spiral out of control.

## Problem Statement
Organizations struggle with:
- Exponential growth in storage costs without corresponding business value
- Lack of visibility into storage usage patterns and access frequencies
- Inefficient data lifecycle management
- Over-provisioned storage with poor utilization
- Duplicate and stale data consuming expensive storage tiers
- Inadequate backup and archival strategies leading to unnecessary costs

## Decision
Implement comprehensive cloud storage cost optimization through automated lifecycle management, intelligent tiering, deduplication, and continuous monitoring.

## Implementation

### 1. Storage Cost Analysis and Monitoring

```go
// Cloud storage cost analyzer
package storage

import (
    "context"
    "fmt"
    "time"
    
    "github.com/aws/aws-sdk-go-v2/service/s3"
    "github.com/aws/aws-sdk-go-v2/service/cloudwatch"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

type StorageClass string

const (
    Standard           StorageClass = "STANDARD"
    StandardIA         StorageClass = "STANDARD_IA"
    OneZoneIA          StorageClass = "ONEZONE_IA"
    ReducedRedundancy  StorageClass = "REDUCED_REDUNDANCY"
    Glacier            StorageClass = "GLACIER"
    GlacierIR          StorageClass = "GLACIER_IR"
    DeepArchive        StorageClass = "DEEP_ARCHIVE"
    IntelligentTiering StorageClass = "INTELLIGENT_TIERING"
)

type StorageMetrics struct {
    BucketName     string       `json:"bucket_name"`
    StorageClass   StorageClass `json:"storage_class"`
    TotalSize      int64        `json:"total_size_bytes"`
    ObjectCount    int64        `json:"object_count"`
    MonthlyCost    float64      `json:"monthly_cost"`
    LastAccessed   time.Time    `json:"last_accessed"`
    AccessFrequency int64       `json:"access_frequency"`
    Team           string       `json:"team"`
    Project        string       `json:"project"`
    Environment    string       `json:"environment"`
}

var (
    storageSize = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "cloud_storage_size_bytes",
            Help: "Total storage size in bytes",
        },
        []string{"bucket", "storage_class", "team", "project", "environment"},
    )
    
    storageCost = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "cloud_storage_cost_usd_monthly",
            Help: "Monthly storage cost in USD",
        },
        []string{"bucket", "storage_class", "team", "project", "environment"},
    )
    
    storageAccessFrequency = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "cloud_storage_access_frequency",
            Help: "Storage access frequency per month",
        },
        []string{"bucket", "storage_class", "team", "project", "environment"},
    )
)

type StorageCostAnalyzer struct {
    s3Client         *s3.Client
    cloudwatchClient *cloudwatch.Client
    pricingTable     map[StorageClass]StoragePricing
}

type StoragePricing struct {
    StorageClass     StorageClass `json:"storage_class"`
    PricePerGBMonth  float64      `json:"price_per_gb_month"`
    RequestPricePut  float64      `json:"request_price_put"`
    RequestPriceGet  float64      `json:"request_price_get"`
    RetrievalPrice   float64      `json:"retrieval_price"`
    MinStorageDuration int        `json:"min_storage_duration_days"`
}

func NewStorageCostAnalyzer(s3Client *s3.Client, cwClient *cloudwatch.Client) *StorageCostAnalyzer {
    analyzer := &StorageCostAnalyzer{
        s3Client:         s3Client,
        cloudwatchClient: cwClient,
        pricingTable:     make(map[StorageClass]StoragePricing),
    }
    
    // Initialize AWS S3 pricing (US East 1, as of 2024)
    analyzer.loadPricingData()
    return analyzer
}

func (sca *StorageCostAnalyzer) loadPricingData() {
    pricing := []StoragePricing{
        {Standard, 0.023, 0.0005, 0.0004, 0, 0},
        {StandardIA, 0.0125, 0.001, 0.001, 0.01, 30},
        {OneZoneIA, 0.01, 0.001, 0.001, 0.01, 30},
        {Glacier, 0.004, 0.03, 0.0004, 0.01, 90},
        {GlacierIR, 0.0036, 0.03, 0.001, 0.03, 90},
        {DeepArchive, 0.00099, 0.05, 0.0004, 0.02, 180},
        {IntelligentTiering, 0.023, 0.0025, 0.0004, 0, 0}, // Plus monitoring fee
    }
    
    for _, p := range pricing {
        sca.pricingTable[p.StorageClass] = p
    }
}

func (sca *StorageCostAnalyzer) AnalyzeBucketCosts(ctx context.Context, bucketName string) ([]StorageMetrics, error) {
    // Get bucket inventory
    inventory, err := sca.getBucketInventory(ctx, bucketName)
    if err != nil {
        return nil, fmt.Errorf("failed to get bucket inventory: %w", err)
    }
    
    // Get access patterns from CloudWatch
    accessPatterns, err := sca.getAccessPatterns(ctx, bucketName, 30) // Last 30 days
    if err != nil {
        return nil, fmt.Errorf("failed to get access patterns: %w", err)
    }
    
    var metrics []StorageMetrics
    
    // Group by storage class
    classMetrics := make(map[StorageClass]*StorageMetrics)
    
    for _, object := range inventory {
        class := StorageClass(object.StorageClass)
        
        if metric, exists := classMetrics[class]; exists {
            metric.TotalSize += object.Size
            metric.ObjectCount++
        } else {
            // Get bucket tags for cost allocation
            tags, _ := sca.getBucketTags(ctx, bucketName)
            
            classMetrics[class] = &StorageMetrics{
                BucketName:     bucketName,
                StorageClass:   class,
                TotalSize:      object.Size,
                ObjectCount:    1,
                Team:           tags["Team"],
                Project:        tags["Project"],
                Environment:    tags["Environment"],
                AccessFrequency: accessPatterns[bucketName],
            }
        }
    }
    
    // Calculate costs
    for _, metric := range classMetrics {
        pricing := sca.pricingTable[metric.StorageClass]
        sizeGB := float64(metric.TotalSize) / (1024 * 1024 * 1024)
        metric.MonthlyCost = sizeGB * pricing.PricePerGBMonth
        
        // Update Prometheus metrics
        labels := []string{
            metric.BucketName,
            string(metric.StorageClass),
            metric.Team,
            metric.Project,
            metric.Environment,
        }
        
        storageSize.WithLabelValues(labels...).Set(float64(metric.TotalSize))
        storageCost.WithLabelValues(labels...).Set(metric.MonthlyCost)
        storageAccessFrequency.WithLabelValues(labels...).Set(float64(metric.AccessFrequency))
        
        metrics = append(metrics, *metric)
    }
    
    return metrics, nil
}
```

### 2. Automated Lifecycle Management

```go
// Intelligent storage lifecycle management
type LifecycleManager struct {
    s3Client *s3.Client
    rules    []LifecycleRule
    analyzer *StorageCostAnalyzer
}

type LifecycleRule struct {
    ID                    string            `json:"id"`
    Prefix                string            `json:"prefix"`
    Tags                  map[string]string `json:"tags"`
    Transitions           []Transition      `json:"transitions"`
    ExpirationDays        int               `json:"expiration_days"`
    AbortIncompleteUploads int              `json:"abort_incomplete_uploads"`
    Enabled               bool              `json:"enabled"`
}

type Transition struct {
    Days         int          `json:"days"`
    StorageClass StorageClass `json:"storage_class"`
}

func (lm *LifecycleManager) GenerateOptimalRules(ctx context.Context, bucketName string) ([]LifecycleRule, error) {
    // Analyze current usage patterns
    metrics, err := lm.analyzer.AnalyzeBucketCosts(ctx, bucketName)
    if err != nil {
        return nil, err
    }
    
    // Get access patterns for the last 90 days
    accessPatterns, err := lm.getDetailedAccessPatterns(ctx, bucketName, 90)
    if err != nil {
        return nil, err
    }
    
    var rules []LifecycleRule
    
    // Generate rules based on access patterns
    for prefix, pattern := range accessPatterns {
        rule := lm.generateRuleForPattern(prefix, pattern)
        if rule != nil {
            rules = append(rules, *rule)
        }
    }
    
    return rules, nil
}

func (lm *LifecycleManager) generateRuleForPattern(prefix string, pattern AccessPattern) *LifecycleRule {
    if pattern.AvgDaysSinceLastAccess < 30 {
        // Frequently accessed data - keep in Standard
        return &LifecycleRule{
            ID:      fmt.Sprintf("frequent-access-%s", prefix),
            Prefix:  prefix,
            Enabled: true,
            Transitions: []Transition{
                {Days: 30, StorageClass: StandardIA},   // After 30 days
                {Days: 90, StorageClass: Glacier},      // After 90 days
                {Days: 365, StorageClass: DeepArchive}, // After 1 year
            },
            ExpirationDays:        2555, // 7 years
            AbortIncompleteUploads: 7,
        }
    } else if pattern.AvgDaysSinceLastAccess < 90 {
        // Infrequently accessed - move to IA faster
        return &LifecycleRule{
            ID:      fmt.Sprintf("infrequent-access-%s", prefix),
            Prefix:  prefix,
            Enabled: true,
            Transitions: []Transition{
                {Days: 7, StorageClass: StandardIA},    // After 7 days
                {Days: 30, StorageClass: Glacier},      // After 30 days
                {Days: 180, StorageClass: DeepArchive}, // After 6 months
            },
            ExpirationDays:        1825, // 5 years
            AbortIncompleteUploads: 3,
        }
    } else {
        // Rarely accessed - aggressive archiving
        return &LifecycleRule{
            ID:      fmt.Sprintf("archive-%s", prefix),
            Prefix:  prefix,
            Enabled: true,
            Transitions: []Transition{
                {Days: 1, StorageClass: StandardIA},    // Immediate
                {Days: 7, StorageClass: Glacier},       // After 7 days
                {Days: 30, StorageClass: DeepArchive},  // After 30 days
            },
            ExpirationDays:        1095, // 3 years
            AbortIncompleteUploads: 1,
        }
    }
}

type AccessPattern struct {
    Prefix                  string  `json:"prefix"`
    TotalAccesses          int64   `json:"total_accesses"`
    AvgDaysSinceLastAccess float64 `json:"avg_days_since_last_access"`
    ReadWriteRatio         float64 `json:"read_write_ratio"`
    SizeBytes              int64   `json:"size_bytes"`
}

func (lm *LifecycleManager) ApplyLifecycleRules(ctx context.Context, bucketName string, rules []LifecycleRule) error {
    // Convert to AWS S3 lifecycle configuration
    lifecycleConfig := &s3.PutBucketLifecycleConfigurationInput{
        Bucket: &bucketName,
        LifecycleConfiguration: &s3Types.BucketLifecycleConfiguration{
            Rules: make([]s3Types.LifecycleRule, 0, len(rules)),
        },
    }
    
    for _, rule := range rules {
        s3Rule := s3Types.LifecycleRule{
            ID:     &rule.ID,
            Status: s3Types.ExpirationStatus("Enabled"),
            Filter: &s3Types.LifecycleRuleFilter{
                Prefix: &rule.Prefix,
            },
        }
        
        // Add transitions
        for _, transition := range rule.Transitions {
            s3Rule.Transitions = append(s3Rule.Transitions, s3Types.Transition{
                Days:         int32(transition.Days),
                StorageClass: s3Types.TransitionStorageClass(transition.StorageClass),
            })
        }
        
        // Add expiration
        if rule.ExpirationDays > 0 {
            s3Rule.Expiration = &s3Types.LifecycleExpiration{
                Days: int32(rule.ExpirationDays),
            }
        }
        
        // Add incomplete multipart upload abortion
        if rule.AbortIncompleteUploads > 0 {
            s3Rule.AbortIncompleteMultipartUpload = &s3Types.AbortIncompleteMultipartUpload{
                DaysAfterInitiation: int32(rule.AbortIncompleteUploads),
            }
        }
        
        lifecycleConfig.LifecycleConfiguration.Rules = append(
            lifecycleConfig.LifecycleConfiguration.Rules, s3Rule)
    }
    
    _, err := lm.s3Client.PutBucketLifecycleConfiguration(ctx, lifecycleConfig)
    return err
}
```

### 3. Data Deduplication and Cleanup

```go
// Data deduplication and cleanup system
type DataDeduplicator struct {
    s3Client    *s3.Client
    hashStorage map[string][]string // hash -> []object_keys
    duplicates  []DuplicateGroup
}

type DuplicateGroup struct {
    Hash           string            `json:"hash"`
    Objects        []DuplicateObject `json:"objects"`
    TotalSize      int64             `json:"total_size"`
    PotentialSavings float64         `json:"potential_savings"`
}

type DuplicateObject struct {
    Key          string    `json:"key"`
    Size         int64     `json:"size"`
    LastModified time.Time `json:"last_modified"`
    StorageClass string    `json:"storage_class"`
    Cost         float64   `json:"monthly_cost"`
}

func (dd *DataDeduplicator) ScanForDuplicates(ctx context.Context, bucketName string) error {
    dd.hashStorage = make(map[string][]string)
    dd.duplicates = nil
    
    // List all objects and calculate hashes
    paginator := s3.NewListObjectsV2Paginator(dd.s3Client, &s3.ListObjectsV2Input{
        Bucket: &bucketName,
    })
    
    for paginator.HasMorePages() {
        page, err := paginator.NextPage(ctx)
        if err != nil {
            return fmt.Errorf("failed to list objects: %w", err)
        }
        
        for _, object := range page.Contents {
            // Calculate object hash (using ETag as approximation)
            hash := strings.Trim(*object.ETag, "\"")
            
            if _, exists := dd.hashStorage[hash]; !exists {
                dd.hashStorage[hash] = make([]string, 0)
            }
            dd.hashStorage[hash] = append(dd.hashStorage[hash], *object.Key)
        }
    }
    
    // Identify duplicates
    for hash, objects := range dd.hashStorage {
        if len(objects) > 1 {
            duplicateGroup := DuplicateGroup{
                Hash:    hash,
                Objects: make([]DuplicateObject, 0, len(objects)),
            }
            
            for _, objectKey := range objects {
                // Get object details
                headOutput, err := dd.s3Client.HeadObject(ctx, &s3.HeadObjectInput{
                    Bucket: &bucketName,
                    Key:    &objectKey,
                })
                if err != nil {
                    continue
                }
                
                obj := DuplicateObject{
                    Key:          objectKey,
                    Size:         headOutput.ContentLength,
                    LastModified: *headOutput.LastModified,
                    StorageClass: string(headOutput.StorageClass),
                }
                
                // Calculate cost
                obj.Cost = dd.calculateObjectCost(obj.Size, StorageClass(obj.StorageClass))
                
                duplicateGroup.Objects = append(duplicateGroup.Objects, obj)
                duplicateGroup.TotalSize += obj.Size
            }
            
            // Calculate potential savings (keep newest, delete others)
            sort.Slice(duplicateGroup.Objects, func(i, j int) bool {
                return duplicateGroup.Objects[i].LastModified.After(duplicateGroup.Objects[j].LastModified)
            })
            
            for i := 1; i < len(duplicateGroup.Objects); i++ {
                duplicateGroup.PotentialSavings += duplicateGroup.Objects[i].Cost
            }
            
            dd.duplicates = append(dd.duplicates, duplicateGroup)
        }
    }
    
    // Sort by potential savings
    sort.Slice(dd.duplicates, func(i, j int) bool {
        return dd.duplicates[i].PotentialSavings > dd.duplicates[j].PotentialSavings
    })
    
    return nil
}

func (dd *DataDeduplicator) GenerateCleanupReport() DeduplicationReport {
    totalSavings := 0.0
    totalObjects := 0
    totalSize := int64(0)
    
    for _, group := range dd.duplicates {
        totalSavings += group.PotentialSavings
        totalObjects += len(group.Objects) - 1 // Keep one copy
        totalSize += group.TotalSize - group.Objects[0].Size // Size of duplicates to remove
    }
    
    return DeduplicationReport{
        TotalDuplicateGroups: len(dd.duplicates),
        TotalObjectsToRemove: totalObjects,
        TotalSizeToRemove:   totalSize,
        PotentialMonthlySavings: totalSavings,
        DuplicateGroups:     dd.duplicates,
        GeneratedAt:         time.Now(),
    }
}

type DeduplicationReport struct {
    TotalDuplicateGroups    int              `json:"total_duplicate_groups"`
    TotalObjectsToRemove    int              `json:"total_objects_to_remove"`
    TotalSizeToRemove      int64            `json:"total_size_to_remove"`
    PotentialMonthlySavings float64          `json:"potential_monthly_savings"`
    DuplicateGroups        []DuplicateGroup `json:"duplicate_groups"`
    GeneratedAt            time.Time        `json:"generated_at"`
}

func (dd *DataDeduplicator) ExecuteCleanup(ctx context.Context, bucketName string, dryRun bool) error {
    deleted := 0
    failed := 0
    
    for _, group := range dd.duplicates {
        if len(group.Objects) <= 1 {
            continue
        }
        
        // Keep the newest object, delete others
        for i := 1; i < len(group.Objects); i++ {
            obj := group.Objects[i]
            
            if dryRun {
                log.Printf("Would delete: %s (size: %d, cost: $%.4f)", 
                    obj.Key, obj.Size, obj.Cost)
                continue
            }
            
            _, err := dd.s3Client.DeleteObject(ctx, &s3.DeleteObjectInput{
                Bucket: &bucketName,
                Key:    &obj.Key,
            })
            
            if err != nil {
                log.Printf("Failed to delete %s: %v", obj.Key, err)
                failed++
            } else {
                log.Printf("Deleted duplicate: %s", obj.Key)
                deleted++
            }
        }
    }
    
    log.Printf("Cleanup completed: %d deleted, %d failed", deleted, failed)
    return nil
}
```

### 4. Storage Class Optimization

```go
// Intelligent storage class recommendation engine
type StorageClassOptimizer struct {
    analyzer    *StorageCostAnalyzer
    costModel   CostModel
    accessModel AccessModel
}

type CostModel struct {
    StorageCosts    map[StorageClass]float64 // Per GB per month
    RequestCosts    map[StorageClass]RequestCosts
    RetrievalCosts  map[StorageClass]float64
    MinStorageDuration map[StorageClass]int // Days
}

type RequestCosts struct {
    Put float64 // Per 1000 requests
    Get float64 // Per 1000 requests
}

type AccessModel struct {
    AccessFrequency map[string]float64 // object_key -> accesses per month
    AccessPrediction map[string]AccessPrediction
}

type AccessPrediction struct {
    ObjectKey               string  `json:"object_key"`
    PredictedAccessesNext30Days float64 `json:"predicted_accesses_next_30_days"`
    PredictedAccessesNext90Days float64 `json:"predicted_accesses_next_90_days"`
    Confidence              float64 `json:"confidence"`
    CurrentStorageClass     StorageClass `json:"current_storage_class"`
    RecommendedStorageClass StorageClass `json:"recommended_storage_class"`
    PotentialMonthlySavings float64 `json:"potential_monthly_savings"`
}

func (sco *StorageClassOptimizer) AnalyzeAndRecommend(ctx context.Context, bucketName string) ([]AccessPrediction, error) {
    // Get historical access patterns
    accessHistory, err := sco.getAccessHistory(ctx, bucketName, 180) // 6 months
    if err != nil {
        return nil, fmt.Errorf("failed to get access history: %w", err)
    }
    
    // Predict future access patterns
    predictions := make([]AccessPrediction, 0)
    
    for objectKey, history := range accessHistory {
        prediction := sco.predictAccess(objectKey, history)
        recommendation := sco.recommendStorageClass(prediction)
        
        // Calculate potential savings
        currentCost := sco.calculateMonthlyCost(objectKey, prediction.CurrentStorageClass, 
            prediction.PredictedAccessesNext30Days)
        recommendedCost := sco.calculateMonthlyCost(objectKey, recommendation, 
            prediction.PredictedAccessesNext30Days)
        
        prediction.RecommendedStorageClass = recommendation
        prediction.PotentialMonthlySavings = currentCost - recommendedCost
        
        predictions = append(predictions, prediction)
    }
    
    // Sort by potential savings
    sort.Slice(predictions, func(i, j int) bool {
        return predictions[i].PotentialMonthlySavings > predictions[j].PotentialMonthlySavings
    })
    
    return predictions, nil
}

func (sco *StorageClassOptimizer) recommendStorageClass(prediction AccessPrediction) StorageClass {
    accesses30 := prediction.PredictedAccessesNext30Days
    accesses90 := prediction.PredictedAccessesNext90Days
    
    switch {
    case accesses30 > 10: // Frequently accessed
        return Standard
    case accesses30 > 3 && accesses90 > 5: // Moderately accessed
        return StandardIA
    case accesses30 > 1 && accesses90 > 2: // Infrequently accessed
        return OneZoneIA
    case accesses90 > 1: // Rarely accessed
        return Glacier
    case accesses90 > 0.1: // Very rarely accessed
        return GlacierIR
    default: // Archive
        return DeepArchive
    }
}

func (sco *StorageClassOptimizer) ExecuteRecommendations(ctx context.Context, bucketName string, 
    recommendations []AccessPrediction, minSavings float64) error {
    
    executed := 0
    totalSavings := 0.0
    
    for _, rec := range recommendations {
        if rec.PotentialMonthlySavings < minSavings {
            continue
        }
        
        // Copy object to new storage class
        copyInput := &s3.CopyObjectInput{
            Bucket:       &bucketName,
            Key:          &rec.ObjectKey,
            CopySource:   aws.String(fmt.Sprintf("%s/%s", bucketName, rec.ObjectKey)),
            StorageClass: s3Types.StorageClass(rec.RecommendedStorageClass),
            MetadataDirective: s3Types.MetadataDirective("COPY"),
        }
        
        _, err := sco.s3Client.CopyObject(ctx, copyInput)
        if err != nil {
            log.Printf("Failed to change storage class for %s: %v", rec.ObjectKey, err)
            continue
        }
        
        executed++
        totalSavings += rec.PotentialMonthlySavings
        
        log.Printf("Changed storage class for %s: %s -> %s (savings: $%.4f/month)",
            rec.ObjectKey, rec.CurrentStorageClass, rec.RecommendedStorageClass, 
            rec.PotentialMonthlySavings)
    }
    
    log.Printf("Storage class optimization completed: %d objects optimized, $%.2f monthly savings",
        executed, totalSavings)
    
    return nil
}
```

### 5. Monitoring and Alerting

```yaml
# Prometheus alerting rules for storage costs
groups:
- name: storage-cost-alerts
  rules:
  - alert: StorageCostSpike
    expr: increase(cloud_storage_cost_usd_monthly[1d]) > 100
    for: 15m
    labels:
      severity: warning
      team: finops
    annotations:
      summary: "Storage cost increased significantly"
      description: "Storage costs increased by ${{ $value }} in bucket {{ $labels.bucket }}"
      
  - alert: UnusedStorageDetected
    expr: cloud_storage_access_frequency == 0 and cloud_storage_size_bytes > 1073741824  # 1GB
    for: 7d
    labels:
      severity: info
      team: platform
    annotations:
      summary: "Unused storage detected"
      description: "Bucket {{ $labels.bucket }} has not been accessed in 7 days and contains {{ $value }} bytes"
      
  - alert: ExpensiveStorageClassUsage
    expr: (cloud_storage_cost_usd_monthly{storage_class="STANDARD"} / cloud_storage_size_bytes) > 0.000025  # $0.025/GB
    for: 1h
    labels:
      severity: warning
      team: finops
    annotations:
      summary: "Expensive storage class usage"
      description: "Bucket {{ $labels.bucket }} is using expensive storage class inefficiently"

  - alert: LifecyclePolicyMissing
    expr: up{job="storage-lifecycle-checker"} == 0
    for: 1h
    labels:
      severity: warning
      team: platform
    annotations:
      summary: "Storage lifecycle policy check failed"
      description: "Unable to verify lifecycle policies are properly configured"
```

### 6. Cost Optimization Dashboard

```yaml
# Grafana dashboard for storage cost optimization
apiVersion: v1
kind: ConfigMap
metadata:
  name: storage-cost-dashboard
data:
  dashboard.json: |
    {
      "dashboard": {
        "title": "Cloud Storage Cost Optimization",
        "panels": [
          {
            "title": "Storage Cost Trend",
            "type": "graph",
            "targets": [
              {
                "expr": "sum by (storage_class) (cloud_storage_cost_usd_monthly)",
                "legendFormat": "{{storage_class}}"
              }
            ]
          },
          {
            "title": "Storage Size by Class",
            "type": "piechart",
            "targets": [
              {
                "expr": "sum by (storage_class) (cloud_storage_size_bytes)",
                "legendFormat": "{{storage_class}}"
              }
            ]
          },
          {
            "title": "Top Expensive Buckets",
            "type": "table",
            "targets": [
              {
                "expr": "topk(10, sum by (bucket) (cloud_storage_cost_usd_monthly))",
                "format": "table"
              }
            ]
          },
          {
            "title": "Storage Access Patterns",
            "type": "heatmap",
            "targets": [
              {
                "expr": "cloud_storage_access_frequency",
                "legendFormat": "{{bucket}}"
              }
            ]
          },
          {
            "title": "Optimization Opportunities",
            "type": "stat",
            "targets": [
              {
                "expr": "sum(storage_optimization_potential_savings)",
                "legendFormat": "Potential Monthly Savings"
              }
            ]
          }
        ]
      }
    }
```

### 7. Automation Scripts

```bash
#!/bin/bash
# storage-optimization.sh - Daily storage optimization script

set -e

# Configuration
BUCKET_LIST_FILE="/config/buckets.txt"
MIN_SAVINGS_THRESHOLD=10.0  # Minimum $10 monthly savings
DRY_RUN=${DRY_RUN:-true}
LOG_LEVEL=${LOG_LEVEL:-INFO}

# Functions
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
}

analyze_bucket() {
    local bucket=$1
    log "INFO" "Analyzing bucket: $bucket"
    
    # Run cost analysis
    go run cmd/storage-analyzer/main.go \
        --bucket "$bucket" \
        --output-format json \
        --output-file "/tmp/${bucket}-analysis.json"
    
    # Generate lifecycle recommendations
    go run cmd/lifecycle-optimizer/main.go \
        --bucket "$bucket" \
        --analysis-file "/tmp/${bucket}-analysis.json" \
        --output-file "/tmp/${bucket}-lifecycle.json"
    
    # Generate storage class recommendations
    go run cmd/storage-class-optimizer/main.go \
        --bucket "$bucket" \
        --analysis-file "/tmp/${bucket}-analysis.json" \
        --min-savings "$MIN_SAVINGS_THRESHOLD" \
        --output-file "/tmp/${bucket}-storage-class.json"
    
    # Scan for duplicates
    go run cmd/deduplicator/main.go \
        --bucket "$bucket" \
        --output-file "/tmp/${bucket}-duplicates.json"
}

apply_optimizations() {
    local bucket=$1
    
    if [ "$DRY_RUN" = "true" ]; then
        log "INFO" "DRY RUN: Would apply optimizations to $bucket"
        return
    fi
    
    log "INFO" "Applying optimizations to bucket: $bucket"
    
    # Apply lifecycle policies
    if [ -f "/tmp/${bucket}-lifecycle.json" ]; then
        go run cmd/lifecycle-applier/main.go \
            --bucket "$bucket" \
            --config-file "/tmp/${bucket}-lifecycle.json"
    fi
    
    # Apply storage class changes
    if [ -f "/tmp/${bucket}-storage-class.json" ]; then
        go run cmd/storage-class-applier/main.go \
            --bucket "$bucket" \
            --config-file "/tmp/${bucket}-storage-class.json" \
            --min-savings "$MIN_SAVINGS_THRESHOLD"
    fi
    
    # Remove duplicates (with confirmation)
    if [ -f "/tmp/${bucket}-duplicates.json" ]; then
        go run cmd/duplicate-remover/main.go \
            --bucket "$bucket" \
            --config-file "/tmp/${bucket}-duplicates.json" \
            --auto-approve
    fi
}

# Main execution
log "INFO" "Starting storage optimization process"

if [ ! -f "$BUCKET_LIST_FILE" ]; then
    log "ERROR" "Bucket list file not found: $BUCKET_LIST_FILE"
    exit 1
fi

# Process each bucket
while IFS= read -r bucket; do
    if [ -n "$bucket" ] && [[ ! "$bucket" =~ ^# ]]; then
        analyze_bucket "$bucket"
        apply_optimizations "$bucket"
    fi
done < "$BUCKET_LIST_FILE"

# Generate summary report
log "INFO" "Generating optimization summary report"
go run cmd/optimization-reporter/main.go \
    --input-dir "/tmp" \
    --output-file "/reports/storage-optimization-$(date +%Y%m%d).json"

log "INFO" "Storage optimization process completed"
```

## Best Practices

### 1. Data Classification and Tagging
- Implement consistent tagging for cost allocation
- Classify data by access patterns and retention requirements
- Use tags to drive automated lifecycle policies

### 2. Storage Class Selection
- **Standard**: Frequently accessed data (>1 access/month)
- **Standard-IA**: Infrequently accessed data (>1 access/quarter)
- **Glacier**: Long-term backups and archives (>1 access/year)
- **Deep Archive**: Long-term archival (rare access)

### 3. Lifecycle Management
- Implement automated lifecycle policies for all buckets
- Review and adjust policies based on actual access patterns
- Consider using Intelligent Tiering for unpredictable access patterns

### 4. Cost Monitoring
- Set up alerts for unusual cost spikes
- Monitor storage class distribution and costs
- Track optimization opportunities and savings

## Success Metrics

- **Cost Reduction**: 30-50% reduction in storage costs
- **Storage Efficiency**: >80% of data in appropriate storage classes
- **Lifecycle Coverage**: 100% of buckets have lifecycle policies
- **Duplicate Reduction**: <5% duplicate data
- **Access Optimization**: >90% accuracy in access pattern predictions

## Consequences

### Positive
- **Significant Cost Savings**: 30-50% reduction in storage costs
- **Automated Management**: Reduced manual effort for lifecycle management
- **Better Data Governance**: Clear understanding of data usage patterns
- **Compliance**: Automated retention and deletion policies

### Negative
- **Complexity**: Additional infrastructure and monitoring required
- **Retrieval Delays**: Archived data has retrieval latency
- **Risk of Data Loss**: Aggressive deletion policies require careful validation
- **Initial Investment**: Time and resources to implement optimization

## References

- [AWS S3 Storage Classes](https://aws.amazon.com/s3/storage-classes/)
- [AWS S3 Lifecycle Management](https://docs.aws.amazon.com/s3/lifecycle/)
- [Google Cloud Storage Classes](https://cloud.google.com/storage/docs/storage-classes)
- [Azure Blob Storage Tiers](https://docs.microsoft.com/en-us/azure/storage/blobs/storage-blob-storage-tiers)

## Related ADRs

- [001-rationality](./001-rationality.md) - General FinOps principles
- [020-storage](../database/020-storage.md) - Database storage optimization
- [013-logging](../backend/013-logging.md) - Log retention and storage costs
