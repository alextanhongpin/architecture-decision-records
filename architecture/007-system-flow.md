# System Flow

## Status

`draft`

## Context

System flow represents the orchestration of business operations within an application. It's essentially the usecase layer, but the term "usecase" usually involves interactions with external actors (users, systems) and doesn't capture the full scope of internal system orchestration.

System flows are responsible for:
- Coordinating multiple domain services
- Managing transaction boundaries
- Orchestrating external service calls
- Implementing business workflows
- Handling cross-cutting concerns like logging, metrics, and error handling

## Decisions

### Flow-Based Architecture

Instead of traditional service-oriented approaches, we organize code around business flows:

```go
type SystemFlow interface {
    Execute(ctx context.Context, input interface{}) (interface{}, error)
}

type OrderProcessingFlow struct {
    inventoryService InventoryService
    paymentService   PaymentService
    shippingService  ShippingService
    eventPublisher   EventPublisher
    logger          Logger
}

func (f *OrderProcessingFlow) Execute(ctx context.Context, input *ProcessOrderInput) (*ProcessOrderOutput, error) {
    // Step 1: Validate input
    if err := f.validateInput(input); err != nil {
        return nil, fmt.Errorf("invalid input: %w", err)
    }
    
    // Step 2: Check inventory
    available, err := f.inventoryService.CheckAvailability(ctx, input.ProductID, input.Quantity)
    if err != nil {
        return nil, fmt.Errorf("inventory check failed: %w", err)
    }
    
    if !available {
        return nil, fmt.Errorf("product not available")
    }
    
    // Step 3: Reserve inventory
    reservation, err := f.inventoryService.Reserve(ctx, input.ProductID, input.Quantity)
    if err != nil {
        return nil, fmt.Errorf("inventory reservation failed: %w", err)
    }
    
    // Step 4: Process payment
    payment, err := f.paymentService.ProcessPayment(ctx, &PaymentRequest{
        Amount:   input.Amount,
        Currency: input.Currency,
        Source:   input.PaymentSource,
    })
    if err != nil {
        // Rollback inventory reservation
        f.inventoryService.ReleaseReservation(ctx, reservation.ID)
        return nil, fmt.Errorf("payment processing failed: %w", err)
    }
    
    // Step 5: Create shipping label
    label, err := f.shippingService.CreateLabel(ctx, &ShippingRequest{
        Address: input.ShippingAddress,
        Items:   input.Items,
    })
    if err != nil {
        // Rollback payment and inventory
        f.paymentService.RefundPayment(ctx, payment.ID)
        f.inventoryService.ReleaseReservation(ctx, reservation.ID)
        return nil, fmt.Errorf("shipping label creation failed: %w", err)
    }
    
    // Step 6: Publish order created event
    event := &OrderCreatedEvent{
        OrderID:       input.OrderID,
        CustomerID:    input.CustomerID,
        PaymentID:     payment.ID,
        ShippingID:    label.ID,
        ReservationID: reservation.ID,
    }
    
    if err := f.eventPublisher.Publish(ctx, event); err != nil {
        f.logger.Error("failed to publish order created event", "error", err)
        // Don't fail the whole flow for event publishing
    }
    
    return &ProcessOrderOutput{
        OrderID:    input.OrderID,
        PaymentID:  payment.ID,
        ShippingID: label.ID,
        Status:     "processed",
    }, nil
}
```

### Flow Composition

Flows can be composed of smaller sub-flows:

```go
type CompositeFlow struct {
    subFlows []SystemFlow
}

func (cf *CompositeFlow) Execute(ctx context.Context, input interface{}) (interface{}, error) {
    var result interface{} = input
    
    for i, flow := range cf.subFlows {
        output, err := flow.Execute(ctx, result)
        if err != nil {
            return nil, fmt.Errorf("sub-flow %d failed: %w", i, err)
        }
        result = output
    }
    
    return result, nil
}

// Example: User registration flow
func NewUserRegistrationFlow(
    validationFlow SystemFlow,
    accountCreationFlow SystemFlow,
    notificationFlow SystemFlow,
) SystemFlow {
    return &CompositeFlow{
        subFlows: []SystemFlow{
            validationFlow,
            accountCreationFlow,
            notificationFlow,
        },
    }
}
```

