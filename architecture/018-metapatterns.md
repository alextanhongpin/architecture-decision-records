# Architectural Metapatterns

## Status

`accepted`

## Context

Architectural metapatterns are high-level patterns that describe common architectural solutions and principles that can be applied across different domains and technologies. These patterns provide a vocabulary and framework for discussing architectural decisions and trade-offs.

Understanding and applying metapatterns helps architects make informed decisions about system design, communicate effectively with stakeholders, and avoid common pitfalls in large-scale system design.

## Decision

Adopt and document architectural metapatterns as a foundation for system design decisions, providing a common language and set of principles for our architectural approach.

## Metapatterns Catalog

### 1. Layered Architecture

Organize system components into horizontal layers with defined dependencies:

```
┌─────────────────────────────────────┐
│         Presentation Layer          │
├─────────────────────────────────────┤
│          Business Layer             │
├─────────────────────────────────────┤
│        Persistence Layer            │
├─────────────────────────────────────┤
│         Database Layer              │
└─────────────────────────────────────┘
```

**When to use**: Well-understood domains with clear separation of concerns.

**Trade-offs**: 
- ✅ Clear separation, easy to understand
- ❌ Performance bottlenecks, rigid structure

### 2. Service-Oriented Architecture (SOA)

Decompose system into loosely coupled services:

```go
type OrderService interface {
    CreateOrder(ctx context.Context, req CreateOrderRequest) (*Order, error)
    GetOrder(ctx context.Context, id string) (*Order, error)
    UpdateOrder(ctx context.Context, order *Order) error
}

type PaymentService interface {
    ProcessPayment(ctx context.Context, req PaymentRequest) (*Payment, error)
    RefundPayment(ctx context.Context, paymentID string) error
}

type NotificationService interface {
    SendNotification(ctx context.Context, notification Notification) error
}
```

**When to use**: Complex systems requiring independent deployment and scaling.

**Trade-offs**:
- ✅ Loose coupling, independent deployment
- ❌ Network complexity, data consistency challenges

### 3. Event-Driven Architecture

Use events to trigger actions and maintain consistency:

```go
type Event interface {
    EventType() string
    AggregateID() string
    Timestamp() time.Time
}

type OrderCreatedEvent struct {
    OrderID   string    `json:"order_id"`
    UserID    string    `json:"user_id"`
    Amount    float64   `json:"amount"`
    CreatedAt time.Time `json:"created_at"`
}

func (e OrderCreatedEvent) EventType() string { return "order.created" }
func (e OrderCreatedEvent) AggregateID() string { return e.OrderID }
func (e OrderCreatedEvent) Timestamp() time.Time { return e.CreatedAt }

type EventHandler interface {
    Handle(ctx context.Context, event Event) error
}

type PaymentHandler struct {
    paymentService PaymentService
}

func (h *PaymentHandler) Handle(ctx context.Context, event Event) error {
    switch e := event.(type) {
    case OrderCreatedEvent:
        return h.processOrderPayment(ctx, e)
    }
    return nil
}
```

**When to use**: Systems requiring loose coupling and eventual consistency.

**Trade-offs**:
- ✅ Loose coupling, scalability
- ❌ Complexity, debugging challenges

### 4. Pipes and Filters

Process data through a series of transformations:

```go
type Filter interface {
    Process(ctx context.Context, data interface{}) (interface{}, error)
}

type Pipeline struct {
    filters []Filter
}

func (p *Pipeline) Execute(ctx context.Context, input interface{}) (interface{}, error) {
    data := input
    for _, filter := range p.filters {
        var err error
        data, err = filter.Process(ctx, data)
        if err != nil {
            return nil, fmt.Errorf("filter failed: %w", err)
        }
    }
    return data, nil
}

// Example: Data processing pipeline
type ValidateFilter struct{}
func (f *ValidateFilter) Process(ctx context.Context, data interface{}) (interface{}, error) {
    // Validation logic
    return data, nil
}

type TransformFilter struct{}
func (f *TransformFilter) Process(ctx context.Context, data interface{}) (interface{}, error) {
    // Transformation logic
    return data, nil
}

type EnrichFilter struct{}
func (f *EnrichFilter) Process(ctx context.Context, data interface{}) (interface{}, error) {
    // Enrichment logic
    return data, nil
}
```

**When to use**: Data processing, transformation workflows.

**Trade-offs**:
- ✅ Reusable components, testable
- ❌ Performance overhead, complex error handling

### 5. Broker Pattern

Coordinate communication between distributed components:

