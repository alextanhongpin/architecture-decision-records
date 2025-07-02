# ADR 021: Status Management Patterns

## Status

**Accepted**

## Context

Status management is crucial for tracking entity states, workflow progression, and business process validation. We need robust patterns for defining, validating, and transitioning between different states while maintaining data consistency and business rule enforcement.

### Problem Statement

Applications often struggle with:

- **Inconsistent status definitions**: Different formats across entities
- **State validation**: Ensuring valid transitions and business rules
- **Derived states**: Computing status from multiple fields
- **Audit requirements**: Tracking status changes over time
- **Complex workflows**: Multi-step processes with conditional paths

## Decision

We will implement status management using:

1. **Typed status enums** with validation
2. **Computed status patterns** for derived states
3. **Status transition validation** with business rules
4. **Audit trails** for status changes
5. **Conditional status logic** for complex workflows

## Implementation

### Basic Status Enum Pattern

```go
package status

import (
    "database/sql/driver"
    "fmt"
    "strings"
)

// Status represents a generic status type
type Status string

// StatusValidator defines validation interface for status types
type StatusValidator interface {
    Valid() bool
    ValidTransitions() []Status
    CanTransitionTo(target Status) bool
}

// String returns the string representation
func (s Status) String() string {
    return string(s)
}

// Value implements driver.Valuer for database storage
func (s Status) Value() (driver.Value, error) {
    return string(s), nil
}

// Scan implements sql.Scanner for database retrieval
func (s *Status) Scan(value interface{}) error {
    switch v := value.(type) {
    case string:
        *s = Status(v)
    case []byte:
        *s = Status(v)
    case nil:
        *s = ""
    default:
        return fmt.Errorf("unsupported type: %T", value)
    }
    return nil
}

// MarshalJSON implements json.Marshaler
func (s Status) MarshalJSON() ([]byte, error) {
    return []byte(fmt.Sprintf(`"%s"`, s)), nil
}

// UnmarshalJSON implements json.Unmarshaler
func (s *Status) UnmarshalJSON(data []byte) error {
    str := strings.Trim(string(data), `"`)
    *s = Status(str)
    return nil
}
```

### Order Status Implementation

```go
package order

import (
    "context"
    "errors"
    "fmt"
    "time"
)

// OrderStatus represents the state of an order
type OrderStatus string

const (
    OrderStatusDraft      OrderStatus = "draft"
    OrderStatusPending    OrderStatus = "pending"
    OrderStatusConfirmed  OrderStatus = "confirmed"
    OrderStatusProcessing OrderStatus = "processing"
    OrderStatusShipped    OrderStatus = "shipped"
    OrderStatusDelivered  OrderStatus = "delivered"
    OrderStatusCancelled  OrderStatus = "cancelled"
    OrderStatusRefunded   OrderStatus = "refunded"
    OrderStatusReturned   OrderStatus = "returned"
)

// Valid checks if the status is a valid order status
func (s OrderStatus) Valid() bool {
    switch s {
    case OrderStatusDraft, OrderStatusPending, OrderStatusConfirmed,
         OrderStatusProcessing, OrderStatusShipped, OrderStatusDelivered,
         OrderStatusCancelled, OrderStatusRefunded, OrderStatusReturned:
        return true
    default:
        return false
    }
}

// ValidTransitions returns valid transitions from current status
func (s OrderStatus) ValidTransitions() []OrderStatus {
    transitionMap := map[OrderStatus][]OrderStatus{
        OrderStatusDraft: {
            OrderStatusPending,
            OrderStatusCancelled,
        },
        OrderStatusPending: {
            OrderStatusConfirmed,
            OrderStatusCancelled,
        },
        OrderStatusConfirmed: {
            OrderStatusProcessing,
            OrderStatusCancelled,
        },
        OrderStatusProcessing: {
            OrderStatusShipped,
            OrderStatusCancelled,
        },
        OrderStatusShipped: {
            OrderStatusDelivered,
            OrderStatusReturned,
        },
        OrderStatusDelivered: {
            OrderStatusRefunded,
            OrderStatusReturned,
        },
        // Terminal states
        OrderStatusCancelled: {},
        OrderStatusRefunded:  {},
        OrderStatusReturned:  {},
    }
    
    return transitionMap[s]
}

