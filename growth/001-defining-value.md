# Defining Value: Impact-Effort Framework for Growth Initiatives

## Status
**Accepted** - 2024-01-15

## Context
Not all work produces the same value. Doing more work does not equal more value, especially when the overall impact is low. Organizations often struggle with prioritizing growth initiatives, leading to resource misallocation and suboptimal outcomes.

It is challenging to measure the relative value of an impact, but we can measure it relative to other impacts using a systematic framework.

## Problem Statement
Teams frequently face decision paralysis when choosing between multiple growth opportunities. Without a clear value framework:
- High-impact initiatives get delayed due to perceived effort
- Low-impact work consumes disproportionate resources
- Strategic alignment across teams becomes difficult
- ROI measurement lacks consistency

## Decision
Implement a comprehensive impact-effort framework to prioritize growth initiatives and maximize value delivery.

### The Impact-Effort Quadrant

We define value using a two-dimensional quadrant where:
- **Y-axis**: Measure of impact (business value, user value, strategic value)
- **X-axis**: Measure of effort (time, resources, complexity, risk)

```go
// Value assessment framework
package value

import (
    "fmt"
    "math"
    "sort"
    "time"
)

type ImpactLevel int
type EffortLevel int

const (
    ImpactLow    ImpactLevel = 1
    ImpactMedium ImpactLevel = 2
    ImpactHigh   ImpactLevel = 3
    
    EffortLow    EffortLevel = 1
    EffortMedium EffortLevel = 2
    EffortHigh   EffortLevel = 3
)

type Initiative struct {
    ID              string        `json:"id"`
    Name            string        `json:"name"`
    Description     string        `json:"description"`
    Impact          ImpactScore   `json:"impact"`
    Effort          EffortScore   `json:"effort"`
    ValueScore      float64       `json:"value_score"`
    Quadrant        string        `json:"quadrant"`
    Priority        int           `json:"priority"`
    EstimatedROI    float64       `json:"estimated_roi"`
    RiskLevel       string        `json:"risk_level"`
    Dependencies    []string      `json:"dependencies"`
    Team            string        `json:"team"`
    EstimatedDuration time.Duration `json:"estimated_duration"`
    CreatedAt       time.Time     `json:"created_at"`
}

type ImpactScore struct {
    BusinessValue   int     `json:"business_value"`   // 1-10 scale
    UserValue       int     `json:"user_value"`       // 1-10 scale
    StrategicValue  int     `json:"strategic_value"`  // 1-10 scale
    TotalScore      float64 `json:"total_score"`
    Reasoning       string  `json:"reasoning"`
}

type EffortScore struct {
    DevelopmentTime int     `json:"development_time"` // days
    ResourceCount   int     `json:"resource_count"`   // number of people
    Complexity      int     `json:"complexity"`       // 1-10 scale
    TechnicalRisk   int     `json:"technical_risk"`   // 1-10 scale
    TotalScore      float64 `json:"total_score"`
    Reasoning       string  `json:"reasoning"`
}

type ValueFramework struct {
    initiatives []Initiative
    weights     ImpactWeights
}

type ImpactWeights struct {
    Business   float64 `json:"business"`   // Weight for business impact
    User       float64 `json:"user"`       // Weight for user impact
    Strategic  float64 `json:"strategic"`  // Weight for strategic impact
}

func NewValueFramework() *ValueFramework {
    return &ValueFramework{
        initiatives: make([]Initiative, 0),
        weights: ImpactWeights{
            Business:  0.4,
            User:      0.35,
            Strategic: 0.25,
        },
    }
}

func (vf *ValueFramework) AssessInitiative(initiative Initiative) Initiative {
    // Calculate impact score (weighted average)
    initiative.Impact.TotalScore = 
        (float64(initiative.Impact.BusinessValue) * vf.weights.Business +
         float64(initiative.Impact.UserValue) * vf.weights.User +
         float64(initiative.Impact.StrategicValue) * vf.weights.Strategic)
    
    // Calculate effort score (considering multiple factors)
    timeScore := math.Min(float64(initiative.Effort.DevelopmentTime)/30, 10) // Normalize to 30 days max
    resourceScore := math.Min(float64(initiative.Effort.ResourceCount), 10)
    complexityScore := float64(initiative.Effort.Complexity)
    riskScore := float64(initiative.Effort.TechnicalRisk)
    
    initiative.Effort.TotalScore = (timeScore + resourceScore + complexityScore + riskScore) / 4
    
    // Calculate value score (Impact / Effort ratio)
    if initiative.Effort.TotalScore > 0 {
        initiative.ValueScore = initiative.Impact.TotalScore / initiative.Effort.TotalScore
    }
    
    // Determine quadrant
    initiative.Quadrant = vf.determineQuadrant(initiative.Impact.TotalScore, initiative.Effort.TotalScore)
    
    // Calculate estimated ROI
    initiative.EstimatedROI = vf.calculateROI(initiative)
    
    // Assess risk level
    initiative.RiskLevel = vf.assessRisk(initiative)
    
    return initiative
}

func (vf *ValueFramework) determineQuadrant(impact, effort float64) string {
    impactThreshold := 6.0  // High impact threshold
    effortThreshold := 6.0  // High effort threshold
    
    switch {
    case impact >= impactThreshold && effort < effortThreshold:
        return "Quick Wins"      // High impact, low effort
    case impact >= impactThreshold && effort >= effortThreshold:
        return "Major Projects"  // High impact, high effort
    case impact < impactThreshold && effort < effortThreshold:
        return "Fill-ins"        // Low impact, low effort
    default:
        return "Money Pits"      // Low impact, high effort
    }
}

func (vf *ValueFramework) calculateROI(initiative Initiative) float64 {
    // Simple ROI calculation based on impact and effort
    // In practice, this would use more sophisticated business metrics
    
    estimatedRevenue := initiative.Impact.BusinessValue * 10000.0 // $10k per business impact point
    estimatedCost := initiative.Effort.TotalScore * 5000.0        // $5k per effort point
    
    if estimatedCost > 0 {
        return ((estimatedRevenue - estimatedCost) / estimatedCost) * 100
    }
    return 0
}

func (vf *ValueFramework) assessRisk(initiative Initiative) string {
    riskScore := (initiative.Effort.TechnicalRisk + initiative.Effort.Complexity) / 2
    
    switch {
    case riskScore <= 3:
        return "Low"
    case riskScore <= 6:
        return "Medium"
    default:
        return "High"
    }
}

func (vf *ValueFramework) PrioritizeInitiatives(initiatives []Initiative) []Initiative {
    // Assess each initiative
    for i, initiative := range initiatives {
        initiatives[i] = vf.AssessInitiative(initiative)
    }
    
    // Sort by value score (descending)
    sort.Slice(initiatives, func(i, j int) bool {
        return initiatives[i].ValueScore > initiatives[j].ValueScore
    })
    
    // Assign priority numbers
    for i := range initiatives {
        initiatives[i].Priority = i + 1
    }
    
    return initiatives
}

func (vf *ValueFramework) GenerateRoadmap(initiatives []Initiative, 
    timeframeWeeks int) Roadmap {
    
    prioritized := vf.PrioritizeInitiatives(initiatives)
    
    roadmap := Roadmap{
        TimeframeWeeks: timeframeWeeks,
        Quarters:       make([]Quarter, 0),
        CreatedAt:      time.Now(),
    }
    
    // Group initiatives by quarters
    weeksPerQuarter := 13
    quartersCount := (timeframeWeeks + weeksPerQuarter - 1) / weeksPerQuarter
    
    for q := 0; q < quartersCount; q++ {
        quarter := Quarter{
            Number:      q + 1,
            Initiatives: make([]Initiative, 0),
            Theme:       vf.determineQuarterTheme(q, prioritized),
        }
        
        // Assign initiatives to quarter based on capacity and dependencies
        capacity := 40 // Development weeks per quarter
        usedCapacity := 0
        
        for _, initiative := range prioritized {
            if vf.canFitInQuarter(initiative, usedCapacity, capacity) &&
               vf.dependenciesMet(initiative, roadmap) {
                
                quarter.Initiatives = append(quarter.Initiatives, initiative)
                usedCapacity += int(initiative.EstimatedDuration.Hours() / 40) // Convert to weeks
                
                // Remove from available initiatives
                prioritized = vf.removeInitiative(prioritized, initiative.ID)
            }
        }
        
        roadmap.Quarters = append(roadmap.Quarters, quarter)
    }
    
    return roadmap
}

type Roadmap struct {
    TimeframeWeeks int       `json:"timeframe_weeks"`
    Quarters       []Quarter `json:"quarters"`
    CreatedAt      time.Time `json:"created_at"`
}

type Quarter struct {
    Number      int          `json:"number"`
    Theme       string       `json:"theme"`
    Initiatives []Initiative `json:"initiatives"`
    TotalValue  float64      `json:"total_value"`
    TotalEffort float64      `json:"total_effort"`
}

func (vf *ValueFramework) determineQuarterTheme(quarter int, initiatives []Initiative) string {
    themes := []string{
        "Foundation & Quick Wins",
        "Growth Acceleration", 
        "Scale & Optimization",
        "Innovation & Expansion",
    }
    
    if quarter < len(themes) {
        return themes[quarter]
    }
    return "Continuous Improvement"
}
```

