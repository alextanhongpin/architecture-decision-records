# ADR 013: State Machine Implementation

## Status

**Accepted**

## Context

State machines provide a structured approach to managing state transitions in complex business workflows. They help prevent invalid state transitions, ensure data consistency, and provide clear audit trails for business processes.

### Problem Statement

In distributed systems, we often encounter:

- **Non-linear execution paths**: Multiple API calls required to complete workflows
- **Concurrent state modifications**: Multiple processes attempting to modify the same entity
- **Invalid state transitions**: Business rules violations during state changes
- **Audit requirements**: Need to track state change history
- **Compensation logic**: Ability to reverse or compensate failed operations

### Use Cases

- Order processing workflows (pending → processing → shipped → delivered)
- Payment processing (initiated → processing → completed/failed)
- User onboarding flows (registration → verification → activation)
- Document approval workflows (draft → review → approved/rejected)

## Decision

We will implement finite state machines using:

1. **Type-safe status enums** with validation
2. **Transition validation** with business rules
3. **Distributed locking** for concurrent safety
4. **Event sourcing** for audit trails
5. **Compensation patterns** for rollbacks

## Implementation

### Basic State Machine Pattern

```go
package statemachine

import (
    "context"
    "errors"
    "fmt"
    "time"
)

// State represents a state in the state machine
type State string

// Transition represents a state transition
type Transition struct {
    From   State
    To     State
    Action string
}

// StateMachine defines the state machine interface
type StateMachine[T State] interface {
    CurrentState() T
    CanTransition(to T) bool
    Transition(ctx context.Context, to T, action string) error
    ValidTransitions() []T
}

// TransitionError represents a state transition error
type TransitionError struct {
    From   State
    To     State
    Reason string
}

func (e TransitionError) Error() string {
    return fmt.Sprintf("invalid transition from %s to %s: %s", 
        e.From, e.To, e.Reason)
}

// StateMachineConfig defines the state machine configuration
type StateMachineConfig[T State] struct {
    InitialState T
    Transitions  map[T][]T
    Validators   map[Transition]func(context.Context) error
    Actions      map[Transition]func(context.Context) error
}
```

### Order State Machine Example