// CanTransitionTo checks if transition to target status is valid
func (s OrderStatus) CanTransitionTo(target OrderStatus) bool {
    validTransitions := s.ValidTransitions()
    for _, valid := range validTransitions {
        if valid == target {
            return true
        }
    }
    return false
}

// IsTerminal checks if the status is a terminal state
func (s OrderStatus) IsTerminal() bool {
    return len(s.ValidTransitions()) == 0
}

// IsPending checks if the status indicates a pending state
func (s OrderStatus) IsPending() bool {
    return s == OrderStatusDraft || s == OrderStatusPending
}

// IsActive checks if the order is in an active processing state
func (s OrderStatus) IsActive() bool {
    switch s {
    case OrderStatusConfirmed, OrderStatusProcessing, OrderStatusShipped:
        return true
    default:
        return false
    }
}

// IsCompleted checks if the order has been completed successfully
func (s OrderStatus) IsCompleted() bool {
    return s == OrderStatusDelivered
}

// IsCancellable checks if the order can be cancelled
func (s OrderStatus) IsCancellable() bool {
    return s.CanTransitionTo(OrderStatusCancelled)
}
```

### Computed Status Pattern

```go
package fulfillment

import (
    "time"
)

// FulfillmentStatus represents computed fulfillment status
type FulfillmentStatus string

const (
    FulfillmentStatusPending    FulfillmentStatus = "pending"
    FulfillmentStatusPicked     FulfillmentStatus = "picked"
    FulfillmentStatusShipped    FulfillmentStatus = "shipped"
    FulfillmentStatusInTransit  FulfillmentStatus = "in_transit"
    FulfillmentStatusDelivered  FulfillmentStatus = "delivered"
    FulfillmentStatusFailed     FulfillmentStatus = "failed"
)

// Shipment represents shipment information
type Shipment struct {
    Courier     string     `json:"courier"`
    TrackingID  string     `json:"tracking_id"`
    ShippedAt   time.Time  `json:"shipped_at"`
    DeliveredAt *time.Time `json:"delivered_at,omitempty"`
}

// Fulfillment represents order fulfillment with computed status
type Fulfillment struct {
    ID            string      `json:"id"`
    OrderID       string      `json:"order_id"`
    AirwayBill    *string     `json:"airway_bill,omitempty"`
    Shipment      *Shipment   `json:"shipment,omitempty"`
    PickedAt      *time.Time  `json:"picked_at,omitempty"`
    FailedAt      *time.Time  `json:"failed_at,omitempty"`
    FailureReason *string     `json:"failure_reason,omitempty"`
    CreatedAt     time.Time   `json:"created_at"`
    UpdatedAt     time.Time   `json:"updated_at"`
}

// Status computes the current fulfillment status
func (f *Fulfillment) Status() FulfillmentStatus {
    // Failed state takes precedence
    if f.FailedAt != nil {
        return FulfillmentStatusFailed
    }
    
    // Check delivery
    if f.Shipment != nil && f.Shipment.DeliveredAt != nil {
        return FulfillmentStatusDelivered
    }
    
    // Check shipping and tracking
    if f.Shipment != nil {
        if f.Shipment.TrackingID != "" {
            return FulfillmentStatusInTransit
        }
        return FulfillmentStatusShipped
    }
    
    // Check if items are picked
    if f.PickedAt != nil {
        return FulfillmentStatusPicked
    }
    
    // Default to pending
    return FulfillmentStatusPending
}

// CanPick checks if fulfillment can be picked
func (f *Fulfillment) CanPick() bool {
    return f.Status() == FulfillmentStatusPending
}

// CanShip checks if fulfillment can be shipped
func (f *Fulfillment) CanShip() bool {
    return f.Status() == FulfillmentStatusPicked
}

// CanMarkDelivered checks if fulfillment can be marked as delivered
func (f *Fulfillment) CanMarkDelivered() bool {
    status := f.Status()
    return status == FulfillmentStatusShipped || status == FulfillmentStatusInTransit
}

// Pick marks the fulfillment as picked
func (f *Fulfillment) Pick() error {
    if !f.CanPick() {
        return fmt.Errorf("cannot pick fulfillment in %s status", f.Status())
    }
    
    now := time.Now()
    f.PickedAt = &now
    f.UpdatedAt = now
    
    return nil
}

