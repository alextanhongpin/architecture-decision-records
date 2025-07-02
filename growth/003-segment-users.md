# User Segmentation Strategy

## Status

`production`

## Context

User segmentation is a fundamental growth strategy that involves dividing users into distinct groups based on shared characteristics, behaviors, or needs. Effective segmentation enables personalized experiences, targeted marketing campaigns, and optimized product development. It transforms generic approaches into precision-targeted strategies that drive higher engagement and conversion rates.

## Decision

### Segmentation Frameworks

#### Demographic Segmentation
```
Age Groups: 18-25, 26-35, 36-45, 46-55, 55+
Location: Country, Region, City, Timezone
Gender: Male, Female, Non-binary, Prefer not to say
Income: Low, Middle, High, Enterprise
Occupation: Student, Professional, Executive, Retired
```

#### Behavioral Segmentation
```
Usage Frequency: Daily, Weekly, Monthly, Occasional
Feature Adoption: Power User, Feature Explorer, Basic User
Purchase Behavior: High-Value, Regular, One-time, Never
Engagement Level: Highly Engaged, Moderately Engaged, Low Engagement
Lifecycle Stage: New, Active, At-Risk, Churned, Reactivated
```

#### Psychographic Segmentation
```
Values: Innovation, Security, Convenience, Cost-effectiveness
Personality: Risk-taker, Conservative, Social, Independent
Lifestyle: Tech-savvy, Traditional, Mobile-first, Desktop-focused
Motivations: Efficiency, Status, Learning, Entertainment
```

#### Value-Based Segmentation
```
Customer Lifetime Value: High-value, Medium-value, Low-value
Revenue Contribution: Premium, Standard, Freemium
Support Cost: High-touch, Self-service, Automated
Retention Risk: Loyal, Stable, At-risk, Critical
```

### Segmentation Implementation Framework

