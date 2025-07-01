# Database State Machine Implementation

## Status
**Accepted**

## Context
Many business entities have complex lifecycle states that must be managed consistently across the application. Examples include:

- **Order Processing**: pending → confirmed → processing → shipped → delivered
- **User Authentication**: unverified → verified → active → suspended → deactivated
- **Payment Processing**: pending → authorized → captured → settled → refunded
- **Content Moderation**: draft → submitted → approved → published → archived

Managing these state transitions manually in application code often leads to:
- **Inconsistent State Changes**: Different parts of the application handling transitions differently
- **Business Rule Violations**: Invalid state transitions being allowed
- **Audit Trail Loss**: No comprehensive tracking of state changes
- **Race Conditions**: Concurrent state modifications causing data corruption
- **Complex Validation Logic**: Scattered business rules across multiple layers

Database-level state machines provide atomic, consistent, and auditable state management with proper business rule enforcement.

## Decision
We will implement state machines at the database level using:
1. **Enum Types** for valid states
2. **Transition Tables** for allowed state changes
3. **Triggers and Functions** for validation and automation
4. **Audit Tables** for complete state change history
5. **Application Layer Integration** for business logic coordination

## Implementation

### 1. Order State Machine Example

```sql
-- Define valid order states
CREATE TYPE order_status AS ENUM (
    'draft',
    'pending',
    'confirmed',
    'processing',
    'shipped',
    'delivered',
    'cancelled',
    'refunded'
);

-- Main orders table
CREATE TABLE orders (
    id BIGSERIAL PRIMARY KEY,
    order_number VARCHAR(50) UNIQUE NOT NULL,
    customer_id BIGINT NOT NULL,
    status order_status NOT NULL DEFAULT 'draft',
    total_amount DECIMAL(15,2) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    version INTEGER DEFAULT 1,
    
    -- State-specific fields
    confirmed_at TIMESTAMP WITH TIME ZONE,
    shipped_at TIMESTAMP WITH TIME ZONE,
    delivered_at TIMESTAMP WITH TIME ZONE,
    cancelled_at TIMESTAMP WITH TIME ZONE,
    cancellation_reason TEXT,
    
    -- Constraints
    CONSTRAINT chk_confirmed_after_created CHECK (confirmed_at IS NULL OR confirmed_at >= created_at),
    CONSTRAINT chk_shipped_after_confirmed CHECK (shipped_at IS NULL OR (confirmed_at IS NOT NULL AND shipped_at >= confirmed_at)),
    CONSTRAINT chk_delivered_after_shipped CHECK (delivered_at IS NULL OR (shipped_at IS NOT NULL AND delivered_at >= shipped_at))
);

-- State transition rules table
CREATE TABLE order_state_transitions (
    id SERIAL PRIMARY KEY,
    from_status order_status NOT NULL,
    to_status order_status NOT NULL,
    is_valid BOOLEAN NOT NULL DEFAULT true,
    requires_reason BOOLEAN NOT NULL DEFAULT false,
    auto_timestamp_field VARCHAR(50), -- Field to auto-update with timestamp
    description TEXT,
    
    UNIQUE(from_status, to_status)
);

-- Populate valid transitions
INSERT INTO order_state_transitions (from_status, to_status, auto_timestamp_field, description) VALUES
    ('draft', 'pending', NULL, 'Customer submits order'),
    ('pending', 'confirmed', 'confirmed_at', 'Payment authorized'),
    ('pending', 'cancelled', 'cancelled_at', 'Order cancelled before confirmation'),
    ('confirmed', 'processing', NULL, 'Order enters fulfillment'),
    ('confirmed', 'cancelled', 'cancelled_at', 'Order cancelled after confirmation'),
    ('processing', 'shipped', 'shipped_at', 'Order shipped to customer'),
    ('processing', 'cancelled', 'cancelled_at', 'Order cancelled during processing'),
    ('shipped', 'delivered', 'delivered_at', 'Order delivered successfully'),
    ('delivered', 'refunded', NULL, 'Order refunded after delivery'),
    ('cancelled', 'refunded', NULL, 'Refund processed for cancelled order');

-- Update transitions that require reasons
UPDATE order_state_transitions 
SET requires_reason = true 
WHERE to_status IN ('cancelled', 'refunded');

-- State change audit table
CREATE TABLE order_state_history (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    from_status order_status,
    to_status order_status NOT NULL,
    reason TEXT,
    metadata JSONB DEFAULT '{}',
    changed_by BIGINT, -- References users(id)
    changed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    INDEX idx_order_state_history_order (order_id, changed_at DESC),
    INDEX idx_order_state_history_status (to_status, changed_at DESC)
);
```

