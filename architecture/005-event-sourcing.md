# Event Sourcing

## Status

`draft`

## Context

Event sourcing is a pattern where we store the state of a business entity as a sequence of state-changing events. Instead of storing just the current state, we store all the events that led to that state.

This approach provides several advantages:
- Complete audit trail of all changes
- Ability to reconstruct state at any point in time
- Natural fit for event-driven architectures
- Support for complex business workflows
- Time-travel debugging capabilities

## Decisions

### Core Concepts

#### Events as First-Class Citizens

Events represent facts that have happened in the domain:

```go
type Event interface {
    EventID() string
    EventType() string
    AggregateID() string
    Version() int
    Timestamp() time.Time
    Data() interface{}
}

type BaseEvent struct {
    ID          string    `json:"id"`
    Type        string    `json:"type"`
    AggregateId string    `json:"aggregate_id"`
    Ver         int       `json:"version"`
    Time        time.Time `json:"timestamp"`
    Payload     []byte    `json:"data"`
}

func (e BaseEvent) EventID() string     { return e.ID }
func (e BaseEvent) EventType() string   { return e.Type }
func (e BaseEvent) AggregateID() string { return e.AggregateId }
func (e BaseEvent) Version() int        { return e.Ver }
func (e BaseEvent) Timestamp() time.Time { return e.Time }
func (e BaseEvent) Data() interface{}   { return e.Payload }
```

#### Domain Events

Define specific business events:

```go
// Account domain events
type AccountCreated struct {
    BaseEvent
    Email    string `json:"email"`
    Name     string `json:"name"`
}

type MoneyDeposited struct {
    BaseEvent
    Amount   decimal.Decimal `json:"amount"`
    Currency string         `json:"currency"`
}

type MoneyWithdrawn struct {
    BaseEvent
    Amount   decimal.Decimal `json:"amount"`
    Currency string         `json:"currency"`
}

type AccountClosed struct {
    BaseEvent
    Reason string `json:"reason"`
}
```

### Event Store Implementation

#### Simple Event Store

```go
type EventStore interface {
    SaveEvents(aggregateID string, events []Event, expectedVersion int) error
    GetEvents(aggregateID string) ([]Event, error)
    GetEventsFromVersion(aggregateID string, version int) ([]Event, error)
}

type InMemoryEventStore struct {
    events map[string][]Event
    mutex  sync.RWMutex
}

func NewInMemoryEventStore() *InMemoryEventStore {
    return &InMemoryEventStore{
        events: make(map[string][]Event),
    }
}

func (es *InMemoryEventStore) SaveEvents(aggregateID string, events []Event, expectedVersion int) error {
    es.mutex.Lock()
    defer es.mutex.Unlock()
    
    existingEvents := es.events[aggregateID]
    
    // Optimistic concurrency check
    if len(existingEvents) != expectedVersion {
        return fmt.Errorf("concurrency conflict: expected version %d, got %d", 
            expectedVersion, len(existingEvents))
    }
    
    // Assign version numbers to new events
    for i, event := range events {
        if baseEvent, ok := event.(*BaseEvent); ok {
            baseEvent.Ver = expectedVersion + i + 1
        }
    }
    
    es.events[aggregateID] = append(existingEvents, events...)
    return nil
}

func (es *InMemoryEventStore) GetEvents(aggregateID string) ([]Event, error) {
    es.mutex.RLock()
    defer es.mutex.RUnlock()
    
    events := es.events[aggregateID]
    if events == nil {
        return []Event{}, nil
    }
    
    // Return a copy to prevent external modification
    result := make([]Event, len(events))
    copy(result, events)
    return result, nil
}
```

#### PostgreSQL Event Store

For production use with persistence:

```go
type PostgreSQLEventStore struct {
    db *sql.DB
}

func (es *PostgreSQLEventStore) SaveEvents(aggregateID string, events []Event, expectedVersion int) error {
    tx, err := es.db.Begin()
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Check current version
    var currentVersion int
    err = tx.QueryRow(
        "SELECT COALESCE(MAX(version), 0) FROM events WHERE aggregate_id = $1",
        aggregateID,
    ).Scan(&currentVersion)
    
    if err != nil && err != sql.ErrNoRows {
        return err
    }
    
    if currentVersion != expectedVersion {
        return fmt.Errorf("concurrency conflict: expected %d, got %d", 
            expectedVersion, currentVersion)
    }
    
    // Insert new events
    stmt, err := tx.Prepare(`
        INSERT INTO events (id, aggregate_id, event_type, version, timestamp, data) 
        VALUES ($1, $2, $3, $4, $5, $6)
    `)
    if err != nil {
        return err
    }
    defer stmt.Close()
    
    for i, event := range events {
        version := expectedVersion + i + 1
        data, _ := json.Marshal(event.Data())
        
        _, err = stmt.Exec(
            event.EventID(),
            aggregateID,
            event.EventType(),
            version,
            event.Timestamp(),
            data,
        )
        if err != nil {
            return err
        }
    }
    
    return tx.Commit()
}
```