// Ship marks the fulfillment as shipped
func (f *Fulfillment) Ship(courier, trackingID string) error {
    if !f.CanShip() {
        return fmt.Errorf("cannot ship fulfillment in %s status", f.Status())
    }
    
    now := time.Now()
    f.Shipment = &Shipment{
        Courier:    courier,
        TrackingID: trackingID,
        ShippedAt:  now,
    }
    f.UpdatedAt = now
    
    return nil
}

// MarkDelivered marks the fulfillment as delivered
func (f *Fulfillment) MarkDelivered() error {
    if !f.CanMarkDelivered() {
        return fmt.Errorf("cannot mark delivered fulfillment in %s status", f.Status())
    }
    
    if f.Shipment == nil {
        return errors.New("shipment information required for delivery")
    }
    
    now := time.Now()
    f.Shipment.DeliveredAt = &now
    f.UpdatedAt = now
    
    return nil
}

// MarkFailed marks the fulfillment as failed
func (f *Fulfillment) MarkFailed(reason string) error {
    if f.Status() == FulfillmentStatusDelivered {
        return errors.New("cannot mark delivered fulfillment as failed")
    }
    
    now := time.Now()
    f.FailedAt = &now
    f.FailureReason = &reason
    f.UpdatedAt = now
    
    return nil
}
```

### Status Transition Audit

```go
package audit

import (
    "context"
    "encoding/json"
    "time"
)

// StatusTransition represents a status change audit record
type StatusTransition struct {
    ID          string                 `json:"id" db:"id"`
    EntityType  string                 `json:"entity_type" db:"entity_type"`
    EntityID    string                 `json:"entity_id" db:"entity_id"`
    FromStatus  string                 `json:"from_status" db:"from_status"`
    ToStatus    string                 `json:"to_status" db:"to_status"`
    Reason      *string                `json:"reason,omitempty" db:"reason"`
    Metadata    map[string]interface{} `json:"metadata,omitempty" db:"metadata"`
    Actor       string                 `json:"actor" db:"actor"`
    ActorType   string                 `json:"actor_type" db:"actor_type"`
    Timestamp   time.Time              `json:"timestamp" db:"timestamp"`
}

// StatusAuditor handles status transition auditing
type StatusAuditor struct {
    store AuditStore
}

// AuditStore defines the storage interface for audit records
type AuditStore interface {
    Save(ctx context.Context, transition *StatusTransition) error
    GetHistory(ctx context.Context, entityType, entityID string) ([]*StatusTransition, error)
    GetByTimeRange(ctx context.Context, entityType string, start, end time.Time) ([]*StatusTransition, error)
}

// NewStatusAuditor creates a new status auditor
func NewStatusAuditor(store AuditStore) *StatusAuditor {
    return &StatusAuditor{store: store}
}

// RecordTransition records a status transition
func (sa *StatusAuditor) RecordTransition(
    ctx context.Context,
    entityType, entityID string,
    fromStatus, toStatus Status,
    actor, actorType string,
    reason *string,
    metadata map[string]interface{},
) error {
    transition := &StatusTransition{
        ID:         generateID(),
        EntityType: entityType,
        EntityID:   entityID,
        FromStatus: fromStatus.String(),
        ToStatus:   toStatus.String(),
        Reason:     reason,
        Metadata:   metadata,
        Actor:      actor,
        ActorType:  actorType,
        Timestamp:  time.Now(),
    }
    
    return sa.store.Save(ctx, transition)
}

// GetEntityHistory returns the status history for an entity
func (sa *StatusAuditor) GetEntityHistory(
    ctx context.Context,
    entityType, entityID string,
) ([]*StatusTransition, error) {
    return sa.store.GetHistory(ctx, entityType, entityID)
}
```

### Payment Status with Retry Logic

```go
package payment

import (
    "context"
    "time"
)

// PaymentStatus represents payment processing status
type PaymentStatus string

const (
    PaymentStatusPending    PaymentStatus = "pending"
    PaymentStatusProcessing PaymentStatus = "processing"
    PaymentStatusCompleted  PaymentStatus = "completed"
    PaymentStatusFailed     PaymentStatus = "failed"
    PaymentStatusRefunded   PaymentStatus = "refunded"
    PaymentStatusCancelled  PaymentStatus = "cancelled"
)

// PaymentAttempt represents a payment processing attempt
type PaymentAttempt struct {
    ID           string                 `json:"id"`
    AttemptedAt  time.Time              `json:"attempted_at"`
    CompletedAt  *time.Time             `json:"completed_at,omitempty"`
    Status       PaymentStatus          `json:"status"`
    ErrorCode    *string                `json:"error_code,omitempty"`
    ErrorMessage *string                `json:"error_message,omitempty"`
    Metadata     map[string]interface{} `json:"metadata,omitempty"`
}