### Conditional Flows

Handle business logic with conditional execution:

```go
type ConditionalFlow struct {
    condition func(ctx context.Context, input interface{}) bool
    trueFlow  SystemFlow
    falseFlow SystemFlow
}

func (cf *ConditionalFlow) Execute(ctx context.Context, input interface{}) (interface{}, error) {
    if cf.condition(ctx, input) {
        return cf.trueFlow.Execute(ctx, input)
    }
    return cf.falseFlow.Execute(ctx, input)
}

// Example: Premium vs regular user flow
func NewPaymentFlow(
    premiumFlow SystemFlow,
    regularFlow SystemFlow,
) SystemFlow {
    return &ConditionalFlow{
        condition: func(ctx context.Context, input interface{}) bool {
            req := input.(*PaymentRequest)
            return req.User.IsPremium
        },
        trueFlow:  premiumFlow,
        falseFlow: regularFlow,
    }
}
```

### Parallel Flows

Execute independent operations concurrently:

```go
type ParallelFlow struct {
    flows []SystemFlow
}

func (pf *ParallelFlow) Execute(ctx context.Context, input interface{}) (interface{}, error) {
    type result struct {
        output interface{}
        err    error
        index  int
    }
    
    results := make(chan result, len(pf.flows))
    
    // Start all flows concurrently
    for i, flow := range pf.flows {
        go func(idx int, f SystemFlow) {
            output, err := f.Execute(ctx, input)
            results <- result{output: output, err: err, index: idx}
        }(i, flow)
    }
    
    // Collect results
    outputs := make([]interface{}, len(pf.flows))
    for i := 0; i < len(pf.flows); i++ {
        res := <-results
        if res.err != nil {
            return nil, fmt.Errorf("parallel flow %d failed: %w", res.index, res.err)
        }
        outputs[res.index] = res.output
    }
    
    return outputs, nil
}
```

### Error Handling and Compensation

Implement saga pattern for complex flows:

```go
type CompensatableFlow struct {
    steps []CompensatableStep
}

type CompensatableStep struct {
    Execute    func(ctx context.Context, input interface{}) (interface{}, error)
    Compensate func(ctx context.Context, input interface{}) error
}

func (cf *CompensatableFlow) Execute(ctx context.Context, input interface{}) (interface{}, error) {
    var completedSteps []int
    var result interface{} = input
    
    // Execute steps
    for i, step := range cf.steps {
        output, err := step.Execute(ctx, result)
        if err != nil {
            // Compensate completed steps in reverse order
            for j := len(completedSteps) - 1; j >= 0; j-- {
                stepIdx := completedSteps[j]
                if compErr := cf.steps[stepIdx].Compensate(ctx, result); compErr != nil {
                    log.Printf("Compensation failed for step %d: %v", stepIdx, compErr)
                }
            }
            return nil, fmt.Errorf("step %d failed: %w", i, err)
        }
        
        completedSteps = append(completedSteps, i)
        result = output
    }
    
    return result, nil
}
```

### Flow Metrics and Observability

Add monitoring and observability to flows:

```go
type InstrumentedFlow struct {
    name     string
    flow     SystemFlow
    metrics  MetricsCollector
    logger   Logger
}

func (if *InstrumentedFlow) Execute(ctx context.Context, input interface{}) (interface{}, error) {
    start := time.Now()
    flowCtx := context.WithValue(ctx, "flow_name", if.name)
    
    if.logger.Info("flow started", "flow", if.name, "input", input)
    if.metrics.IncrementCounter("flow_started", map[string]string{"flow": if.name})
    
    defer func() {
        duration := time.Since(start)
        if.metrics.RecordDuration("flow_duration", duration, map[string]string{"flow": if.name})
    }()
    
    result, err := if.flow.Execute(flowCtx, input)
    
    if err != nil {
        if.logger.Error("flow failed", "flow", if.name, "error", err)
        if.metrics.IncrementCounter("flow_failed", map[string]string{"flow": if.name})
        return nil, err
    }
    
    if.logger.Info("flow completed", "flow", if.name, "output", result)
    if.metrics.IncrementCounter("flow_completed", map[string]string{"flow": if.name})
    
    return result, nil
}
```

### Flow State Management

For long-running flows that need to persist state:

```go
type StatefulFlow struct {
    stateStore StateStore
    flow       SystemFlow
}

type FlowState struct {
    ID          string                 `json:"id"`
    Name        string                 `json:"name"`
    CurrentStep int                    `json:"current_step"`
    Data        map[string]interface{} `json:"data"`
    Status      FlowStatus             `json:"status"`
    CreatedAt   time.Time              `json:"created_at"`
    UpdatedAt   time.Time              `json:"updated_at"`
}

type FlowStatus string

const (
    FlowStatusRunning   FlowStatus = "running"
    FlowStatusCompleted FlowStatus = "completed"
    FlowStatusFailed    FlowStatus = "failed"
    FlowStatusPaused    FlowStatus = "paused"
)

func (sf *StatefulFlow) Execute(ctx context.Context, input interface{}) (interface{}, error) {
    flowID := generateFlowID()
    
    state := &FlowState{
        ID:          flowID,
        Name:        sf.getName(),
        CurrentStep: 0,
        Data:        make(map[string]interface{}),
        Status:      FlowStatusRunning,
        CreatedAt:   time.Now(),
        UpdatedAt:   time.Now(),
    }
    
    // Save initial state
    if err := sf.stateStore.SaveState(ctx, state); err != nil {
        return nil, fmt.Errorf("failed to save initial state: %w", err)
    }
    
    // Execute with state tracking
    result, err := sf.executeWithState(ctx, input, state)
    
    // Update final state
    if err != nil {
        state.Status = FlowStatusFailed
    } else {
        state.Status = FlowStatusCompleted
    }
    state.UpdatedAt = time.Now()
    
    sf.stateStore.SaveState(ctx, state)
    
    return result, err
}

func (sf *StatefulFlow) ResumeFlow(ctx context.Context, flowID string) (interface{}, error) {
    state, err := sf.stateStore.GetState(ctx, flowID)
    if err != nil {
        return nil, fmt.Errorf("failed to get flow state: %w", err)
    }
    
    if state.Status != FlowStatusPaused {
        return nil, fmt.Errorf("flow is not in paused state: %s", state.Status)
    }
    
    // Resume from current step
    return sf.executeWithState(ctx, state.Data, state)
}
```

### Flow Testing

Structure flows for easy testing:

```go
type FlowTestCase struct {
    Name           string
    Input          interface{}
    ExpectedOutput interface{}
    ExpectedError  string
    Mocks          map[string]interface{}
}

func TestFlow(t *testing.T, flow SystemFlow, testCases []FlowTestCase) {
    for _, tc := range testCases {
        t.Run(tc.Name, func(t *testing.T) {
            ctx := context.Background()
            
            // Setup mocks
            for serviceName, mock := range tc.Mocks {
                setupMock(serviceName, mock)
            }
            
            // Execute flow
            result, err := flow.Execute(ctx, tc.Input)
            
            // Verify results
            if tc.ExpectedError != "" {
                assert.Error(t, err)
                assert.Contains(t, err.Error(), tc.ExpectedError)
            } else {
                assert.NoError(t, err)
                assert.Equal(t, tc.ExpectedOutput, result)
            }
        })
    }
}
```

## Consequences

### Benefits
- **Clear business logic**: Each flow represents a complete business operation
- **Testability**: Flows can be tested independently with mocked dependencies
- **Composability**: Complex flows can be built from simpler ones
- **Observability**: Easy to add monitoring and metrics to flows
- **Error handling**: Centralized error handling and compensation logic

### Challenges
- **Complexity**: Large flows can become complex to understand
- **Performance**: Sequential execution may be slower than optimized approaches
- **State management**: Long-running flows need persistent state
- **Debugging**: Complex flows can be harder to debug

### Best Practices
- Keep individual flows focused on single business operations
- Use composition to build complex flows from simpler ones
- Implement proper error handling and compensation
- Add comprehensive logging and metrics
- Test flows with realistic scenarios
- Use dependency injection for easy mocking
- Document flow diagrams for complex business processes

### Anti-patterns to Avoid
- **God flows**: Flows that try to do too much
- **Tight coupling**: Flows that directly depend on implementation details
- **No error handling**: Flows without proper error handling and rollback
- **Synchronous everything**: Not using parallel execution where appropriate 