### Aggregate Root Pattern

Aggregates encapsulate business logic and generate events:

```go
type Aggregate interface {
    ID() string
    Version() int
    UncommittedEvents() []Event
    MarkEventsAsCommitted()
    LoadFromHistory(events []Event)
}

type Account struct {
    id               string
    version          int
    balance          decimal.Decimal
    currency         string
    status           AccountStatus
    uncommittedEvents []Event
}

type AccountStatus string

const (
    AccountActive AccountStatus = "active"
    AccountClosed AccountStatus = "closed"
)

func NewAccount(id, email, name string) *Account {
    account := &Account{
        id:      id,
        version: 0,
        balance: decimal.Zero,
        status:  AccountActive,
    }
    
    event := &AccountCreated{
        BaseEvent: BaseEvent{
            ID:          uuid.New().String(),
            Type:        "AccountCreated",
            AggregateId: id,
            Time:        time.Now(),
        },
        Email: email,
        Name:  name,
    }
    
    account.apply(event)
    return account
}

func (a *Account) Deposit(amount decimal.Decimal, currency string) error {
    if a.status != AccountActive {
        return fmt.Errorf("cannot deposit to inactive account")
    }
    
    if amount.LessThanOrEqual(decimal.Zero) {
        return fmt.Errorf("deposit amount must be positive")
    }
    
    event := &MoneyDeposited{
        BaseEvent: BaseEvent{
            ID:          uuid.New().String(),
            Type:        "MoneyDeposited",
            AggregateId: a.id,
            Time:        time.Now(),
        },
        Amount:   amount,
        Currency: currency,
    }
    
    a.apply(event)
    return nil
}

func (a *Account) Withdraw(amount decimal.Decimal) error {
    if a.status != AccountActive {
        return fmt.Errorf("cannot withdraw from inactive account")
    }
    
    if amount.LessThanOrEqual(decimal.Zero) {
        return fmt.Errorf("withdrawal amount must be positive")
    }
    
    if a.balance.LessThan(amount) {
        return fmt.Errorf("insufficient funds")
    }
    
    event := &MoneyWithdrawn{
        BaseEvent: BaseEvent{
            ID:          uuid.New().String(),
            Type:        "MoneyWithdrawn",
            AggregateId: a.id,
            Time:        time.Now(),
        },
        Amount: amount,
    }
    
    a.apply(event)
    return nil
}

func (a *Account) apply(event Event) {
    switch e := event.(type) {
    case *AccountCreated:
        a.currency = "USD" // Default currency
    case *MoneyDeposited:
        a.balance = a.balance.Add(e.Amount)
        if a.currency == "" {
            a.currency = e.Currency
        }
    case *MoneyWithdrawn:
        a.balance = a.balance.Sub(e.Amount)
    case *AccountClosed:
        a.status = AccountClosed
    }
    
    a.version++
    a.uncommittedEvents = append(a.uncommittedEvents, event)
}

func (a *Account) LoadFromHistory(events []Event) {
    for _, event := range events {
        a.apply(event)
    }
    a.uncommittedEvents = nil // Clear uncommitted events after loading
}

func (a *Account) UncommittedEvents() []Event {
    return a.uncommittedEvents
}

func (a *Account) MarkEventsAsCommitted() {
    a.uncommittedEvents = nil
}
```

### Repository Pattern for Event Sourcing

```go
type AccountRepository struct {
    eventStore EventStore
}

func NewAccountRepository(eventStore EventStore) *AccountRepository {
    return &AccountRepository{eventStore: eventStore}
}

func (r *AccountRepository) Save(account *Account) error {
    events := account.UncommittedEvents()
    if len(events) == 0 {
        return nil // Nothing to save
    }
    
    err := r.eventStore.SaveEvents(
        account.ID(),
        events,
        account.Version()-len(events),
    )
    
    if err != nil {
        return err
    }
    
    account.MarkEventsAsCommitted()
    return nil
}

func (r *AccountRepository) GetByID(id string) (*Account, error) {
    events, err := r.eventStore.GetEvents(id)
    if err != nil {
        return nil, err
    }
    
    if len(events) == 0 {
        return nil, fmt.Errorf("account not found: %s", id)
    }
    
    account := &Account{id: id}
    account.LoadFromHistory(events)
    return account, nil
}
```