```go
package order

import (
    "context"
    "database/sql"
    "errors"
    "fmt"
    "time"
)

// OrderStatus represents the order status
type OrderStatus string

const (
    OrderStatusPending    OrderStatus = "pending"
    OrderStatusProcessing OrderStatus = "processing"
    OrderStatusShipped    OrderStatus = "shipped"
    OrderStatusDelivered  OrderStatus = "delivered"
    OrderStatusCancelled  OrderStatus = "cancelled"
    OrderStatusRefunded   OrderStatus = "refunded"
)

// Order represents an order entity
type Order struct {
    ID          string      `json:"id"`
    CustomerID  string      `json:"customer_id"`
    Status      OrderStatus `json:"status"`
    TotalAmount int64       `json:"total_amount"`
    CreatedAt   time.Time   `json:"created_at"`
    UpdatedAt   time.Time   `json:"updated_at"`
    Version     int64       `json:"version"`
}

// OrderStateMachine manages order state transitions
type OrderStateMachine struct {
    order      *Order
    repository OrderRepository
    lockSvc    LockService
    eventBus   EventBus
    
    // Valid transitions map
    transitions map[OrderStatus][]OrderStatus
}

// NewOrderStateMachine creates a new order state machine
func NewOrderStateMachine(
    order *Order,
    repo OrderRepository,
    lockSvc LockService,
    eventBus EventBus,
) *OrderStateMachine {
    return &OrderStateMachine{
        order:      order,
        repository: repo,
        lockSvc:    lockSvc,
        eventBus:   eventBus,
        transitions: map[OrderStatus][]OrderStatus{
            OrderStatusPending: {
                OrderStatusProcessing,
                OrderStatusCancelled,
            },
            OrderStatusProcessing: {
                OrderStatusShipped,
                OrderStatusCancelled,
            },
            OrderStatusShipped: {
                OrderStatusDelivered,
                OrderStatusRefunded, // If return initiated
            },
            OrderStatusDelivered: {
                OrderStatusRefunded,
            },
            // Terminal states
            OrderStatusCancelled: {},
            OrderStatusRefunded:  {},
        },
    }
}

// CurrentState returns the current order status
func (sm *OrderStateMachine) CurrentState() OrderStatus {
    return sm.order.Status
}

// CanTransition checks if transition is valid
func (sm *OrderStateMachine) CanTransition(to OrderStatus) bool {
    validStates, exists := sm.transitions[sm.order.Status]
    if !exists {
        return false
    }
    
    for _, state := range validStates {
        if state == to {
            return true
        }
    }
    return false
}

// Transition performs a state transition with validation
func (sm *OrderStateMachine) Transition(
    ctx context.Context, 
    to OrderStatus, 
    reason string,
) error {
    // Acquire distributed lock
    lockKey := fmt.Sprintf("order:%s", sm.order.ID)
    unlock, err := sm.lockSvc.AcquireLock(ctx, lockKey, 30*time.Second)
    if err != nil {
        return fmt.Errorf("acquiring lock: %w", err)
    }
    defer unlock()
    
    // Refresh order state
    current, err := sm.repository.GetByID(ctx, sm.order.ID)
    if err != nil {
        return fmt.Errorf("refreshing order state: %w", err)
    }
    sm.order = current
    
    // Validate transition
    if !sm.CanTransition(to) {
        return TransitionError{
            From:   State(sm.order.Status),
            To:     State(to),
            Reason: "transition not allowed",
        }
    }
    
    // Validate business rules
    if err := sm.validateTransition(ctx, to); err != nil {
        return fmt.Errorf("validation failed: %w", err)
    }
    
    // Execute pre-transition actions
    if err := sm.executePreActions(ctx, to); err != nil {
        return fmt.Errorf("pre-action failed: %w", err)
    }
    
    // Perform the transition
    from := sm.order.Status
    sm.order.Status = to
    sm.order.UpdatedAt = time.Now()
    sm.order.Version++
    
    // Persist with optimistic locking
    if err := sm.repository.UpdateWithVersion(ctx, sm.order); err != nil {
        if errors.Is(err, ErrVersionConflict) {
            return errors.New("concurrent modification detected")
        }
        return fmt.Errorf("persisting state transition: %w", err)
    }
    
    // Execute post-transition actions
    if err := sm.executePostActions(ctx, from, to); err != nil {
        // Log error but don't fail the transition
        // Post-actions should be idempotent and retryable
        sm.eventBus.Publish(ctx, OrderPostActionFailed{
            OrderID:   sm.order.ID,
            FromState: from,
            ToState:   to,
            Error:     err,
        })
    }
    
    // Publish state change event
    sm.eventBus.Publish(ctx, OrderStateChanged{
        OrderID:   sm.order.ID,
        FromState: from,
        ToState:   to,
        Reason:    reason,
        Timestamp: time.Now(),
    })
    
    return nil
}

// validateTransition validates business rules for transitions
func (sm *OrderStateMachine) validateTransition(
    ctx context.Context, 
    to OrderStatus,
) error {
    switch to {
    case OrderStatusProcessing:
        return sm.validateProcessing(ctx)
    case OrderStatusShipped:
        return sm.validateShipping(ctx)
    case OrderStatusCancelled:
        return sm.validateCancellation(ctx)
    case OrderStatusRefunded:
        return sm.validateRefund(ctx)
    }
    return nil
}

func (sm *OrderStateMachine) validateProcessing(ctx context.Context) error {
    // Check inventory availability
    items, err := sm.repository.GetOrderItems(ctx, sm.order.ID)
    if err != nil {
        return fmt.Errorf("getting order items: %w", err)
    }
    
    for _, item := range items {
        available, err := sm.repository.CheckInventory(ctx, item.ProductID, item.Quantity)
        if err != nil {
            return fmt.Errorf("checking inventory: %w", err)
        }
        if !available {
            return errors.New("insufficient inventory")
        }
    }
    
    return nil
}

func (sm *OrderStateMachine) validateShipping(ctx context.Context) error {
    // Check payment status
    payment, err := sm.repository.GetPayment(ctx, sm.order.ID)
    if err != nil {
        return fmt.Errorf("getting payment: %w", err)
    }
    
    if payment.Status != "completed" {
        return errors.New("payment not completed")
    }
    
    return nil
}
```