```go
package segmentation

import (
    "context"
    "time"
    "math"
)

// UserSegment defines a user segment with its criteria and metadata
type UserSegment struct {
    ID          string                 `json:"id"`
    Name        string                 `json:"name"`
    Description string                 `json:"description"`
    Criteria    SegmentCriteria        `json:"criteria"`
    CreatedAt   time.Time              `json:"created_at"`
    UpdatedAt   time.Time              `json:"updated_at"`
    IsActive    bool                   `json:"is_active"`
    Priority    int                    `json:"priority"`
    Metadata    map[string]interface{} `json:"metadata"`
}

// SegmentCriteria defines the rules for segment membership
type SegmentCriteria struct {
    Demographics map[string]interface{} `json:"demographics"`
    Behaviors    map[string]interface{} `json:"behaviors"`
    Events       []EventCriterion       `json:"events"`
    Properties   []PropertyCriterion    `json:"properties"`
    TimeWindow   time.Duration          `json:"time_window"`
    Operator     string                 `json:"operator"` // AND, OR
}

// EventCriterion defines event-based segmentation rules
type EventCriterion struct {
    EventName   string        `json:"event_name"`
    Operator    string        `json:"operator"` // occurred, not_occurred, count_gt, count_lt
    Value       interface{}   `json:"value"`
    TimeWindow  time.Duration `json:"time_window"`
    Properties  map[string]interface{} `json:"properties"`
}

// PropertyCriterion defines property-based segmentation rules
type PropertyCriterion struct {
    PropertyName string      `json:"property_name"`
    Operator     string      `json:"operator"` // equals, not_equals, gt, lt, contains, etc.
    Value        interface{} `json:"value"`
}

// UserProfile contains comprehensive user data for segmentation
type UserProfile struct {
    UserID       string                 `json:"user_id"`
    Demographics Demographics           `json:"demographics"`
    Behaviors    BehaviorMetrics        `json:"behaviors"`
    Preferences  map[string]interface{} `json:"preferences"`
    Events       []UserEvent            `json:"events"`
    Properties   map[string]interface{} `json:"properties"`
    LastUpdated  time.Time              `json:"last_updated"`
}

// Demographics holds demographic information
type Demographics struct {
    Age         int    `json:"age"`
    Gender      string `json:"gender"`
    Country     string `json:"country"`
    City        string `json:"city"`
    Timezone    string `json:"timezone"`
    Language    string `json:"language"`
    Occupation  string `json:"occupation"`
}

// BehaviorMetrics tracks user behavior patterns
type BehaviorMetrics struct {
    SessionCount        int           `json:"session_count"`
    TotalSessionTime    time.Duration `json:"total_session_time"`
    AvgSessionDuration  time.Duration `json:"avg_session_duration"`
    LastActiveDate      time.Time     `json:"last_active_date"`
    DaysSinceLastActive int           `json:"days_since_last_active"`
    FeatureUsage        map[string]int `json:"feature_usage"`
    PurchaseHistory     []Purchase     `json:"purchase_history"`
    SupportTickets      int           `json:"support_tickets"`
    NPS                 int           `json:"nps"`
}

// Purchase represents a user purchase event
type Purchase struct {
    Amount    float64   `json:"amount"`
    Currency  string    `json:"currency"`
    ProductID string    `json:"product_id"`
    Date      time.Time `json:"date"`
}

// UserEvent represents a tracked user event
type UserEvent struct {
    EventName  string                 `json:"event_name"`
    Timestamp  time.Time              `json:"timestamp"`
    Properties map[string]interface{} `json:"properties"`
}

// SegmentEngine provides user segmentation capabilities
type SegmentEngine struct {
    segments    []UserSegment
    profiles    map[string]UserProfile
    mlModel     MLSegmentModel
    cache       SegmentCache
}

// EvaluateUserSegments determines which segments a user belongs to
func (se *SegmentEngine) EvaluateUserSegments(ctx context.Context, userID string) ([]string, error) {
    profile, exists := se.profiles[userID]
    if !exists {
        return nil, fmt.Errorf("user profile not found: %s", userID)
    }
    
    var memberSegments []string
    
    for _, segment := range se.segments {
        if !segment.IsActive {
            continue
        }
        
        isMember, err := se.evaluateSegmentCriteria(profile, segment.Criteria)
        if err != nil {
            return nil, fmt.Errorf("error evaluating segment %s: %w", segment.ID, err)
        }
        
        if isMember {
            memberSegments = append(memberSegments, segment.ID)
        }
    }
    
    // Cache results for performance
    se.cache.Set(userID, memberSegments, 1*time.Hour)
    
    return memberSegments, nil
}

// evaluateSegmentCriteria checks if user profile matches segment criteria
func (se *SegmentEngine) evaluateSegmentCriteria(profile UserProfile, criteria SegmentCriteria) (bool, error) {
    results := make([]bool, 0)
    
    // Evaluate demographic criteria
    if len(criteria.Demographics) > 0 {
        match := se.evaluateDemographics(profile.Demographics, criteria.Demographics)
        results = append(results, match)
    }
    
    // Evaluate behavioral criteria
    if len(criteria.Behaviors) > 0 {
        match := se.evaluateBehaviors(profile.Behaviors, criteria.Behaviors)
        results = append(results, match)
    }
    
    // Evaluate event criteria
    for _, eventCriterion := range criteria.Events {
        match := se.evaluateEventCriterion(profile.Events, eventCriterion)
        results = append(results, match)
    }
    
    // Evaluate property criteria
    for _, propertyCriterion := range criteria.Properties {
        match := se.evaluatePropertyCriterion(profile.Properties, propertyCriterion)
        results = append(results, match)
    }
    
    // Apply logical operator
    return se.applyLogicalOperator(results, criteria.Operator), nil
}

// CalculateCustomerLifetimeValue computes CLV for value-based segmentation
func (se *SegmentEngine) CalculateCustomerLifetimeValue(profile UserProfile) float64 {
    if len(profile.Behaviors.PurchaseHistory) == 0 {
        return 0
    }
    
    // Calculate average order value
    totalRevenue := 0.0
    for _, purchase := range profile.Behaviors.PurchaseHistory {
        totalRevenue += purchase.Amount
    }
    avgOrderValue := totalRevenue / float64(len(profile.Behaviors.PurchaseHistory))
    
    // Calculate purchase frequency (purchases per year)
    firstPurchase := profile.Behaviors.PurchaseHistory[0].Date
    lastPurchase := profile.Behaviors.PurchaseHistory[len(profile.Behaviors.PurchaseHistory)-1].Date
    daysBetween := lastPurchase.Sub(firstPurchase).Hours() / 24
    
    if daysBetween == 0 {
        daysBetween = 1
    }
    
    purchaseFrequency := float64(len(profile.Behaviors.PurchaseHistory)) / (daysBetween / 365)
    
    // Calculate customer lifespan (simplified - can be more sophisticated)
    customerLifespan := math.Max(1, daysBetween/365) // at least 1 year
    
    // CLV = Average Order Value × Purchase Frequency × Customer Lifespan
    clv := avgOrderValue * purchaseFrequency * customerLifespan
    
    return clv
}
```

### Advanced Segmentation Strategies

#### 1. RFM Segmentation (Recency, Frequency, Monetary)