### 2. State Transition Validation Function

```sql
-- Function to validate and execute state transitions
CREATE OR REPLACE FUNCTION change_order_status(
    p_order_id BIGINT,
    p_new_status order_status,
    p_reason TEXT DEFAULT NULL,
    p_changed_by BIGINT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
) RETURNS BOOLEAN AS $$
DECLARE
    v_current_status order_status;
    v_transition_valid BOOLEAN;
    v_requires_reason BOOLEAN;
    v_auto_timestamp_field VARCHAR(50);
    v_order_version INTEGER;
BEGIN
    -- Get current order status and version
    SELECT status, version INTO v_current_status, v_order_version
    FROM orders 
    WHERE id = p_order_id
    FOR UPDATE; -- Lock the row to prevent concurrent modifications
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order not found: %', p_order_id;
    END IF;
    
    -- Check if transition is valid
    SELECT is_valid, requires_reason, auto_timestamp_field
    INTO v_transition_valid, v_requires_reason, v_auto_timestamp_field
    FROM order_state_transitions
    WHERE from_status = v_current_status 
    AND to_status = p_new_status;
    
    IF NOT FOUND OR NOT v_transition_valid THEN
        RAISE EXCEPTION 'Invalid state transition from % to % for order %', 
            v_current_status, p_new_status, p_order_id;
    END IF;
    
    -- Check if reason is required
    IF v_requires_reason AND (p_reason IS NULL OR TRIM(p_reason) = '') THEN
        RAISE EXCEPTION 'Reason required for transition from % to %', 
            v_current_status, p_new_status;
    END IF;
    
    -- Record state change in history
    INSERT INTO order_state_history (
        order_id, from_status, to_status, reason, metadata, changed_by
    ) VALUES (
        p_order_id, v_current_status, p_new_status, p_reason, p_metadata, p_changed_by
    );
    
    -- Update order status and version
    UPDATE orders 
    SET 
        status = p_new_status,
        updated_at = NOW(),
        version = version + 1,
        -- Conditionally update timestamp fields
        confirmed_at = CASE WHEN v_auto_timestamp_field = 'confirmed_at' THEN NOW() ELSE confirmed_at END,
        shipped_at = CASE WHEN v_auto_timestamp_field = 'shipped_at' THEN NOW() ELSE shipped_at END,
        delivered_at = CASE WHEN v_auto_timestamp_field = 'delivered_at' THEN NOW() ELSE delivered_at END,
        cancelled_at = CASE WHEN v_auto_timestamp_field = 'cancelled_at' THEN NOW() ELSE cancelled_at END,
        cancellation_reason = CASE WHEN p_new_status = 'cancelled' THEN p_reason ELSE cancellation_reason END
    WHERE id = p_order_id 
    AND version = v_order_version; -- Optimistic locking
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order was modified by another process (version conflict)';
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
```

### 3. Go Application Integration