### Workflow State Machine Pattern

```go
package workflow

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
)

// Step represents a workflow step
type Step struct {
    ID          string                 `json:"id"`
    Name        string                 `json:"name"`
    Status      StepStatus             `json:"status"`
    Input       map[string]interface{} `json:"input"`
    Output      map[string]interface{} `json:"output"`
    Error       *string                `json:"error,omitempty"`
    StartedAt   *time.Time             `json:"started_at,omitempty"`
    CompletedAt *time.Time             `json:"completed_at,omitempty"`
    RetryCount  int                    `json:"retry_count"`
    MaxRetries  int                    `json:"max_retries"`
}

// StepStatus represents the status of a workflow step
type StepStatus string

const (
    StepStatusNotStarted StepStatus = "not_started"
    StepStatusPending    StepStatus = "pending"
    StepStatusCompleted  StepStatus = "completed"
    StepStatusFailed     StepStatus = "failed"
    StepStatusSkipped    StepStatus = "skipped"
)

// WorkflowStatus represents the overall workflow status
type WorkflowStatus string

const (
    WorkflowStatusNotStarted WorkflowStatus = "not_started"
    WorkflowStatusRunning    WorkflowStatus = "running"
    WorkflowStatusCompleted  WorkflowStatus = "completed"
    WorkflowStatusFailed     WorkflowStatus = "failed"
    WorkflowStatusCancelled  WorkflowStatus = "cancelled"
)

// Workflow represents a workflow instance
type Workflow struct {
    ID        string                 `json:"id"`
    Name      string                 `json:"name"`
    Status    WorkflowStatus         `json:"status"`
    Steps     []Step                 `json:"steps"`
    Context   map[string]interface{} `json:"context"`
    CreatedAt time.Time              `json:"created_at"`
    UpdatedAt time.Time              `json:"updated_at"`
}

// WorkflowEngine manages workflow execution
type WorkflowEngine struct {
    repository WorkflowRepository
    stepRunner StepRunner
    lockSvc    LockService
}

// ExecuteStep executes a specific workflow step
func (we *WorkflowEngine) ExecuteStep(
    ctx context.Context, 
    workflowID, stepID string,
) error {
    lockKey := fmt.Sprintf("workflow:%s:step:%s", workflowID, stepID)
    unlock, err := we.lockSvc.AcquireLock(ctx, lockKey, 5*time.Minute)
    if err != nil {
        return fmt.Errorf("acquiring step lock: %w", err)
    }
    defer unlock()
    
    workflow, err := we.repository.GetByID(ctx, workflowID)
    if err != nil {
        return fmt.Errorf("getting workflow: %w", err)
    }
    
    stepIndex := we.findStepIndex(workflow, stepID)
    if stepIndex == -1 {
        return errors.New("step not found")
    }
    
    step := &workflow.Steps[stepIndex]
    
    // Validate step can be executed
    if err := we.validateStepExecution(workflow, stepIndex); err != nil {
        return fmt.Errorf("validation failed: %w", err)
    }
    
    // Execute the step
    if err := we.executeStep(ctx, workflow, step); err != nil {
        step.Status = StepStatusFailed
        step.Error = &err.Error()
        step.RetryCount++
        
        // Check if we should retry
        if step.RetryCount <= step.MaxRetries {
            // Schedule retry (implementation depends on your job queue)
            we.scheduleRetry(ctx, workflowID, stepID, time.Minute*time.Duration(step.RetryCount))
        }
    } else {
        step.Status = StepStatusCompleted
        step.CompletedAt = &time.Time{}
        *step.CompletedAt = time.Now()
    }
    
    // Update workflow status
    we.updateWorkflowStatus(workflow)
    
    // Persist changes
    if err := we.repository.Update(ctx, workflow); err != nil {
        return fmt.Errorf("updating workflow: %w", err)
    }
    
    // Trigger next step if applicable
    if step.Status == StepStatusCompleted {
        if err := we.triggerNextStep(ctx, workflow, stepIndex); err != nil {
            // Log but don't fail
            fmt.Printf("Failed to trigger next step: %v\n", err)
        }
    }
    
    return nil
}

// validateStepExecution validates if a step can be executed
func (we *WorkflowEngine) validateStepExecution(
    workflow *Workflow, 
    stepIndex int,
) error {
    step := &workflow.Steps[stepIndex]
    
    // Check if step is already completed
    if step.Status == StepStatusCompleted {
        return errors.New("step already completed")
    }
    
    // Check if workflow is in valid state
    if workflow.Status == WorkflowStatusCompleted ||
       workflow.Status == WorkflowStatusCancelled ||
       workflow.Status == WorkflowStatusFailed {
        return errors.New("workflow not in executable state")
    }
    
    // Check if previous steps are completed (sequential execution)
    for i := 0; i < stepIndex; i++ {
        prevStep := &workflow.Steps[i]
        if prevStep.Status != StepStatusCompleted && 
           prevStep.Status != StepStatusSkipped {
            return fmt.Errorf("previous step %s not completed", prevStep.ID)
        }
    }
    
    return nil
}
```