```go
type MessageBroker interface {
    Publish(topic string, message interface{}) error
    Subscribe(topic string, handler MessageHandler) error
}

type MessageHandler interface {
    Handle(message interface{}) error
}

type OrderBroker struct {
    broker MessageBroker
}

func (b *OrderBroker) PublishOrderCreated(order *Order) error {
    event := OrderCreatedEvent{
        OrderID:   order.ID,
        UserID:    order.UserID,
        Amount:    order.Amount,
        CreatedAt: order.CreatedAt,
    }
    return b.broker.Publish("order.created", event)
}

func (b *OrderBroker) SubscribeToPayments() error {
    handler := &PaymentHandler{paymentService: b.paymentService}
    return b.broker.Subscribe("order.created", handler)
}
```

**When to use**: Distributed systems requiring message routing and coordination.

**Trade-offs**:
- ✅ Decoupling, dynamic routing
- ❌ Single point of failure, complexity

### 6. Repository Pattern

Abstract data access logic:

```go
type Repository[T any] interface {
    Create(ctx context.Context, entity *T) error
    GetByID(ctx context.Context, id string) (*T, error)
    Update(ctx context.Context, entity *T) error
    Delete(ctx context.Context, id string) error
    List(ctx context.Context, filter Filter) ([]*T, error)
}

type UserRepository interface {
    Repository[User]
    GetByEmail(ctx context.Context, email string) (*User, error)
    GetByStatus(ctx context.Context, status string) ([]*User, error)
}

type PostgresUserRepository struct {
    db *sql.DB
}

func (r *PostgresUserRepository) Create(ctx context.Context, user *User) error {
    query := `INSERT INTO users (id, email, name, created_at) VALUES ($1, $2, $3, $4)`
    _, err := r.db.ExecContext(ctx, query, user.ID, user.Email, user.Name, user.CreatedAt)
    return err
}

func (r *PostgresUserRepository) GetByID(ctx context.Context, id string) (*User, error) {
    query := `SELECT id, email, name, created_at FROM users WHERE id = $1`
    row := r.db.QueryRowContext(ctx, query, id)
    
    var user User
    err := row.Scan(&user.ID, &user.Email, &user.Name, &user.CreatedAt)
    if err != nil {
        return nil, err
    }
    return &user, nil
}
```

**When to use**: Applications requiring data persistence abstraction.

**Trade-offs**:
- ✅ Testability, database independence
- ❌ Additional abstraction layer

### 7. Command Query Responsibility Segregation (CQRS)

Separate read and write operations:

```go
// Command side - writes
type CreateUserCommand struct {
    Email string
    Name  string
}

type CommandHandler interface {
    Handle(ctx context.Context, cmd interface{}) error
}

type CreateUserHandler struct {
    repo UserRepository
    bus  EventBus
}

func (h *CreateUserHandler) Handle(ctx context.Context, cmd interface{}) error {
    createCmd, ok := cmd.(CreateUserCommand)
    if !ok {
        return fmt.Errorf("invalid command type")
    }
    
    user := &User{
        ID:        generateID(),
        Email:     createCmd.Email,
        Name:      createCmd.Name,
        CreatedAt: time.Now(),
    }
    
    if err := h.repo.Create(ctx, user); err != nil {
        return err
    }
    
    event := UserCreatedEvent{UserID: user.ID, Email: user.Email}
    return h.bus.Publish(event)
}

// Query side - reads
type GetUserQuery struct {
    UserID string
}

type QueryHandler interface {
    Handle(ctx context.Context, query interface{}) (interface{}, error)
}

type GetUserHandler struct {
    readRepo UserReadRepository
}

func (h *GetUserHandler) Handle(ctx context.Context, query interface{}) (interface{}, error) {
    getQuery, ok := query.(GetUserQuery)
    if !ok {
        return nil, fmt.Errorf("invalid query type")
    }
    
    return h.readRepo.GetByID(ctx, getQuery.UserID)
}
```

**When to use**: Systems with complex read/write patterns, high performance requirements.

**Trade-offs**:
- ✅ Optimized reads/writes, scalability
- ❌ Complexity, eventual consistency

### 8. Saga Pattern

Manage distributed transactions:

```go
type SagaStep interface {
    Execute(ctx context.Context, data interface{}) (interface{}, error)
    Compensate(ctx context.Context, data interface{}) error
}

type Saga struct {
    steps []SagaStep
}

func (s *Saga) Execute(ctx context.Context, data interface{}) error {
    executedSteps := []SagaStep{}
    
    for _, step := range s.steps {
        result, err := step.Execute(ctx, data)
        if err != nil {
            // Compensate in reverse order
            for i := len(executedSteps) - 1; i >= 0; i-- {
                if compErr := executedSteps[i].Compensate(ctx, data); compErr != nil {
                    log.Printf("compensation failed: %v", compErr)
                }
            }
            return err
        }
        executedSteps = append(executedSteps, step)
        data = result
    }
    
    return nil
}

// Example: Order processing saga
type ReserveInventoryStep struct{}
func (s *ReserveInventoryStep) Execute(ctx context.Context, data interface{}) (interface{}, error) {
    // Reserve inventory logic
    return data, nil
}
func (s *ReserveInventoryStep) Compensate(ctx context.Context, data interface{}) error {
    // Release inventory logic
    return nil
}

type ProcessPaymentStep struct{}
func (s *ProcessPaymentStep) Execute(ctx context.Context, data interface{}) (interface{}, error) {
    // Process payment logic
    return data, nil
}
func (s *ProcessPaymentStep) Compensate(ctx context.Context, data interface{}) error {
    // Refund payment logic
    return nil
}
```