```go
// pkg/statemachine/order.go
package statemachine

import (
    "context"
    "database/sql"
    "fmt"
    "time"
)

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
)

type OrderStateMachine struct {
    db *sql.DB
}

func NewOrderStateMachine(db *sql.DB) *OrderStateMachine {
    return &OrderStateMachine{db: db}
}

type StateChangeRequest struct {
    OrderID   int64
    NewStatus OrderStatus
    Reason    string
    ChangedBy int64
    Metadata  map[string]interface{}
}

type StateChangeResult struct {
    Success      bool
    PreviousState OrderStatus
    NewState     OrderStatus
    Timestamp    time.Time
    Error        error
}

func (osm *OrderStateMachine) ChangeState(ctx context.Context, req StateChangeRequest) (*StateChangeResult, error) {
    // Get current state
    currentState, err := osm.getCurrentState(ctx, req.OrderID)
    if err != nil {
        return &StateChangeResult{
            Success: false,
            Error:   fmt.Errorf("failed to get current state: %w", err),
        }, err
    }
    
    // Validate transition in application layer (optional additional validation)
    if err := osm.validateTransition(currentState, req.NewStatus); err != nil {
        return &StateChangeResult{
            Success:       false,
            PreviousState: currentState,
            Error:         err,
        }, err
    }
    
    // Execute state change using database function
    metadataJSON, _ := json.Marshal(req.Metadata)
    
    var success bool
    err = osm.db.QueryRowContext(ctx, `
        SELECT change_order_status($1, $2, $3, $4, $5)
    `, req.OrderID, string(req.NewStatus), req.Reason, req.ChangedBy, string(metadataJSON)).Scan(&success)
    
    if err != nil {
        return &StateChangeResult{
            Success:       false,
            PreviousState: currentState,
            Error:         err,
        }, err
    }
    
    return &StateChangeResult{
        Success:       true,
        PreviousState: currentState,
        NewState:      req.NewStatus,
        Timestamp:     time.Now(),
    }, nil
}

func (osm *OrderStateMachine) getCurrentState(ctx context.Context, orderID int64) (OrderStatus, error) {
    var status string
    err := osm.db.QueryRowContext(ctx, 
        "SELECT status FROM orders WHERE id = $1", orderID).Scan(&status)
    if err != nil {
        return "", err
    }
    return OrderStatus(status), nil
}

func (osm *OrderStateMachine) validateTransition(from, to OrderStatus) error {
    // Application-level validation (in addition to database constraints)
    validTransitions := map[OrderStatus][]OrderStatus{
        OrderStatusDraft:      {OrderStatusPending},
        OrderStatusPending:    {OrderStatusConfirmed, OrderStatusCancelled},
        OrderStatusConfirmed:  {OrderStatusProcessing, OrderStatusCancelled},
        OrderStatusProcessing: {OrderStatusShipped, OrderStatusCancelled},
        OrderStatusShipped:    {OrderStatusDelivered},
        OrderStatusDelivered:  {OrderStatusRefunded},
        OrderStatusCancelled:  {OrderStatusRefunded},
    }
    
    allowedTargets, exists := validTransitions[from]
    if !exists {
        return fmt.Errorf("no transitions allowed from state %s", from)
    }
    
    for _, allowed := range allowedTargets {
        if allowed == to {
            return nil
        }
    }
    
    return fmt.Errorf("invalid transition from %s to %s", from, to)
}

// Get state history for an order
func (osm *OrderStateMachine) GetStateHistory(ctx context.Context, orderID int64) ([]StateChange, error) {
    rows, err := osm.db.QueryContext(ctx, `
        SELECT 
            from_status,
            to_status,
            reason,
            metadata,
            changed_by,
            changed_at
        FROM order_state_history
        WHERE order_id = $1
        ORDER BY changed_at ASC
    `, orderID)
    
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var history []StateChange
    for rows.Next() {
        var change StateChange
        var fromStatus sql.NullString
        var metadata string
        var changedBy sql.NullInt64
        
        err := rows.Scan(
            &fromStatus,
            &change.ToStatus,
            &change.Reason,
            &metadata,
            &changedBy,
            &change.ChangedAt,
        )
        
        if err != nil {
            continue
        }
        
        if fromStatus.Valid {
            change.FromStatus = OrderStatus(fromStatus.String)
        }
        if changedBy.Valid {
            change.ChangedBy = changedBy.Int64
        }
        
        json.Unmarshal([]byte(metadata), &change.Metadata)
        history = append(history, change)
    }
    
    return history, nil
}

type StateChange struct {
    FromStatus OrderStatus            `json:"from_status"`
    ToStatus   OrderStatus            `json:"to_status"`
    Reason     string                 `json:"reason"`
    Metadata   map[string]interface{} `json:"metadata"`
    ChangedBy  int64                  `json:"changed_by"`
    ChangedAt  time.Time              `json:"changed_at"`
}
```