// Payment represents a payment with retry capabilities
type Payment struct {
    ID            string           `json:"id"`
    Amount        int64            `json:"amount"`
    Currency      string           `json:"currency"`
    Status        PaymentStatus    `json:"status"`
    Attempts      []PaymentAttempt `json:"attempts"`
    MaxRetries    int              `json:"max_retries"`
    RetryDelay    time.Duration    `json:"retry_delay"`
    NextRetryAt   *time.Time       `json:"next_retry_at,omitempty"`
    CreatedAt     time.Time        `json:"created_at"`
    UpdatedAt     time.Time        `json:"updated_at"`
}

// CanRetry checks if payment can be retried
func (p *Payment) CanRetry() bool {
    if p.Status != PaymentStatusFailed {
        return false
    }
    
    // Check retry count
    failedAttempts := 0
    for _, attempt := range p.Attempts {
        if attempt.Status == PaymentStatusFailed {
            failedAttempts++
        }
    }
    
    return failedAttempts < p.MaxRetries
}

// ShouldRetry checks if payment should be retried now
func (p *Payment) ShouldRetry() bool {
    if !p.CanRetry() {
        return false
    }
    
    if p.NextRetryAt == nil {
        return true
    }
    
    return time.Now().After(*p.NextRetryAt)
}

// LastAttempt returns the most recent payment attempt
func (p *Payment) LastAttempt() *PaymentAttempt {
    if len(p.Attempts) == 0 {
        return nil
    }
    return &p.Attempts[len(p.Attempts)-1]
}

// AddAttempt adds a new payment attempt
func (p *Payment) AddAttempt(attempt PaymentAttempt) {
    p.Attempts = append(p.Attempts, attempt)
    p.Status = attempt.Status
    p.UpdatedAt = time.Now()
    
    // Schedule next retry if failed and retries available
    if attempt.Status == PaymentStatusFailed && p.CanRetry() {
        nextRetry := time.Now().Add(p.calculateRetryDelay())
        p.NextRetryAt = &nextRetry
    } else {
        p.NextRetryAt = nil
    }
}

// calculateRetryDelay calculates the delay for the next retry
func (p *Payment) calculateRetryDelay() time.Duration {
    failedAttempts := 0
    for _, attempt := range p.Attempts {
        if attempt.Status == PaymentStatusFailed {
            failedAttempts++
        }
    }
    
    // Exponential backoff: base delay * 2^(failed attempts)
    multiplier := 1 << uint(failedAttempts)
    return p.RetryDelay * time.Duration(multiplier)
}

// Process attempts to process the payment
func (p *Payment) Process(ctx context.Context, processor PaymentProcessor) error {
    if p.Status == PaymentStatusCompleted {
        return errors.New("payment already completed")
    }
    
    if p.Status == PaymentStatusProcessing {
        return errors.New("payment already processing")
    }
    
    // Create new attempt
    attempt := PaymentAttempt{
        ID:          generateID(),
        AttemptedAt: time.Now(),
        Status:      PaymentStatusProcessing,
    }
    
    p.AddAttempt(attempt)
    
    // Process payment
    result, err := processor.Process(ctx, p)
    
    // Update attempt with result
    attempt = p.Attempts[len(p.Attempts)-1] // Get the latest attempt
    now := time.Now()
    attempt.CompletedAt = &now
    
    if err != nil {
        attempt.Status = PaymentStatusFailed
        errMsg := err.Error()
        attempt.ErrorMessage = &errMsg
        
        // Extract error code if available
        if codedErr, ok := err.(CodedError); ok {
            code := codedErr.Code()
            attempt.ErrorCode = &code
        }
    } else {
        attempt.Status = PaymentStatusCompleted
        attempt.Metadata = result.Metadata
    }
    
    // Update the attempt in the slice
    p.Attempts[len(p.Attempts)-1] = attempt
    p.Status = attempt.Status
    p.UpdatedAt = time.Now()
    
    return err
}

// CodedError interface for errors with codes
type CodedError interface {
    error
    Code() string
}

// PaymentProcessor interface for processing payments
type PaymentProcessor interface {
    Process(ctx context.Context, payment *Payment) (*ProcessResult, error)
}

