# LLM Cost Measurement and Optimization

## Status
**Accepted** - 2024-01-15

## Context
Large Language Models (LLMs) have become integral to modern applications, but their costs can quickly spiral out of control without proper measurement and optimization. Unlike traditional compute resources, LLM costs are driven by token consumption, model complexity, and inference patterns, requiring specialized monitoring and optimization strategies.

## Problem Statement
Organizations are struggling to:
- Track and predict LLM API costs across multiple providers
- Optimize token usage without degrading user experience
- Implement cost controls for LLM-powered features
- Allocate LLM costs to specific teams, projects, or customers
- Monitor and prevent cost anomalies in LLM usage

## Decision
Implement comprehensive LLM cost measurement, monitoring, and optimization strategies across the entire AI/ML pipeline.

## Implementation

### 1. Token Usage Tracking

```go
// LLM usage tracking system
package llmcost

import (
    "context"
    "fmt"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

type LLMProvider string

const (
    OpenAI      LLMProvider = "openai"
    Anthropic   LLMProvider = "anthropic"
    AWS_Bedrock LLMProvider = "aws-bedrock"
    Azure       LLMProvider = "azure"
    Google      LLMProvider = "google"
)

type TokenUsage struct {
    InputTokens  int64
    OutputTokens int64
    TotalTokens  int64
}

type LLMRequest struct {
    ID           string      `json:"id"`
    Provider     LLMProvider `json:"provider"`
    Model        string      `json:"model"`
    Usage        TokenUsage  `json:"usage"`
    Cost         float64     `json:"cost"`
    Latency      time.Duration `json:"latency"`
    Timestamp    time.Time   `json:"timestamp"`
    UserID       string      `json:"user_id"`
    TeamID       string      `json:"team_id"`
    ProjectID    string      `json:"project_id"`
    FeatureName  string      `json:"feature_name"`
    Success      bool        `json:"success"`
    ErrorType    string      `json:"error_type,omitempty"`
}

var (
    llmTokensUsed = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "llm_tokens_used_total",
            Help: "Total number of LLM tokens used",
        },
        []string{"provider", "model", "team", "project", "feature", "token_type"},
    )
    
    llmCost = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "llm_cost_usd_total",
            Help: "Total LLM cost in USD",
        },
        []string{"provider", "model", "team", "project", "feature"},
    )
    
    llmLatency = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "llm_request_duration_seconds",
            Help:    "LLM request duration in seconds",
            Buckets: prometheus.ExponentialBuckets(0.1, 2, 10),
        },
        []string{"provider", "model", "team", "project", "feature"},
    )
)

type LLMCostTracker struct {
    pricingTable map[string]ModelPricing
    storage      LLMUsageStorage
}

type ModelPricing struct {
    Provider         LLMProvider `json:"provider"`
    Model           string      `json:"model"`
    InputPricePer1K  float64     `json:"input_price_per_1k"`
    OutputPricePer1K float64     `json:"output_price_per_1k"`
    LastUpdated     time.Time   `json:"last_updated"`
}

func NewLLMCostTracker(storage LLMUsageStorage) *LLMCostTracker {
    tracker := &LLMCostTracker{
        pricingTable: make(map[string]ModelPricing),
        storage:      storage,
    }
    
    // Initialize with current pricing (as of 2024)
    tracker.loadPricingData()
    return tracker
}

func (t *LLMCostTracker) loadPricingData() {
    pricing := []ModelPricing{
        // OpenAI Pricing
        {OpenAI, "gpt-4", 0.03, 0.06, time.Now()},
        {OpenAI, "gpt-4-turbo", 0.01, 0.03, time.Now()},
        {OpenAI, "gpt-3.5-turbo", 0.0015, 0.002, time.Now()},
        {OpenAI, "text-embedding-ada-002", 0.0001, 0, time.Now()},
        
        // Anthropic Pricing
        {Anthropic, "claude-3-opus", 0.015, 0.075, time.Now()},
        {Anthropic, "claude-3-sonnet", 0.003, 0.015, time.Now()},
        {Anthropic, "claude-3-haiku", 0.00025, 0.00125, time.Now()},
        
        // AWS Bedrock Pricing
        {AWS_Bedrock, "anthropic.claude-v2", 0.008, 0.024, time.Now()},
        {AWS_Bedrock, "amazon.titan-text-express-v1", 0.0008, 0.0016, time.Now()},
        
        // Add more providers as needed
    }
    
    for _, p := range pricing {
        key := fmt.Sprintf("%s:%s", p.Provider, p.Model)
        t.pricingTable[key] = p
    }
}

func (t *LLMCostTracker) CalculateCost(provider LLMProvider, model string, usage TokenUsage) float64 {
    key := fmt.Sprintf("%s:%s", provider, model)
    pricing, exists := t.pricingTable[key]
    if !exists {
        return 0 // Unknown model, should alert
    }
    
    inputCost := float64(usage.InputTokens) / 1000.0 * pricing.InputPricePer1K
    outputCost := float64(usage.OutputTokens) / 1000.0 * pricing.OutputPricePer1K
    
    return inputCost + outputCost
}

func (t *LLMCostTracker) TrackRequest(ctx context.Context, req *LLMRequest) error {
    // Calculate cost
    req.Cost = t.CalculateCost(req.Provider, req.Model, req.Usage)
    
    // Update metrics
    labels := []string{
        string(req.Provider),
        req.Model,
        req.TeamID,
        req.ProjectID,
        req.FeatureName,
    }
    
    llmTokensUsed.WithLabelValues(append(labels, "input")...).Add(float64(req.Usage.InputTokens))
    llmTokensUsed.WithLabelValues(append(labels, "output")...).Add(float64(req.Usage.OutputTokens))
    llmCost.WithLabelValues(labels...).Add(req.Cost)
    llmLatency.WithLabelValues(labels...).Observe(req.Latency.Seconds())
    
    // Store for detailed analysis
    return t.storage.Store(ctx, req)
}
```

