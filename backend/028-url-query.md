
# URL Query Parameter Design

## Status
Accepted

## Context
API endpoints often need to support complex filtering, sorting, and querying capabilities through URL query parameters. A well-designed query parameter system provides flexibility while maintaining simplicity and URL-safety.

## Problem
Without standardized query parameter conventions, APIs suffer from:

1. **Inconsistent filtering**: Different endpoints use different parameter formats
2. **Limited expressiveness**: Simple key-value pairs cannot express complex queries
3. **URL encoding issues**: Special characters in query values cause problems
4. **Poor discoverability**: Clients cannot easily understand available query options
5. **Type safety**: No clear way to handle different data types in queries

## Decision
We will implement a standardized URL query parameter system that supports:

- **Comparison operators** for numeric and date filtering
- **Logical operators** for combining conditions
- **Collection operations** for array-like queries
- **Standardized naming conventions** for common operations
- **Type-safe parsing** with proper validation

## Implementation

### Query Parameter Conventions

#### Basic Filtering
```
GET /users?name=john&email=john@example.com
GET /products?category=electronics&price=100
```

#### Comparison Operators
```
GET /products?price_gte=100&price_lte=500
GET /orders?created_after=2024-01-01&created_before=2024-12-31
GET /users?age_gt=18&age_lt=65
```

#### Collection Operations
```
GET /products?category_in=electronics,clothing,books
GET /users?status_nin=inactive,banned
GET /orders?tags_contains=urgent
```

#### Sorting and Pagination
```
GET /users?sort=name&order=asc&page=1&limit=20
GET /products?sort=price,created_at&order=desc,asc
```

### Go Implementation

