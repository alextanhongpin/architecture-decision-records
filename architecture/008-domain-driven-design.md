# Domain-Driven Design

## Status

`draft`

## Context

Domain-Driven Design (DDD) is an approach to software development that emphasizes collaboration between technical and domain experts to create a model that reflects the business domain.

Key concepts we'll apply:
- Ubiquitous Language: Shared vocabulary between developers and domain experts
- Bounded Contexts: Clear boundaries between different parts of the system
- Aggregates: Consistency boundaries within the domain
- Value Objects: Immutable objects that represent domain concepts
- Domain Events: Significant occurrences in the domain
- Domain Services: Operations that don't belong to any specific entity

## Decisions

### Ubiquitous Language

Establish a common vocabulary that both developers and domain experts use:

```go
// Instead of generic terms like "User" or "Record"
// Use domain-specific terms

// E-commerce domain
type Customer struct {
    CustomerID CustomerID
    Email      EmailAddress
    Profile    CustomerProfile
}

type Order struct {
    OrderID     OrderID
    Customer    CustomerID
    LineItems   []LineItem
    OrderStatus OrderStatus
    PlacedAt    time.Time
}

type OrderStatus string

const (
    OrderStatusPending   OrderStatus = "pending"
    OrderStatusConfirmed OrderStatus = "confirmed"
    OrderStatusShipped   OrderStatus = "shipped"
    OrderStatusDelivered OrderStatus = "delivered"
    OrderStatusCancelled OrderStatus = "cancelled"
)

// Banking domain would use different terms
type Account struct {
    AccountNumber AccountNumber
    Balance       Money
    AccountType   AccountType
    Holder        AccountHolder
}
```

### Value Objects

Encapsulate validation logic and ensure invariants:

```go
// Email value object
type EmailAddress struct {
    value string
}

func NewEmailAddress(email string) (EmailAddress, error) {
    if email == "" {
        return EmailAddress{}, fmt.Errorf("email cannot be empty")
    }
    
    if !isValidEmail(email) {
        return EmailAddress{}, fmt.Errorf("invalid email format: %s", email)
    }
    
    return EmailAddress{value: strings.ToLower(email)}, nil
}

func (e EmailAddress) String() string {
    return e.value
}

func (e EmailAddress) Domain() string {
    parts := strings.Split(e.value, "@")
    if len(parts) != 2 {
        return ""
    }
    return parts[1]
}

// Money value object
type Money struct {
    amount   decimal.Decimal
    currency Currency
}

func NewMoney(amount decimal.Decimal, currency Currency) (Money, error) {
    if amount.IsNegative() {
        return Money{}, fmt.Errorf("money amount cannot be negative")
    }
    
    if currency == "" {
        return Money{}, fmt.Errorf("currency is required")
    }
    
    return Money{amount: amount, currency: currency}, nil
}

func (m Money) Amount() decimal.Decimal {
    return m.amount
}

func (m Money) Currency() Currency {
    return m.currency
}

func (m Money) Add(other Money) (Money, error) {
    if m.currency != other.currency {
        return Money{}, fmt.Errorf("cannot add different currencies: %s and %s", 
            m.currency, other.currency)
    }
    
    return Money{
        amount:   m.amount.Add(other.amount),
        currency: m.currency,
    }, nil
}

func (m Money) IsZero() bool {
    return m.amount.IsZero()
}

// Address value object
type Address struct {
    street     string
    city       string
    state      string
    postalCode string
    country    string
}

func NewAddress(street, city, state, postalCode, country string) (Address, error) {
    if street == "" || city == "" || country == "" {
        return Address{}, fmt.Errorf("street, city, and country are required")
    }
    
    return Address{
        street:     street,
        city:       city,
        state:      state,
        postalCode: postalCode,
        country:    country,
    }, nil
}

func (a Address) FullAddress() string {
    return fmt.Sprintf("%s, %s, %s %s, %s", 
        a.street, a.city, a.state, a.postalCode, a.country)
}

func (a Address) IsSameCountry(other Address) bool {
    return strings.EqualFold(a.country, other.country)
}
```