### Projections and Read Models

Create optimized views for queries:

```go
type AccountProjection struct {
    ID       string          `db:"id"`
    Email    string          `db:"email"`
    Name     string          `db:"name"`
    Balance  decimal.Decimal `db:"balance"`
    Currency string          `db:"currency"`
    Status   string          `db:"status"`
    UpdatedAt time.Time      `db:"updated_at"`
}

type AccountProjectionHandler struct {
    db *sql.DB
}

func (h *AccountProjectionHandler) Handle(event Event) error {
    switch e := event.(type) {
    case *AccountCreated:
        return h.createAccountProjection(e)
    case *MoneyDeposited:
        return h.updateBalance(e.AggregateID(), e.Amount, true)
    case *MoneyWithdrawn:
        return h.updateBalance(e.AggregateID(), e.Amount, false)
    case *AccountClosed:
        return h.updateStatus(e.AggregateID(), "closed")
    }
    return nil
}

func (h *AccountProjectionHandler) createAccountProjection(event *AccountCreated) error {
    _, err := h.db.Exec(`
        INSERT INTO account_projections (id, email, name, balance, currency, status, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
    `, event.AggregateID(), event.Email, event.Name, 0, "USD", "active", time.Now())
    return err
}

func (h *AccountProjectionHandler) updateBalance(aggregateID string, amount decimal.Decimal, isDeposit bool) error {
    var query string
    if isDeposit {
        query = "UPDATE account_projections SET balance = balance + $1, updated_at = $2 WHERE id = $3"
    } else {
        query = "UPDATE account_projections SET balance = balance - $1, updated_at = $2 WHERE id = $3"
    }
    
    _, err := h.db.Exec(query, amount, time.Now(), aggregateID)
    return err
}
```

### Snapshots for Performance

Optimize aggregate loading with snapshots:

```go
type Snapshot struct {
    AggregateID string    `json:"aggregate_id"`
    Version     int       `json:"version"`
    Data        []byte    `json:"data"`
    Timestamp   time.Time `json:"timestamp"`
}

type SnapshotStore interface {
    SaveSnapshot(snapshot Snapshot) error
    GetSnapshot(aggregateID string) (*Snapshot, error)
}

func (r *AccountRepository) GetByIDWithSnapshot(id string) (*Account, error) {
    // Try to load from snapshot first
    snapshot, err := r.snapshotStore.GetSnapshot(id)
    var account *Account
    var fromVersion int
    
    if err == nil && snapshot != nil {
        account = &Account{}
        json.Unmarshal(snapshot.Data, account)
        fromVersion = snapshot.Version
    } else {
        account = &Account{id: id}
        fromVersion = 0
    }
    
    // Load events since the snapshot
    events, err := r.eventStore.GetEventsFromVersion(id, fromVersion)
    if err != nil {
        return nil, err
    }
    
    account.LoadFromHistory(events)
    
    // Create new snapshot if many events were replayed
    if len(events) > 100 {
        go r.createSnapshot(account)
    }
    
    return account, nil
}
```

## Consequences

### Benefits
- **Complete audit trail**: Every change is recorded as an immutable event
- **Time travel**: Can reconstruct state at any point in time
- **Debugging**: Easy to understand what happened and when
- **Performance**: Read models can be optimized for specific queries
- **Scalability**: Read and write sides can be scaled independently
- **Compliance**: Natural support for regulatory requirements

### Challenges
- **Complexity**: More complex than traditional CRUD operations
- **Storage overhead**: All events must be stored permanently
- **Schema evolution**: Handling changes to event structures over time
- **Eventual consistency**: Read models may lag behind write side
- **Query complexity**: Some queries require event replay or specialized projections

### Best Practices
- Design events as immutable facts from the domain
- Use domain experts to identify meaningful business events
- Implement proper versioning for event schema evolution
- Create efficient projections for common query patterns
- Use snapshots for aggregates with many events
- Handle concurrency with optimistic locking
- Monitor event store performance and projection lag

### Anti-patterns to Avoid
- **Event as current state**: Events should represent changes, not snapshots
- **Too granular events**: Avoid creating events for every property change
- **Events with behavior**: Events should only contain data, not logic
- **Shared event schemas**: Each bounded context should own its events