### 4. Business Logic Integration

```go
// pkg/orders/service.go
package orders

import (
    "context"
    "fmt"
    
    "your-project/pkg/statemachine"
)

type OrderService struct {
    stateMachine   *statemachine.OrderStateMachine
    paymentService PaymentService
    inventoryService InventoryService
    shippingService ShippingService
}

func (os *OrderService) ConfirmOrder(ctx context.Context, orderID int64, userID int64) error {
    // Business logic before state change
    order, err := os.getOrder(ctx, orderID)
    if err != nil {
        return err
    }
    
    // Authorize payment
    paymentResult, err := os.paymentService.AuthorizePayment(ctx, order.PaymentMethodID, order.TotalAmount)
    if err != nil {
        return fmt.Errorf("payment authorization failed: %w", err)
    }
    
    // Reserve inventory
    if err := os.inventoryService.ReserveItems(ctx, order.Items); err != nil {
        // Rollback payment authorization
        os.paymentService.CancelAuthorization(ctx, paymentResult.AuthorizationID)
        return fmt.Errorf("inventory reservation failed: %w", err)
    }
    
    // Change state to confirmed
    result, err := os.stateMachine.ChangeState(ctx, statemachine.StateChangeRequest{
        OrderID:   orderID,
        NewStatus: statemachine.OrderStatusConfirmed,
        Reason:    "Payment authorized and inventory reserved",
        ChangedBy: userID,
        Metadata: map[string]interface{}{
            "payment_authorization_id": paymentResult.AuthorizationID,
            "reserved_items":          order.Items,
        },
    })
    
    if err != nil {
        // Rollback operations
        os.inventoryService.ReleaseReservation(ctx, order.Items)
        os.paymentService.CancelAuthorization(ctx, paymentResult.AuthorizationID)
        return err
    }
    
    // Business logic after successful state change
    if result.Success {
        os.notifyOrderConfirmed(ctx, orderID)
        os.scheduleProcessing(ctx, orderID)
    }
    
    return nil
}

func (os *OrderService) ShipOrder(ctx context.Context, orderID int64, trackingNumber string, userID int64) error {
    // Capture payment before shipping
    order, err := os.getOrder(ctx, orderID)
    if err != nil {
        return err
    }
    
    if err := os.paymentService.CapturePayment(ctx, order.PaymentAuthorizationID); err != nil {
        return fmt.Errorf("payment capture failed: %w", err)
    }
    
    // Create shipping label and arrange pickup
    shippingLabel, err := os.shippingService.CreateShippingLabel(ctx, order)
    if err != nil {
        return fmt.Errorf("shipping label creation failed: %w", err)
    }
    
    // Change state to shipped
    _, err = os.stateMachine.ChangeState(ctx, statemachine.StateChangeRequest{
        OrderID:   orderID,
        NewStatus: statemachine.OrderStatusShipped,
        Reason:    "Order shipped with tracking number",
        ChangedBy: userID,
        Metadata: map[string]interface{}{
            "tracking_number": trackingNumber,
            "shipping_label":  shippingLabel.URL,
            "carrier":         shippingLabel.Carrier,
        },
    })
    
    if err != nil {
        return err
    }
    
    // Post-shipping actions
    os.notifyOrderShipped(ctx, orderID, trackingNumber)
    os.scheduleDeliveryCheck(ctx, orderID)
    
    return nil
}

func (os *OrderService) CancelOrder(ctx context.Context, orderID int64, reason string, userID int64) error {
    order, err := os.getOrder(ctx, orderID)
    if err != nil {
        return err
    }
    
    // Business logic validation
    if order.Status == statemachine.OrderStatusShipped {
        return fmt.Errorf("cannot cancel order that has already shipped")
    }
    
    // Change state to cancelled
    result, err := os.stateMachine.ChangeState(ctx, statemachine.StateChangeRequest{
        OrderID:   orderID,
        NewStatus: statemachine.OrderStatusCancelled,
        Reason:    reason,
        ChangedBy: userID,
    })
    
    if err != nil {
        return err
    }
    
    if result.Success {
        // Cleanup operations
        if order.Status != statemachine.OrderStatusDraft {
            os.inventoryService.ReleaseReservation(ctx, order.Items)
        }
        
        if order.PaymentAuthorizationID != "" {
            os.paymentService.CancelAuthorization(ctx, order.PaymentAuthorizationID)
        }
        
        os.notifyOrderCancelled(ctx, orderID, reason)
    }
    
    return nil
}
```