### 2. Cost Optimization Strategies

```go
// LLM cost optimization techniques
type LLMOptimizer struct {
    tracker *LLMCostTracker
    cache   *ResponseCache
    router  *ModelRouter
}

type OptimizationStrategy struct {
    Name        string
    Description string
    Savings     float64 // Percentage savings
    Complexity  string  // Low, Medium, High
}

func (o *LLMOptimizer) GetOptimizationStrategies() []OptimizationStrategy {
    return []OptimizationStrategy{
        {
            Name:        "Response Caching",
            Description: "Cache similar requests to avoid duplicate API calls",
            Savings:     40.0,
            Complexity:  "Low",
        },
        {
            Name:        "Model Selection",
            Description: "Use cheaper models for simpler tasks",
            Savings:     60.0,
            Complexity:  "Medium",
        },
        {
            Name:        "Prompt Optimization",
            Description: "Reduce token usage through better prompts",
            Savings:     25.0,
            Complexity:  "Medium",
        },
        {
            Name:        "Batch Processing",
            Description: "Combine multiple requests into single API call",
            Savings:     20.0,
            Complexity:  "High",
        },
        {
            Name:        "Streaming Responses",
            Description: "Use streaming to reduce perceived latency",
            Savings:     0.0,
            Complexity:  "Low",
        },
    }
}

// Response caching for identical requests
type ResponseCache struct {
    store map[string]CachedResponse
    ttl   time.Duration
}

type CachedResponse struct {
    Response  string    `json:"response"`
    Cost      float64   `json:"cost"`
    Timestamp time.Time `json:"timestamp"`
    Usage     TokenUsage `json:"usage"`
}

func (c *ResponseCache) Get(requestHash string) (*CachedResponse, bool) {
    cached, exists := c.store[requestHash]
    if !exists || time.Since(cached.Timestamp) > c.ttl {
        return nil, false
    }
    return &cached, true
}

func (c *ResponseCache) Set(requestHash string, response CachedResponse) {
    c.store[requestHash] = response
}

// Smart model routing based on task complexity
type ModelRouter struct {
    rules []RoutingRule
}

type RoutingRule struct {
    Condition string // e.g., "word_count < 100"
    Model     string
    Provider  LLMProvider
    Priority  int
}

func (r *ModelRouter) SelectModel(request string) (LLMProvider, string) {
    wordCount := len(strings.Fields(request))
    complexity := r.assessComplexity(request)
    
    // Simple routing logic
    switch {
    case wordCount < 50 && complexity == "low":
        return OpenAI, "gpt-3.5-turbo"
    case wordCount < 200 && complexity == "medium":
        return Anthropic, "claude-3-haiku"
    case complexity == "high":
        return OpenAI, "gpt-4-turbo"
    default:
        return Anthropic, "claude-3-sonnet"
    }
}

func (r *ModelRouter) assessComplexity(request string) string {
    // Simple heuristics - in practice, use ML models
    if strings.Contains(strings.ToLower(request), "code") ||
       strings.Contains(strings.ToLower(request), "analyze") {
        return "high"
    }
    if strings.Contains(strings.ToLower(request), "summarize") ||
       strings.Contains(strings.ToLower(request), "translate") {
        return "medium"
    }
    return "low"
}
```