### Quadrant Strategies

#### 1. Quick Wins (High Impact, Low Effort)
- **Priority**: Immediate execution
- **Strategy**: Do first to build momentum
- **Examples**: A/B testing simple UI changes, optimizing existing funnels
- **Timeline**: 1-4 weeks

#### 2. Major Projects (High Impact, High Effort)
- **Priority**: Strategic planning required
- **Strategy**: Break into smaller milestones with measurable outcomes
- **Examples**: New product features, major infrastructure changes
- **Timeline**: 3-6 months

#### 3. Fill-ins (Low Impact, Low Effort)
- **Priority**: Delegate or use for skill development
- **Strategy**: Good for junior team members or spare capacity
- **Examples**: Minor UI improvements, documentation updates
- **Timeline**: 1-2 weeks

#### 4. Money Pits (Low Impact, High Effort)
- **Priority**: Avoid or defer
- **Strategy**: Challenge assumptions, find alternatives
- **Examples**: Over-engineered solutions, premature optimizations
- **Timeline**: Indefinitely deferred

### Task Decomposition Strategy

For high-effort, high-impact initiatives:

```go
// Task decomposition for large initiatives
type TaskDecomposition struct {
    ParentInitiative Initiative  `json:"parent_initiative"`
    Milestones      []Milestone  `json:"milestones"`
    TotalValue      float64      `json:"total_value"`
}

type Milestone struct {
    ID              string        `json:"id"`
    Name            string        `json:"name"`
    Description     string        `json:"description"`
    Dependencies    []string      `json:"dependencies"`
    EstimatedEffort int           `json:"estimated_effort_days"`
    ExpectedValue   float64       `json:"expected_value"`
    SuccessMetrics  []string      `json:"success_metrics"`
    RiskMitigation  []string      `json:"risk_mitigation"`
    Order           int           `json:"order"`
}

func (vf *ValueFramework) DecomposeInitiative(initiative Initiative, 
    targetMilestoneSize int) TaskDecomposition {
    
    if initiative.Effort.DevelopmentTime <= targetMilestoneSize {
        // Already small enough
        return TaskDecomposition{
            ParentInitiative: initiative,
            Milestones: []Milestone{{
                ID:              initiative.ID + "-m1",
                Name:            initiative.Name,
                Description:     initiative.Description,
                EstimatedEffort: initiative.Effort.DevelopmentTime,
                ExpectedValue:   initiative.ValueScore,
                Order:           1,
            }},
        }
    }
    
    // Break into logical milestones
    milestoneCount := (initiative.Effort.DevelopmentTime + targetMilestoneSize - 1) / targetMilestoneSize
    milestones := make([]Milestone, 0, milestoneCount)
    
    for i := 0; i < milestoneCount; i++ {
        milestone := Milestone{
            ID:              fmt.Sprintf("%s-m%d", initiative.ID, i+1),
            Name:            fmt.Sprintf("%s - Phase %d", initiative.Name, i+1),
            EstimatedEffort: targetMilestoneSize,
            ExpectedValue:   initiative.ValueScore / float64(milestoneCount),
            Order:           i + 1,
        }
        
        // Last milestone might be smaller
        if i == milestoneCount-1 {
            remaining := initiative.Effort.DevelopmentTime % targetMilestoneSize
            if remaining > 0 {
                milestone.EstimatedEffort = remaining
            }
        }
        
        milestones = append(milestones, milestone)
    }
    
    return TaskDecomposition{
        ParentInitiative: initiative,
        Milestones:      milestones,
        TotalValue:      initiative.ValueScore,
    }
}
```