### 5. State Machine Monitoring and Analytics

```sql
-- Create monitoring views
CREATE VIEW order_state_analytics AS
SELECT 
    status,
    COUNT(*) as order_count,
    AVG(EXTRACT(EPOCH FROM (updated_at - created_at))/3600) as avg_hours_in_state,
    MIN(created_at) as first_order,
    MAX(created_at) as last_order
FROM orders
GROUP BY status;

-- State transition timing analysis
CREATE VIEW order_transition_timing AS
SELECT 
    from_status,
    to_status,
    COUNT(*) as transition_count,
    AVG(EXTRACT(EPOCH FROM (
        SELECT MIN(changed_at) 
        FROM order_state_history osh2 
        WHERE osh2.order_id = osh.order_id 
        AND osh2.changed_at > osh.changed_at
    ) - changed_at)/3600) as avg_hours_to_next_state
FROM order_state_history osh
WHERE from_status IS NOT NULL
GROUP BY from_status, to_status
ORDER BY from_status, to_status;

-- Problematic orders (stuck in states)
CREATE VIEW stuck_orders AS
SELECT 
    o.id,
    o.order_number,
    o.status,
    o.updated_at,
    EXTRACT(EPOCH FROM (NOW() - o.updated_at))/3600 as hours_in_current_state
FROM orders o
WHERE 
    (o.status = 'pending' AND o.updated_at < NOW() - INTERVAL '24 hours') OR
    (o.status = 'confirmed' AND o.updated_at < NOW() - INTERVAL '48 hours') OR
    (o.status = 'processing' AND o.updated_at < NOW() - INTERVAL '72 hours') OR
    (o.status = 'shipped' AND o.updated_at < NOW() - INTERVAL '14 days')
ORDER BY hours_in_current_state DESC;
```