```go
package query

import (
    "fmt"
    "net/url"
    "reflect"
    "strconv"
    "strings"
    "time"
)

// QueryParser handles URL query parameter parsing
type QueryParser struct {
    values url.Values
}

// NewQueryParser creates a new query parser
func NewQueryParser(values url.Values) *QueryParser {
    return &QueryParser{values: values}
}

// FilterCondition represents a single filter condition
type FilterCondition struct {
    Field    string
    Operator string
    Value    interface{}
}

// SortCondition represents sorting criteria
type SortCondition struct {
    Field string
    Order string // "asc" or "desc"
}

// PaginationParams represents pagination parameters
type PaginationParams struct {
    Page   int
    Limit  int
    Offset int
}

// ParseFilters extracts filter conditions from query parameters
func (qp *QueryParser) ParseFilters() ([]FilterCondition, error) {
    var conditions []FilterCondition
    
    for key, values := range qp.values {
        if len(values) == 0 {
            continue
        }
        
        // Skip pagination and sorting parameters
        if isSpecialParam(key) {
            continue
        }
        
        field, operator := parseFieldOperator(key)
        value := values[0] // Take first value
        
        // Parse value based on operator
        parsedValue, err := parseValue(value, operator)
        if err != nil {
            return nil, fmt.Errorf("invalid value for %s: %w", key, err)
        }
        
        conditions = append(conditions, FilterCondition{
            Field:    field,
            Operator: operator,
            Value:    parsedValue,
        })
    }
    
    return conditions, nil
}

// ParseSort extracts sorting conditions from query parameters
func (qp *QueryParser) ParseSort() ([]SortCondition, error) {
    sortFields := qp.values.Get("sort")
    orderFields := qp.values.Get("order")
    
    if sortFields == "" {
        return nil, nil
    }
    
    fields := strings.Split(sortFields, ",")
    orders := strings.Split(orderFields, ",")
    
    // Default to ascending if order not specified
    if len(orders) == 1 && orders[0] == "" {
        orders = []string{"asc"}
    }
    
    var conditions []SortCondition
    for i, field := range fields {
        field = strings.TrimSpace(field)
        if field == "" {
            continue
        }
        
        order := "asc" // default
        if i < len(orders) && orders[i] != "" {
            order = strings.ToLower(strings.TrimSpace(orders[i]))
            if order != "asc" && order != "desc" {
                return nil, fmt.Errorf("invalid sort order: %s", order)
            }
        }
        
        conditions = append(conditions, SortCondition{
            Field: field,
            Order: order,
        })
    }
    
    return conditions, nil
}

// ParsePagination extracts pagination parameters
func (qp *QueryParser) ParsePagination() (PaginationParams, error) {
    params := PaginationParams{
        Page:  1,  // default
        Limit: 20, // default
    }
    
    if pageStr := qp.values.Get("page"); pageStr != "" {
        page, err := strconv.Atoi(pageStr)
        if err != nil || page < 1 {
            return params, fmt.Errorf("invalid page number: %s", pageStr)
        }
        params.Page = page
    }
    
    if limitStr := qp.values.Get("limit"); limitStr != "" {
        limit, err := strconv.Atoi(limitStr)
        if err != nil || limit < 1 || limit > 100 {
            return params, fmt.Errorf("invalid limit: %s (must be 1-100)", limitStr)
        }
        params.Limit = limit
    }
    
    params.Offset = (params.Page - 1) * params.Limit
    
    return params, nil
}

// parseFieldOperator extracts field name and operator from parameter key
func parseFieldOperator(key string) (field, operator string) {
    // Check for common operators
    operators := []string{
        "_gte", "_gt", "_lte", "_lt", "_ne", "_in", "_nin", 
        "_contains", "_starts_with", "_ends_with", "_regex",
        "_after", "_before", "_between",
    }
    
    for _, op := range operators {
        if strings.HasSuffix(key, op) {
            return strings.TrimSuffix(key, op), op[1:] // remove underscore
        }
    }
    
    return key, "eq" // default to equality
}

// parseValue parses string value based on operator
func parseValue(value, operator string) (interface{}, error) {
    switch operator {
    case "in", "nin":
        return strings.Split(value, ","), nil
    case "between":
        parts := strings.Split(value, ",")
        if len(parts) != 2 {
            return nil, fmt.Errorf("between operator requires two values")
        }
        return parts, nil
    case "gt", "gte", "lt", "lte":
        // Try to parse as number first, then as date
        if num, err := strconv.ParseFloat(value, 64); err == nil {
            return num, nil
        }
        if date, err := time.Parse(time.RFC3339, value); err == nil {
            return date, nil
        }
        if date, err := time.Parse("2006-01-02", value); err == nil {
            return date, nil
        }
        return value, nil // Keep as string
    case "after", "before":
        if date, err := time.Parse(time.RFC3339, value); err == nil {
            return date, nil
        }
        if date, err := time.Parse("2006-01-02", value); err == nil {
            return date, nil
        }
        return nil, fmt.Errorf("invalid date format")
    default:
        return value, nil
    }
}

// isSpecialParam checks if parameter is used for pagination/sorting
func isSpecialParam(key string) bool {
    specialParams := []string{"page", "limit", "sort", "order", "offset"}
    for _, param := range specialParams {
        if key == param {
            return true
        }
    }
    return false
}
```

### HTTP Handler Integration

```go
package handlers

import (
    "net/http"
    "strconv"
    
    "github.com/gin-gonic/gin"
    "your-app/pkg/query"
)

type ProductHandler struct {
    productService ProductService
}

// ListProducts handles GET /products with query parameters
func (h *ProductHandler) ListProducts(c *gin.Context) {
    // Parse query parameters
    parser := query.NewQueryParser(c.Request.URL.Query())
    
    // Extract filters
    filters, err := parser.ParseFilters()
    if err != nil {
        c.JSON(http.StatusBadRequest, gin.H{
            "error": "Invalid filter parameters",
            "details": err.Error(),
        })
        return
    }
    
    // Extract sorting
    sorting, err := parser.ParseSort()
    if err != nil {
        c.JSON(http.StatusBadRequest, gin.H{
            "error": "Invalid sort parameters", 
            "details": err.Error(),
        })
        return
    }
    
    // Extract pagination
    pagination, err := parser.ParsePagination()
    if err != nil {
        c.JSON(http.StatusBadRequest, gin.H{
            "error": "Invalid pagination parameters",
            "details": err.Error(),
        })
        return
    }
    
    // Build query options
    opts := ProductQueryOptions{
        Filters:    filters,
        Sorting:    sorting,
        Pagination: pagination,
    }
    
    // Execute query
    products, total, err := h.productService.ListProducts(c.Request.Context(), opts)
    if err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{
            "error": "Failed to fetch products",
        })
        return
    }
    
    // Calculate pagination metadata
    totalPages := (total + int64(pagination.Limit) - 1) / int64(pagination.Limit)
    hasNext := pagination.Page < int(totalPages)
    hasPrev := pagination.Page > 1
    
    c.JSON(http.StatusOK, gin.H{
        "data": products,
        "pagination": gin.H{
            "page":        pagination.Page,
            "limit":       pagination.Limit,
            "total":       total,
            "total_pages": totalPages,
            "has_next":    hasNext,
            "has_prev":    hasPrev,
        },
    })
}
```