### Entities and Aggregates

Define entities with identity and aggregates with consistency boundaries:

```go
// Entity with identity
type Customer struct {
    id       CustomerID
    email    EmailAddress
    profile  CustomerProfile
    version  int
    
    // Domain events
    events []DomainEvent
}

func NewCustomer(id CustomerID, email EmailAddress, profile CustomerProfile) *Customer {
    customer := &Customer{
        id:      id,
        email:   email,
        profile: profile,
        version: 1,
    }
    
    // Raise domain event
    customer.raiseEvent(&CustomerRegistered{
        CustomerID: id,
        Email:      email,
        RegisteredAt: time.Now(),
    })
    
    return customer
}

func (c *Customer) ID() CustomerID {
    return c.id
}

func (c *Customer) Email() EmailAddress {
    return c.email
}

func (c *Customer) UpdateProfile(profile CustomerProfile) {
    oldProfile := c.profile
    c.profile = profile
    c.version++
    
    if !reflect.DeepEqual(oldProfile, profile) {
        c.raiseEvent(&CustomerProfileUpdated{
            CustomerID: c.id,
            OldProfile: oldProfile,
            NewProfile: profile,
            UpdatedAt:  time.Now(),
        })
    }
}

func (c *Customer) raiseEvent(event DomainEvent) {
    c.events = append(c.events, event)
}

func (c *Customer) Events() []DomainEvent {
    return c.events
}

func (c *Customer) ClearEvents() {
    c.events = nil
}

// Aggregate root - Order
type Order struct {
    id         OrderID
    customerID CustomerID
    lineItems  []LineItem
    status     OrderStatus
    placedAt   time.Time
    total      Money
    version    int
    events     []DomainEvent
}

func NewOrder(id OrderID, customerID CustomerID) *Order {
    order := &Order{
        id:         id,
        customerID: customerID,
        lineItems:  make([]LineItem, 0),
        status:     OrderStatusPending,
        placedAt:   time.Now(),
        version:    1,
    }
    
    return order
}

func (o *Order) AddLineItem(productID ProductID, quantity int, unitPrice Money) error {
    if o.status != OrderStatusPending {
        return fmt.Errorf("cannot modify order in status: %s", o.status)
    }
    
    if quantity <= 0 {
        return fmt.Errorf("quantity must be positive")
    }
    
    // Check if item already exists
    for i, item := range o.lineItems {
        if item.ProductID == productID {
            o.lineItems[i].Quantity += quantity
            o.recalculateTotal()
            return nil
        }
    }
    
    // Add new line item
    lineItem := LineItem{
        ProductID: productID,
        Quantity:  quantity,
        UnitPrice: unitPrice,
    }
    
    o.lineItems = append(o.lineItems, lineItem)
    o.recalculateTotal()
    
    return nil
}

func (o *Order) Confirm() error {
    if o.status != OrderStatusPending {
        return fmt.Errorf("cannot confirm order in status: %s", o.status)
    }
    
    if len(o.lineItems) == 0 {
        return fmt.Errorf("cannot confirm empty order")
    }
    
    o.status = OrderStatusConfirmed
    o.version++
    
    o.raiseEvent(&OrderConfirmed{
        OrderID:     o.id,
        CustomerID:  o.customerID,
        Total:       o.total,
        ConfirmedAt: time.Now(),
    })
    
    return nil
}

func (o *Order) recalculateTotal() {
    total := Money{amount: decimal.Zero, currency: "USD"}
    
    for _, item := range o.lineItems {
        itemTotal := item.UnitPrice.amount.Mul(decimal.NewFromInt(int64(item.Quantity)))
        total.amount = total.amount.Add(itemTotal)
    }
    
    o.total = total
}
```

### Domain Events

Capture significant domain occurrences:

```go
type DomainEvent interface {
    EventID() string
    EventType() string
    OccurredAt() time.Time
    AggregateID() string
}

type CustomerRegistered struct {
    EventID_     string      `json:"event_id"`
    CustomerID   CustomerID  `json:"customer_id"`
    Email        EmailAddress `json:"email"`
    RegisteredAt time.Time   `json:"registered_at"`
}

func (e CustomerRegistered) EventID() string     { return e.EventID_ }
func (e CustomerRegistered) EventType() string   { return "CustomerRegistered" }
func (e CustomerRegistered) OccurredAt() time.Time { return e.RegisteredAt }
func (e CustomerRegistered) AggregateID() string  { return string(e.CustomerID) }

type OrderConfirmed struct {
    EventID_     string     `json:"event_id"`
    OrderID      OrderID    `json:"order_id"`
    CustomerID   CustomerID `json:"customer_id"`
    Total        Money      `json:"total"`
    ConfirmedAt  time.Time  `json:"confirmed_at"`
}

func (e OrderConfirmed) EventID() string     { return e.EventID_ }
func (e OrderConfirmed) EventType() string   { return "OrderConfirmed" }
func (e OrderConfirmed) OccurredAt() time.Time { return e.ConfirmedAt }
func (e OrderConfirmed) AggregateID() string  { return string(e.OrderID) }

// Domain event dispatcher
type DomainEventDispatcher struct {
    handlers map[string][]DomainEventHandler
}

type DomainEventHandler interface {
    Handle(ctx context.Context, event DomainEvent) error
}

func (d *DomainEventDispatcher) RegisterHandler(eventType string, handler DomainEventHandler) {
    if d.handlers == nil {
        d.handlers = make(map[string][]DomainEventHandler)
    }
    d.handlers[eventType] = append(d.handlers[eventType], handler)
}

func (d *DomainEventDispatcher) Dispatch(ctx context.Context, events []DomainEvent) error {
    for _, event := range events {
        handlers := d.handlers[event.EventType()]
        for _, handler := range handlers {
            if err := handler.Handle(ctx, event); err != nil {
                return fmt.Errorf("handler failed for event %s: %w", event.EventType(), err)
            }
        }
    }
    return nil
}
```

### Domain Services

Operations that don't belong to a specific entity:

```go
// Domain service for complex business logic
type PricingService struct {
    discountRepository DiscountRepository
    taxService         TaxService
}

func NewPricingService(discountRepo DiscountRepository, taxService TaxService) *PricingService {
    return &PricingService{
        discountRepository: discountRepo,
        taxService:         taxService,
    }
}

func (ps *PricingService) CalculateOrderTotal(ctx context.Context, order *Order, customer *Customer) (Money, error) {
    subtotal := order.Subtotal()
    
    // Apply customer-specific discounts
    discount, err := ps.calculateDiscount(ctx, order, customer)
    if err != nil {
        return Money{}, err
    }
    
    discountedTotal, err := subtotal.Subtract(discount)
    if err != nil {
        return Money{}, err
    }
    
    // Calculate tax
    tax, err := ps.taxService.CalculateTax(ctx, discountedTotal, customer.ShippingAddress())
    if err != nil {
        return Money{}, err
    }
    
    // Final total
    return discountedTotal.Add(tax)
}

func (ps *PricingService) calculateDiscount(ctx context.Context, order *Order, customer *Customer) (Money, error) {
    discounts, err := ps.discountRepository.GetApplicableDiscounts(ctx, customer.ID(), order)
    if err != nil {
        return Money{}, err
    }
    
    var totalDiscount Money
    for _, discount := range discounts {
        discountAmount := discount.Calculate(order.Subtotal())
        totalDiscount, _ = totalDiscount.Add(discountAmount)
    }
    
    return totalDiscount, nil
}

// Transfer domain service
type MoneyTransferService struct {
    exchangeRateService ExchangeRateService
}

func (mts *MoneyTransferService) Transfer(ctx context.Context, from *Account, to *Account, amount Money) error {
    // Business rules for money transfer
    if from.Balance().LessThan(amount) {
        return fmt.Errorf("insufficient funds")
    }
    
    if from.IsFrozen() {
        return fmt.Errorf("source account is frozen")
    }
    
    if to.IsClosed() {
        return fmt.Errorf("destination account is closed")
    }
    
    // Handle currency conversion if needed
    transferAmount := amount
    if from.Currency() != to.Currency() {
        rate, err := mts.exchangeRateService.GetExchangeRate(ctx, from.Currency(), to.Currency())
        if err != nil {
            return err
        }
        transferAmount = amount.Convert(rate)
    }
    
    // Perform the transfer
    from.Withdraw(amount)
    to.Deposit(transferAmount)
    
    return nil
}
```

