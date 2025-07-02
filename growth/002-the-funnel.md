# Growth Funnel

## Status

`production`

## Context

A growth funnel is a crucial framework for understanding user behavior throughout their journey with your product. It identifies conversion bottlenecks, quantifies drop-off rates at each stage, and provides actionable insights for optimization. By mapping and measuring each step, teams can prioritize improvements based on data rather than assumptions.

## Decision

### Funnel Frameworks

#### E-commerce Funnel
```
Awareness → Interest → Consideration → Purchase → Retention → Advocacy
     ↓        ↓           ↓           ↓          ↓          ↓
Visit → Browse → Add to Cart → Checkout → Purchase → Repeat Purchase
```

#### SaaS Product Funnel
```
Discovery → Signup → Activation → Feature Adoption → Retention → Expansion
     ↓        ↓        ↓              ↓             ↓          ↓
Landing → Register → First Value → Core Features → Renewed → Upgraded
```

#### Content Platform Funnel
```
Acquisition → Activation → Engagement → Retention → Monetization
     ↓           ↓           ↓           ↓            ↓
Visit → Signup → First Session → Regular Usage → Subscription
```

### Funnel Analysis Framework

```go
package funnel

import (
    "context"
    "time"
)

// FunnelStep represents a single step in the conversion funnel
type FunnelStep struct {
    Name        string    `json:"name"`
    Description string    `json:"description"`
    Order       int       `json:"order"`
    Required    bool      `json:"required"`
    TimeWindow  time.Duration `json:"time_window"`
}

// FunnelEvent represents user interaction events
type FunnelEvent struct {
    UserID      string                 `json:"user_id"`
    SessionID   string                 `json:"session_id"`
    Step        string                 `json:"step"`
    Timestamp   time.Time              `json:"timestamp"`
    Properties  map[string]interface{} `json:"properties"`
    CorrelationID string               `json:"correlation_id"`
}

// FunnelMetrics holds conversion data for analysis
type FunnelMetrics struct {
    Step            string  `json:"step"`
    Users           int64   `json:"users"`
    Conversions     int64   `json:"conversions"`
    ConversionRate  float64 `json:"conversion_rate"`
    DropOffRate     float64 `json:"drop_off_rate"`
    AverageTime     time.Duration `json:"average_time"`
    MedianTime      time.Duration `json:"median_time"`
}

// FunnelAnalyzer provides funnel analysis capabilities
type FunnelAnalyzer struct {
    steps     []FunnelStep
    events    []FunnelEvent
    timeframe time.Duration
}

// CalculateFunnelMetrics computes conversion rates for each step
func (f *FunnelAnalyzer) CalculateFunnelMetrics(ctx context.Context) ([]FunnelMetrics, error) {
    metrics := make([]FunnelMetrics, len(f.steps))
    
    for i, step := range f.steps {
        users := f.getUsersAtStep(step.Name)
        conversions := int64(0)
        
        if i < len(f.steps)-1 {
            nextStep := f.steps[i+1]
            conversions = f.getConversionsToStep(step.Name, nextStep.Name, step.TimeWindow)
        }
        
        conversionRate := float64(conversions) / float64(users)
        dropOffRate := 1.0 - conversionRate
        
        metrics[i] = FunnelMetrics{
            Step:           step.Name,
            Users:          users,
            Conversions:    conversions,
            ConversionRate: conversionRate,
            DropOffRate:    dropOffRate,
            AverageTime:    f.getAverageTimeAtStep(step.Name),
            MedianTime:     f.getMedianTimeAtStep(step.Name),
        }
    }
    
    return metrics, nil
}

// CohortAnalysis analyzes funnel performance across user cohorts
func (f *FunnelAnalyzer) CohortAnalysis(ctx context.Context, cohortBy string) (map[string][]FunnelMetrics, error) {
    cohorts := make(map[string][]FunnelMetrics)
    
    // Group users by cohort (signup date, traffic source, etc.)
    userCohorts := f.groupUsersByCohort(cohortBy)
    
    for cohortName, users := range userCohorts {
        cohortEvents := f.filterEventsByUsers(users)
        cohortAnalyzer := &FunnelAnalyzer{
            steps:     f.steps,
            events:    cohortEvents,
            timeframe: f.timeframe,
        }
        
        metrics, err := cohortAnalyzer.CalculateFunnelMetrics(ctx)
        if err != nil {
            return nil, err
        }
        
        cohorts[cohortName] = metrics
    }
    
    return cohorts, nil
}
```

### Implementation Strategy

