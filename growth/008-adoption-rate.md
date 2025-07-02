# Feature Adoption Rate Analysis

## Status

`production`

## Context

Feature adoption rate is a critical growth metric that measures how effectively users discover, try, and continue using new or existing features. This metric provides insights into product-market fit, user experience quality, and feature value proposition.

Adoption rate helps answer key questions:
- Which features drive the most user engagement?
- How quickly do users discover and adopt new features?
- What's the correlation between feature adoption and user retention?
- Where should we invest development resources?

## Framework

### Adoption Metrics Hierarchy

```
Feature Adoption = Discovery → Trial → Adoption → Retention → Advocacy
```

### Key Metrics

1. **Discovery Rate**: % of users who see the feature
2. **Trial Rate**: % of discoverers who try the feature
3. **Adoption Rate**: % of trialists who use it regularly
4. **Retention Rate**: % of adopters who continue using it
5. **Depth of Adoption**: How deeply users engage with the feature

### Calculation Models

```go
// Adoption rate calculation types
type AdoptionMetrics struct {
    FeatureID          string    `json:"feature_id"`
    Period             string    `json:"period"` // daily, weekly, monthly
    TotalUsers         int64     `json:"total_users"`
    DiscoveredUsers    int64     `json:"discovered_users"`
    TrialUsers         int64     `json:"trial_users"`
    AdoptedUsers       int64     `json:"adopted_users"`
    RetainedUsers      int64     `json:"retained_users"`
    DiscoveryRate      float64   `json:"discovery_rate"`
    TrialRate          float64   `json:"trial_rate"`
    AdoptionRate       float64   `json:"adoption_rate"`
    RetentionRate      float64   `json:"retention_rate"`
    TimeToAdoption     time.Duration `json:"time_to_adoption"`
}

func CalculateAdoptionMetrics(events []UserEvent, period string) *AdoptionMetrics {
    metrics := &AdoptionMetrics{
        Period: period,
    }
    
    userStates := make(map[string]*UserFeatureState)
    
    for _, event := range events {
        if userStates[event.UserID] == nil {
            userStates[event.UserID] = &UserFeatureState{}
        }
        
        state := userStates[event.UserID]
        
        switch event.Type {
        case "feature_viewed":
            state.Discovered = true
            state.DiscoveryTime = event.Timestamp
        case "feature_clicked", "feature_started":
            state.Trialed = true
            state.TrialTime = event.Timestamp
        case "feature_completed", "feature_used":
            state.Adopted = true
            state.AdoptionTime = event.Timestamp
        case "feature_repeated_use":
            state.Retained = true
            state.RetentionTime = event.Timestamp
        }
    }
    
    metrics.TotalUsers = int64(len(userStates))
    
    for _, state := range userStates {
        if state.Discovered {
            metrics.DiscoveredUsers++
        }
        if state.Trialed {
            metrics.TrialUsers++
        }
        if state.Adopted {
            metrics.AdoptedUsers++
        }
        if state.Retained {
            metrics.RetainedUsers++
        }
    }
    
    // Calculate rates
    if metrics.TotalUsers > 0 {
        metrics.DiscoveryRate = float64(metrics.DiscoveredUsers) / float64(metrics.TotalUsers)
    }
    if metrics.DiscoveredUsers > 0 {
        metrics.TrialRate = float64(metrics.TrialUsers) / float64(metrics.DiscoveredUsers)
    }
    if metrics.TrialUsers > 0 {
        metrics.AdoptionRate = float64(metrics.AdoptedUsers) / float64(metrics.TrialUsers)
    }
    if metrics.AdoptedUsers > 0 {
        metrics.RetentionRate = float64(metrics.RetainedUsers) / float64(metrics.AdoptedUsers)
    }
    
    return metrics
}

type UserFeatureState struct {
    Discovered     bool      `json:"discovered"`
    Trialed        bool      `json:"trialed"`
    Adopted        bool      `json:"adopted"`
    Retained       bool      `json:"retained"`
    DiscoveryTime  time.Time `json:"discovery_time"`
    TrialTime      time.Time `json:"trial_time"`
    AdoptionTime   time.Time `json:"adoption_time"`
    RetentionTime  time.Time `json:"retention_time"`
}
```

### Cohort Analysis Implementation

