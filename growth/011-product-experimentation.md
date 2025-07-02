# Product Experimentation and Hypothesis-Driven Development

## Status

`production`

## Context

Product experimentation and hypothesis-driven development represent a fundamental shift from opinion-based to evidence-based product decisions. This approach reduces risk, accelerates learning, and ensures product development efforts focus on features that truly drive user value and business outcomes.

By embedding experimentation into the product development lifecycle, teams can validate assumptions, measure impact, and iterate based on real user behavior rather than intuition alone.

## Hypothesis-Driven Framework

### The Scientific Product Method

```
Hypothesis → Experiment → Measurement → Learning → Iteration
```

### Core Philosophy

```go
package experimentation

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
    "database/sql"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

type HypothesisType string

const (
    TypeFeature      HypothesisType = "feature"      // New feature hypothesis
    TypeOptimization HypothesisType = "optimization" // Improvement hypothesis
    TypeBehavioral   HypothesisType = "behavioral"   // User behavior hypothesis
    TypeBusiness     HypothesisType = "business"     // Business model hypothesis
    TypeTechnical    HypothesisType = "technical"    // Technical performance hypothesis
)

type ConfidenceLevel string

const (
    ConfidenceLow    ConfidenceLevel = "low"    // 0-30%
    ConfidenceMedium ConfidenceLevel = "medium" // 31-70%
    ConfidenceHigh   ConfidenceLevel = "high"   // 71-100%
)

type HypothesisStatus string

const (
    StatusDraft      HypothesisStatus = "draft"
    StatusActive     HypothesisStatus = "active"
    StatusTesting    HypothesisStatus = "testing"
    StatusValidated  HypothesisStatus = "validated"
    StatusRefuted    HypothesisStatus = "refuted"
    StatusInconclusive HypothesisStatus = "inconclusive"
)

type Hypothesis struct {
    ID               string                 `json:"id"`
    Title            string                 `json:"title"`
    Type             HypothesisType         `json:"type"`
    Status           HypothesisStatus       `json:"status"`
    Problem          ProblemStatement       `json:"problem"`
    Solution         SolutionHypothesis     `json:"solution"`
    Assumptions      []Assumption           `json:"assumptions"`
    SuccessMetrics   []MetricDefinition     `json:"success_metrics"`
    Experiments      []ExperimentDesign     `json:"experiments"`
    Timeline         Timeline               `json:"timeline"`
    Resources        ResourceRequirements   `json:"resources"`
    RiskAssessment   RiskAssessment         `json:"risk_assessment"`
    Results          *HypothesisResults     `json:"results,omitempty"`
    Learnings        []Learning             `json:"learnings"`
    Owner            string                 `json:"owner"`
    Stakeholders     []string               `json:"stakeholders"`
    Tags             []string               `json:"tags"`
    CreatedAt        time.Time              `json:"created_at"`
    UpdatedAt        time.Time              `json:"updated_at"`
}

type ProblemStatement struct {
    Description      string            `json:"description"`
    UserSegments     []string          `json:"user_segments"`
    PainPoints       []string          `json:"pain_points"`
    CurrentSolution  string            `json:"current_solution"`
    OpportunityCost  float64           `json:"opportunity_cost"`
    Evidence         []Evidence        `json:"evidence"`
    Frequency        string            `json:"frequency"`        // how often problem occurs
    Severity         string            `json:"severity"`         // impact when it occurs
}

type SolutionHypothesis struct {
    Description      string                 `json:"description"`
    Approach         string                 `json:"approach"`
    ExpectedOutcome  string                 `json:"expected_outcome"`
    UserExperience   UserExperienceDesign   `json:"user_experience"`
    TechnicalDesign  TechnicalDesign        `json:"technical_design"`
    Alternatives     []Alternative          `json:"alternatives"`
    Dependencies     []string               `json:"dependencies"`
}

type Assumption struct {
    ID             string          `json:"id"`
    Description    string          `json:"description"`
    Type           string          `json:"type"`           // user, market, technical, business
    Confidence     ConfidenceLevel `json:"confidence"`
    Criticality    string          `json:"criticality"`    // low, medium, high
    Evidence       []Evidence      `json:"evidence"`
    TestMethod     string          `json:"test_method"`
    Status         string          `json:"status"`         // untested, testing, validated, refuted
    TestResults    *TestResult     `json:"test_results,omitempty"`
}

type Evidence struct {
    Type        string    `json:"type"`        // data, research, feedback, observation
    Source      string    `json:"source"`
    Description string    `json:"description"`
    Strength    string    `json:"strength"`    // weak, moderate, strong
    Date        time.Time `json:"date"`
    URL         string    `json:"url,omitempty"`
}

type ExperimentDesign struct {
    ID              string                 `json:"id"`
    Name            string                 `json:"name"`
    Type            string                 `json:"type"`
    Description     string                 `json:"description"`
    TestingMethod   string                 `json:"testing_method"` // ab_test, multivariate, user_testing, analytics
    Participants    ParticipantCriteria    `json:"participants"`
    Variables       []ExperimentVariable   `json:"variables"`
    SuccessCriteria []SuccessCriteria      `json:"success_criteria"`
    Duration        time.Duration          `json:"duration"`
    Resources       ResourceRequirements   `json:"resources"`
    Risks           []Risk                 `json:"risks"`
}

type ParticipantCriteria struct {
    TargetSegments   []string `json:"target_segments"`
    SampleSize       int      `json:"sample_size"`
    PowerAnalysis    PowerAnalysis `json:"power_analysis"`
    InclusionCriteria []string `json:"inclusion_criteria"`
    ExclusionCriteria []string `json:"exclusion_criteria"`
}

type ExperimentVariable struct {
    Name         string      `json:"name"`
    Type         string      `json:"type"`         // independent, dependent, control
    Description  string      `json:"description"`
    Values       []string    `json:"values"`
    MeasureMethod string     `json:"measure_method"`
}

type SuccessCriteria struct {
    Metric       string  `json:"metric"`
    Direction    string  `json:"direction"`     // increase, decrease, maintain
    Threshold    float64 `json:"threshold"`
    Significance float64 `json:"significance"`  // required statistical significance
}

var (
    hypothesesActive = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "hypotheses_active_total",
            Help: "Number of active hypotheses by type",
        },
        []string{"type", "owner"},
    )
    
    hypothesesValidated = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "hypotheses_validated_total",
            Help: "Number of validated hypotheses",
        },
        []string{"type"},
    )
    
    experimentsRunning = promauto.NewGauge(
        prometheus.GaugeOpts{
            Name: "experiments_running_total",
            Help: "Number of currently running experiments",
        },
    )
    
    learningVelocity = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "learning_velocity_per_week",
            Help: "Rate of validated learnings per week",
        },
        []string{"team"},
    )
)

type ExperimentationEngine struct {
    db                *sql.DB
    hypothesisManager HypothesisManager
    experimentRunner  ExperimentRunner
    dataCollector     DataCollector
    analysisEngine    AnalysisEngine
    learningCapture   LearningCapture
    logger            Logger
}

func NewExperimentationEngine(db *sql.DB) *ExperimentationEngine {
    return &ExperimentationEngine{
        db:                db,
        hypothesisManager: NewHypothesisManager(db),
        experimentRunner:  NewExperimentRunner(),
        dataCollector:     NewDataCollector(),
        analysisEngine:    NewAnalysisEngine(),
        learningCapture:   NewLearningCapture(),
        logger:            NewLogger(),
    }
}

func (e *ExperimentationEngine) CreateHypothesis(ctx context.Context, 
    hypothesis *Hypothesis) error {
    
    // Validate hypothesis structure
    if err := e.validateHypothesis(hypothesis); err != nil {
        return fmt.Errorf("hypothesis validation failed: %w", err)
    }
    
    // Generate experiments for key assumptions
    experiments, err := e.generateExperiments(hypothesis)
    if err != nil {
        return fmt.Errorf("failed to generate experiments: %w", err)
    }
    
    hypothesis.Experiments = experiments
    hypothesis.ID = generateHypothesisID()
    hypothesis.Status = StatusDraft
    hypothesis.CreatedAt = time.Now()
    
    // Store hypothesis
    if err := e.hypothesisManager.Store(ctx, hypothesis); err != nil {
        return fmt.Errorf("failed to store hypothesis: %w", err)
    }
    
    // Update metrics
    hypothesesActive.WithLabelValues(string(hypothesis.Type), hypothesis.Owner).Inc()
    
    e.logger.Info("hypothesis created", "hypothesis_id", hypothesis.ID, 
                  "type", hypothesis.Type)
    
    return nil
}

func (e *ExperimentationEngine) validateHypothesis(hypothesis *Hypothesis) error {
    if hypothesis.Problem.Description == "" {
        return fmt.Errorf("problem description is required")
    }
    
    if hypothesis.Solution.Description == "" {
        return fmt.Errorf("solution description is required")
    }
    
    if len(hypothesis.SuccessMetrics) == 0 {
        return fmt.Errorf("at least one success metric is required")
    }
    
    if len(hypothesis.Assumptions) == 0 {
        return fmt.Errorf("at least one assumption is required")
    }
    
    // Validate assumptions have test methods
    for _, assumption := range hypothesis.Assumptions {
        if assumption.TestMethod == "" {
            return fmt.Errorf("assumption '%s' missing test method", assumption.Description)
        }
    }
    
    return nil
}

func (e *ExperimentationEngine) generateExperiments(hypothesis *Hypothesis) ([]ExperimentDesign, error) {
    var experiments []ExperimentDesign
    
    // Create experiments for high-criticality assumptions
    for _, assumption := range hypothesis.Assumptions {
        if assumption.Criticality == "high" {
            experiment := e.createExperimentForAssumption(hypothesis, assumption)
            experiments = append(experiments, experiment)
        }
    }
    
    // Create main feature experiment if applicable
    if hypothesis.Type == TypeFeature {
        mainExperiment := e.createMainFeatureExperiment(hypothesis)
        experiments = append(experiments, mainExperiment)
    }
    
    return experiments, nil
}

func (e *ExperimentationEngine) createExperimentForAssumption(hypothesis *Hypothesis, 
    assumption Assumption) ExperimentDesign {
    
    experiment := ExperimentDesign{
        ID:          fmt.Sprintf("%s-assumption-%s", hypothesis.ID, assumption.ID),
        Name:        fmt.Sprintf("Test: %s", assumption.Description),
        Type:        "assumption_validation",
        Description: fmt.Sprintf("Validate assumption: %s", assumption.Description),
    }
    
    // Set testing method based on assumption type
    switch assumption.Type {
    case "user":
        experiment.TestingMethod = "user_testing"
        experiment.Duration = 7 * 24 * time.Hour // 1 week
    case "market":
        experiment.TestingMethod = "analytics"
        experiment.Duration = 14 * 24 * time.Hour // 2 weeks
    case "technical":
        experiment.TestingMethod = "prototype"
        experiment.Duration = 5 * 24 * time.Hour // 1 week
    case "business":
        experiment.TestingMethod = "ab_test"
        experiment.Duration = 21 * 24 * time.Hour // 3 weeks
    default:
        experiment.TestingMethod = "analytics"
        experiment.Duration = 14 * 24 * time.Hour
    }
    
    // Set success criteria based on assumption confidence
    experiment.SuccessCriteria = []SuccessCriteria{
        {
            Metric:       "assumption_confidence",
            Direction:    "increase",
            Threshold:    0.7, // 70% confidence
            Significance: 0.95,
        },
    }
    
    return experiment
}
```