```go
// pkg/statemachine/monitoring.go
package statemachine

import (
    "context"
    "database/sql"
    "time"
)

type StateMonitor struct {
    db *sql.DB
}

func NewStateMonitor(db *sql.DB) *StateMonitor {
    return &StateMonitor{db: db}
}

type StateAnalytics struct {
    Status           OrderStatus `json:"status"`
    OrderCount       int         `json:"order_count"`
    AvgHoursInState  float64     `json:"avg_hours_in_state"`
    FirstOrderTime   time.Time   `json:"first_order_time"`
    LastOrderTime    time.Time   `json:"last_order_time"`
}

func (sm *StateMonitor) GetStateAnalytics(ctx context.Context) ([]StateAnalytics, error) {
    rows, err := sm.db.QueryContext(ctx, `
        SELECT status, order_count, avg_hours_in_state, first_order, last_order
        FROM order_state_analytics
        ORDER BY 
            CASE status
                WHEN 'draft' THEN 1
                WHEN 'pending' THEN 2
                WHEN 'confirmed' THEN 3
                WHEN 'processing' THEN 4
                WHEN 'shipped' THEN 5
                WHEN 'delivered' THEN 6
                WHEN 'cancelled' THEN 7
                WHEN 'refunded' THEN 8
            END
    `)
    
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var analytics []StateAnalytics
    for rows.Next() {
        var sa StateAnalytics
        var avgHours sql.NullFloat64
        
        err := rows.Scan(
            &sa.Status,
            &sa.OrderCount,
            &avgHours,
            &sa.FirstOrderTime,
            &sa.LastOrderTime,
        )
        
        if err != nil {
            continue
        }
        
        if avgHours.Valid {
            sa.AvgHoursInState = avgHours.Float64
        }
        
        analytics = append(analytics, sa)
    }
    
    return analytics, nil
}

type StuckOrder struct {
    ID                    int64     `json:"id"`
    OrderNumber          string    `json:"order_number"`
    Status               OrderStatus `json:"status"`
    UpdatedAt            time.Time `json:"updated_at"`
    HoursInCurrentState  float64   `json:"hours_in_current_state"`
}

func (sm *StateMonitor) GetStuckOrders(ctx context.Context) ([]StuckOrder, error) {
    rows, err := sm.db.QueryContext(ctx, `
        SELECT id, order_number, status, updated_at, hours_in_current_state
        FROM stuck_orders
        LIMIT 100
    `)
    
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var stuckOrders []StuckOrder
    for rows.Next() {
        var so StuckOrder
        
        err := rows.Scan(
            &so.ID,
            &so.OrderNumber,
            &so.Status,
            &so.UpdatedAt,
            &so.HoursInCurrentState,
        )
        
        if err != nil {
            continue
        }
        
        stuckOrders = append(stuckOrders, so)
    }
    
    return stuckOrders, nil
}
```

## Best Practices

### 1. State Design Guidelines

- **Keep States Simple**: Each state should represent a clear business condition
- **Minimize State Count**: Too many states create complexity; group related conditions
- **Clear Transition Rules**: Every transition should have clear business justification
- **Audit Everything**: Track all state changes with timestamps and reasons
- **Handle Edge Cases**: Plan for error states and recovery mechanisms

### 2. Performance Considerations

```sql
-- Efficient state queries with proper indexing
CREATE INDEX idx_orders_status_created ON orders(status, created_at DESC);
CREATE INDEX idx_order_state_history_order_date ON order_state_history(order_id, changed_at DESC);

-- Partitioning for large state history tables
CREATE TABLE order_state_history_y2024 PARTITION OF order_state_history
FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
```

### 3. Testing State Machines

```go
func TestOrderStateMachine(t *testing.T) {
    testCases := []struct {
        name        string
        fromState   OrderStatus
        toState     OrderStatus
        shouldError bool
    }{
        {"valid pending to confirmed", OrderStatusPending, OrderStatusConfirmed, false},
        {"invalid draft to shipped", OrderStatusDraft, OrderStatusShipped, true},
        {"valid confirmed to cancelled", OrderStatusConfirmed, OrderStatusCancelled, false},
    }
    
    for _, tc := range testCases {
        t.Run(tc.name, func(t *testing.T) {
            err := stateMachine.validateTransition(tc.fromState, tc.toState)
            if tc.shouldError {
                assert.Error(t, err)
            } else {
                assert.NoError(t, err)
            }
        })
    }
}
```

## Consequences

### Positive
- **Data Consistency**: Database-level enforcement prevents invalid state transitions
- **Audit Trail**: Complete history of all state changes with metadata
- **Business Rule Enforcement**: Critical business logic enforced at the database level
- **Concurrent Safety**: Database transactions prevent race conditions
- **Monitoring**: Built-in analytics and monitoring capabilities

### Negative
- **Database Complexity**: More complex database schema and stored procedures
- **Migration Challenges**: State changes require careful migration planning
- **Debugging Difficulty**: Database-level logic can be harder to debug
- **Performance Impact**: Additional queries and validations for state changes

## Related Patterns
- [Database Design Record](009-database-design-record.md) - Documenting state machine designs
- [Optimistic Locking](007-optimistic-locking.md) - Version control for state changes
- [Audit Logging](013-logging.md) - State change audit implementation
- [Background Jobs](../backend/029-background-job.md) - Automated state transitions