// ProcessResult represents the result of payment processing
type ProcessResult struct {
    TransactionID string                 `json:"transaction_id"`
    Metadata      map[string]interface{} `json:"metadata"`
}
```

## Testing

```go
func TestOrderStatus_ValidTransitions(t *testing.T) {
    tests := []struct {
        name           string
        currentStatus  OrderStatus
        targetStatus   OrderStatus
        shouldBeValid  bool
    }{
        {
            name:           "draft to pending",
            currentStatus:  OrderStatusDraft,
            targetStatus:   OrderStatusPending,
            shouldBeValid:  true,
        },
        {
            name:           "draft to shipped (invalid)",
            currentStatus:  OrderStatusDraft,
            targetStatus:   OrderStatusShipped,
            shouldBeValid:  false,
        },
        {
            name:           "delivered to refunded",
            currentStatus:  OrderStatusDelivered,
            targetStatus:   OrderStatusRefunded,
            shouldBeValid:  true,
        },
        {
            name:           "cancelled to processing (invalid)",
            currentStatus:  OrderStatusCancelled,
            targetStatus:   OrderStatusProcessing,
            shouldBeValid:  false,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            result := tt.currentStatus.CanTransitionTo(tt.targetStatus)
            assert.Equal(t, tt.shouldBeValid, result)
        })
    }
}

func TestFulfillment_ComputedStatus(t *testing.T) {
    tests := []struct {
        name               string
        fulfillment        *Fulfillment
        expectedStatus     FulfillmentStatus
        canPick            bool
        canShip            bool
        canMarkDelivered   bool
    }{
        {
            name:           "new fulfillment",
            fulfillment:    &Fulfillment{},
            expectedStatus: FulfillmentStatusPending,
            canPick:        true,
            canShip:        false,
            canMarkDelivered: false,
        },
        {
            name: "picked fulfillment",
            fulfillment: &Fulfillment{
                PickedAt: timePtr(time.Now()),
            },
            expectedStatus: FulfillmentStatusPicked,
            canPick:        false,
            canShip:        true,
            canMarkDelivered: false,
        },
        {
            name: "shipped fulfillment",
            fulfillment: &Fulfillment{
                PickedAt: timePtr(time.Now()),
                Shipment: &Shipment{
                    Courier:   "DHL",
                    ShippedAt: time.Now(),
                },
            },
            expectedStatus: FulfillmentStatusShipped,
            canPick:        false,
            canShip:        false,
            canMarkDelivered: true,
        },
        {
            name: "delivered fulfillment",
            fulfillment: &Fulfillment{
                PickedAt: timePtr(time.Now()),
                Shipment: &Shipment{
                    Courier:     "DHL",
                    ShippedAt:   time.Now(),
                    DeliveredAt: timePtr(time.Now()),
                },
            },
            expectedStatus: FulfillmentStatusDelivered,
            canPick:        false,
            canShip:        false,
            canMarkDelivered: false,
        },
        {
            name: "failed fulfillment",
            fulfillment: &Fulfillment{
                FailedAt: timePtr(time.Now()),
            },
            expectedStatus: FulfillmentStatusFailed,
            canPick:        false,
            canShip:        false,
            canMarkDelivered: false,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            assert.Equal(t, tt.expectedStatus, tt.fulfillment.Status())
            assert.Equal(t, tt.canPick, tt.fulfillment.CanPick())
            assert.Equal(t, tt.canShip, tt.fulfillment.CanShip())
            assert.Equal(t, tt.canMarkDelivered, tt.fulfillment.CanMarkDelivered())
        })
    }
}

func TestPayment_RetryLogic(t *testing.T) {
    payment := &Payment{
        ID:         "payment-123",
        Amount:     1000,
        Currency:   "USD",
        Status:     PaymentStatusPending,
        MaxRetries: 3,
        RetryDelay: time.Minute,
    }
    
    // First attempt fails
    payment.AddAttempt(PaymentAttempt{
        ID:           "attempt-1",
        AttemptedAt:  time.Now(),
        Status:       PaymentStatusFailed,
        ErrorMessage: stringPtr("insufficient funds"),
    })
    
    assert.Equal(t, PaymentStatusFailed, payment.Status)
    assert.True(t, payment.CanRetry())
    assert.NotNil(t, payment.NextRetryAt)
    
    // Second attempt fails
    payment.AddAttempt(PaymentAttempt{
        ID:           "attempt-2",
        AttemptedAt:  time.Now(),
        Status:       PaymentStatusFailed,
        ErrorMessage: stringPtr("network error"),
    })
    
    assert.True(t, payment.CanRetry())
    
    // Third attempt fails (max retries reached)
    payment.AddAttempt(PaymentAttempt{
        ID:           "attempt-3",
        AttemptedAt:  time.Now(),
        Status:       PaymentStatusFailed,
        ErrorMessage: stringPtr("service unavailable"),
    })
    
    assert.False(t, payment.CanRetry())
    assert.Nil(t, payment.NextRetryAt)
}