### Learning Velocity Framework

```go
type LearningCapture struct {
    db               *sql.DB
    knowledgeBase    KnowledgeBase
    patternDetector  PatternDetector
    recommendationEngine RecommendationEngine
}

type Learning struct {
    ID               string                 `json:"id"`
    HypothesisID     string                 `json:"hypothesis_id"`
    ExperimentID     string                 `json:"experiment_id"`
    Type             LearningType           `json:"type"`
    Title            string                 `json:"title"`
    Description      string                 `json:"description"`
    Evidence         []Evidence             `json:"evidence"`
    Confidence       ConfidenceLevel        `json:"confidence"`
    Applicability    []string               `json:"applicability"`    // contexts where learning applies
    Implications     []Implication          `json:"implications"`
    RecommendedActions []RecommendedAction  `json:"recommended_actions"`
    RelatedLearnings []string               `json:"related_learnings"`
    Tags             []string               `json:"tags"`
    CreatedBy        string                 `json:"created_by"`
    CreatedAt        time.Time              `json:"created_at"`
    VerifiedAt       *time.Time             `json:"verified_at,omitempty"`
}

type LearningType string

const (
    LearningUserBehavior    LearningType = "user_behavior"
    LearningFeatureImpact   LearningType = "feature_impact"
    LearningMarketInsight   LearningType = "market_insight"
    LearningTechnicalInsight LearningType = "technical_insight"
    LearningBusinessModel   LearningType = "business_model"
    LearningProcessInsight  LearningType = "process_insight"
)

type Implication struct {
    Area        string `json:"area"`        // product, engineering, marketing, business
    Impact      string `json:"impact"`      // high, medium, low
    Description string `json:"description"`
    Timeline    string `json:"timeline"`    // immediate, short-term, long-term
}

type RecommendedAction struct {
    Type        string `json:"type"`        // continue, stop, pivot, investigate
    Description string `json:"description"`
    Priority    string `json:"priority"`    // high, medium, low
    Owner       string `json:"owner"`
    Effort      string `json:"effort"`      // low, medium, high
    Timeline    string `json:"timeline"`
}

func (lc *LearningCapture) CaptureExperimentLearning(ctx context.Context, 
    experimentResults *ExperimentResults) (*Learning, error) {
    
    learning := &Learning{
        ID:           generateLearningID(),
        ExperimentID: experimentResults.ExperimentID,
        CreatedAt:    time.Now(),
    }
    
    // Analyze results to extract insights
    insights := lc.analyzeResults(experimentResults)
    
    // Determine learning type
    learning.Type = lc.determineLearningType(experimentResults, insights)
    
    // Generate title and description
    learning.Title = lc.generateLearningTitle(experimentResults, insights)
    learning.Description = lc.generateLearningDescription(experimentResults, insights)
    
    // Assess confidence
    learning.Confidence = lc.assessConfidence(experimentResults)
    
    // Generate implications
    learning.Implications = lc.generateImplications(insights)
    
    // Generate recommended actions
    learning.RecommendedActions = lc.generateRecommendedActions(insights)
    
    // Find related learnings
    relatedLearnings, err := lc.findRelatedLearnings(ctx, learning)
    if err != nil {
        lc.logger.Error("failed to find related learnings", "error", err)
    } else {
        learning.RelatedLearnings = relatedLearnings
    }
    
    // Store learning
    if err := lc.storeLearning(ctx, learning); err != nil {
        return nil, fmt.Errorf("failed to store learning: %w", err)
    }
    
    // Update knowledge base
    lc.knowledgeBase.AddLearning(learning)
    
    // Update learning velocity metrics
    lc.updateLearningMetrics(learning)
    
    return learning, nil
}

func (lc *LearningCapture) analyzeResults(results *ExperimentResults) []Insight {
    var insights []Insight
    
    // Analyze metric changes
    for metricName, metricResult := range results.MetricResults {
        if metricResult.Significance {
            insight := Insight{
                Type:        "metric_impact",
                Description: fmt.Sprintf("%s showed significant %s of %.2f%%", 
                           metricName, getDirection(metricResult.EffectSize), 
                           math.Abs(metricResult.EffectSize)*100),
                Confidence:  metricResult.Confidence,
                Evidence:    []string{fmt.Sprintf("p-value: %.4f", metricResult.PValue)},
            }
            insights = append(insights, insight)
        }
    }
    
    // Analyze user segments
    segmentInsights := lc.analyzeSegmentBehavior(results)
    insights = append(insights, segmentInsights...)
    
    // Analyze unexpected results
    unexpectedInsights := lc.detectUnexpectedResults(results)
    insights = append(insights, unexpectedInsights...)
    
    return insights
}

type ExperimentationDashboard struct {
    engine         *ExperimentationEngine
    portfolioManager ExperimentPortfolioManager
    learningManager *LearningCapture
}

func (d *ExperimentationDashboard) GenerateExperimentationReport(ctx context.Context) (*ExperimentationReport, error) {
    report := &ExperimentationReport{
        GeneratedAt: time.Now(),
    }
    
    // Get active hypotheses
    activeHypotheses, err := d.engine.hypothesisManager.GetActiveHypotheses(ctx)
    if err != nil {
        return nil, fmt.Errorf("failed to get active hypotheses: %w", err)
    }
    
    report.ActiveHypotheses = len(activeHypotheses)
    
    // Get running experiments
    runningExperiments, err := d.engine.experimentRunner.GetRunningExperiments(ctx)
    if err != nil {
        return nil, fmt.Errorf("failed to get running experiments: %w", err)
    }
    
    report.RunningExperiments = len(runningExperiments)
    
    // Calculate learning velocity
    learningVelocity, err := d.calculateLearningVelocity(ctx, 30) // last 30 days
    if err != nil {
        return nil, fmt.Errorf("failed to calculate learning velocity: %w", err)
    }
    
    report.LearningVelocity = learningVelocity
    
    // Get hypothesis success rate
    successRate, err := d.calculateHypothesisSuccessRate(ctx, 90) // last 90 days
    if err != nil {
        return nil, fmt.Errorf("failed to calculate success rate: %w", err)
    }
    
    report.HypothesisSuccessRate = successRate
    
    // Get top learnings
    topLearnings, err := d.getTopLearnings(ctx, 10)
    if err != nil {
        return nil, fmt.Errorf("failed to get top learnings: %w", err)
    }
    
    report.TopLearnings = topLearnings
    
    // Generate recommendations
    recommendations := d.generateRecommendations(activeHypotheses, runningExperiments)
    report.Recommendations = recommendations
    
    return report, nil
}

type ExperimentationReport struct {
    GeneratedAt           time.Time             `json:"generated_at"`
    ActiveHypotheses      int                   `json:"active_hypotheses"`
    RunningExperiments    int                   `json:"running_experiments"`
    LearningVelocity      float64               `json:"learning_velocity"`      // learnings per week
    HypothesisSuccessRate float64               `json:"hypothesis_success_rate"` // % validated
    TopLearnings          []Learning            `json:"top_learnings"`
    Recommendations       []Recommendation      `json:"recommendations"`
    ExperimentPipeline    ExperimentPipeline    `json:"experiment_pipeline"`
}

type ExperimentPipeline struct {
    IdeasBacklog      int `json:"ideas_backlog"`
    HypothesesDraft   int `json:"hypotheses_draft"`
    ExperimentsReady  int `json:"experiments_ready"`
    ExperimentsRunning int `json:"experiments_running"`
    ResultsAnalyzing  int `json:"results_analyzing"`
    LearningsCapturing int `json:"learnings_capturing"`
}

type Recommendation struct {
    Type        string `json:"type"`
    Priority    string `json:"priority"`
    Title       string `json:"title"`
    Description string `json:"description"`
    Action      string `json:"action"`
    Impact      string `json:"impact"`
}
```