### 3. Budget Controls and Alerts

```go
// Budget management for LLM usage
type LLMBudgetManager struct {
    budgets map[string]Budget
    alerts  []AlertRule
    tracker *LLMCostTracker
}

type Budget struct {
    ID          string    `json:"id"`
    Name        string    `json:"name"`
    Amount      float64   `json:"amount"`
    Period      string    `json:"period"` // daily, weekly, monthly
    Scope       BudgetScope `json:"scope"`
    StartDate   time.Time `json:"start_date"`
    EndDate     time.Time `json:"end_date"`
    SpentAmount float64   `json:"spent_amount"`
    Status      string    `json:"status"` // active, exceeded, warning
}

type BudgetScope struct {
    TeamID      string      `json:"team_id,omitempty"`
    ProjectID   string      `json:"project_id,omitempty"`
    FeatureName string      `json:"feature_name,omitempty"`
    Provider    LLMProvider `json:"provider,omitempty"`
    Model       string      `json:"model,omitempty"`
}

type AlertRule struct {
    BudgetID    string  `json:"budget_id"`
    Threshold   float64 `json:"threshold"` // Percentage of budget
    Recipients  []string `json:"recipients"`
    ActionType  string  `json:"action_type"` // email, slack, webhook, block
    Triggered   bool    `json:"triggered"`
}

func (bm *LLMBudgetManager) CheckBudgets(ctx context.Context) error {
    for budgetID, budget := range bm.budgets {
        spent, err := bm.calculateSpent(ctx, budget)
        if err != nil {
            return fmt.Errorf("failed to calculate spent amount for budget %s: %w", budgetID, err)
        }
        
        budget.SpentAmount = spent
        percentage := (spent / budget.Amount) * 100
        
        // Update budget status
        switch {
        case percentage >= 100:
            budget.Status = "exceeded"
        case percentage >= 80:
            budget.Status = "warning"
        default:
            budget.Status = "active"
        }
        
        // Check alert rules
        for _, alert := range bm.alerts {
            if alert.BudgetID == budgetID && !alert.Triggered {
                if percentage >= alert.Threshold {
                    bm.triggerAlert(ctx, alert, budget)
                    alert.Triggered = true
                }
            }
        }
        
        bm.budgets[budgetID] = budget
    }
    
    return nil
}

func (bm *LLMBudgetManager) triggerAlert(ctx context.Context, alert AlertRule, budget Budget) {
    switch alert.ActionType {
    case "email":
        bm.sendEmailAlert(alert.Recipients, budget)
    case "slack":
        bm.sendSlackAlert(alert.Recipients, budget)
    case "webhook":
        bm.sendWebhookAlert(alert.Recipients, budget)
    case "block":
        bm.blockRequests(budget.Scope)
    }
}
```

### 4. Cost Analytics and Reporting