#### 1. Event Tracking Implementation

```go
package tracking

import (
    "context"
    "encoding/json"
    "time"
)

// EventTracker handles funnel event collection
type EventTracker struct {
    storage EventStorage
    config  TrackerConfig
}

type TrackerConfig struct {
    SamplingRate    float64       `json:"sampling_rate"`
    BufferSize      int           `json:"buffer_size"`
    FlushInterval   time.Duration `json:"flush_interval"`
    RetryAttempts   int           `json:"retry_attempts"`
}

// TrackFunnelEvent records user progression through funnel steps
func (t *EventTracker) TrackFunnelEvent(ctx context.Context, event FunnelEvent) error {
    // Add correlation ID if not present
    if event.CorrelationID == "" {
        event.CorrelationID = generateCorrelationID()
    }
    
    // Enrich event with session context
    enrichedEvent := t.enrichEvent(event)
    
    // Validate event structure
    if err := t.validateEvent(enrichedEvent); err != nil {
        return fmt.Errorf("invalid event: %w", err)
    }
    
    // Store event asynchronously
    return t.storage.Store(ctx, enrichedEvent)
}

// TrackPageView records page view events for funnel analysis
func (t *EventTracker) TrackPageView(ctx context.Context, userID, page string, properties map[string]interface{}) error {
    event := FunnelEvent{
        UserID:      userID,
        SessionID:   extractSessionID(ctx),
        Step:        page,
        Timestamp:   time.Now(),
        Properties:  properties,
    }
    
    return t.TrackFunnelEvent(ctx, event)
}

// TrackConversion records successful step completion
func (t *EventTracker) TrackConversion(ctx context.Context, userID, fromStep, toStep string, value float64) error {
    event := FunnelEvent{
        UserID:    userID,
        SessionID: extractSessionID(ctx),
        Step:      toStep,
        Timestamp: time.Now(),
        Properties: map[string]interface{}{
            "from_step":        fromStep,
            "conversion_value": value,
            "conversion_type":  "step_completion",
        },
    }
    
    return t.TrackFunnelEvent(ctx, event)
}
```

#### 2. Real-time Funnel Monitoring

```go
package monitoring

import (
    "context"
    "time"
)

// FunnelMonitor provides real-time funnel performance tracking
type FunnelMonitor struct {
    analyzer *FunnelAnalyzer
    alerts   AlertManager
    metrics  MetricsCollector
}

// MonitorFunnelHealth tracks funnel performance and triggers alerts
func (m *FunnelMonitor) MonitorFunnelHealth(ctx context.Context) error {
    ticker := time.NewTicker(5 * time.Minute)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-ticker.C:
            if err := m.checkFunnelHealth(ctx); err != nil {
                m.alerts.SendAlert("funnel_health_check_failed", err.Error())
            }
        }
    }
}

// checkFunnelHealth evaluates current funnel performance
func (m *FunnelMonitor) checkFunnelHealth(ctx context.Context) error {
    metrics, err := m.analyzer.CalculateFunnelMetrics(ctx)
    if err != nil {
        return err
    }
    
    for _, metric := range metrics {
        // Check conversion rate thresholds
        if metric.ConversionRate < m.getThreshold(metric.Step) {
            m.alerts.SendAlert("low_conversion_rate", map[string]interface{}{
                "step":            metric.Step,
                "conversion_rate": metric.ConversionRate,
                "threshold":       m.getThreshold(metric.Step),
            })
        }
        
        // Emit metrics for monitoring
        m.metrics.Gauge("funnel.conversion_rate", metric.ConversionRate, map[string]string{
            "step": metric.Step,
        })
        
        m.metrics.Gauge("funnel.drop_off_rate", metric.DropOffRate, map[string]string{
            "step": metric.Step,
        })
    }
    
    return nil
}
```

### User Segmentation Framework