```go
type CohortAnalysis struct {
    CohortID        string                 `json:"cohort_id"`
    CohortDate      time.Time             `json:"cohort_date"`
    InitialSize     int64                 `json:"initial_size"`
    AdoptionByWeek  map[int]int64         `json:"adoption_by_week"`
    RetentionByWeek map[int]float64       `json:"retention_by_week"`
}

func GenerateCohortAnalysis(users []User, events []UserEvent) []*CohortAnalysis {
    cohorts := make(map[string]*CohortAnalysis)
    
    // Group users by signup week
    for _, user := range users {
        weekKey := user.CreatedAt.Format("2006-W02")
        
        if cohorts[weekKey] == nil {
            cohorts[weekKey] = &CohortAnalysis{
                CohortID:        weekKey,
                CohortDate:      user.CreatedAt,
                AdoptionByWeek:  make(map[int]int64),
                RetentionByWeek: make(map[int]float64),
            }
        }
        cohorts[weekKey].InitialSize++
    }
    
    // Track adoption by week for each cohort
    for _, event := range events {
        if event.Type != "feature_adopted" {
            continue
        }
        
        user := findUser(users, event.UserID)
        if user == nil {
            continue
        }
        
        cohortKey := user.CreatedAt.Format("2006-W02")
        cohort := cohorts[cohortKey]
        
        weeksSinceSignup := int(event.Timestamp.Sub(user.CreatedAt).Hours() / (24 * 7))
        cohort.AdoptionByWeek[weeksSinceSignup]++
    }
    
    // Calculate retention rates
    for _, cohort := range cohorts {
        for week, adopted := range cohort.AdoptionByWeek {
            if cohort.InitialSize > 0 {
                cohort.RetentionByWeek[week] = float64(adopted) / float64(cohort.InitialSize)
            }
        }
    }
    
    result := make([]*CohortAnalysis, 0, len(cohorts))
    for _, cohort := range cohorts {
        result = append(result, cohort)
    }
    
    return result
}
```

### Feature Performance Dashboard

```go
type FeaturePerformanceDashboard struct {
    db     *sql.DB
    cache  *redis.Client
    logger *slog.Logger
}

func (d *FeaturePerformanceDashboard) GetFeatureAdoptionReport(ctx context.Context, timeRange string) (*AdoptionReport, error) {
    cacheKey := fmt.Sprintf("adoption_report:%s", timeRange)
    
    // Try cache first
    if cached, err := d.cache.Get(ctx, cacheKey).Result(); err == nil {
        var report AdoptionReport
        if err := json.Unmarshal([]byte(cached), &report); err == nil {
            return &report, nil
        }
    }
    
    query := `
        WITH feature_metrics AS (
            SELECT 
                fe.feature_id,
                f.name as feature_name,
                COUNT(DISTINCT CASE WHEN fe.event_type = 'feature_viewed' THEN fe.user_id END) as discovered_users,
                COUNT(DISTINCT CASE WHEN fe.event_type = 'feature_clicked' THEN fe.user_id END) as trial_users,
                COUNT(DISTINCT CASE WHEN fe.event_type = 'feature_adopted' THEN fe.user_id END) as adopted_users,
                COUNT(DISTINCT CASE WHEN fe.event_type = 'feature_retained' THEN fe.user_id END) as retained_users,
                AVG(CASE WHEN fe.event_type = 'feature_adopted' 
                    THEN EXTRACT(EPOCH FROM (fe.created_at - first_view.first_view_time))/3600 
                    END) as avg_time_to_adoption_hours
            FROM feature_events fe
            JOIN features f ON fe.feature_id = f.id
            LEFT JOIN (
                SELECT user_id, feature_id, MIN(created_at) as first_view_time
                FROM feature_events 
                WHERE event_type = 'feature_viewed'
                GROUP BY user_id, feature_id
            ) first_view ON fe.user_id = first_view.user_id AND fe.feature_id = first_view.feature_id
            WHERE fe.created_at >= NOW() - INTERVAL '%s'
            GROUP BY fe.feature_id, f.name
        ),
        total_users AS (
            SELECT COUNT(DISTINCT user_id) as total_count
            FROM feature_events
            WHERE created_at >= NOW() - INTERVAL '%s'
        )
        SELECT 
            fm.feature_id,
            fm.feature_name,
            fm.discovered_users,
            fm.trial_users,
            fm.adopted_users,
            fm.retained_users,
            tu.total_count as total_users,
            CASE WHEN tu.total_count > 0 THEN fm.discovered_users::float / tu.total_count ELSE 0 END as discovery_rate,
            CASE WHEN fm.discovered_users > 0 THEN fm.trial_users::float / fm.discovered_users ELSE 0 END as trial_rate,
            CASE WHEN fm.trial_users > 0 THEN fm.adopted_users::float / fm.trial_users ELSE 0 END as adoption_rate,
            CASE WHEN fm.adopted_users > 0 THEN fm.retained_users::float / fm.adopted_users ELSE 0 END as retention_rate,
            fm.avg_time_to_adoption_hours
        FROM feature_metrics fm
        CROSS JOIN total_users tu
        ORDER BY fm.adopted_users DESC;
    `
    
    rows, err := d.db.QueryContext(ctx, query, timeRange, timeRange)
    if err != nil {
        return nil, fmt.Errorf("failed to query feature adoption: %w", err)
    }
    defer rows.Close()
    
    var features []FeatureAdoptionData
    for rows.Next() {
        var f FeatureAdoptionData
        err := rows.Scan(
            &f.FeatureID, &f.FeatureName, &f.DiscoveredUsers, &f.TrialUsers,
            &f.AdoptedUsers, &f.RetainedUsers, &f.TotalUsers, &f.DiscoveryRate,
            &f.TrialRate, &f.AdoptionRate, &f.RetentionRate, &f.AvgTimeToAdoption,
        )
        if err != nil {
            return nil, fmt.Errorf("failed to scan feature data: %w", err)
        }
        features = append(features, f)
    }
    
    report := &AdoptionReport{
        TimeRange: timeRange,
        Features:  features,
        GeneratedAt: time.Now(),
    }
    
    // Cache the result
    if data, err := json.Marshal(report); err == nil {
        d.cache.Set(ctx, cacheKey, data, 15*time.Minute)
    }
    
    return report, nil
}

type AdoptionReport struct {
    TimeRange   string                  `json:"time_range"`
    Features    []FeatureAdoptionData   `json:"features"`
    GeneratedAt time.Time              `json:"generated_at"`
}

type FeatureAdoptionData struct {
    FeatureID           string  `json:"feature_id"`
    FeatureName         string  `json:"feature_name"`
    DiscoveredUsers     int64   `json:"discovered_users"`
    TrialUsers          int64   `json:"trial_users"`
    AdoptedUsers        int64   `json:"adopted_users"`
    RetainedUsers       int64   `json:"retained_users"`
    TotalUsers          int64   `json:"total_users"`
    DiscoveryRate       float64 `json:"discovery_rate"`
    TrialRate           float64 `json:"trial_rate"`
    AdoptionRate        float64 `json:"adoption_rate"`
    RetentionRate       float64 `json:"retention_rate"`
    AvgTimeToAdoption   float64 `json:"avg_time_to_adoption_hours"`
}
```