```go
// Analytics for LLM cost insights
type LLMAnalytics struct {
    storage LLMUsageStorage
}

type CostReport struct {
    Period      string              `json:"period"`
    TotalCost   float64             `json:"total_cost"`
    TotalTokens int64               `json:"total_tokens"`
    ByProvider  map[string]float64  `json:"by_provider"`
    ByModel     map[string]float64  `json:"by_model"`
    ByTeam      map[string]float64  `json:"by_team"`
    ByFeature   map[string]float64  `json:"by_feature"`
    TopUsers    []UserUsage         `json:"top_users"`
    Trends      []TrendData         `json:"trends"`
    Efficiency  EfficiencyMetrics   `json:"efficiency"`
}

type UserUsage struct {
    UserID      string  `json:"user_id"`
    Cost        float64 `json:"cost"`
    Requests    int64   `json:"requests"`
    Tokens      int64   `json:"tokens"`
    CostPerToken float64 `json:"cost_per_token"`
}

type TrendData struct {
    Date     time.Time `json:"date"`
    Cost     float64   `json:"cost"`
    Requests int64     `json:"requests"`
    Tokens   int64     `json:"tokens"`
}

type EfficiencyMetrics struct {
    CacheHitRate      float64 `json:"cache_hit_rate"`
    AvgTokensPerReq   float64 `json:"avg_tokens_per_request"`
    CostPerUser       float64 `json:"cost_per_user"`
    ModelUtilization  map[string]float64 `json:"model_utilization"`
}

func (a *LLMAnalytics) GenerateReport(ctx context.Context, startDate, endDate time.Time) (*CostReport, error) {
    requests, err := a.storage.GetUsage(ctx, startDate, endDate)
    if err != nil {
        return nil, err
    }
    
    report := &CostReport{
        Period:     fmt.Sprintf("%s to %s", startDate.Format("2006-01-02"), endDate.Format("2006-01-02")),
        ByProvider: make(map[string]float64),
        ByModel:    make(map[string]float64),
        ByTeam:     make(map[string]float64),
        ByFeature:  make(map[string]float64),
    }
    
    // Aggregate data
    userCosts := make(map[string]*UserUsage)
    dailyCosts := make(map[string]*TrendData)
    
    for _, req := range requests {
        report.TotalCost += req.Cost
        report.TotalTokens += req.Usage.TotalTokens
        
        // By provider
        report.ByProvider[string(req.Provider)] += req.Cost
        
        // By model
        report.ByModel[req.Model] += req.Cost
        
        // By team
        report.ByTeam[req.TeamID] += req.Cost
        
        // By feature
        report.ByFeature[req.FeatureName] += req.Cost
        
        // User usage
        if userUsage, exists := userCosts[req.UserID]; exists {
            userUsage.Cost += req.Cost
            userUsage.Requests++
            userUsage.Tokens += req.Usage.TotalTokens
        } else {
            userCosts[req.UserID] = &UserUsage{
                UserID:   req.UserID,
                Cost:     req.Cost,
                Requests: 1,
                Tokens:   req.Usage.TotalTokens,
            }
        }
        
        // Daily trends
        dateKey := req.Timestamp.Format("2006-01-02")
        if trend, exists := dailyCosts[dateKey]; exists {
            trend.Cost += req.Cost
            trend.Requests++
            trend.Tokens += req.Usage.TotalTokens
        } else {
            dailyCosts[dateKey] = &TrendData{
                Date:     req.Timestamp,
                Cost:     req.Cost,
                Requests: 1,
                Tokens:   req.Usage.TotalTokens,
            }
        }
    }
    
    // Calculate efficiency metrics
    report.Efficiency = a.calculateEfficiencyMetrics(requests)
    
    // Sort and limit top users
    var users []*UserUsage
    for _, user := range userCosts {
        user.CostPerToken = user.Cost / float64(user.Tokens)
        users = append(users, user)
    }
    
    sort.Slice(users, func(i, j int) bool {
        return users[i].Cost > users[j].Cost
    })
    
    // Take top 10 users
    maxUsers := 10
    if len(users) < maxUsers {
        maxUsers = len(users)
    }
    
    for i := 0; i < maxUsers; i++ {
        report.TopUsers = append(report.TopUsers, *users[i])
    }
    
    // Convert daily trends to slice
    for _, trend := range dailyCosts {
        report.Trends = append(report.Trends, *trend)
    }
    
    sort.Slice(report.Trends, func(i, j int) bool {
        return report.Trends[i].Date.Before(report.Trends[j].Date)
    })
    
    return report, nil
}
```