### SQL Query Builder

```go
package query

import (
    "fmt"
    "strings"
    "time"
)

// SQLBuilder builds SQL queries from filter conditions
type SQLBuilder struct {
    tableName string
    conditions []FilterCondition
    sorts []SortCondition
    pagination PaginationParams
}

// NewSQLBuilder creates a new SQL builder
func NewSQLBuilder(tableName string) *SQLBuilder {
    return &SQLBuilder{
        tableName: tableName,
    }
}

// WithFilters adds filter conditions
func (b *SQLBuilder) WithFilters(conditions []FilterCondition) *SQLBuilder {
    b.conditions = conditions
    return b
}

// WithSorting adds sorting conditions
func (b *SQLBuilder) WithSorting(sorts []SortCondition) *SQLBuilder {
    b.sorts = sorts
    return b
}

// WithPagination adds pagination
func (b *SQLBuilder) WithPagination(pagination PaginationParams) *SQLBuilder {
    b.pagination = pagination
    return b
}

// BuildSelect builds a SELECT query
func (b *SQLBuilder) BuildSelect(fields []string) (string, []interface{}, error) {
    var query strings.Builder
    var args []interface{}
    
    // SELECT clause
    query.WriteString("SELECT ")
    if len(fields) == 0 {
        query.WriteString("*")
    } else {
        query.WriteString(strings.Join(fields, ", "))
    }
    
    query.WriteString(" FROM ")
    query.WriteString(b.tableName)
    
    // WHERE clause
    if len(b.conditions) > 0 {
        whereClause, whereArgs, err := b.buildWhereClause()
        if err != nil {
            return "", nil, err
        }
        query.WriteString(" WHERE ")
        query.WriteString(whereClause)
        args = append(args, whereArgs...)
    }
    
    // ORDER BY clause
    if len(b.sorts) > 0 {
        query.WriteString(" ORDER BY ")
        orderParts := make([]string, len(b.sorts))
        for i, sort := range b.sorts {
            orderParts[i] = fmt.Sprintf("%s %s", sort.Field, strings.ToUpper(sort.Order))
        }
        query.WriteString(strings.Join(orderParts, ", "))
    }
    
    // LIMIT and OFFSET
    if b.pagination.Limit > 0 {
        query.WriteString(fmt.Sprintf(" LIMIT %d", b.pagination.Limit))
        if b.pagination.Offset > 0 {
            query.WriteString(fmt.Sprintf(" OFFSET %d", b.pagination.Offset))
        }
    }
    
    return query.String(), args, nil
}

// buildWhereClause builds the WHERE clause
func (b *SQLBuilder) buildWhereClause() (string, []interface{}, error) {
    var parts []string
    var args []interface{}
    
    for _, condition := range b.conditions {
        part, condArgs, err := b.buildCondition(condition)
        if err != nil {
            return "", nil, err
        }
        parts = append(parts, part)
        args = append(args, condArgs...)
    }
    
    return strings.Join(parts, " AND "), args, nil
}

// buildCondition builds a single condition
func (b *SQLBuilder) buildCondition(condition FilterCondition) (string, []interface{}, error) {
    field := condition.Field
    operator := condition.Operator
    value := condition.Value
    
    switch operator {
    case "eq":
        return fmt.Sprintf("%s = ?", field), []interface{}{value}, nil
    case "ne":
        return fmt.Sprintf("%s != ?", field), []interface{}{value}, nil
    case "gt":
        return fmt.Sprintf("%s > ?", field), []interface{}{value}, nil
    case "gte":
        return fmt.Sprintf("%s >= ?", field), []interface{}{value}, nil
    case "lt":
        return fmt.Sprintf("%s < ?", field), []interface{}{value}, nil
    case "lte":
        return fmt.Sprintf("%s <= ?", field), []interface{}{value}, nil
    case "in":
        values, ok := value.([]string)
        if !ok {
            return "", nil, fmt.Errorf("invalid value type for IN operator")
        }
        placeholders := strings.Repeat("?,", len(values))
        placeholders = strings.TrimRight(placeholders, ",")
        args := make([]interface{}, len(values))
        for i, v := range values {
            args[i] = v
        }
        return fmt.Sprintf("%s IN (%s)", field, placeholders), args, nil
    case "nin":
        values, ok := value.([]string)
        if !ok {
            return "", nil, fmt.Errorf("invalid value type for NOT IN operator")
        }
        placeholders := strings.Repeat("?,", len(values))
        placeholders = strings.TrimRight(placeholders, ",")
        args := make([]interface{}, len(values))
        for i, v := range values {
            args[i] = v
        }
        return fmt.Sprintf("%s NOT IN (%s)", field, placeholders), args, nil
    case "contains":
        return fmt.Sprintf("%s LIKE ?", field), []interface{}{"%" + fmt.Sprintf("%v", value) + "%"}, nil
    case "starts_with":
        return fmt.Sprintf("%s LIKE ?", field), []interface{}{fmt.Sprintf("%v", value) + "%"}, nil
    case "ends_with":
        return fmt.Sprintf("%s LIKE ?", field), []interface{}{"%" + fmt.Sprintf("%v", value)}, nil
    case "between":
        values, ok := value.([]string)
        if !ok || len(values) != 2 {
            return "", nil, fmt.Errorf("invalid value for BETWEEN operator")
        }
        return fmt.Sprintf("%s BETWEEN ? AND ?", field), []interface{}{values[0], values[1]}, nil
    case "after":
        return fmt.Sprintf("%s > ?", field), []interface{}{value}, nil
    case "before":
        return fmt.Sprintf("%s < ?", field), []interface{}{value}, nil
    default:
        return "", nil, fmt.Errorf("unsupported operator: %s", operator)
    }
}
```

