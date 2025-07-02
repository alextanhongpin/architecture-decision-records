# Testing Private Methods and Variables

## Status

`accepted`

## Context

Go's package-based visibility model creates a distinction between exported (public) and unexported (private) members. While this encourages good API design, it raises questions about testing strategies for internal implementation details.

Two primary testing approaches exist:
- **Black-box testing**: Testing only public interfaces from external packages
- **White-box testing**: Testing internal implementation from within the same package

The choice between these approaches depends on the layer being tested and the confidence needed in internal logic.

## Decision

**Use a layered testing strategy that matches testing approach to the component's role:**

### 1. Testing Strategy by Layer

```go
// Domain Layer - White-box testing for business logic validation
package domain

import (
    "errors"
    "time"
)

// Public interface
type OrderService interface {
    CreateOrder(customerID string, items []Item) (*Order, error)
}

// Private implementation details
type orderService struct {
    repo         OrderRepository
    validator    *orderValidator
    priceEngine  *priceCalculator
}

type orderValidator struct {
    minItems int
    maxItems int
}

func (v *orderValidator) validate(items []Item) error {
    if len(items) < v.minItems {
        return errors.New("insufficient items")
    }
    if len(items) > v.maxItems {
        return errors.New("too many items")
    }
    return nil
}

type priceCalculator struct {
    taxRate      float64
    discountRate float64
}

func (p *priceCalculator) calculateTotal(items []Item) Money {
    subtotal := p.calculateSubtotal(items)
    discount := p.calculateDiscount(subtotal)
    tax := p.calculateTax(subtotal - discount)
    return subtotal - discount + tax
}

func (p *priceCalculator) calculateSubtotal(items []Item) Money {
    var total Money
    for _, item := range items {
        total += item.Price * Money(item.Quantity)
    }
    return total
}

func (p *priceCalculator) calculateDiscount(subtotal Money) Money {
    return Money(float64(subtotal) * p.discountRate)
}

func (p *priceCalculator) calculateTax(taxableAmount Money) Money {
    return Money(float64(taxableAmount) * p.taxRate)
}

// White-box tests in same package - test internal logic
func TestOrderValidator_validate(t *testing.T) {
    validator := &orderValidator{
        minItems: 1,
        maxItems: 10,
    }
    
    tests := []struct {
        name    string
        items   []Item
        wantErr bool
    }{
        {
            name:    "valid items",
            items:   []Item{{ID: "1", Price: 100, Quantity: 2}},
            wantErr: false,
        },
        {
            name:    "no items",
            items:   []Item{},
            wantErr: true,
        },
        {
            name:    "too many items",
            items:   make([]Item, 11),
            wantErr: true,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            err := validator.validate(tt.items)
            if (err != nil) != tt.wantErr {
                t.Errorf("validate() error = %v, wantErr %v", err, tt.wantErr)
            }
        })
    }
}

func TestPriceCalculator_calculateSubtotal(t *testing.T) {
    calc := &priceCalculator{
        taxRate:      0.1,
        discountRate: 0.05,
    }
    
    items := []Item{
        {ID: "1", Price: 100, Quantity: 2},
        {ID: "2", Price: 50, Quantity: 1},
    }
    
    got := calc.calculateSubtotal(items)
    want := Money(250) // (100*2) + (50*1)
    
    if got != want {
        t.Errorf("calculateSubtotal() = %v, want %v", got, want)
    }
}

func TestPriceCalculator_calculateTotal(t *testing.T) {
    calc := &priceCalculator{
        taxRate:      0.1,  // 10% tax
        discountRate: 0.05, // 5% discount
    }
    
    items := []Item{
        {ID: "1", Price: 100, Quantity: 2},
    }
    
    // Subtotal: 200
    // Discount: 200 * 0.05 = 10
    // Taxable: 200 - 10 = 190
    // Tax: 190 * 0.1 = 19
    // Total: 200 - 10 + 19 = 209
    
    got := calc.calculateTotal(items)
    want := Money(209)
    
    if got != want {
        t.Errorf("calculateTotal() = %v, want %v", got, want)
    }
}
```

