# Aggregates

## Status

`draft`

## Context

We want to implement aggregates as part of Domain-Driven Design, which requires managing shared state and maintaining consistency boundaries.

Aggregates are clusters of domain objects that can be treated as a single unit for data changes. They define consistency boundaries and ensure business invariants are maintained.

Key concepts:
- Aggregate Root: The only entry point to the aggregate
- Consistency Boundary: Changes within an aggregate are consistent
- Transaction Boundary: One aggregate per transaction
- Invariants: Business rules that must always be true

## Decisions

### Aggregate Root Pattern

Define clear aggregate boundaries with a single root entity:

```go
// Aggregate root for Order
type Order struct {
    id         OrderID
    customerID CustomerID
    items      []OrderItem
    status     OrderStatus
    total      Money
    createdAt  time.Time
    version    int
    
    // Domain events
    uncommittedEvents []DomainEvent
}

// Factory method for creating new aggregate
func NewOrder(orderID OrderID, customerID CustomerID) *Order {
    order := &Order{
        id:         orderID,
        customerID: customerID,
        items:      make([]OrderItem, 0),
        status:     OrderStatusPending,
        total:      Money{Amount: decimal.Zero, Currency: "USD"},
        createdAt:  time.Now(),
        version:    1,
    }
    
    // Raise domain event
    order.raiseEvent(&OrderCreated{
        OrderID:    orderID,
        CustomerID: customerID,
        CreatedAt:  time.Now(),
    })
    
    return order
}

// Aggregate root methods - these are the only public methods
func (o *Order) ID() OrderID {
    return o.id
}

func (o *Order) Version() int {
    return o.version
}

func (o *Order) AddItem(productID ProductID, quantity int, unitPrice Money) error {
    // Business invariant: Cannot modify confirmed orders
    if o.status != OrderStatusPending {
        return fmt.Errorf("cannot add items to order in status: %s", o.status)
    }
    
    // Business invariant: Positive quantity required
    if quantity <= 0 {
        return fmt.Errorf("quantity must be positive")
    }
    
    // Business logic: Check if item already exists
    for i, item := range o.items {
        if item.ProductID == productID {
            o.items[i].Quantity += quantity
            o.recalculateTotal()
            o.version++
            
            o.raiseEvent(&OrderItemUpdated{
                OrderID:   o.id,
                ProductID: productID,
                Quantity:  o.items[i].Quantity,
                UpdatedAt: time.Now(),
            })
            return nil
        }
    }
    
    // Add new item
    newItem := OrderItem{
        ProductID: productID,
        Quantity:  quantity,
        UnitPrice: unitPrice,
    }
    
    o.items = append(o.items, newItem)
    o.recalculateTotal()
    o.version++
    
    o.raiseEvent(&OrderItemAdded{
        OrderID:   o.id,
        ProductID: productID,
        Quantity:  quantity,
        UnitPrice: unitPrice,
        AddedAt:   time.Now(),
    })
    
    return nil
}

func (o *Order) RemoveItem(productID ProductID) error {
    if o.status != OrderStatusPending {
        return fmt.Errorf("cannot remove items from order in status: %s", o.status)
    }
    
    for i, item := range o.items {
        if item.ProductID == productID {
            o.items = append(o.items[:i], o.items[i+1:]...)
            o.recalculateTotal()
            o.version++
            
            o.raiseEvent(&OrderItemRemoved{
                OrderID:   o.id,
                ProductID: productID,
                RemovedAt: time.Now(),
            })
            return nil
        }
    }
    
    return fmt.Errorf("item not found in order")
}

func (o *Order) Confirm() error {
    // Business invariant: Can only confirm pending orders
    if o.status != OrderStatusPending {
        return fmt.Errorf("cannot confirm order in status: %s", o.status)
    }
    
    // Business invariant: Order must have items
    if len(o.items) == 0 {
        return fmt.Errorf("cannot confirm empty order")
    }
    
    // Business invariant: Total must be positive
    if o.total.Amount.LessThanOrEqual(decimal.Zero) {
        return fmt.Errorf("order total must be positive")
    }
    
    o.status = OrderStatusConfirmed
    o.version++
    
    o.raiseEvent(&OrderConfirmed{
        OrderID:     o.id,
        CustomerID:  o.customerID,
        Total:       o.total,
        ItemCount:   len(o.items),
        ConfirmedAt: time.Now(),
    })
    
    return nil
}

// Private methods for internal aggregate logic
func (o *Order) recalculateTotal() {
    total := decimal.Zero
    for _, item := range o.items {
        itemTotal := item.UnitPrice.Amount.Mul(decimal.NewFromInt(int64(item.Quantity)))
        total = total.Add(itemTotal)
    }
    o.total = Money{Amount: total, Currency: o.total.Currency}
}

func (o *Order) raiseEvent(event DomainEvent) {
    o.uncommittedEvents = append(o.uncommittedEvents, event)
}

func (o *Order) UncommittedEvents() []DomainEvent {
    return o.uncommittedEvents
}

func (o *Order) MarkEventsAsCommitted() {
    o.uncommittedEvents = nil
}
```