### 5. Infrastructure Integration

```yaml
# Kubernetes deployment with cost monitoring
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-cost-tracker
  labels:
    app: llm-cost-tracker
spec:
  replicas: 2
  selector:
    matchLabels:
      app: llm-cost-tracker
  template:
    metadata:
      labels:
        app: llm-cost-tracker
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: tracker
        image: llm-cost-tracker:latest
        ports:
        - containerPort: 8080
          name: http
        - containerPort: 8090
          name: metrics
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: url
        - name: REDIS_URL
          valueFrom:
            configMapKeyRef:
              name: cache-config
              key: redis-url
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: llm-cost-tracker-service
spec:
  selector:
    app: llm-cost-tracker
  ports:
  - name: http
    port: 80
    targetPort: 8080
  - name: metrics
    port: 8090
    targetPort: 8090

---
# Grafana Dashboard ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: llm-cost-dashboard
data:
  dashboard.json: |
    {
      "dashboard": {
        "title": "LLM Cost Analytics",
        "panels": [
          {
            "title": "Daily LLM Costs",
            "type": "graph",
            "targets": [
              {
                "expr": "increase(llm_cost_usd_total[1d])",
                "legendFormat": "{{provider}}-{{model}}"
              }
            ]
          },
          {
            "title": "Token Usage by Provider",
            "type": "piechart",
            "targets": [
              {
                "expr": "sum by (provider) (llm_tokens_used_total)",
                "legendFormat": "{{provider}}"
              }
            ]
          },
          {
            "title": "Cost per Team",
            "type": "table",
            "targets": [
              {
                "expr": "sum by (team) (llm_cost_usd_total)",
                "legendFormat": "{{team}}"
              }
            ]
          },
          {
            "title": "Request Latency",
            "type": "graph",
            "targets": [
              {
                "expr": "histogram_quantile(0.95, llm_request_duration_seconds)",
                "legendFormat": "95th percentile"
              }
            ]
          }
        ]
      }
    }
```

### 6. Cost Optimization Automation

```go
// Automated cost optimization decisions
type CostOptimizationEngine struct {
    analytics *LLMAnalytics
    optimizer *LLMOptimizer
    rules     []OptimizationRule
}

type OptimizationRule struct {
    Name        string
    Condition   string  // e.g., "cost_per_token > threshold"
    Action      OptimizationAction
    Threshold   float64
    Enabled     bool
}

type OptimizationAction struct {
    Type        string                 // cache, route, limit, alert
    Parameters  map[string]interface{} // Action-specific config
}

func (oe *CostOptimizationEngine) RunOptimization(ctx context.Context) error {
    // Get recent analytics
    endTime := time.Now()
    startTime := endTime.AddDate(0, 0, -7) // Last 7 days
    
    report, err := oe.analytics.GenerateReport(ctx, startTime, endTime)
    if err != nil {
        return fmt.Errorf("failed to generate report: %w", err)
    }
    
    // Apply optimization rules
    for _, rule := range oe.rules {
        if !rule.Enabled {
            continue
        }
        
        shouldApply, err := oe.evaluateCondition(rule.Condition, report)
        if err != nil {
            log.Printf("Failed to evaluate rule %s: %v", rule.Name, err)
            continue
        }
        
        if shouldApply {
            if err := oe.applyOptimization(ctx, rule.Action, report); err != nil {
                log.Printf("Failed to apply optimization %s: %v", rule.Name, err)
            } else {
                log.Printf("Applied optimization rule: %s", rule.Name)
            }
        }
    }
    
    return nil
}

func (oe *CostOptimizationEngine) evaluateCondition(condition string, report *CostReport) (bool, error) {
    // Simple condition evaluator - in practice, use a proper expression engine
    switch condition {
    case "high_cost_per_token":
        avgCostPerToken := report.TotalCost / float64(report.TotalTokens)
        return avgCostPerToken > 0.001, nil // $0.001 per token threshold
    case "low_cache_hit_rate":
        return report.Efficiency.CacheHitRate < 0.5, nil // 50% threshold
    case "expensive_model_overuse":
        // Check if expensive models are used > 30% of the time
        expensiveModelCost := report.ByModel["gpt-4"] + report.ByModel["claude-3-opus"]
        return (expensiveModelCost / report.TotalCost) > 0.3, nil
    default:
        return false, fmt.Errorf("unknown condition: %s", condition)
    }
}
```