### Bitwise Step Tracking

```go
package tracking

// StepTracker uses bitwise operations for efficient step tracking
type StepTracker struct {
    completed uint64
    failed    uint64
}

const (
    Step1 uint64 = 1 << iota
    Step2
    Step3
    Step4
    Step5
    // ... up to 64 steps
)

// MarkCompleted marks a step as completed
func (st *StepTracker) MarkCompleted(step uint64) {
    st.completed |= step
    st.failed &^= step // Clear failed bit
}

// MarkFailed marks a step as failed
func (st *StepTracker) MarkFailed(step uint64) {
    st.failed |= step
    st.completed &^= step // Clear completed bit
}

// IsCompleted checks if a step is completed
func (st *StepTracker) IsCompleted(step uint64) bool {
    return st.completed&step == step
}

// IsFailed checks if a step is failed
func (st *StepTracker) IsFailed(step uint64) bool {
    return st.failed&step == step
}

// AllCompleted checks if all specified steps are completed
func (st *StepTracker) AllCompleted(steps uint64) bool {
    return st.completed&steps == steps
}

// AnyFailed checks if any specified steps have failed
func (st *StepTracker) AnyFailed(steps uint64) bool {
    return st.failed&steps != 0
}

// CompletedCount returns the number of completed steps
func (st *StepTracker) CompletedCount() int {
    return popCount(st.completed)
}

// popCount counts the number of set bits
func popCount(x uint64) int {
    count := 0
    for x != 0 {
        count++
        x &= x - 1 // Clear the lowest set bit
    }
    return count
}

// Example usage in order processing
type OrderProcessor struct {
    tracker StepTracker
}

const (
    StepValidatePayment uint64 = 1 << iota
    StepReserveInventory
    StepProcessPayment
    StepCreateShipment
    StepSendConfirmation
)

func (op *OrderProcessor) ProcessOrder(ctx context.Context, orderID string) error {
    allSteps := StepValidatePayment | StepReserveInventory | 
                StepProcessPayment | StepCreateShipment | StepSendConfirmation
    
    // Validate payment
    if err := op.validatePayment(ctx, orderID); err != nil {
        op.tracker.MarkFailed(StepValidatePayment)
        return err
    }
    op.tracker.MarkCompleted(StepValidatePayment)
    
    // Reserve inventory
    if err := op.reserveInventory(ctx, orderID); err != nil {
        op.tracker.MarkFailed(StepReserveInventory)
        return err
    }
    op.tracker.MarkCompleted(StepReserveInventory)
    
    // Continue with other steps...
    
    // Check if all steps completed
    if op.tracker.AllCompleted(allSteps) {
        // Order processing complete
        return nil
    }
    
    return errors.New("order processing incomplete")
}
```