### 2. Black-box Testing for Public APIs

```go
// Separate test package for black-box testing
package domain_test

import (
    "testing"
    
    "your-project/domain"
    "your-project/mocks"
)

// Test only public interface
func TestOrderService_CreateOrder(t *testing.T) {
    // Mock dependencies
    mockRepo := &mocks.OrderRepository{}
    
    service := domain.NewOrderService(mockRepo)
    
    tests := []struct {
        name       string
        customerID string
        items      []domain.Item
        setupMocks func(*mocks.OrderRepository)
        wantErr    bool
    }{
        {
            name:       "successful order creation",
            customerID: "cust-123",
            items: []domain.Item{
                {ID: "item-1", Price: 100, Quantity: 2},
            },
            setupMocks: func(repo *mocks.OrderRepository) {
                repo.On("Save", mock.AnythingOfType("*domain.Order")).Return(nil)
            },
            wantErr: false,
        },
        {
            name:       "empty customer ID",
            customerID: "",
            items: []domain.Item{
                {ID: "item-1", Price: 100, Quantity: 1},
            },
            setupMocks: func(repo *mocks.OrderRepository) {
                // No expectations - should fail before repo call
            },
            wantErr: true,
        },
        {
            name:       "repository error",
            customerID: "cust-123",
            items: []domain.Item{
                {ID: "item-1", Price: 100, Quantity: 1},
            },
            setupMocks: func(repo *mocks.OrderRepository) {
                repo.On("Save", mock.AnythingOfType("*domain.Order")).
                    Return(errors.New("database error"))
            },
            wantErr: true,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Reset mock
            mockRepo.ExpectedCalls = nil
            tt.setupMocks(mockRepo)
            
            order, err := service.CreateOrder(tt.customerID, tt.items)
            
            if (err != nil) != tt.wantErr {
                t.Errorf("CreateOrder() error = %v, wantErr %v", err, tt.wantErr)
                return
            }
            
            if !tt.wantErr && order == nil {
                t.Error("CreateOrder() returned nil order without error")
            }
            
            mockRepo.AssertExpectations(t)
        })
    }
}
```

### 3. Repository Layer - White-box for Data Logic

