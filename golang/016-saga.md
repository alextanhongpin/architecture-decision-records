# ADR 016: Saga Pattern Implementation

## Status

**Accepted**

## Context

The Saga pattern manages long-running transactions across multiple services or domains by breaking them into a series of compensable steps. Each step can be undone if a subsequent step fails, ensuring data consistency without requiring distributed transactions.

### Problem Statement

In distributed systems, we need to:

- **Maintain consistency** across multiple services without distributed transactions
- **Handle partial failures** gracefully with compensation logic
- **Track transaction progress** through complex workflows
- **Prevent concurrent execution** of the same saga
- **Ensure reliability** with retries and error handling

### Use Cases

- Order processing across inventory, payment, and shipping services
- User onboarding workflows spanning multiple systems
- Financial transactions requiring multiple steps
- Data migration workflows with rollback capabilities

## Decision

We will implement the Saga pattern using:

1. **Orchestrator-based approach** for centralized control
2. **Compensating actions** for rollback logic
3. **Saga state persistence** for reliability
4. **Distributed locking** for concurrency control
5. **Event-driven execution** for loose coupling

## Implementation

### Core Saga Framework

```go
package saga

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "log/slog"
    "time"
)

// SagaStatus represents the current status of a saga
type SagaStatus string

const (
    SagaStatusPending     SagaStatus = "pending"
    SagaStatusRunning     SagaStatus = "running"
    SagaStatusCompleted   SagaStatus = "completed"
    SagaStatusFailed      SagaStatus = "failed"
    SagaStatusCompensating SagaStatus = "compensating"
    SagaStatusCompensated SagaStatus = "compensated"
)

// StepStatus represents the status of a saga step
type StepStatus string

const (
    StepStatusPending     StepStatus = "pending"
    StepStatusRunning     StepStatus = "running"
    StepStatusCompleted   StepStatus = "completed"
    StepStatusFailed      StepStatus = "failed"
    StepStatusCompensating StepStatus = "compensating"
    StepStatusCompensated StepStatus = "compensated"
)

// SagaStep represents a single step in a saga
type SagaStep struct {
    ID            string                 `json:"id"`
    Name          string                 `json:"name"`
    Status        StepStatus             `json:"status"`
    Input         map[string]interface{} `json:"input"`
    Output        map[string]interface{} `json:"output"`
    Error         *string                `json:"error,omitempty"`
    StartedAt     *time.Time             `json:"started_at,omitempty"`
    CompletedAt   *time.Time             `json:"completed_at,omitempty"`
    CompensatedAt *time.Time             `json:"compensated_at,omitempty"`
    RetryCount    int                    `json:"retry_count"`
    MaxRetries    int                    `json:"max_retries"`
}

// SagaInstance represents a saga execution instance
type SagaInstance struct {
    ID          string                 `json:"id"`
    Type        string                 `json:"type"`
    Status      SagaStatus             `json:"status"`
    Steps       []SagaStep             `json:"steps"`
    Context     map[string]interface{} `json:"context"`
    CreatedAt   time.Time              `json:"created_at"`
    UpdatedAt   time.Time              `json:"updated_at"`
    CompletedAt *time.Time             `json:"completed_at,omitempty"`
    Version     int64                  `json:"version"`
}

// StepHandler defines the interface for saga step execution
type StepHandler interface {
    Execute(ctx context.Context, input map[string]interface{}) (map[string]interface{}, error)
    Compensate(ctx context.Context, input, output map[string]interface{}) error
}

// SagaDefinition defines a saga workflow
type SagaDefinition struct {
    Type     string                    `json:"type"`
    Steps    []StepDefinition          `json:"steps"`
    Handlers map[string]StepHandler    `json:"-"`
}

// StepDefinition defines a single step in a saga
type StepDefinition struct {
    ID         string `json:"id"`
    Name       string `json:"name"`
    Handler    string `json:"handler"`
    MaxRetries int    `json:"max_retries"`
    Timeout    time.Duration `json:"timeout"`
}

// SagaOrchestrator manages saga execution
type SagaOrchestrator struct {
    store       SagaStore
    lockService LockService
    eventBus    EventBus
    logger      *slog.Logger
    definitions map[string]*SagaDefinition
}

// SagaStore defines persistence interface for sagas
type SagaStore interface {
    Save(ctx context.Context, saga *SagaInstance) error
    GetByID(ctx context.Context, sagaID string) (*SagaInstance, error)
    UpdateStep(ctx context.Context, sagaID string, stepID string, step SagaStep) error
    UpdateStatus(ctx context.Context, sagaID string, status SagaStatus, version int64) error
    GetPendingSagas(ctx context.Context, limit int) ([]*SagaInstance, error)
}

// NewSagaOrchestrator creates a new saga orchestrator
func NewSagaOrchestrator(
    store SagaStore,
    lockService LockService,
    eventBus EventBus,
    logger *slog.Logger,
) *SagaOrchestrator {
    return &SagaOrchestrator{
        store:       store,
        lockService: lockService,
        eventBus:    eventBus,
        logger:      logger,
        definitions: make(map[string]*SagaDefinition),
    }
}

// RegisterSaga registers a saga definition
func (o *SagaOrchestrator) RegisterSaga(definition *SagaDefinition) {
    o.definitions[definition.Type] = definition
}

// StartSaga starts a new saga instance
func (o *SagaOrchestrator) StartSaga(
    ctx context.Context,
    sagaType string,
    sagaContext map[string]interface{},
) (*SagaInstance, error) {
    definition, exists := o.definitions[sagaType]
    if !exists {
        return nil, fmt.Errorf("saga definition not found: %s", sagaType)
    }
    
    // Create saga instance
    saga := &SagaInstance{
        ID:        generateSagaID(),
        Type:      sagaType,
        Status:    SagaStatusPending,
        Context:   sagaContext,
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
        Version:   1,
    }
    
    // Initialize steps
    for _, stepDef := range definition.Steps {
        step := SagaStep{
            ID:         stepDef.ID,
            Name:       stepDef.Name,
            Status:     StepStatusPending,
            MaxRetries: stepDef.MaxRetries,
        }
        saga.Steps = append(saga.Steps, step)
    }
    
    // Save to store
    if err := o.store.Save(ctx, saga); err != nil {
        return nil, fmt.Errorf("saving saga: %w", err)
    }
    
    // Publish saga started event
    o.eventBus.Publish(ctx, SagaStartedEvent{
        SagaID:    saga.ID,
        SagaType:  saga.Type,
        Context:   saga.Context,
        Timestamp: saga.CreatedAt,
    })
    
    o.logger.InfoContext(ctx, "saga started", 
        "saga_id", saga.ID, 
        "saga_type", saga.Type)
    
    return saga, nil
}

// ExecuteSaga executes a saga from its current state
func (o *SagaOrchestrator) ExecuteSaga(ctx context.Context, sagaID string) error {
    // Acquire distributed lock
    lockKey := fmt.Sprintf("saga:%s", sagaID)
    unlock, err := o.lockService.AcquireLock(ctx, lockKey, 5*time.Minute)
    if err != nil {
        return fmt.Errorf("acquiring saga lock: %w", err)
    }
    defer unlock()
    
    // Load saga
    saga, err := o.store.GetByID(ctx, sagaID)
    if err != nil {
        return fmt.Errorf("loading saga: %w", err)
    }
    
    // Get saga definition
    definition, exists := o.definitions[saga.Type]
    if !exists {
        return fmt.Errorf("saga definition not found: %s", saga.Type)
    }
    
    // Execute based on current status
    switch saga.Status {
    case SagaStatusPending, SagaStatusRunning:
        return o.executeForward(ctx, saga, definition)
    case SagaStatusFailed:
        return o.executeCompensation(ctx, saga, definition)
    case SagaStatusCompensating:
        return o.continueCompensation(ctx, saga, definition)
    default:
        o.logger.InfoContext(ctx, "saga already completed", 
            "saga_id", sagaID, 
            "status", saga.Status)
        return nil
    }
}

// executeForward executes saga steps forward
func (o *SagaOrchestrator) executeForward(
    ctx context.Context,
    saga *SagaInstance,
    definition *SagaDefinition,
) error {
    saga.Status = SagaStatusRunning
    o.store.UpdateStatus(ctx, saga.ID, saga.Status, saga.Version)
    
    for i := range saga.Steps {
        step := &saga.Steps[i]
        
        if step.Status == StepStatusCompleted {
            continue // Skip already completed steps
        }
        
        if step.Status == StepStatusFailed {
            // Start compensation
            return o.startCompensation(ctx, saga, definition)
        }
        
        // Execute the step
        if err := o.executeStep(ctx, saga, step, definition); err != nil {
            o.logger.ErrorContext(ctx, "step execution failed",
                "saga_id", saga.ID,
                "step_id", step.ID,
                "error", err)
            
            // Mark step as failed
            step.Status = StepStatusFailed
            errMsg := err.Error()
            step.Error = &errMsg
            o.store.UpdateStep(ctx, saga.ID, step.ID, *step)
            
            // Start compensation
            return o.startCompensation(ctx, saga, definition)
        }
    }
    
    // All steps completed successfully
    saga.Status = SagaStatusCompleted
    now := time.Now()
    saga.CompletedAt = &now
    saga.UpdatedAt = now
    
    if err := o.store.UpdateStatus(ctx, saga.ID, saga.Status, saga.Version); err != nil {
        return fmt.Errorf("updating saga completion status: %w", err)
    }
    
    // Publish completion event
    o.eventBus.Publish(ctx, SagaCompletedEvent{
        SagaID:    saga.ID,
        SagaType:  saga.Type,
        Timestamp: now,
    })
    
    o.logger.InfoContext(ctx, "saga completed successfully", 
        "saga_id", saga.ID)
    
    return nil
}

// executeStep executes a single saga step
func (o *SagaOrchestrator) executeStep(
    ctx context.Context,
    saga *SagaInstance,
    step *SagaStep,
    definition *SagaDefinition,
) error {
    // Find step definition
    var stepDef *StepDefinition
    for _, def := range definition.Steps {
        if def.ID == step.ID {
            stepDef = &def
            break
        }
    }
    
    if stepDef == nil {
        return fmt.Errorf("step definition not found: %s", step.ID)
    }
    
    // Get handler
    handler, exists := definition.Handlers[stepDef.Handler]
    if !exists {
        return fmt.Errorf("step handler not found: %s", stepDef.Handler)
    }
    
    // Mark step as running
    step.Status = StepStatusRunning
    now := time.Now()
    step.StartedAt = &now
    step.RetryCount++
    
    if err := o.store.UpdateStep(ctx, saga.ID, step.ID, *step); err != nil {
        return fmt.Errorf("updating step status: %w", err)
    }
    
    // Create step context with timeout
    stepCtx := ctx
    if stepDef.Timeout > 0 {
        var cancel context.CancelFunc
        stepCtx, cancel = context.WithTimeout(ctx, stepDef.Timeout)
        defer cancel()
    }
    
    // Prepare input (merge saga context with step input)
    input := make(map[string]interface{})
    for k, v := range saga.Context {
        input[k] = v
    }
    for k, v := range step.Input {
        input[k] = v
    }
    
    // Execute the step
    output, err := handler.Execute(stepCtx, input)
    
    // Update step with result
    now = time.Now()
    step.CompletedAt = &now
    
    if err != nil {
        step.Status = StepStatusFailed
        errMsg := err.Error()
        step.Error = &errMsg
        
        // Check if we should retry
        if step.RetryCount <= step.MaxRetries {
            step.Status = StepStatusPending
            o.logger.WarnContext(ctx, "step failed, will retry",
                "saga_id", saga.ID,
                "step_id", step.ID,
                "retry_count", step.RetryCount,
                "max_retries", step.MaxRetries,
                "error", err)
        }
    } else {
        step.Status = StepStatusCompleted
        step.Output = output
        
        // Merge output into saga context
        for k, v := range output {
            saga.Context[k] = v
        }
    }
    
    return o.store.UpdateStep(ctx, saga.ID, step.ID, *step)
}

// startCompensation begins the compensation process
func (o *SagaOrchestrator) startCompensation(
    ctx context.Context,
    saga *SagaInstance,
    definition *SagaDefinition,
) error {
    saga.Status = SagaStatusCompensating
    saga.UpdatedAt = time.Now()
    
    if err := o.store.UpdateStatus(ctx, saga.ID, saga.Status, saga.Version); err != nil {
        return fmt.Errorf("updating saga to compensating status: %w", err)
    }
    
    o.logger.InfoContext(ctx, "starting saga compensation", 
        "saga_id", saga.ID)
    
    return o.executeCompensation(ctx, saga, definition)
}

// executeCompensation executes compensation for completed steps
func (o *SagaOrchestrator) executeCompensation(
    ctx context.Context,
    saga *SagaInstance,
    definition *SagaDefinition,
) error {
    // Compensate steps in reverse order
    for i := len(saga.Steps) - 1; i >= 0; i-- {
        step := &saga.Steps[i]
        
        // Only compensate completed steps
        if step.Status != StepStatusCompleted {
            continue
        }
        
        if err := o.compensateStep(ctx, saga, step, definition); err != nil {
            o.logger.ErrorContext(ctx, "step compensation failed",
                "saga_id", saga.ID,
                "step_id", step.ID,
                "error", err)
            
            // Mark step compensation as failed
            step.Status = StepStatusFailed
            errMsg := err.Error()
            step.Error = &errMsg
            o.store.UpdateStep(ctx, saga.ID, step.ID, *step)
            
            // Continue with other compensations
            continue
        }
    }
    
    // Mark saga as compensated
    saga.Status = SagaStatusCompensated
    now := time.Now()
    saga.CompletedAt = &now
    saga.UpdatedAt = now
    
    if err := o.store.UpdateStatus(ctx, saga.ID, saga.Status, saga.Version); err != nil {
        return fmt.Errorf("updating saga compensation status: %w", err)
    }
    
    // Publish compensation event
    o.eventBus.Publish(ctx, SagaCompensatedEvent{
        SagaID:    saga.ID,
        SagaType:  saga.Type,
        Timestamp: now,
    })
    
    o.logger.InfoContext(ctx, "saga compensation completed", 
        "saga_id", saga.ID)
    
    return nil
}

// compensateStep compensates a single step
func (o *SagaOrchestrator) compensateStep(
    ctx context.Context,
    saga *SagaInstance,
    step *SagaStep,
    definition *SagaDefinition,
) error {
    // Find step definition
    var stepDef *StepDefinition
    for _, def := range definition.Steps {
        if def.ID == step.ID {
            stepDef = &def
            break
        }
    }
    
    if stepDef == nil {
        return fmt.Errorf("step definition not found: %s", step.ID)
    }
    
    // Get handler
    handler, exists := definition.Handlers[stepDef.Handler]
    if !exists {
        return fmt.Errorf("step handler not found: %s", stepDef.Handler)
    }
    
    // Mark step as compensating
    step.Status = StepStatusCompensating
    if err := o.store.UpdateStep(ctx, saga.ID, step.ID, *step); err != nil {
        return fmt.Errorf("updating step compensation status: %w", err)
    }
    
    // Create compensation context with timeout
    stepCtx := ctx
    if stepDef.Timeout > 0 {
        var cancel context.CancelFunc
        stepCtx, cancel = context.WithTimeout(ctx, stepDef.Timeout)
        defer cancel()
    }
    
    // Execute compensation
    err := handler.Compensate(stepCtx, step.Input, step.Output)
    
    // Update step status
    now := time.Now()
    step.CompensatedAt = &now
    
    if err != nil {
        step.Status = StepStatusFailed
        errMsg := err.Error()
        step.Error = &errMsg
    } else {
        step.Status = StepStatusCompensated
    }
    
    return o.store.UpdateStep(ctx, saga.ID, step.ID, *step)
}
```