### Query Examples

#### Product Filtering
```
GET /products?category=electronics&price_gte=100&price_lte=500
GET /products?name_contains=phone&brand_in=apple,samsung
GET /products?created_after=2024-01-01&status_ne=inactive
```

#### User Queries
```
GET /users?age_gt=18&age_lt=65&status=active
GET /users?email_ends_with=@company.com&role_in=admin,manager
GET /users?created_between=2024-01-01,2024-12-31
```

#### Complex Sorting
```
GET /products?sort=price,rating,created_at&order=asc,desc,desc
GET /users?sort=last_login&order=desc&limit=50
```

### Validation and Security

```go
package query

import (
    "fmt"
    "regexp"
    "strings"
)

// QueryValidator validates query parameters
type QueryValidator struct {
    allowedFields map[string]FieldSpec
    maxLimit      int
}

// FieldSpec defines validation rules for a field
type FieldSpec struct {
    Type            string   // "string", "int", "float", "date", "bool"
    AllowedOperators []string
    Required        bool
    MaxLength       int
}

// NewQueryValidator creates a new validator
func NewQueryValidator(allowedFields map[string]FieldSpec, maxLimit int) *QueryValidator {
    return &QueryValidator{
        allowedFields: allowedFields,
        maxLimit:      maxLimit,
    }
}

// ValidateFilters validates filter conditions
func (v *QueryValidator) ValidateFilters(conditions []FilterCondition) error {
    for _, condition := range conditions {
        if err := v.validateField(condition.Field, condition.Operator); err != nil {
            return err
        }
        
        if err := v.validateValue(condition.Field, condition.Value); err != nil {
            return err
        }
    }
    return nil
}

// ValidateSorting validates sort conditions
func (v *QueryValidator) ValidateSorting(sorts []SortCondition) error {
    for _, sort := range sorts {
        if _, exists := v.allowedFields[sort.Field]; !exists {
            return fmt.Errorf("sorting not allowed on field: %s", sort.Field)
        }
    }
    return nil
}

// ValidatePagination validates pagination parameters
func (v *QueryValidator) ValidatePagination(pagination PaginationParams) error {
    if pagination.Page < 1 {
        return fmt.Errorf("page must be >= 1")
    }
    if pagination.Limit < 1 || pagination.Limit > v.maxLimit {
        return fmt.Errorf("limit must be between 1 and %d", v.maxLimit)
    }
    return nil
}

func (v *QueryValidator) validateField(field, operator string) error {
    spec, exists := v.allowedFields[field]
    if !exists {
        return fmt.Errorf("field not allowed: %s", field)
    }
    
    if len(spec.AllowedOperators) > 0 {
        allowed := false
        for _, op := range spec.AllowedOperators {
            if op == operator {
                allowed = true
                break
            }
        }
        if !allowed {
            return fmt.Errorf("operator %s not allowed for field %s", operator, field)
        }
    }
    
    return nil
}

func (v *QueryValidator) validateValue(field string, value interface{}) error {
    spec := v.allowedFields[field]
    
    switch spec.Type {
    case "string":
        str, ok := value.(string)
        if !ok {
            return fmt.Errorf("field %s must be string", field)
        }
        if spec.MaxLength > 0 && len(str) > spec.MaxLength {
            return fmt.Errorf("field %s exceeds max length %d", field, spec.MaxLength)
        }
        // Check for SQL injection patterns
        if containsSQLInjection(str) {
            return fmt.Errorf("field %s contains invalid characters", field)
        }
    }
    
    return nil
}

// containsSQLInjection checks for basic SQL injection patterns
func containsSQLInjection(value string) bool {
    dangerousPatterns := []string{
        `'`,
        `"`,
        `;`,
        `--`,
        `/*`,
        `*/`,
        `xp_`,
        `sp_`,
        `union\s+select`,
        `drop\s+table`,
        `insert\s+into`,
        `delete\s+from`,
        `update\s+.*\s+set`,
    }
    
    lowerValue := strings.ToLower(value)
    for _, pattern := range dangerousPatterns {
        matched, _ := regexp.MatchString(pattern, lowerValue)
        if matched {
            return true
        }
    }
    return false
}
```

## Usage Examples

### Handler with Validation

```go
func (h *ProductHandler) ListProducts(c *gin.Context) {
    // Define allowed fields for products
    allowedFields := map[string]query.FieldSpec{
        "name": {
            Type: "string",
            AllowedOperators: []string{"eq", "contains", "starts_with"},
            MaxLength: 100,
        },
        "price": {
            Type: "float",
            AllowedOperators: []string{"eq", "gt", "gte", "lt", "lte", "between"},
        },
        "category": {
            Type: "string", 
            AllowedOperators: []string{"eq", "in", "nin"},
        },
        "created_at": {
            Type: "date",
            AllowedOperators: []string{"gt", "gte", "lt", "lte", "after", "before"},
        },
    }
    
    validator := query.NewQueryValidator(allowedFields, 100)
    parser := query.NewQueryParser(c.Request.URL.Query())
    
    // Parse and validate
    filters, err := parser.ParseFilters()
    if err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
        return
    }
    
    if err := validator.ValidateFilters(filters); err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
        return
    }
    
    // Continue with query execution...
}
```

## Best Practices

1. **Consistent naming**: Use snake_case for parameter names
2. **Clear operators**: Use descriptive operator names (gte, not gte)
3. **Input validation**: Always validate and sanitize query parameters
4. **Pagination limits**: Set reasonable maximum limits
5. **Field whitelisting**: Only allow querying on intended fields
6. **SQL injection prevention**: Sanitize string values
7. **Performance**: Add database indexes for commonly queried fields
8. **Documentation**: Document available query parameters in API docs

## Consequences

### Advantages
- **Expressive querying**: Support for complex filtering and sorting
- **Consistent API**: Standardized parameter format across endpoints
- **Type safety**: Proper parsing and validation of different data types
- **Security**: Built-in protection against SQL injection
- **Performance**: Efficient SQL generation from query parameters

### Disadvantages
- **Complexity**: More complex than simple key-value parameters
- **URL length**: Complex queries can result in very long URLs
- **Learning curve**: Developers need to understand the query syntax
- **Validation overhead**: Additional validation logic required
- **Potential abuse**: Complex queries can be expensive to execute

## References
- [REST API Query Parameters Best Practices](https://restfulapi.net/resource-naming/)
- [GraphQL Cursor Connections Specification](https://relay.dev/graphql/connections.htm)
- [OData URL Conventions](https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part2-url-conventions.html)