## Testing

```go
func TestOrderStateMachine_Transition(t *testing.T) {
    tests := []struct {
        name          string
        currentStatus OrderStatus
        targetStatus  OrderStatus
        shouldSucceed bool
        expectedError string
    }{
        {
            name:          "valid transition pending to processing",
            currentStatus: OrderStatusPending,
            targetStatus:  OrderStatusProcessing,
            shouldSucceed: true,
        },
        {
            name:          "invalid transition pending to delivered",
            currentStatus: OrderStatusPending,
            targetStatus:  OrderStatusDelivered,
            shouldSucceed: false,
            expectedError: "transition not allowed",
        },
        {
            name:          "invalid transition from terminal state",
            currentStatus: OrderStatusCancelled,
            targetStatus:  OrderStatusProcessing,
            shouldSucceed: false,
            expectedError: "transition not allowed",
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            order := &Order{
                ID:     "test-order",
                Status: tt.currentStatus,
            }
            
            mockRepo := &MockOrderRepository{}
            mockLock := &MockLockService{}
            mockEvent := &MockEventBus{}
            
            sm := NewOrderStateMachine(order, mockRepo, mockLock, mockEvent)
            
            err := sm.Transition(context.Background(), tt.targetStatus, "test transition")
            
            if tt.shouldSucceed {
                assert.NoError(t, err)
                assert.Equal(t, tt.targetStatus, order.Status)
            } else {
                assert.Error(t, err)
                assert.Contains(t, err.Error(), tt.expectedError)
            }
        })
    }
}

func TestStepTracker_BitOperations(t *testing.T) {
    tracker := StepTracker{}
    
    // Mark steps as completed
    tracker.MarkCompleted(Step1 | Step3)
    
    assert.True(t, tracker.IsCompleted(Step1))
    assert.False(t, tracker.IsCompleted(Step2))
    assert.True(t, tracker.IsCompleted(Step3))
    
    // Check completion count
    assert.Equal(t, 2, tracker.CompletedCount())
    
    // Mark step as failed
    tracker.MarkFailed(Step2)
    assert.True(t, tracker.IsFailed(Step2))
    assert.False(t, tracker.IsCompleted(Step2))
}
```

## Best Practices

### Do

- ✅ Use type-safe enums for states
- ✅ Implement distributed locking for concurrent safety
- ✅ Validate transitions before execution
- ✅ Use optimistic locking for data consistency
- ✅ Publish events for state changes
- ✅ Implement compensation for rollbacks
- ✅ Design idempotent state transitions

### Don't

- ❌ Allow direct state modification without validation
- ❌ Skip locking in concurrent environments
- ❌ Create circular state dependencies
- ❌ Ignore error handling in transitions
- ❌ Make state transitions non-idempotent

## Consequences

### Positive

- **Data Consistency**: Prevents invalid state transitions
- **Audit Trail**: Complete history of state changes
- **Concurrent Safety**: Handles multiple processes safely
- **Business Rules**: Enforces domain constraints
- **Debuggability**: Clear state transition logs

### Negative

- **Complexity**: Additional code for state management
- **Performance**: Locking overhead for each transition
- **Storage**: Additional tables for audit trails

## References

- [Finite State Machine](https://en.wikipedia.org/wiki/Finite-state_machine)
- [Saga Pattern](https://microservices.io/patterns/data/saga.html)
- [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)
- [Optimistic Locking](https://en.wikipedia.org/wiki/Optimistic_concurrency_control)