### Order Processing Saga Example

```go
package order

import (
    "context"
    "fmt"
)

// OrderSaga defines the order processing saga
type OrderSaga struct {
    orchestrator *SagaOrchestrator
}

// NewOrderSaga creates a new order processing saga
func NewOrderSaga(orchestrator *SagaOrchestrator) *OrderSaga {
    saga := &OrderSaga{orchestrator: orchestrator}
    saga.registerDefinition()
    return saga
}

// registerDefinition registers the order saga definition
func (s *OrderSaga) registerDefinition() {
    definition := &SagaDefinition{
        Type: "order_processing",
        Steps: []StepDefinition{
            {
                ID:         "validate_order",
                Name:       "Validate Order",
                Handler:    "validate_order",
                MaxRetries: 2,
                Timeout:    30 * time.Second,
            },
            {
                ID:         "reserve_inventory",
                Name:       "Reserve Inventory",
                Handler:    "reserve_inventory",
                MaxRetries: 3,
                Timeout:    60 * time.Second,
            },
            {
                ID:         "process_payment",
                Name:       "Process Payment",
                Handler:    "process_payment",
                MaxRetries: 3,
                Timeout:    120 * time.Second,
            },
            {
                ID:         "create_shipment",
                Name:       "Create Shipment",
                Handler:    "create_shipment",
                MaxRetries: 2,
                Timeout:    60 * time.Second,
            },
            {
                ID:         "send_confirmation",
                Name:       "Send Confirmation",
                Handler:    "send_confirmation",
                MaxRetries: 5,
                Timeout:    30 * time.Second,
            },
        },
        Handlers: map[string]StepHandler{
            "validate_order":    &ValidateOrderHandler{},
            "reserve_inventory": &ReserveInventoryHandler{},
            "process_payment":   &ProcessPaymentHandler{},
            "create_shipment":   &CreateShipmentHandler{},
            "send_confirmation": &SendConfirmationHandler{},
        },
    }
    
    s.orchestrator.RegisterSaga(definition)
}

// ProcessOrder starts the order processing saga
func (s *OrderSaga) ProcessOrder(ctx context.Context, orderID string) (*SagaInstance, error) {
    sagaContext := map[string]interface{}{
        "order_id": orderID,
    }
    
    return s.orchestrator.StartSaga(ctx, "order_processing", sagaContext)
}

// ValidateOrderHandler validates the order
type ValidateOrderHandler struct {
    orderService OrderService
}

func (h *ValidateOrderHandler) Execute(ctx context.Context, input map[string]interface{}) (map[string]interface{}, error) {
    orderID, ok := input["order_id"].(string)
    if !ok {
        return nil, errors.New("order_id is required")
    }
    
    order, err := h.orderService.GetOrder(ctx, orderID)
    if err != nil {
        return nil, fmt.Errorf("getting order: %w", err)
    }
    
    if err := h.orderService.ValidateOrder(ctx, order); err != nil {
        return nil, fmt.Errorf("validating order: %w", err)
    }
    
    return map[string]interface{}{
        "order":        order,
        "customer_id":  order.CustomerID,
        "total_amount": order.TotalAmount,
        "items":        order.Items,
    }, nil
}

func (h *ValidateOrderHandler) Compensate(ctx context.Context, input, output map[string]interface{}) error {
    // Order validation doesn't need compensation
    return nil
}

// ReserveInventoryHandler reserves inventory for the order
type ReserveInventoryHandler struct {
    inventoryService InventoryService
}

func (h *ReserveInventoryHandler) Execute(ctx context.Context, input map[string]interface{}) (map[string]interface{}, error) {
    orderID, _ := input["order_id"].(string)
    items, _ := input["items"].([]OrderItem)
    
    reservationID, err := h.inventoryService.ReserveItems(ctx, orderID, items)
    if err != nil {
        return nil, fmt.Errorf("reserving inventory: %w", err)
    }
    
    return map[string]interface{}{
        "reservation_id": reservationID,
    }, nil
}

func (h *ReserveInventoryHandler) Compensate(ctx context.Context, input, output map[string]interface{}) error {
    reservationID, ok := output["reservation_id"].(string)
    if !ok {
        return nil // No reservation to cancel
    }
    
    return h.inventoryService.CancelReservation(ctx, reservationID)
}

// ProcessPaymentHandler processes the payment
type ProcessPaymentHandler struct {
    paymentService PaymentService
}

func (h *ProcessPaymentHandler) Execute(ctx context.Context, input map[string]interface{}) (map[string]interface{}, error) {
    orderID, _ := input["order_id"].(string)
    customerID, _ := input["customer_id"].(string)
    totalAmount, _ := input["total_amount"].(int64)
    
    paymentID, err := h.paymentService.ProcessPayment(ctx, PaymentRequest{
        OrderID:    orderID,
        CustomerID: customerID,
        Amount:     totalAmount,
    })
    if err != nil {
        return nil, fmt.Errorf("processing payment: %w", err)
    }
    
    return map[string]interface{}{
        "payment_id": paymentID,
    }, nil
}

func (h *ProcessPaymentHandler) Compensate(ctx context.Context, input, output map[string]interface{}) error {
    paymentID, ok := output["payment_id"].(string)
    if !ok {
        return nil // No payment to refund
    }
    
    return h.paymentService.RefundPayment(ctx, paymentID)
}

// CreateShipmentHandler creates a shipment
type CreateShipmentHandler struct {
    shippingService ShippingService
}

func (h *CreateShipmentHandler) Execute(ctx context.Context, input map[string]interface{}) (map[string]interface{}, error) {
    orderID, _ := input["order_id"].(string)
    
    shipmentID, err := h.shippingService.CreateShipment(ctx, orderID)
    if err != nil {
        return nil, fmt.Errorf("creating shipment: %w", err)
    }
    
    return map[string]interface{}{
        "shipment_id": shipmentID,
    }, nil
}

func (h *CreateShipmentHandler) Compensate(ctx context.Context, input, output map[string]interface{}) error {
    shipmentID, ok := output["shipment_id"].(string)
    if !ok {
        return nil // No shipment to cancel
    }
    
    return h.shippingService.CancelShipment(ctx, shipmentID)
}

// SendConfirmationHandler sends order confirmation
type SendConfirmationHandler struct {
    notificationService NotificationService
}

func (h *SendConfirmationHandler) Execute(ctx context.Context, input map[string]interface{}) (map[string]interface{}, error) {
    orderID, _ := input["order_id"].(string)
    customerID, _ := input["customer_id"].(string)
    
    notificationID, err := h.notificationService.SendOrderConfirmation(ctx, customerID, orderID)
    if err != nil {
        return nil, fmt.Errorf("sending confirmation: %w", err)
    }
    
    return map[string]interface{}{
        "notification_id": notificationID,
    }, nil
}

func (h *SendConfirmationHandler) Compensate(ctx context.Context, input, output map[string]interface{}) error {
    // Notification compensation might involve sending a cancellation notice
    orderID, _ := input["order_id"].(string)
    customerID, _ := input["customer_id"].(string)
    
    _, err := h.notificationService.SendOrderCancellation(ctx, customerID, orderID)
    return err
}
```