## Implementation Strategy

### Phase 1: Basic Tracking

1. **Event Collection**
   - Implement feature interaction tracking
   - Set up user journey mapping
   - Create adoption event schema

2. **Data Pipeline**
   - Real-time event streaming
   - Batch processing for historical analysis
   - Data validation and cleanup

### Phase 2: Advanced Analytics

1. **Cohort Analysis**
   - Weekly/monthly cohort tracking
   - Feature adoption curves
   - Retention analysis

2. **Predictive Modeling**
   - Adoption likelihood scoring
   - Time-to-adoption prediction
   - Churn risk assessment

### Phase 3: Optimization

1. **A/B Testing Integration**
   - Feature rollout strategies
   - Adoption optimization experiments
   - Personalized feature recommendations

2. **Automated Insights**
   - Anomaly detection
   - Performance alerts
   - Recommendation engine

## Monitoring and Alerting

```sql
-- Feature adoption monitoring queries
CREATE VIEW feature_adoption_summary AS
SELECT 
    f.name as feature_name,
    DATE_TRUNC('week', fe.created_at) as week,
    COUNT(DISTINCT CASE WHEN fe.event_type = 'feature_viewed' THEN fe.user_id END) as discovered,
    COUNT(DISTINCT CASE WHEN fe.event_type = 'feature_adopted' THEN fe.user_id END) as adopted,
    CASE 
        WHEN COUNT(DISTINCT CASE WHEN fe.event_type = 'feature_viewed' THEN fe.user_id END) > 0 
        THEN COUNT(DISTINCT CASE WHEN fe.event_type = 'feature_adopted' THEN fe.user_id END)::float / 
             COUNT(DISTINCT CASE WHEN fe.event_type = 'feature_viewed' THEN fe.user_id END)
        ELSE 0 
    END as adoption_rate
FROM features f
JOIN feature_events fe ON f.id = fe.feature_id
WHERE fe.created_at >= CURRENT_DATE - INTERVAL '12 weeks'
GROUP BY f.name, DATE_TRUNC('week', fe.created_at)
ORDER BY week DESC, adoption_rate DESC;

-- Alert for low adoption rates
SELECT 
    feature_name,
    adoption_rate,
    discovered,
    adopted
FROM feature_adoption_summary
WHERE week = DATE_TRUNC('week', CURRENT_DATE - INTERVAL '1 week')
AND adoption_rate < 0.1
AND discovered > 100;
```

## Best Practices

### Data Collection

1. **Event Granularity**: Track micro-interactions, not just major events
2. **User Context**: Include user segment, device, and session information
3. **Feature Metadata**: Track feature version, configuration, and flags

### Analysis Techniques

1. **Segmented Analysis**: Break down adoption by user cohorts
2. **Funnel Analysis**: Identify drop-off points in adoption flow
3. **Correlation Analysis**: Find patterns between features and user behavior

### Optimization Strategies

1. **Progressive Disclosure**: Gradually introduce complex features
2. **Contextual Onboarding**: Show features when most relevant
3. **Social Proof**: Highlight popular or trending features

## Common Pitfalls

1. **Vanity Metrics**: Focus on meaningful adoption, not just initial usage
2. **Sample Bias**: Ensure representative user samples in analysis
3. **Feature Interference**: Account for feature interactions and dependencies
4. **Temporal Effects**: Consider seasonality and external factors

## Consequences

**Benefits:**
- Data-driven feature prioritization
- Improved user experience through usage insights
- Better resource allocation for development
- Enhanced product-market fit measurement

**Challenges:**
- Complex data pipeline requirements
- Privacy and data governance considerations
- Need for cross-functional collaboration
- Potential for analysis paralysis

**Trade-offs:**
- Detailed tracking vs. user privacy
- Real-time insights vs. system performance
- Feature complexity vs. adoption simplicity