**When to use**: Distributed transactions requiring consistency across services.

**Trade-offs**:
- ✅ Consistency, error handling
- ❌ Complexity, coordination overhead

### 9. Bulkhead Pattern

Isolate critical resources:

```go
type ResourcePool struct {
    pool chan struct{}
    name string
}

func NewResourcePool(name string, size int) *ResourcePool {
    pool := make(chan struct{}, size)
    for i := 0; i < size; i++ {
        pool <- struct{}{}
    }
    return &ResourcePool{pool: pool, name: name}
}

func (p *ResourcePool) Acquire(ctx context.Context) error {
    select {
    case <-p.pool:
        return nil
    case <-ctx.Done():
        return fmt.Errorf("failed to acquire resource from %s pool: %w", p.name, ctx.Err())
    }
}

func (p *ResourcePool) Release() {
    select {
    case p.pool <- struct{}{}:
    default:
        // Pool is full, resource was likely already released
    }
}

// Example: Separate connection pools for different services
type ServiceClients struct {
    userServicePool    *ResourcePool
    paymentServicePool *ResourcePool
    emailServicePool   *ResourcePool
}

func NewServiceClients() *ServiceClients {
    return &ServiceClients{
        userServicePool:    NewResourcePool("user-service", 10),
        paymentServicePool: NewResourcePool("payment-service", 5),
        emailServicePool:   NewResourcePool("email-service", 3),
    }
}
```

**When to use**: Systems requiring fault isolation and resource protection.

**Trade-offs**:
- ✅ Fault isolation, resource protection
- ❌ Resource utilization, complexity

### 10. Circuit Breaker Pattern

Prevent cascading failures:

```go
type CircuitState int

const (
    Closed CircuitState = iota
    Open
    HalfOpen
)

type CircuitBreaker struct {
    failureThreshold int
    timeout          time.Duration
    state            CircuitState
    failureCount     int
    lastFailureTime  time.Time
    mutex            sync.Mutex
}

func (cb *CircuitBreaker) Call(ctx context.Context, fn func() error) error {
    cb.mutex.Lock()
    defer cb.mutex.Unlock()
    
    if cb.state == Open {
        if time.Since(cb.lastFailureTime) > cb.timeout {
            cb.state = HalfOpen
            cb.failureCount = 0
        } else {
            return fmt.Errorf("circuit breaker is open")
        }
    }
    
    err := fn()
    if err != nil {
        cb.failureCount++
        cb.lastFailureTime = time.Now()
        
        if cb.failureCount >= cb.failureThreshold {
            cb.state = Open
        }
        return err
    }
    
    // Success - reset circuit breaker
    cb.failureCount = 0
    cb.state = Closed
    return nil
}
```

**When to use**: Systems calling external services or unreliable components.

**Trade-offs**:
- ✅ Fault tolerance, fast failure
- ❌ Complexity, false positives

## Metapattern Selection Guidelines

### Decision Matrix

| Pattern | Complexity | Performance | Scalability | Consistency | Maintenance |
|---------|------------|-------------|-------------|-------------|-------------|
| Layered | Low | Medium | Low | Strong | Easy |
| SOA | Medium | Low | High | Eventual | Medium |
| Event-Driven | High | High | High | Eventual | Hard |
| Pipes & Filters | Medium | Medium | Medium | Strong | Medium |
| CQRS | High | High | High | Eventual | Hard |
| Saga | High | Low | Medium | Strong | Hard |

### Selection Criteria

1. **System Complexity**: Start simple, evolve to complex patterns as needed
2. **Performance Requirements**: High-performance systems may need CQRS, Event-Driven
3. **Consistency Requirements**: Strong consistency favors Layered, Saga patterns
4. **Team Expertise**: Complex patterns require experienced developers
5. **Operational Overhead**: Consider monitoring, debugging, deployment complexity

## Anti-patterns

- **Pattern Overuse**: Applying complex patterns to simple problems
- **Pattern Mixing**: Combining incompatible patterns without clear boundaries
- **Premature Optimization**: Choosing patterns based on hypothetical future needs
- **Cargo Cult**: Copying patterns without understanding their trade-offs
- **One Size Fits All**: Using the same pattern for all problems in a system

## References

- [Architectural Metapatterns](https://itnext.io/the-list-of-architectural-metapatterns-ed64d8ba125d)
- Enterprise Integration Patterns by Gregor Hohpe
- Patterns of Enterprise Application Architecture by Martin Fowler
- Building Microservices by Sam Newman