### PostgreSQL Storage Implementation

```go
package postgres

import (
    "context"
    "database/sql"
    "encoding/json"
    "time"
    
    "github.com/lib/pq"
)

const createSagaTable = `
CREATE TABLE IF NOT EXISTS sagas (
    id UUID PRIMARY KEY,
    type VARCHAR(255) NOT NULL,
    status VARCHAR(50) NOT NULL,
    steps JSONB NOT NULL,
    context JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL,
    completed_at TIMESTAMP WITH TIME ZONE,
    version BIGINT NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_sagas_status ON sagas(status);
CREATE INDEX IF NOT EXISTS idx_sagas_type ON sagas(type);
CREATE INDEX IF NOT EXISTS idx_sagas_created_at ON sagas(created_at);
`

// PostgresSagaStore implements SagaStore using PostgreSQL
type PostgresSagaStore struct {
    db *sql.DB
}

// NewPostgresSagaStore creates a new PostgreSQL saga store
func NewPostgresSagaStore(db *sql.DB) (*PostgresSagaStore, error) {
    if _, err := db.Exec(createSagaTable); err != nil {
        return nil, fmt.Errorf("creating saga table: %w", err)
    }
    
    return &PostgresSagaStore{db: db}, nil
}

// Save saves a saga instance
func (s *PostgresSagaStore) Save(ctx context.Context, saga *SagaInstance) error {
    stepsJSON, err := json.Marshal(saga.Steps)
    if err != nil {
        return fmt.Errorf("marshaling steps: %w", err)
    }
    
    contextJSON, err := json.Marshal(saga.Context)
    if err != nil {
        return fmt.Errorf("marshaling context: %w", err)
    }
    
    query := `
        INSERT INTO sagas (id, type, status, steps, context, created_at, updated_at, version)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    `
    
    _, err = s.db.ExecContext(ctx, query,
        saga.ID, saga.Type, saga.Status, stepsJSON, contextJSON,
        saga.CreatedAt, saga.UpdatedAt, saga.Version,
    )
    
    if err != nil {
        return fmt.Errorf("inserting saga: %w", err)
    }
    
    return nil
}

// GetByID retrieves a saga by ID
func (s *PostgresSagaStore) GetByID(ctx context.Context, sagaID string) (*SagaInstance, error) {
    query := `
        SELECT id, type, status, steps, context, created_at, updated_at, completed_at, version
        FROM sagas 
        WHERE id = $1
    `
    
    var saga SagaInstance
    var stepsJSON, contextJSON []byte
    var completedAt sql.NullTime
    
    err := s.db.QueryRowContext(ctx, query, sagaID).Scan(
        &saga.ID, &saga.Type, &saga.Status, &stepsJSON, &contextJSON,
        &saga.CreatedAt, &saga.UpdatedAt, &completedAt, &saga.Version,
    )
    
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, fmt.Errorf("saga not found: %s", sagaID)
        }
        return nil, fmt.Errorf("scanning saga: %w", err)
    }
    
    if err := json.Unmarshal(stepsJSON, &saga.Steps); err != nil {
        return nil, fmt.Errorf("unmarshaling steps: %w", err)
    }
    
    if err := json.Unmarshal(contextJSON, &saga.Context); err != nil {
        return nil, fmt.Errorf("unmarshaling context: %w", err)
    }
    
    if completedAt.Valid {
        saga.CompletedAt = &completedAt.Time
    }
    
    return &saga, nil
}

// UpdateStep updates a specific step in a saga
func (s *PostgresSagaStore) UpdateStep(ctx context.Context, sagaID string, stepID string, step SagaStep) error {
    // First, get the current saga
    saga, err := s.GetByID(ctx, sagaID)
    if err != nil {
        return err
    }
    
    // Update the specific step
    for i, existingStep := range saga.Steps {
        if existingStep.ID == stepID {
            saga.Steps[i] = step
            break
        }
    }
    
    // Marshal updated steps
    stepsJSON, err := json.Marshal(saga.Steps)
    if err != nil {
        return fmt.Errorf("marshaling steps: %w", err)
    }
    
    // Update with optimistic locking
    query := `
        UPDATE sagas 
        SET steps = $2, updated_at = $3, version = version + 1
        WHERE id = $1 AND version = $4
    `
    
    result, err := s.db.ExecContext(ctx, query, sagaID, stepsJSON, time.Now(), saga.Version)
    if err != nil {
        return fmt.Errorf("updating saga step: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return fmt.Errorf("checking rows affected: %w", err)
    }
    
    if rowsAffected == 0 {
        return errors.New("saga version conflict or not found")
    }
    
    return nil
}

// UpdateStatus updates the saga status
func (s *PostgresSagaStore) UpdateStatus(ctx context.Context, sagaID string, status SagaStatus, version int64) error {
    var query string
    var args []interface{}
    
    if status == SagaStatusCompleted || status == SagaStatusCompensated {
        query = `
            UPDATE sagas 
            SET status = $2, updated_at = $3, completed_at = $3, version = version + 1
            WHERE id = $1 AND version = $4
        `
        args = []interface{}{sagaID, status, time.Now(), version}
    } else {
        query = `
            UPDATE sagas 
            SET status = $2, updated_at = $3, version = version + 1
            WHERE id = $1 AND version = $4
        `
        args = []interface{}{sagaID, status, time.Now(), version}
    }
    
    result, err := s.db.ExecContext(ctx, query, args...)
    if err != nil {
        return fmt.Errorf("updating saga status: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return fmt.Errorf("checking rows affected: %w", err)
    }
    
    if rowsAffected == 0 {
        return errors.New("saga version conflict or not found")
    }
    
    return nil
}

// GetPendingSagas retrieves pending sagas for processing
func (s *PostgresSagaStore) GetPendingSagas(ctx context.Context, limit int) ([]*SagaInstance, error) {
    query := `
        SELECT id, type, status, steps, context, created_at, updated_at, completed_at, version
        FROM sagas 
        WHERE status IN ('pending', 'running', 'compensating')
        ORDER BY created_at ASC
        LIMIT $1
        FOR UPDATE SKIP LOCKED
    `
    
    rows, err := s.db.QueryContext(ctx, query, limit)
    if err != nil {
        return nil, fmt.Errorf("querying pending sagas: %w", err)
    }
    defer rows.Close()
    
    var sagas []*SagaInstance
    
    for rows.Next() {
        var saga SagaInstance
        var stepsJSON, contextJSON []byte
        var completedAt sql.NullTime
        
        err := rows.Scan(
            &saga.ID, &saga.Type, &saga.Status, &stepsJSON, &contextJSON,
            &saga.CreatedAt, &saga.UpdatedAt, &completedAt, &saga.Version,
        )
        if err != nil {
            return nil, fmt.Errorf("scanning saga: %w", err)
        }
        
        if err := json.Unmarshal(stepsJSON, &saga.Steps); err != nil {
            return nil, fmt.Errorf("unmarshaling steps: %w", err)
        }
        
        if err := json.Unmarshal(contextJSON, &saga.Context); err != nil {
            return nil, fmt.Errorf("unmarshaling context: %w", err)
        }
        
        if completedAt.Valid {
            saga.CompletedAt = &completedAt.Time
        }
        
        sagas = append(sagas, &saga)
    }
    
    return sagas, nil
}
```

## Testing

```go
func TestSagaOrchestrator_OrderProcessing(t *testing.T) {
    // Setup test dependencies
    store := &MockSagaStore{}
    lockService := &MockLockService{}
    eventBus := &MockEventBus{}
    logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
    
    orchestrator := NewSagaOrchestrator(store, lockService, eventBus, logger)
    
    // Register test saga
    definition := &SagaDefinition{
        Type: "test_order",
        Steps: []StepDefinition{
            {ID: "step1", Name: "Step 1", Handler: "step1", MaxRetries: 2},
            {ID: "step2", Name: "Step 2", Handler: "step2", MaxRetries: 2},
        },
        Handlers: map[string]StepHandler{
            "step1": &MockStepHandler{shouldSucceed: true},
            "step2": &MockStepHandler{shouldSucceed: true},
        },
    }
    orchestrator.RegisterSaga(definition)
    
    // Test successful saga execution
    t.Run("successful execution", func(t *testing.T) {
        store.Reset()
        lockService.Reset()
        
        ctx := context.Background()
        
        // Start saga
        saga, err := orchestrator.StartSaga(ctx, "test_order", map[string]interface{}{
            "order_id": "order-123",
        })
        
        require.NoError(t, err)
        assert.Equal(t, SagaStatusPending, saga.Status)
        assert.Len(t, saga.Steps, 2)
        
        // Execute saga
        err = orchestrator.ExecuteSaga(ctx, saga.ID)
        require.NoError(t, err)
        
        // Verify saga completed
        updatedSaga, err := store.GetByID(ctx, saga.ID)
        require.NoError(t, err)
        assert.Equal(t, SagaStatusCompleted, updatedSaga.Status)
        
        // Verify all steps completed
        for _, step := range updatedSaga.Steps {
            assert.Equal(t, StepStatusCompleted, step.Status)
        }
    })
    
    // Test saga compensation
    t.Run("compensation on failure", func(t *testing.T) {
        store.Reset()
        lockService.Reset()
        
        // Set up handlers where step2 fails
        definition.Handlers["step2"] = &MockStepHandler{shouldSucceed: false}
        
        ctx := context.Background()
        
        saga, err := orchestrator.StartSaga(ctx, "test_order", map[string]interface{}{
            "order_id": "order-456",
        })
        require.NoError(t, err)
        
        // Execute saga (should fail and compensate)
        err = orchestrator.ExecuteSaga(ctx, saga.ID)
        require.NoError(t, err)
        
        // Verify saga was compensated
        updatedSaga, err := store.GetByID(ctx, saga.ID)
        require.NoError(t, err)
        assert.Equal(t, SagaStatusCompensated, updatedSaga.Status)
        
        // Verify step1 was compensated, step2 failed
        assert.Equal(t, StepStatusCompensated, updatedSaga.Steps[0].Status)
        assert.Equal(t, StepStatusFailed, updatedSaga.Steps[1].Status)
    })
}

// MockStepHandler for testing
type MockStepHandler struct {
    shouldSucceed bool
    executeCount  int
    compensateCount int
}

func (h *MockStepHandler) Execute(ctx context.Context, input map[string]interface{}) (map[string]interface{}, error) {
    h.executeCount++
    if !h.shouldSucceed {
        return nil, errors.New("step failed")
    }
    return map[string]interface{}{"result": "success"}, nil
}

func (h *MockStepHandler) Compensate(ctx context.Context, input, output map[string]interface{}) error {
    h.compensateCount++
    return nil
}
```

## Best Practices

### Do

- ✅ Design idempotent step handlers
- ✅ Implement proper compensation logic for each step
- ✅ Use distributed locks to prevent concurrent execution
- ✅ Store saga state persistently with versioning
- ✅ Implement timeouts for each step
- ✅ Add comprehensive logging and monitoring
- ✅ Design for retries with exponential backoff

### Don't

- ❌ Create steps that cannot be compensated
- ❌ Make steps dependent on external state changes
- ❌ Skip error handling in compensation logic
- ❌ Create circular dependencies between sagas
- ❌ Ignore saga execution timeouts

## Consequences

### Positive

- **Data Consistency**: Maintains consistency across services without distributed transactions
- **Fault Tolerance**: Handles partial failures gracefully with compensation
- **Visibility**: Complete audit trail of transaction progress
- **Scalability**: Supports long-running transactions across services
- **Flexibility**: Easy to modify workflows by changing step definitions

### Negative

- **Complexity**: Additional infrastructure for saga management
- **Performance**: Overhead from persistence and coordination
- **Debugging**: Complex failure scenarios across multiple steps
- **Compensation Logic**: Requires careful design of rollback operations

## References

- [Saga Pattern](https://microservices.io/patterns/data/saga.html)
- [Orchestration vs Choreography](https://stackoverflow.com/questions/4127241/orchestration-vs-choreography)
- [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)
- [Distributed Transactions](https://docs.microsoft.com/en-us/azure/architecture/patterns/saga)