```go
package repository

import (
    "database/sql"
    "fmt"
    "time"
)

type PostgresOrderRepository struct {
    db *sql.DB
}

// Private methods for complex queries
func (r *PostgresOrderRepository) buildOrderQuery(filters OrderFilters) (string, []interface{}) {
    query := `
        SELECT o.id, o.customer_id, o.status, o.total, o.created_at,
               oi.id, oi.product_id, oi.quantity, oi.price
        FROM orders o
        LEFT JOIN order_items oi ON o.id = oi.order_id
        WHERE 1=1`
    
    args := make([]interface{}, 0)
    argIndex := 1
    
    if filters.CustomerID != "" {
        query += fmt.Sprintf(" AND o.customer_id = $%d", argIndex)
        args = append(args, filters.CustomerID)
        argIndex++
    }
    
    if !filters.StartDate.IsZero() {
        query += fmt.Sprintf(" AND o.created_at >= $%d", argIndex)
        args = append(args, filters.StartDate)
        argIndex++
    }
    
    if !filters.EndDate.IsZero() {
        query += fmt.Sprintf(" AND o.created_at <= $%d", argIndex)
        args = append(args, filters.EndDate)
        argIndex++
    }
    
    query += " ORDER BY o.created_at DESC"
    
    if filters.Limit > 0 {
        query += fmt.Sprintf(" LIMIT $%d", argIndex)
        args = append(args, filters.Limit)
    }
    
    return query, args
}

func (r *PostgresOrderRepository) scanOrderRows(rows *sql.Rows) ([]*Order, error) {
    orderMap := make(map[string]*Order)
    
    for rows.Next() {
        var (
            orderID    string
            customerID string
            status     string
            total      float64
            createdAt  time.Time
            
            itemID    sql.NullString
            productID sql.NullString
            quantity  sql.NullInt64
            price     sql.NullFloat64
        )
        
        err := rows.Scan(
            &orderID, &customerID, &status, &total, &createdAt,
            &itemID, &productID, &quantity, &price,
        )
        if err != nil {
            return nil, fmt.Errorf("scanning order row: %w", err)
        }
        
        order, exists := orderMap[orderID]
        if !exists {
            order = &Order{
                ID:         orderID,
                CustomerID: customerID,
                Status:     OrderStatus(status),
                Total:      Money(total),
                CreatedAt:  createdAt,
                Items:      make([]OrderItem, 0),
            }
            orderMap[orderID] = order
        }
        
        // Add item if it exists
        if itemID.Valid && productID.Valid {
            item := OrderItem{
                ID:        itemID.String,
                ProductID: productID.String,
                Quantity:  int(quantity.Int64),
                Price:     Money(price.Float64),
            }
            order.Items = append(order.Items, item)
        }
    }
    
    // Convert map to slice
    orders := make([]*Order, 0, len(orderMap))
    for _, order := range orderMap {
        orders = append(orders, order)
    }
    
    return orders, nil
}

// White-box tests for complex private methods
func TestPostgresOrderRepository_buildOrderQuery(t *testing.T) {
    repo := &PostgresOrderRepository{}
    
    tests := []struct {
        name           string
        filters        OrderFilters
        expectedQuery  string
        expectedArgs   []interface{}
    }{
        {
            name:    "no filters",
            filters: OrderFilters{},
            expectedQuery: `
        SELECT o.id, o.customer_id, o.status, o.total, o.created_at,
               oi.id, oi.product_id, oi.quantity, oi.price
        FROM orders o
        LEFT JOIN order_items oi ON o.id = oi.order_id
        WHERE 1=1 ORDER BY o.created_at DESC`,
            expectedArgs: []interface{}{},
        },
        {
            name: "customer filter",
            filters: OrderFilters{
                CustomerID: "cust-123",
            },
            expectedQuery: `
        SELECT o.id, o.customer_id, o.status, o.total, o.created_at,
               oi.id, oi.product_id, oi.quantity, oi.price
        FROM orders o
        LEFT JOIN order_items oi ON o.id = oi.order_id
        WHERE 1=1 AND o.customer_id = $1 ORDER BY o.created_at DESC`,
            expectedArgs: []interface{}{"cust-123"},
        },
        {
            name: "date range filter",
            filters: OrderFilters{
                StartDate: time.Date(2023, 1, 1, 0, 0, 0, 0, time.UTC),
                EndDate:   time.Date(2023, 12, 31, 0, 0, 0, 0, time.UTC),
            },
            expectedQuery: `
        SELECT o.id, o.customer_id, o.status, o.total, o.created_at,
               oi.id, oi.product_id, oi.quantity, oi.price
        FROM orders o
        LEFT JOIN order_items oi ON o.id = oi.order_id
        WHERE 1=1 AND o.created_at >= $1 AND o.created_at <= $2 ORDER BY o.created_at DESC`,
            expectedArgs: []interface{}{
                time.Date(2023, 1, 1, 0, 0, 0, 0, time.UTC),
                time.Date(2023, 12, 31, 0, 0, 0, 0, time.UTC),
            },
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            query, args := repo.buildOrderQuery(tt.filters)
            
            // Normalize whitespace for comparison
            normalizedQuery := strings.ReplaceAll(strings.TrimSpace(query), "\n", " ")
            normalizedExpected := strings.ReplaceAll(strings.TrimSpace(tt.expectedQuery), "\n", " ")
            
            if normalizedQuery != normalizedExpected {
                t.Errorf("buildOrderQuery() query = %v, want %v", normalizedQuery, normalizedExpected)
            }
            
            if len(args) != len(tt.expectedArgs) {
                t.Errorf("buildOrderQuery() args length = %v, want %v", len(args), len(tt.expectedArgs))
                return
            }
            
            for i, arg := range args {
                if arg != tt.expectedArgs[i] {
                    t.Errorf("buildOrderQuery() args[%d] = %v, want %v", i, arg, tt.expectedArgs[i])
                }
            }
        })
    }
}
```