### Value Objects within Aggregates

Encapsulate business logic in value objects:

```go
// Value object within the aggregate
type OrderItem struct {
    ProductID ProductID
    Quantity  int
    UnitPrice Money
}

func (oi OrderItem) Total() Money {
    amount := oi.UnitPrice.Amount.Mul(decimal.NewFromInt(int64(oi.Quantity)))
    return Money{Amount: amount, Currency: oi.UnitPrice.Currency}
}

func (oi OrderItem) IsValid() error {
    if oi.Quantity <= 0 {
        return fmt.Errorf("quantity must be positive")
    }
    if oi.UnitPrice.Amount.LessThanOrEqual(decimal.Zero) {
        return fmt.Errorf("unit price must be positive")
    }
    return nil
}

// Money value object
type Money struct {
    Amount   decimal.Decimal
    Currency string
}

func (m Money) Add(other Money) (Money, error) {
    if m.Currency != other.Currency {
        return Money{}, fmt.Errorf("cannot add different currencies")
    }
    return Money{
        Amount:   m.Amount.Add(other.Amount),
        Currency: m.Currency,
    }, nil
}

func (m Money) Multiply(factor decimal.Decimal) Money {
    return Money{
        Amount:   m.Amount.Mul(factor),
        Currency: m.Currency,
    }
}

func (m Money) IsZero() bool {
    return m.Amount.IsZero()
}
```

### Complex Aggregate Example

A more complex aggregate with multiple entities:

```go
// Shopping Cart aggregate
type ShoppingCart struct {
    id         CartID
    customerID CustomerID
    items      map[ProductID]*CartItem
    discounts  []Discount
    status     CartStatus
    expiresAt  time.Time
    version    int
    events     []DomainEvent
}

type CartItem struct {
    ProductID    ProductID
    ProductName  string
    Quantity     int
    UnitPrice    Money
    AddedAt      time.Time
    LastUpdated  time.Time
}

type Discount struct {
    Code       string
    Type       DiscountType
    Value      decimal.Decimal
    AppliedAt  time.Time
}

func NewShoppingCart(cartID CartID, customerID CustomerID) *ShoppingCart {
    return &ShoppingCart{
        id:         cartID,
        customerID: customerID,
        items:      make(map[ProductID]*CartItem),
        discounts:  make([]Discount, 0),
        status:     CartStatusActive,
        expiresAt:  time.Now().Add(24 * time.Hour),
        version:    1,
    }
}

func (sc *ShoppingCart) AddProduct(productID ProductID, productName string, quantity int, unitPrice Money) error {
    if sc.status != CartStatusActive {
        return fmt.Errorf("cannot add to inactive cart")
    }
    
    if sc.isExpired() {
        return fmt.Errorf("cart has expired")
    }
    
    if quantity <= 0 {
        return fmt.Errorf("quantity must be positive")
    }
    
    // Update existing item or add new one
    if existingItem, exists := sc.items[productID]; exists {
        existingItem.Quantity += quantity
        existingItem.LastUpdated = time.Now()
    } else {
        sc.items[productID] = &CartItem{
            ProductID:   productID,
            ProductName: productName,
            Quantity:    quantity,
            UnitPrice:   unitPrice,
            AddedAt:     time.Now(),
            LastUpdated: time.Now(),
        }
    }
    
    sc.version++
    sc.raiseEvent(&ProductAddedToCart{
        CartID:    sc.id,
        ProductID: productID,
        Quantity:  quantity,
        AddedAt:   time.Now(),
    })
    
    return nil
}

func (sc *ShoppingCart) ApplyDiscount(code string, discountType DiscountType, value decimal.Decimal) error {
    if sc.status != CartStatusActive {
        return fmt.Errorf("cannot apply discount to inactive cart")
    }
    
    // Business rule: Only one discount per type
    for _, discount := range sc.discounts {
        if discount.Type == discountType {
            return fmt.Errorf("discount of type %s already applied", discountType)
        }
    }
    
    discount := Discount{
        Code:      code,
        Type:      discountType,
        Value:     value,
        AppliedAt: time.Now(),
    }
    
    sc.discounts = append(sc.discounts, discount)
    sc.version++
    
    sc.raiseEvent(&DiscountApplied{
        CartID:      sc.id,
        Code:        code,
        Type:        discountType,
        Value:       value,
        AppliedAt:   time.Now(),
    })
    
    return nil
}

func (sc *ShoppingCart) CalculateTotal() Money {
    subtotal := decimal.Zero
    
    // Calculate subtotal
    for _, item := range sc.items {
        itemTotal := item.UnitPrice.Amount.Mul(decimal.NewFromInt(int64(item.Quantity)))
        subtotal = subtotal.Add(itemTotal)
    }
    
    // Apply discounts
    total := subtotal
    for _, discount := range sc.discounts {
        switch discount.Type {
        case DiscountTypePercentage:
            discountAmount := subtotal.Mul(discount.Value).Div(decimal.NewFromInt(100))
            total = total.Sub(discountAmount)
        case DiscountTypeFixed:
            total = total.Sub(discount.Value)
        }
    }
    
    // Ensure total is not negative
    if total.LessThan(decimal.Zero) {
        total = decimal.Zero
    }
    
    return Money{Amount: total, Currency: "USD"}
}

func (sc *ShoppingCart) Checkout() (*Order, error) {
    if sc.status != CartStatusActive {
        return nil, fmt.Errorf("cannot checkout inactive cart")
    }
    
    if len(sc.items) == 0 {
        return nil, fmt.Errorf("cannot checkout empty cart")
    }
    
    if sc.isExpired() {
        return nil, fmt.Errorf("cart has expired")
    }
    
    // Create order from cart
    orderID := NewOrderID()
    order := NewOrder(orderID, sc.customerID)
    
    // Add all cart items to order
    for _, item := range sc.items {
        if err := order.AddItem(item.ProductID, item.Quantity, item.UnitPrice); err != nil {
            return nil, fmt.Errorf("failed to add item to order: %w", err)
        }
    }
    
    // Apply discounts to order (this would be handled differently in practice)
    
    // Mark cart as checked out
    sc.status = CartStatusCheckedOut
    sc.version++
    
    sc.raiseEvent(&CartCheckedOut{
        CartID:      sc.id,
        OrderID:     orderID,
        CustomerID:  sc.customerID,
        Total:       sc.CalculateTotal(),
        CheckedOutAt: time.Now(),
    })
    
    return order, nil
}

func (sc *ShoppingCart) isExpired() bool {
    return time.Now().After(sc.expiresAt)
}

func (sc *ShoppingCart) raiseEvent(event DomainEvent) {
    sc.events = append(sc.events, event)
}
```

### Aggregate Repository

Handle persistence of aggregates:

```go
type OrderRepository interface {
    Save(ctx context.Context, order *Order) error
    GetByID(ctx context.Context, orderID OrderID) (*Order, error)
    GetByCustomer(ctx context.Context, customerID CustomerID, limit int) ([]*Order, error)
}

type PostgreSQLOrderRepository struct {
    db            *sql.DB
    eventStore    EventStore
}

func (r *PostgreSQLOrderRepository) Save(ctx context.Context, order *Order) error {
    return r.db.Transaction(func(tx *sql.Tx) error {
        // Save aggregate snapshot
        err := r.saveOrderSnapshot(tx, order)
        if err != nil {
            return err
        }
        
        // Save uncommitted events
        events := order.UncommittedEvents()
        if len(events) > 0 {
            err = r.eventStore.SaveEvents(ctx, string(order.ID()), events, order.Version()-len(events))
            if err != nil {
                return err
            }
            
            order.MarkEventsAsCommitted()
        }
        
        return nil
    })
}

func (r *PostgreSQLOrderRepository) GetByID(ctx context.Context, orderID OrderID) (*Order, error) {
    // Load aggregate snapshot
    order, err := r.loadOrderSnapshot(ctx, orderID)
    if err != nil {
        return nil, err
    }
    
    // Apply any events since snapshot
    events, err := r.eventStore.GetEventsFromVersion(ctx, string(orderID), order.Version())
    if err != nil {
        return nil, err
    }
    
    for _, event := range events {
        order.Apply(event) // Method to apply events to aggregate
    }
    
    return order, nil
}
```

### Aggregate Consistency

Ensure consistency within aggregate boundaries:

```go
// Ensure invariants are maintained
func (o *Order) validateInvariants() error {
    // Total must match sum of items
    calculatedTotal := decimal.Zero
    for _, item := range o.items {
        itemTotal := item.UnitPrice.Amount.Mul(decimal.NewFromInt(int64(item.Quantity)))
        calculatedTotal = calculatedTotal.Add(itemTotal)
    }
    
    if !o.total.Amount.Equal(calculatedTotal) {
        return fmt.Errorf("order total mismatch: expected %s, got %s", 
            calculatedTotal, o.total.Amount)
    }
    
    // Status transitions must be valid
    if o.status == OrderStatusShipped && len(o.items) == 0 {
        return fmt.Errorf("cannot ship empty order")
    }
    
    return nil
}

// Apply business rules consistently
func (o *Order) Ship(shippingAddress Address, trackingNumber string) error {
    if err := o.validateInvariants(); err != nil {
        return err
    }
    
    if o.status != OrderStatusConfirmed {
        return fmt.Errorf("can only ship confirmed orders")
    }
    
    if shippingAddress.IsEmpty() {
        return fmt.Errorf("shipping address required")
    }
    
    o.status = OrderStatusShipped
    o.version++
    
    o.raiseEvent(&OrderShipped{
        OrderID:         o.id,
        ShippingAddress: shippingAddress,
        TrackingNumber:  trackingNumber,
        ShippedAt:       time.Now(),
    })
    
    return nil
}
```

## Consequences

### Benefits
- **Consistency**: Business invariants are maintained within aggregate boundaries
- **Encapsulation**: Internal structure is hidden, only aggregate root is accessible
- **Transactional integrity**: One aggregate per transaction ensures consistency
- **Testability**: Aggregates can be tested in isolation
- **Performance**: Reduced need for distributed transactions

### Challenges
- **Size management**: Aggregates can grow too large over time
- **Query complexity**: May need to traverse aggregate structure for queries
- **Cross-aggregate consistency**: Eventually consistent across aggregates
- **Loading performance**: Large aggregates may be slow to load

### Best Practices
- Keep aggregates as small as possible while maintaining consistency
- Design aggregates around business invariants, not data relationships
- Use domain events for communication between aggregates
- Avoid references between aggregates - use IDs instead
- Implement aggregate repositories for persistence
- Use factories for complex aggregate creation
- Validate invariants before state changes
- Consider snapshots for large aggregates with many events

### Anti-patterns to Avoid
- **God aggregates**: Aggregates that are too large and complex
- **Cross-aggregate transactions**: Transactions spanning multiple aggregates
- **Anemic aggregates**: Aggregates with no behavior, just data
- **Breaking encapsulation**: Accessing aggregate internals directly