## Monitoring and Alerting

### Grafana Alerts Configuration

```yaml
# AlertManager configuration for LLM costs
groups:
- name: llm-cost-alerts
  rules:
  - alert: HighLLMCostSpike
    expr: increase(llm_cost_usd_total[1h]) > 100
    for: 5m
    labels:
      severity: warning
      team: platform
    annotations:
      summary: "High LLM cost spike detected"
      description: "LLM costs increased by ${{ $value }} in the last hour"
      
  - alert: BudgetExceeded
    expr: llm_monthly_budget_used_percent > 100
    for: 0m
    labels:
      severity: critical
      team: finops
    annotations:
      summary: "LLM budget exceeded"
      description: "Team {{ $labels.team }} has exceeded their monthly LLM budget"
      
  - alert: UnusualTokenUsage
    expr: rate(llm_tokens_used_total[5m]) > 10000
    for: 10m
    labels:
      severity: warning
      team: platform
    annotations:
      summary: "Unusual token usage pattern"
      description: "Token usage rate is {{ $value }} tokens/second, which is unusually high"
```

## Best Practices

### 1. Cost Allocation Strategy
- Tag every LLM request with team, project, and feature identifiers
- Implement showback/chargeback mechanisms
- Set clear budget limits per team/project

### 2. Model Selection Guidelines
- Use GPT-3.5-turbo for simple tasks (classification, basic Q&A)
- Use Claude-3-haiku for medium complexity tasks
- Reserve GPT-4/Claude-3-opus for complex reasoning tasks
- Regularly evaluate new models for cost-performance ratios

### 3. Prompt Engineering for Cost Optimization
- Keep prompts concise and specific
- Use system messages to reduce repetitive context
- Implement few-shot learning with minimal examples
- Consider fine-tuning for high-volume, specific use cases

### 4. Caching Strategy
- Cache responses for identical requests (exact match)
- Implement semantic caching for similar requests
- Set appropriate TTL based on content freshness requirements
- Monitor cache hit rates and optimize cache keys

## Consequences

### Positive
- **Cost Visibility**: Clear understanding of LLM spending patterns
- **Budget Control**: Automated enforcement of spending limits
- **Optimization**: Systematic reduction in unnecessary costs
- **Accountability**: Teams become responsible for their LLM usage
- **Performance**: Better model selection improves cost-performance ratios

### Negative
- **Complexity**: Additional infrastructure to maintain
- **Latency**: Caching and routing may add slight delays
- **Development Overhead**: Need to instrument all LLM calls
- **False Positives**: Automated optimization might be too aggressive

## Success Metrics

- **Cost Reduction**: 30-50% reduction in LLM costs through optimization
- **Budget Adherence**: 95% of teams stay within monthly budgets
- **Cache Hit Rate**: >60% cache hit rate for similar requests
- **Model Distribution**: <20% usage of most expensive models
- **Response Time**: <5% increase in average response time due to optimization

## References

- [OpenAI Pricing](https://openai.com/pricing)
- [Anthropic Pricing](https://www.anthropic.com/pricing)
- [AWS Bedrock Pricing](https://aws.amazon.com/bedrock/pricing/)
- [LLM Cost Optimization Best Practices](https://platform.openai.com/docs/guides/production-best-practices)
- [Token Usage Optimization](https://help.openai.com/en/articles/4936856-what-are-tokens-and-how-to-count-them)

## Related ADRs

- [001-rationality](./001-rationality.md) - General FinOps principles
- [013-logging](../backend/013-logging.md) - Cost-effective logging for LLM requests
- [012-use-metrics](../backend/012-use-metrics.md) - Metrics collection for cost tracking
