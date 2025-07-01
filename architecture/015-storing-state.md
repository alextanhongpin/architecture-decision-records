# Storing State

## Status

`draft`

## Context

Instead of tracking state individually for a sequence of actions (e.g., saga), we can represent it using integers or bit flags. This approach provides a compact way to store and query complex state information.

For example, if we have 3 sequential actions: book hotel, book flight, and make payment.

Traditional approach might store:
```json
{
  "hotel_booked": false,
  "flight_booked": false, 
  "payment_completed": false
}
```

With integer state representation, we can use a single number to represent all states.

## Decisions

### Integer State Representation

Use powers of 10 or binary representation to encode multiple states:

```go
type SagaState int

const (
    SagaStateInitial       SagaState = 0   // 000
    SagaStateHotelPending  SagaState = 100 // Hotel booking started
    SagaStateHotelBooked   SagaState = 110 // Hotel booked, flight pending  
    SagaStateFlightBooked  SagaState = 111 // All completed
)

// Or using binary flags
const (
    StateHotelBooked  = 1 << 0 // 001
    StateFlightBooked = 1 << 1 // 010  
    StatePaymentDone  = 1 << 2 // 100
)

type BookingState struct {
    ID    string    `json:"id"`
    State SagaState `json:"state"`
}

func (bs *BookingState) IsHotelBooked() bool {
    return bs.State >= SagaStateHotelBooked
}

func (bs *BookingState) IsFlightBooked() bool {
    return bs.State >= SagaStateFlightBooked  
}

func (bs *BookingState) IsCompleted() bool {
    return bs.State == SagaStateFlightBooked
}

func (bs *BookingState) CanBookFlight() bool {
    return bs.State >= SagaStateHotelBooked && bs.State < SagaStateFlightBooked
}

// Progress the state
func (bs *BookingState) AdvanceToHotelBooked() error {
    if bs.State != SagaStateInitial {
        return fmt.Errorf("invalid state transition from %d", bs.State)
    }
    bs.State = SagaStateHotelBooked
    return nil
}
```

### Bit Flag Implementation

For more complex scenarios with independent flags:

```go
type ProcessingFlags uint32

const (
    FlagValidated     ProcessingFlags = 1 << 0  // 0001
    FlagApproved      ProcessingFlags = 1 << 1  // 0010
    FlagProcessed     ProcessingFlags = 1 << 2  // 0100
    FlagNotified      ProcessingFlags = 1 << 3  // 1000
)

type ProcessingState struct {
    ID    string          `json:"id"`
    Flags ProcessingFlags `json:"flags"`
}

func (ps *ProcessingState) HasFlag(flag ProcessingFlags) bool {
    return ps.Flags&flag != 0
}

func (ps *ProcessingState) SetFlag(flag ProcessingFlags) {
    ps.Flags |= flag
}

func (ps *ProcessingState) ClearFlag(flag ProcessingFlags) {
    ps.Flags &^= flag
}

func (ps *ProcessingState) IsValidated() bool {
    return ps.HasFlag(FlagValidated)
}

func (ps *ProcessingState) IsApproved() bool {
    return ps.HasFlag(FlagApproved)
}

func (ps *ProcessingState) IsFullyProcessed() bool {
    requiredFlags := FlagValidated | FlagApproved | FlagProcessed | FlagNotified
    return ps.Flags&requiredFlags == requiredFlags
}

// Get readable state description
func (ps *ProcessingState) Description() string {
    var states []string
    
    if ps.HasFlag(FlagValidated) {
        states = append(states, "validated")
    }
    if ps.HasFlag(FlagApproved) {
        states = append(states, "approved")
    }
    if ps.HasFlag(FlagProcessed) {
        states = append(states, "processed")
    }
    if ps.HasFlag(FlagNotified) {
        states = append(states, "notified")
    }
    
    if len(states) == 0 {
        return "initial"
    }
    
    return strings.Join(states, ", ")
}
```

### State Machine with Integer States

Implement a finite state machine using integer states:

```go
type OrderState int

const (
    OrderStateCreated    OrderState = 100
    OrderStatePaid       OrderState = 200
    OrderStateShipped    OrderState = 300
    OrderStateDelivered  OrderState = 400
    OrderStateCancelled  OrderState = 999
)

type OrderStateMachine struct {
    currentState OrderState
    transitions  map[OrderState][]OrderState
}

func NewOrderStateMachine() *OrderStateMachine {
    return &OrderStateMachine{
        currentState: OrderStateCreated,
        transitions: map[OrderState][]OrderState{
            OrderStateCreated:   {OrderStatePaid, OrderStateCancelled},
            OrderStatePaid:      {OrderStateShipped, OrderStateCancelled},
            OrderStateShipped:   {OrderStateDelivered},
            OrderStateDelivered: {}, // Final state
            OrderStateCancelled: {}, // Final state
        },
    }
}

func (osm *OrderStateMachine) CanTransitionTo(newState OrderState) bool {
    allowedTransitions := osm.transitions[osm.currentState]
    for _, allowed := range allowedTransitions {
        if allowed == newState {
            return true
        }
    }
    return false
}

func (osm *OrderStateMachine) TransitionTo(newState OrderState) error {
    if !osm.CanTransitionTo(newState) {
        return fmt.Errorf("invalid transition from %d to %d", osm.currentState, newState)
    }
    
    osm.currentState = newState
    return nil
}

func (osm *OrderStateMachine) CurrentState() OrderState {
    return osm.currentState
}

func (osm *OrderStateMachine) IsCompleted() bool {
    return osm.currentState == OrderStateDelivered || osm.currentState == OrderStateCancelled
}
```