```go
package rfm

import (
    "time"
    "math"
)

// RFMScore represents Recency, Frequency, and Monetary scores
type RFMScore struct {
    UserID    string  `json:"user_id"`
    Recency   int     `json:"recency"`   // 1-5 scale (5 = most recent)
    Frequency int     `json:"frequency"` // 1-5 scale (5 = most frequent)
    Monetary  int     `json:"monetary"`  // 1-5 scale (5 = highest value)
    RFMString string  `json:"rfm_string"` // e.g., "555", "111"
    Segment   string  `json:"segment"`
}

// CalculateRFMScore computes RFM scores for user segmentation
func CalculateRFMScore(profile UserProfile) RFMScore {
    now := time.Now()
    
    // Calculate Recency (days since last purchase)
    var lastPurchaseDate time.Time
    if len(profile.Behaviors.PurchaseHistory) > 0 {
        lastPurchaseDate = profile.Behaviors.PurchaseHistory[len(profile.Behaviors.PurchaseHistory)-1].Date
    }
    
    daysSinceLastPurchase := int(now.Sub(lastPurchaseDate).Hours() / 24)
    recencyScore := calculateRecencyScore(daysSinceLastPurchase)
    
    // Calculate Frequency (number of purchases)
    frequencyScore := calculateFrequencyScore(len(profile.Behaviors.PurchaseHistory))
    
    // Calculate Monetary (total purchase amount)
    totalSpent := 0.0
    for _, purchase := range profile.Behaviors.PurchaseHistory {
        totalSpent += purchase.Amount
    }
    monetaryScore := calculateMonetaryScore(totalSpent)
    
    rfmString := fmt.Sprintf("%d%d%d", recencyScore, frequencyScore, monetaryScore)
    segment := determineRFMSegment(recencyScore, frequencyScore, monetaryScore)
    
    return RFMScore{
        UserID:    profile.UserID,
        Recency:   recencyScore,
        Frequency: frequencyScore,
        Monetary:  monetaryScore,
        RFMString: rfmString,
        Segment:   segment,
    }
}

// determineRFMSegment maps RFM scores to business segments
func determineRFMSegment(r, f, m int) string {
    switch {
    case r >= 4 && f >= 4 && m >= 4:
        return "Champions"
    case r >= 3 && f >= 3 && m >= 3:
        return "Loyal Customers"
    case r >= 4 && f <= 2:
        return "New Customers"
    case r >= 3 && f <= 2 && m >= 3:
        return "Potential Loyalists"
    case r >= 3 && f >= 3 && m <= 2:
        return "Promising"
    case r <= 2 && f >= 3 && m >= 3:
        return "Need Attention"
    case r <= 2 && f >= 3 && m <= 2:
        return "About to Sleep"
    case r <= 2 && f <= 2 && m >= 3:
        return "At Risk"
    case r <= 2 && f <= 2 && m <= 2:
        return "Cannot Lose Them"
    default:
        return "Others"
    }
}
```

### Practical Implementation

#### User Classification System

```go
// ClassifyUserByActivity categorizes users by activity patterns
func ClassifyUserByActivity(lastActiveDate time.Time) string {
    now := time.Now()
    daysSinceActive := now.Sub(lastActiveDate).Hours() / 24
    
    switch {
    case daysSinceActive <= 1:
        return "Super Active" // Daily users
    case daysSinceActive <= 7:
        return "Active" // Weekly users
    case daysSinceActive <= 30:
        return "Regular" // Monthly users
    case daysSinceActive <= 90:
        return "Inactive" // Quarterly users
    case daysSinceActive <= 365:
        return "Dormant" // Yearly users
    default:
        return "Churned" // > 1 year inactive
    }
}

// ClassifyUserByValue segments users by their contribution
func ClassifyUserByValue(totalRevenue float64, supportTickets int) string {
    // High-value: High revenue, low support cost
    if totalRevenue > 1000 && supportTickets < 5 {
        return "High-Value Customer"
    }
    
    // Medium-value: Moderate revenue
    if totalRevenue > 100 && totalRevenue <= 1000 {
        return "Medium-Value Customer"
    }
    
    // High-maintenance: High support cost regardless of revenue
    if supportTickets > 20 {
        return "High-Maintenance Customer"
    }
    
    // Low-value: Low revenue, potentially high cost
    return "Low-Value Customer"
}

// SegmentByFeatureUsage classifies users by feature adoption
func SegmentByFeatureUsage(featureUsage map[string]int) string {
    totalFeatures := len(featureUsage)
    usedFeatures := 0
    
    for _, count := range featureUsage {
        if count > 0 {
            usedFeatures++
        }
    }
    
    adoptionRate := float64(usedFeatures) / float64(totalFeatures)
    
    switch {
    case adoptionRate >= 0.8:
        return "Power User"
    case adoptionRate >= 0.5:
        return "Feature Explorer"
    case adoptionRate >= 0.2:
        return "Basic User"
    default:
        return "Limited User"
    }
}
```