### 4. HTTP Handler Layer - Black-box Testing

```go
// handlers_test.go - separate package for black-box testing
package handlers_test

import (
    "bytes"
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "testing"
    
    "your-project/handlers"
    "your-project/mocks"
)

func TestOrderHandler_CreateOrder(t *testing.T) {
    mockService := &mocks.OrderService{}
    handler := handlers.NewOrderHandler(mockService)
    
    tests := []struct {
        name           string
        requestBody    interface{}
        setupMocks     func(*mocks.OrderService)
        expectedStatus int
        expectedBody   map[string]interface{}
    }{
        {
            name: "successful creation",
            requestBody: map[string]interface{}{
                "customer_id": "cust-123",
                "items": []map[string]interface{}{
                    {"product_id": "prod-1", "quantity": 2, "price": 100},
                },
            },
            setupMocks: func(service *mocks.OrderService) {
                expectedOrder := &domain.Order{
                    ID:         "order-123",
                    CustomerID: "cust-123",
                    Status:     domain.OrderStatusPending,
                }
                service.On("CreateOrder", "cust-123", mock.AnythingOfType("[]domain.Item")).
                    Return(expectedOrder, nil)
            },
            expectedStatus: http.StatusCreated,
            expectedBody: map[string]interface{}{
                "id":          "order-123",
                "customer_id": "cust-123",
                "status":      "pending",
            },
        },
        {
            name: "invalid request body",
            requestBody: map[string]interface{}{
                "customer_id": "", // Invalid empty customer ID
                "items":       []map[string]interface{}{},
            },
            setupMocks: func(service *mocks.OrderService) {
                // No expectations - should fail validation
            },
            expectedStatus: http.StatusBadRequest,
            expectedBody: map[string]interface{}{
                "error": "invalid request",
            },
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Setup
            mockService.ExpectedCalls = nil
            tt.setupMocks(mockService)
            
            // Create request
            bodyBytes, _ := json.Marshal(tt.requestBody)
            req := httptest.NewRequest("POST", "/orders", bytes.NewReader(bodyBytes))
            req.Header.Set("Content-Type", "application/json")
            
            // Execute
            w := httptest.NewRecorder()
            handler.CreateOrder(w, req)
            
            // Assert
            assert.Equal(t, tt.expectedStatus, w.Code)
            
            var responseBody map[string]interface{}
            err := json.Unmarshal(w.Body.Bytes(), &responseBody)
            require.NoError(t, err)
            
            for key, expectedValue := range tt.expectedBody {
                assert.Equal(t, expectedValue, responseBody[key])
            }
            
            mockService.AssertExpectations(t)
        })
    }
}
```

### 5. Test Helper Utilities