```go
package segmentation

// UserSegment defines user classification criteria
type UserSegment struct {
    Name        string            `json:"name"`
    Criteria    map[string]interface{} `json:"criteria"`
    Description string            `json:"description"`
    Priority    int               `json:"priority"`
}

// UserClassification categorizes users for targeted funnel optimization
type UserClassification struct {
    UserID          string    `json:"user_id"`
    Segments        []string  `json:"segments"`
    LastActive      time.Time `json:"last_active"`
    LifecycleStage  string    `json:"lifecycle_stage"`
    Value           float64   `json:"value"`
    RiskScore       float64   `json:"risk_score"`
}

// Standard user lifecycle segments
const (
    SegmentNew        = "new"
    SegmentActive     = "active"
    SegmentInactive   = "inactive"
    SegmentDeactivated = "deactivated"
    SegmentChurned    = "churned"
    SegmentReactivated = "reactivated"
)

// ClassifyUser determines user segment based on activity patterns
func (s *UserSegmenter) ClassifyUser(userID string, lastActive time.Time) UserClassification {
    now := time.Now()
    daysSinceActive := now.Sub(lastActive).Hours() / 24
    
    var stage string
    var riskScore float64
    
    switch {
    case daysSinceActive <= 1:
        stage = SegmentActive
        riskScore = 0.1
    case daysSinceActive <= 7:
        stage = SegmentActive
        riskScore = 0.3
    case daysSinceActive <= 30:
        stage = SegmentInactive
        riskScore = 0.6
    case daysSinceActive <= 90:
        stage = SegmentInactive
        riskScore = 0.8
    case daysSinceActive <= 365:
        stage = SegmentDeactivated
        riskScore = 0.9
    default:
        stage = SegmentChurned
        riskScore = 1.0
    }
    
    return UserClassification{
        UserID:         userID,
        LastActive:     lastActive,
        LifecycleStage: stage,
        RiskScore:      riskScore,
    }
}
```

## Implementation

### 1. Setup Event Tracking Infrastructure

```bash
# Setup event storage (BigQuery example)
bq mk --dataset your_project:funnel_analytics
bq mk --table your_project:funnel_analytics.funnel_events schema.json

# Create event processing pipeline
gcloud dataflow jobs run funnel-processor \
    --gcs-location gs://dataflow-templates/streaming/PubSub_to_BigQuery \
    --parameters inputTopic=projects/your-project/topics/funnel-events,\
outputTableSpec=your-project:funnel_analytics.funnel_events
```

### 2. Implement Client-Side Tracking

```javascript
// Frontend tracking implementation
class FunnelTracker {
    constructor(config) {
        this.config = config;
        this.sessionId = this.generateSessionId();
        this.correlationId = this.getCorrelationId();
    }
    
    track(step, properties = {}) {
        const event = {
            user_id: this.getUserId(),
            session_id: this.sessionId,
            correlation_id: this.correlationId,
            step: step,
            timestamp: new Date().toISOString(),
            properties: {
                ...properties,
                page_url: window.location.href,
                referrer: document.referrer,
                user_agent: navigator.userAgent
            }
        };
        
        this.sendEvent(event);
    }
    
    trackPageView(page) {
        this.track('page_view', { page: page });
    }
    
    trackConversion(fromStep, toStep, value) {
        this.track('conversion', {
            from_step: fromStep,
            to_step: toStep,
            conversion_value: value
        });
    }
}
```

### 3. Analytics and Reporting

```sql
-- Funnel conversion analysis query
WITH funnel_steps AS (
  SELECT 
    user_id,
    step,
    MIN(timestamp) as first_occurrence
  FROM funnel_events 
  WHERE timestamp >= '2024-01-01'
  GROUP BY user_id, step
),
step_order AS (
  SELECT 
    user_id,
    step,
    first_occurrence,
    LAG(first_occurrence) OVER (PARTITION BY user_id ORDER BY first_occurrence) as prev_step_time
  FROM funnel_steps
)
SELECT 
  step,
  COUNT(DISTINCT user_id) as users,
  COUNT(DISTINCT CASE WHEN prev_step_time IS NOT NULL THEN user_id END) as conversions,
  SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN prev_step_time IS NOT NULL THEN user_id END),
    LAG(COUNT(DISTINCT user_id)) OVER (ORDER BY MIN(first_occurrence))
  ) * 100 as conversion_rate
FROM step_order
GROUP BY step
ORDER BY MIN(first_occurrence);
```

## Consequences

### Benefits
- **Data-Driven Optimization**: Clear visibility into conversion bottlenecks
- **ROI Measurement**: Quantifiable impact of improvements
- **User Experience**: Better understanding of user journey pain points
- **Resource Allocation**: Focus efforts on highest-impact improvements

### Challenges
- **Implementation Complexity**: Requires robust tracking infrastructure
- **Data Quality**: Accurate tracking across multiple touchpoints
- **Privacy Compliance**: Adherence to GDPR, CCPA regulations
- **Performance Impact**: Tracking overhead on application performance

### Monitoring
- Conversion rates by funnel step
- Drop-off rates and reasons
- Time-to-conversion metrics
- Cohort performance analysis
- A/B test impact on funnel metrics