## Implementation

### 1. Efficient Segment Storage with Bloom Filters

```go
package storage

import (
    "github.com/bits-and-blooms/bloom/v3"
    "sync"
)

// BloomSegmentStore provides memory-efficient segment membership storage
type BloomSegmentStore struct {
    segments map[string]*bloom.BloomFilter
    mutex    sync.RWMutex
    capacity uint // Expected number of users per segment
    fpRate   float64 // False positive rate
}

// NewBloomSegmentStore creates a new bloom filter-based segment store
func NewBloomSegmentStore(capacity uint, fpRate float64) *BloomSegmentStore {
    return &BloomSegmentStore{
        segments: make(map[string]*bloom.BloomFilter),
        capacity: capacity,
        fpRate:   fpRate,
    }
}

// AddUserToSegment adds a user to a segment using bloom filter
func (bs *BloomSegmentStore) AddUserToSegment(segmentID, userID string) {
    bs.mutex.Lock()
    defer bs.mutex.Unlock()
    
    if _, exists := bs.segments[segmentID]; !exists {
        bs.segments[segmentID] = bloom.NewWithEstimates(bs.capacity, bs.fpRate)
    }
    
    bs.segments[segmentID].Add([]byte(userID))
}

// UserInSegment checks if a user might be in a segment (with possible false positives)
func (bs *BloomSegmentStore) UserInSegment(segmentID, userID string) bool {
    bs.mutex.RLock()
    defer bs.mutex.RUnlock()
    
    filter, exists := bs.segments[segmentID]
    if !exists {
        return false
    }
    
    return filter.Test([]byte(userID))
}

// GetSegmentSize returns approximate segment size
func (bs *BloomSegmentStore) GetSegmentSize(segmentID string) uint {
    bs.mutex.RLock()
    defer bs.mutex.RUnlock()
    
    filter, exists := bs.segments[segmentID]
    if !exists {
        return 0
    }
    
    return filter.ApproximatedSize()
}
```

### 2. Real-time Segment Updates

```go
package realtime

import (
    "context"
    "time"
)

// SegmentUpdater handles real-time segment membership updates
type SegmentUpdater struct {
    engine    *SegmentEngine
    storage   *BloomSegmentStore
    eventChan chan UserEvent
    batchSize int
    interval  time.Duration
}

// StartProcessing begins real-time segment processing
func (su *SegmentUpdater) StartProcessing(ctx context.Context) error {
    ticker := time.NewTicker(su.interval)
    defer ticker.Stop()
    
    batch := make([]UserEvent, 0, su.batchSize)
    
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
            
        case event := <-su.eventChan:
            batch = append(batch, event)
            
            if len(batch) >= su.batchSize {
                su.processBatch(ctx, batch)
                batch = batch[:0]
            }
            
        case <-ticker.C:
            if len(batch) > 0 {
                su.processBatch(ctx, batch)
                batch = batch[:0]
            }
        }
    }
}

// processBatch updates segments for a batch of user events
func (su *SegmentUpdater) processBatch(ctx context.Context, events []UserEvent) {
    userSegments := make(map[string][]string)
    
    for _, event := range events {
        segments, err := su.engine.EvaluateUserSegments(ctx, event.UserID)
        if err != nil {
            continue
        }
        
        userSegments[event.UserID] = segments
    }
    
    // Update bloom filters
    for userID, segments := range userSegments {
        for _, segmentID := range segments {
            su.storage.AddUserToSegment(segmentID, userID)
        }
    }
}
```

## Consequences

### Benefits
- **Personalized Experiences**: Tailored content and features for each segment
- **Improved Conversion**: Higher conversion rates through targeted approaches
- **Resource Efficiency**: Focused marketing and development efforts (80/20 rule)
- **Customer Insights**: Deep understanding of user behavior patterns
- **Feature Rollout Strategy**: Targeted testing with high-value segments

### Challenges
- **Data Quality**: Requires comprehensive and accurate user data
- **Privacy Compliance**: Must adhere to GDPR, CCPA regulations
- **Segment Overlap**: Users may belong to multiple segments
- **Dynamic Behavior**: User segments can change over time
- **Memory Efficiency**: Bloom filters provide space efficiency with acceptable false positive rates

### Monitoring
- Segment population sizes and trends
- Conversion rates by segment
- Segment migration patterns
- Feature adoption by user type
- Revenue contribution by segment
- Support cost by segment type