### Database Queries with State

Optimize database queries using integer states:

```sql
-- Find all orders that are at least paid
SELECT * FROM orders WHERE state >= 200;

-- Find all orders in processing (paid but not delivered)
SELECT * FROM orders WHERE state >= 200 AND state < 400;

-- Find orders by specific state combinations using bit flags
SELECT * FROM processing_items 
WHERE flags & 3 = 3  -- Both validated (1) and approved (2)
AND flags & 4 = 0;   -- But not processed (4)

-- Count items by state progress
SELECT 
  CASE 
    WHEN state >= 400 THEN 'completed'
    WHEN state >= 300 THEN 'shipped'
    WHEN state >= 200 THEN 'paid'
    ELSE 'created'
  END as status,
  COUNT(*) as count
FROM orders 
GROUP BY status;
```

### State Persistence Pattern

Store state efficiently in databases:

```go
type StateRepository struct {
    db *sql.DB
}

func (sr *StateRepository) SaveState(ctx context.Context, entityID string, state int) error {
    query := `
        INSERT INTO entity_states (id, state, updated_at) 
        VALUES ($1, $2, NOW())
        ON CONFLICT (id) 
        DO UPDATE SET state = $2, updated_at = NOW()`
    
    _, err := sr.db.ExecContext(ctx, query, entityID, state)
    return err
}

func (sr *StateRepository) GetState(ctx context.Context, entityID string) (int, error) {
    var state int
    query := "SELECT state FROM entity_states WHERE id = $1"
    err := sr.db.QueryRowContext(ctx, query, entityID).Scan(&state)
    return state, err
}

func (sr *StateRepository) GetEntitiesInState(ctx context.Context, minState, maxState int) ([]string, error) {
    query := "SELECT id FROM entity_states WHERE state >= $1 AND state <= $2"
    rows, err := sr.db.QueryContext(ctx, query, minState, maxState)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var entities []string
    for rows.Next() {
        var id string
        if err := rows.Scan(&id); err != nil {
            return nil, err
        }
        entities = append(entities, id)
    }
    
    return entities, nil
}

// Batch state updates for performance
func (sr *StateRepository) BatchUpdateStates(ctx context.Context, updates map[string]int) error {
    tx, err := sr.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    stmt, err := tx.PrepareContext(ctx, `
        INSERT INTO entity_states (id, state, updated_at) 
        VALUES ($1, $2, NOW())
        ON CONFLICT (id) 
        DO UPDATE SET state = $2, updated_at = NOW()`)
    if err != nil {
        return err
    }
    defer stmt.Close()
    
    for entityID, state := range updates {
        if _, err := stmt.ExecContext(ctx, entityID, state); err != nil {
            return err
        }
    }
    
    return tx.Commit()
}
```

### Monitoring and Observability

Track state distributions and transitions:

```go
type StateMetrics struct {
    stateDistribution map[int]int64
    transitions       map[string]int64 // "from_to" -> count
    mutex            sync.RWMutex
}

func (sm *StateMetrics) RecordState(state int) {
    sm.mutex.Lock()
    defer sm.mutex.Unlock()
    
    if sm.stateDistribution == nil {
        sm.stateDistribution = make(map[int]int64)
    }
    
    sm.stateDistribution[state]++
}

func (sm *StateMetrics) RecordTransition(fromState, toState int) {
    sm.mutex.Lock()
    defer sm.mutex.Unlock()
    
    if sm.transitions == nil {
        sm.transitions = make(map[string]int64)
    }
    
    key := fmt.Sprintf("%d_%d", fromState, toState)
    sm.transitions[key]++
}

func (sm *StateMetrics) GetStateDistribution() map[int]int64 {
    sm.mutex.RLock()
    defer sm.mutex.RUnlock()
    
    result := make(map[int]int64)
    for state, count := range sm.stateDistribution {
        result[state] = count
    }
    return result
}

func (sm *StateMetrics) GetTransitionCounts() map[string]int64 {
    sm.mutex.RLock()
    defer sm.mutex.RUnlock()
    
    result := make(map[string]int64)
    for transition, count := range sm.transitions {
        result[transition] = count
    }
    return result
}
```

## Consequences

### Benefits
- **Compact storage**: Single integer instead of multiple boolean fields
- **Efficient queries**: Range queries using simple comparisons
- **Clear progression**: Easy to check if state has progressed beyond a point
- **Database optimization**: Integer comparisons are faster than string comparisons
- **Bit manipulation**: Advanced operations possible with bit flags

### Challenges
- **Readability**: Less intuitive than named states
- **Schema evolution**: Adding new states requires careful planning
- **Debugging**: Harder to understand state at a glance
- **Documentation**: Requires clear documentation of state meanings

### Best Practices
- Document state values and their meanings clearly
- Use constants instead of magic numbers
- Implement helper methods for state checking
- Consider using enums or type aliases for type safety
- Monitor state distributions for business insights
- Plan for state schema evolution from the beginning

### Use Cases
- **Workflow tracking**: Multi-step business processes
- **Feature flags**: Multiple boolean settings as single integer
- **Permission systems**: User capabilities as bit flags
- **Processing pipelines**: Track completion of multiple stages
- **Audit trails**: Compact representation of entity lifecycle