func timePtr(t time.Time) *time.Time {
    return &t
}

func stringPtr(s string) *string {
    return &s
}
```

## Best Practices

### Do

- ✅ Use typed enums for status definitions
- ✅ Implement validation for status transitions
- ✅ Provide helper methods for status queries
- ✅ Use computed status for derived states
- ✅ Implement audit trails for status changes
- ✅ Design terminal states properly
- ✅ Handle retry logic for transient failures

### Don't

- ❌ Use strings directly for status values
- ❌ Allow invalid status transitions
- ❌ Store computed status in database
- ❌ Skip status validation in business logic
- ❌ Create overly complex status hierarchies

## Consequences

### Positive

- **Type Safety**: Compile-time validation of status values
- **Business Rules**: Enforced status transition logic
- **Audit Trail**: Complete history of status changes
- **Flexibility**: Support for both fixed and computed status
- **Maintainability**: Clear status management patterns

### Negative

- **Complexity**: Additional code for status management
- **Performance**: Computation overhead for derived status
- **Storage**: Additional audit tables required

## References

- [Finite State Machine](https://en.wikipedia.org/wiki/Finite-state_machine)
- [State Pattern](https://refactoring.guru/design-patterns/state)
- [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)
}

func (f *Fulfillment) isReady() bool {
	return f.airwayBill != nil && f.shipment == nil && f.deliveredAt == nil
}

func (f *Fulfillment) isShipped() bool {
	return f.airwayBill != nil && f.shipment != nil && f.deliveredAt == nil
}

func (f *Fulfillment) isDelivered() bool {
	return f.airwayBill != nil && f.shipment != nil && f.deliveredAt != nil
}
```

### Nested Status

This can be made more complicated with nested statuses. Extending the example above, the `OrderShipment` now depends on the `Fulfillment` status.

```go
type OrderShipment struct {
	firstMileDelivery *Fulfillment
	lastMileDelivery  *Fulfillment
}

func (os *OrderShipment) isFirstMileDelivered() bool {
	return os.firstMileDelivery != nil && os.firstMileDelivery.isDelivered()
}

func (os *OrderShipment) isLastMileDelivered() bool {
	return os.lastMileDelivery != nil && os.lastMileDelivery.isDelivered()
}

func (os *OrderShipment) status() string {
	switch {
	case os.isFirstMileDelivered() && os.isLastMileDelivered():
		return "last_mile_delivered"
	case os.isFirstMileDelivered():
		return "first_mile_delivered"
	default:
		return "pending_shipment"
	}
}
```

Note that the `last_mile_delivered` status __must__ be after the `first_mile_delivered` status.


### Status Reversal

Status does not necessarily moves in one direction only. For example, once a payment is made, an order can still be refunded, and the payment refunded.


### Status Sequence

One thing is certain - the status must move in a certain sequence. We cannot skip sequences, not accidentally undo a status. However, it is very easy to make those mistakes in a distributed system, when the sequence of events may not be linear.


For example, a customer may be making an order, but not paying immediately. However, the admin realises that the product that is ordered is no longer in stock, and procedes to cancel it. At the same time, the customer may already be proceeding with the payment. What should the final status be?


## Decision

As discussed above, the status of an entity should be updated in the right sequence. To ensure atomicity when updating the status of an entity, a lock must be acquired, and the status must be validated before any action can be taken.


Ideally, all status transition should only happen in a single place, e.g. an aggregate. Since domain aggregates should not include external dependencies like database etc that is required to store, possibly lock and update the states, we alternative approach. That can be publishing events, or creating another service `Transitioner` to validate and handle the state transition.

The logic to determine the current status could also be improved by introducing checkpointing.

A more complicated option is to use bitwise operator to check if steps are partially completed and valid. For most cases, a simple for loop is sufficient.



## Consequences

TBD