### Hypothesis Templates and Patterns

```go
type HypothesisTemplate struct {
    ID              string                    `json:"id"`
    Name            string                    `json:"name"`
    Category        string                    `json:"category"`
    Description     string                    `json:"description"`
    ProblemTemplate ProblemStatementTemplate  `json:"problem_template"`
    SolutionTemplate SolutionTemplate         `json:"solution_template"`
    CommonAssumptions []AssumptionTemplate    `json:"common_assumptions"`
    SuggestedMetrics []string                 `json:"suggested_metrics"`
    TypicalDuration  time.Duration            `json:"typical_duration"`
    ExampleHypotheses []string                `json:"example_hypotheses"`
}

type ProblemStatementTemplate struct {
    Template        string   `json:"template"`
    Variables       []string `json:"variables"`
    PainPointTypes  []string `json:"pain_point_types"`
    EvidenceTypes   []string `json:"evidence_types"`
}

type SolutionTemplate struct {
    Template       string   `json:"template"`
    Variables      []string `json:"variables"`
    ApproachTypes  []string `json:"approach_types"`
    OutcomeTypes   []string `json:"outcome_types"`
}

type AssumptionTemplate struct {
    Template     string          `json:"template"`
    Type         string          `json:"type"`
    Criticality  string          `json:"criticality"`
    TestMethods  []string        `json:"test_methods"`
    SuccessCriteria []string     `json:"success_criteria"`
}

var CommonHypothesisTemplates = []HypothesisTemplate{
    {
        ID:          "onboarding-optimization",
        Name:        "User Onboarding Optimization",
        Category:    "user_experience",
        Description: "Improve user activation and initial experience",
        ProblemTemplate: ProblemStatementTemplate{
            Template: "Users are experiencing {pain_point} during {onboarding_stage}, resulting in {negative_outcome}",
            Variables: []string{"pain_point", "onboarding_stage", "negative_outcome"},
            PainPointTypes: []string{"confusion", "friction", "complexity", "time_to_value"},
            EvidenceTypes: []string{"analytics", "user_feedback", "support_tickets", "user_testing"},
        },
        SolutionTemplate: SolutionTemplate{
            Template: "By {intervention}, we will {expected_improvement} for {user_segment}",
            Variables: []string{"intervention", "expected_improvement", "user_segment"},
            ApproachTypes: []string{"simplification", "guided_tour", "progressive_disclosure", "social_proof"},
            OutcomeTypes: []string{"increased_activation", "reduced_time_to_value", "improved_satisfaction"},
        },
        CommonAssumptions: []AssumptionTemplate{
            {
                Template: "Users understand the value proposition within {time_period}",
                Type: "user",
                Criticality: "high",
                TestMethods: []string{"user_testing", "analytics", "surveys"},
                SuccessCriteria: []string{">70% comprehension rate", "<30 seconds to understanding"},
            },
            {
                Template: "The current onboarding flow creates friction at step {step_number}",
                Type: "user",
                Criticality: "medium",
                TestMethods: []string{"analytics", "funnel_analysis", "user_recordings"},
                SuccessCriteria: []string{">20% drop-off rate", "exit intent data"},
            },
        },
        SuggestedMetrics: []string{
            "activation_rate", "time_to_first_value", "onboarding_completion_rate",
            "user_satisfaction_score", "support_ticket_volume",
        },
        TypicalDuration: 14 * 24 * time.Hour, // 2 weeks
    },
    
    {
        ID:          "feature-adoption",
        Name:        "New Feature Adoption",
        Category:    "feature_development",
        Description: "Drive adoption of new product features",
        ProblemTemplate: ProblemStatementTemplate{
            Template: "Users are not discovering or adopting {feature_name} because {adoption_barrier}",
            Variables: []string{"feature_name", "adoption_barrier"},
            PainPointTypes: []string{"discoverability", "perceived_value", "complexity", "timing"},
            EvidenceTypes: []string{"usage_analytics", "user_interviews", "feature_requests"},
        },
        SolutionTemplate: SolutionTemplate{
            Template: "By {promotion_strategy}, we will increase feature adoption by {target_increase}",
            Variables: []string{"promotion_strategy", "target_increase"},
            ApproachTypes: []string{"in_app_messaging", "email_campaigns", "contextual_prompts", "tutorial"},
            OutcomeTypes: []string{"increased_feature_usage", "improved_user_engagement", "higher_retention"},
        },
        CommonAssumptions: []AssumptionTemplate{
            {
                Template: "Users will find value in {feature_name} once they try it",
                Type: "user",
                Criticality: "high",
                TestMethods: []string{"user_testing", "feature_usage_analytics", "nps_surveys"},
                SuccessCriteria: []string{">60% satisfaction rate", ">40% repeat usage"},
            },
            {
                Template: "Users are not aware that {feature_name} exists",
                Type: "user",
                Criticality: "medium",
                TestMethods: []string{"user_surveys", "discovery_analytics", "user_interviews"},
                SuccessCriteria: []string{"<30% feature awareness", "low discovery metrics"},
            },
        },
        SuggestedMetrics: []string{
            "feature_discovery_rate", "feature_trial_rate", "feature_adoption_rate",
            "feature_retention_rate", "user_satisfaction_with_feature",
        },
        TypicalDuration: 21 * 24 * time.Hour, // 3 weeks
    },
    
    {
        ID:          "conversion-optimization",
        Name:        "Conversion Rate Optimization",
        Category:    "growth",
        Description: "Improve conversion at key funnel stages",
        ProblemTemplate: ProblemStatementTemplate{
            Template: "Conversion from {stage_a} to {stage_b} is below target due to {conversion_barrier}",
            Variables: []string{"stage_a", "stage_b", "conversion_barrier"},
            PainPointTypes: []string{"friction", "unclear_value", "trust_issues", "price_sensitivity"},
            EvidenceTypes: []string{"funnel_analytics", "user_research", "exit_surveys", "heat_maps"},
        },
        SolutionTemplate: SolutionTemplate{
            Template: "By {optimization_approach}, we will improve conversion by {target_lift}",
            Variables: []string{"optimization_approach", "target_lift"},
            ApproachTypes: []string{"reduce_friction", "clarify_value", "build_trust", "adjust_pricing"},
            OutcomeTypes: []string{"increased_conversion", "improved_revenue", "better_user_flow"},
        },
        CommonAssumptions: []AssumptionTemplate{
            {
                Template: "The primary conversion barrier is {specific_barrier}",
                Type: "user",
                Criticality: "high",
                TestMethods: []string{"user_testing", "analytics", "exit_surveys"},
                SuccessCriteria: []string{"user feedback confirms barrier", "analytics show drop-off"},
            },
            {
                Template: "Removing {barrier} will increase conversion by {expected_lift}%",
                Type: "business",
                Criticality: "high",
                TestMethods: []string{"ab_test", "multivariate_test", "gradual_rollout"},
                SuccessCriteria: []string{"statistical significance", "business impact"},
            },
        },
        SuggestedMetrics: []string{
            "conversion_rate", "funnel_completion_rate", "revenue_per_visitor",
            "cart_abandonment_rate", "form_completion_rate",
        },
        TypicalDuration: 28 * 24 * time.Hour, // 4 weeks
    },
}

func (ht *HypothesisTemplate) GenerateHypothesis(variables map[string]string) (*Hypothesis, error) {
    hypothesis := &Hypothesis{
        Type:      TypeFeature, // Default, will be updated based on template
        CreatedAt: time.Now(),
    }
    
    // Generate problem statement
    problemDesc := ht.ProblemTemplate.Template
    for key, value := range variables {
        placeholder := fmt.Sprintf("{%s}", key)
        problemDesc = strings.ReplaceAll(problemDesc, placeholder, value)
    }
    
    hypothesis.Problem = ProblemStatement{
        Description: problemDesc,
    }
    
    // Generate solution hypothesis
    solutionDesc := ht.SolutionTemplate.Template
    for key, value := range variables {
        placeholder := fmt.Sprintf("{%s}", key)
        solutionDesc = strings.ReplaceAll(solutionDesc, placeholder, value)
    }
    
    hypothesis.Solution = SolutionHypothesis{
        Description: solutionDesc,
    }
    
    // Generate assumptions from templates
    var assumptions []Assumption
    for _, template := range ht.CommonAssumptions {
        assumptionDesc := template.Template
        for key, value := range variables {
            placeholder := fmt.Sprintf("{%s}", key)
            assumptionDesc = strings.ReplaceAll(assumptionDesc, placeholder, value)
        }
        
        assumption := Assumption{
            ID:          generateAssumptionID(),
            Description: assumptionDesc,
            Type:        template.Type,
            Criticality: template.Criticality,
            Confidence:  ConfidenceLow, // Start with low confidence
            Status:      "untested",
        }
        
        if len(template.TestMethods) > 0 {
            assumption.TestMethod = template.TestMethods[0] // Use first suggested method
        }
        
        assumptions = append(assumptions, assumption)
    }
    
    hypothesis.Assumptions = assumptions
    
    return hypothesis, nil
}
```