```go
// testutils/helpers.go - utilities for white-box testing
package testutils

import (
    "reflect"
    "testing"
    "unsafe"
)

// GetPrivateField uses reflection to access private fields for testing
func GetPrivateField(obj interface{}, fieldName string) interface{} {
    v := reflect.ValueOf(obj)
    if v.Kind() == reflect.Ptr {
        v = v.Elem()
    }
    
    field := v.FieldByName(fieldName)
    if !field.IsValid() {
        panic("field not found: " + fieldName)
    }
    
    // Make the field accessible
    field = reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem()
    return field.Interface()
}

// SetPrivateField sets a private field value for testing
func SetPrivateField(obj interface{}, fieldName string, value interface{}) {
    v := reflect.ValueOf(obj)
    if v.Kind() == reflect.Ptr {
        v = v.Elem()
    }
    
    field := v.FieldByName(fieldName)
    if !field.IsValid() {
        panic("field not found: " + fieldName)
    }
    
    field = reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem()
    field.Set(reflect.ValueOf(value))
}

// CallPrivateMethod calls a private method for testing
func CallPrivateMethod(obj interface{}, methodName string, args ...interface{}) []interface{} {
    v := reflect.ValueOf(obj)
    method := v.MethodByName(methodName)
    
    if !method.IsValid() {
        panic("method not found: " + methodName)
    }
    
    argValues := make([]reflect.Value, len(args))
    for i, arg := range args {
        argValues[i] = reflect.ValueOf(arg)
    }
    
    results := method.Call(argValues)
    returnValues := make([]interface{}, len(results))
    for i, result := range results {
        returnValues[i] = result.Interface()
    }
    
    return returnValues
}

// Example usage of test utilities
func TestPrivateMethodAccess(t *testing.T) {
    calc := &priceCalculator{
        taxRate:      0.1,
        discountRate: 0.05,
    }
    
    items := []Item{{Price: 100, Quantity: 2}}
    
    // Call private method
    results := CallPrivateMethod(calc, "calculateSubtotal", items)
    subtotal := results[0].(Money)
    
    expected := Money(200)
    if subtotal != expected {
        t.Errorf("calculateSubtotal() = %v, want %v", subtotal, expected)
    }
}

func TestPrivateFieldAccess(t *testing.T) {
    calc := &priceCalculator{
        taxRate:      0.1,
        discountRate: 0.05,
    }
    
    // Get private field
    taxRate := GetPrivateField(calc, "taxRate").(float64)
    if taxRate != 0.1 {
        t.Errorf("taxRate = %v, want %v", taxRate, 0.1)
    }
    
    // Set private field
    SetPrivateField(calc, "taxRate", 0.15)
    
    newTaxRate := GetPrivateField(calc, "taxRate").(float64)
    if newTaxRate != 0.15 {
        t.Errorf("taxRate after set = %v, want %v", newTaxRate, 0.15)
    }
}
```

### 6. Integration Testing Strategy

```go
// integration_test.go - tests that span multiple layers
func TestOrderCreationFlow(t *testing.T) {
    // Setup real dependencies
    db := setupTestDB(t)
    defer db.Close()
    
    repo := repository.NewPostgresOrderRepository(db)
    service := domain.NewOrderService(repo)
    handler := handlers.NewOrderHandler(service)
    
    // Test the complete flow
    requestBody := map[string]interface{}{
        "customer_id": "cust-123",
        "items": []map[string]interface{}{
            {"product_id": "prod-1", "quantity": 2, "price": 100},
        },
    }
    
    bodyBytes, _ := json.Marshal(requestBody)
    req := httptest.NewRequest("POST", "/orders", bytes.NewReader(bodyBytes))
    req.Header.Set("Content-Type", "application/json")
    
    w := httptest.NewRecorder()
    handler.CreateOrder(w, req)
    
    // Assert HTTP response
    assert.Equal(t, http.StatusCreated, w.Code)
    
    // Assert database state
    var count int
    err := db.QueryRow("SELECT COUNT(*) FROM orders WHERE customer_id = $1", "cust-123").Scan(&count)
    require.NoError(t, err)
    assert.Equal(t, 1, count)
}
```

## Consequences

**Benefits:**
- **Comprehensive coverage**: Tests both public contracts and internal logic
- **Confidence**: High confidence in implementation correctness
- **Debugging**: Easier to isolate issues to specific components
- **Refactoring safety**: Internal tests catch breaking changes

**Trade-offs:**
- **Maintenance overhead**: More tests to maintain and update
- **Coupling**: White-box tests coupled to implementation details
- **Complexity**: Need to understand when to use each approach

**Guidelines:**
1. **Use black-box testing for**: HTTP handlers, public APIs, integration scenarios
2. **Use white-box testing for**: Complex business logic, algorithmic code, data transformations
3. **Avoid testing**: Trivial getters/setters, simple delegation methods
4. **Prefer composition**: Design code to be testable through dependency injection
5. **Use reflection sparingly**: Only when absolutely necessary for complex scenarios

## References

- [Go Testing Package](https://pkg.go.dev/testing)
- [Advanced Go Testing Patterns](https://github.com/golang/go/wiki/TestComments)
- [Testify Framework](https://github.com/stretchr/testify)