### Bounded Contexts

Separate different business areas:

```go
// Order Management Context
package ordermanagement

type Order struct {
    ID         OrderID
    CustomerID CustomerID
    Items      []OrderItem
    Status     OrderStatus
}

type OrderService struct {
    orderRepo OrderRepository
}

// Inventory Context
package inventory

type Product struct {
    SKU         ProductSKU
    Name        string
    StockLevel  int
    ReorderPoint int
}

type InventoryService struct {
    productRepo ProductRepository
}

// Customer Context  
package customer

type Customer struct {
    ID      CustomerID
    Email   EmailAddress
    Profile CustomerProfile
}

type CustomerService struct {
    customerRepo CustomerRepository
}

// Anti-corruption layer for integration
type OrderManagementCustomerService struct {
    customerService customer.CustomerService
}

func (ocs *OrderManagementCustomerService) GetCustomerForOrder(customerID CustomerID) (*OrderCustomer, error) {
    // Translate between contexts
    customer, err := ocs.customerService.GetCustomer(customerID)
    if err != nil {
        return nil, err
    }
    
    // Convert to order management context model
    return &OrderCustomer{
        ID:    customer.ID,
        Email: customer.Email,
        // Only include fields relevant to order management
    }, nil
}
```

### Repository Pattern

Abstract data access within the domain:

```go
type CustomerRepository interface {
    Save(ctx context.Context, customer *Customer) error
    GetByID(ctx context.Context, id CustomerID) (*Customer, error)
    GetByEmail(ctx context.Context, email EmailAddress) (*Customer, error)
    Delete(ctx context.Context, id CustomerID) error
}

type OrderRepository interface {
    Save(ctx context.Context, order *Order) error
    GetByID(ctx context.Context, id OrderID) (*Order, error)
    GetByCustomer(ctx context.Context, customerID CustomerID) ([]Order, error)
    GetByStatus(ctx context.Context, status OrderStatus) ([]Order, error)
}

// Implementation would be in infrastructure layer
type PostgreSQLCustomerRepository struct {
    db *sql.DB
}

func (repo *PostgreSQLCustomerRepository) Save(ctx context.Context, customer *Customer) error {
    // Implementation details...
    return nil
}
```

## Consequences

### Benefits
- **Shared understanding**: Ubiquitous language creates clear communication
- **Business focus**: Code reflects business concepts and rules
- **Maintainability**: Clear domain boundaries make code easier to understand
- **Testability**: Domain logic is isolated and testable
- **Flexibility**: Domain model can evolve independently of technical concerns

### Challenges
- **Complexity**: Additional abstraction layers
- **Learning curve**: Team needs to understand DDD concepts
- **Over-engineering**: Can be overkill for simple CRUD applications
- **Bounded context boundaries**: Difficult to get right initially

### Best Practices
- Start with the core domain and expand outward
- Use event storming sessions to discover domain events
- Implement domain events for loose coupling
- Keep value objects immutable
- Use aggregate roots to maintain consistency
- Implement anti-corruption layers for external systems
- Focus on behavior, not just data
- Refactor domain model based on new understanding

### Anti-patterns to Avoid
- **Anemic domain model**: Domain objects with no behavior
- **God aggregates**: Aggregates that are too large
- **Leaky abstractions**: Domain concepts bleeding into infrastructure
- **Ignoring bounded contexts**: Everything in one large model