## Implementation Guidelines

### 1. Regular Assessment Process
- Conduct weekly initiative reviews
- Monthly roadmap updates
- Quarterly strategic realignment

### 2. Stakeholder Involvement
- Product owners define business impact
- Engineering teams estimate effort
- Leadership validates strategic alignment

### 3. Metrics and Tracking
- Value delivery tracking per initiative
- Effort estimation accuracy
- ROI measurement and forecasting

### 4. Decision Documentation
- Record rationale for each initiative assessment
- Track assumption validation
- Maintain historical prioritization data

## Success Metrics

- **Delivery Velocity**: 25% increase in value delivered per quarter
- **Estimation Accuracy**: 90% of initiatives delivered within effort estimates
- **Strategic Alignment**: 80% of initiatives align with quarterly themes
- **ROI Achievement**: 150% average ROI on completed initiatives

## Consequences

### Positive
- **Clear Prioritization**: Systematic approach to initiative selection
- **Resource Optimization**: Better allocation of development resources
- **Strategic Alignment**: Initiatives align with business objectives
- **Measurable Outcomes**: Trackable value delivery and ROI

### Negative
- **Initial Overhead**: Time investment in assessment process
- **Subjectivity**: Impact scoring can be subjective
- **Analysis Paralysis**: Over-analysis may delay quick decisions
- **Framework Maintenance**: Regular updates needed as business evolves

## Best Practices

1. **Start Simple**: Begin with basic impact-effort assessment
2. **Iterate and Improve**: Refine scoring based on historical data
3. **Involve Stakeholders**: Get input from all relevant parties
4. **Regular Reviews**: Update assessments as new information emerges
5. **Document Decisions**: Maintain clear records of prioritization rationale

## Related ADRs

- [002-the-funnel](./002-the-funnel.md) - User funnel optimization prioritization
- [009-ab-testing-framework](./009-ab-testing-framework.md) - Testing high-impact initiatives
- [010-metrics-measurement](./010-metrics-measurement.md) - Measuring initiative impact