## Best Practices

### Hypothesis Formation

1. **Problem-First Approach**: Start with clear problem definitions
2. **Testable Statements**: Ensure hypotheses can be validated or refuted
3. **Specific Predictions**: Include measurable outcomes and timelines
4. **Risk Assessment**: Evaluate potential negative impacts

### Experiment Design

1. **Controlled Variables**: Isolate the factor being tested
2. **Statistical Power**: Ensure sufficient sample sizes
3. **Clear Success Criteria**: Define what constitutes success/failure
4. **Bias Mitigation**: Account for selection and confirmation biases

### Learning Capture

1. **Document Everything**: Record both positive and negative results
2. **Context Preservation**: Maintain environmental and temporal context
3. **Actionable Insights**: Extract specific, implementable learnings
4. **Knowledge Sharing**: Distribute learnings across teams

## Implementation Strategy

### Phase 1: Foundation (Weeks 1-6)
- Establish hypothesis framework and templates
- Implement basic experiment tracking
- Train teams on scientific method
- Create initial knowledge base

### Phase 2: Process (Weeks 7-12)
- Deploy experiment management system
- Implement learning capture process
- Establish review cadences
- Create reporting dashboards

### Phase 3: Optimization (Weeks 13-18)
- Advanced analytics and insights
- Automated experiment generation
- Pattern recognition system
- Continuous improvement process

## Common Pitfalls

1. **Confirmation Bias**: Designing experiments to prove rather than test
2. **Premature Conclusions**: Stopping experiments too early
3. **Feature Factory**: Building without validating assumptions
4. **Learning Hoarding**: Not sharing insights across teams

## Success Metrics

- **Hypothesis Success Rate**: 30-50% validation rate
- **Learning Velocity**: 2-3 validated learnings per team per month
- **Experiment Quality**: >80% experiments with clear success criteria
- **Knowledge Application**: >60% of learnings influence future decisions

## Consequences

**Benefits:**
- Reduced product development risk
- Faster learning and iteration cycles
- Evidence-based decision making
- Improved product-market fit

**Challenges:**
- Cultural shift requirements
- Longer initial development cycles
- Need for analytical capabilities
- Potential for analysis paralysis

**Trade-offs:**
- Speed vs. validation rigor
- Comprehensive testing vs. resource constraints
- Learning depth vs. breadth
