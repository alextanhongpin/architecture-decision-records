# Use Camel-Case for REST Response

## Status

`accepted`

## Context

This decision applies to the backend team responsible for REST-based APIs. It aims to standardize the naming convention for fields in API responses and query strings to use camel-case, aligning with the existing convention in GraphQL and modern JavaScript practices.

## Decision

All fields returned in REST API responses should use camel-case instead of snake-case. This applies to:
- JSON response bodies
- Query string parameters
- Request body fields
- URL path parameters

## Rationale

- **Frontend Consistency**: JavaScript variables and object properties conventionally use camel-case. Standardizing on camel-case eliminates the need for field name conversion on the frontend.
- **Reduced Complexity**: Avoiding conversion between snake-case and camel-case on both client and server sides reduces potential bugs and simplifies the codebase.
- **GraphQL Alignment**: Maintains consistency with existing GraphQL APIs that already use camel-case.
- **Modern Standards**: Most modern REST APIs (including popular services like Stripe, Twitter, GitHub) use camel-case.

## Implementation

### Server-Side (Go)

Use struct tags to serialize Go structs to camel-case JSON:

```go
type User struct {
    ID        int64     `json:"id"`
    FirstName string    `json:"firstName"`
    LastName  string    `json:"lastName"`
    Email     string    `json:"email"`
    CreatedAt time.Time `json:"createdAt"`
    UpdatedAt time.Time `json:"updatedAt"`
}

type CreateUserRequest struct {
    FirstName string `json:"firstName" binding:"required"`
    LastName  string `json:"lastName" binding:"required"`
    Email     string `json:"email" binding:"required,email"`
}

type PaginationQuery struct {
    Page     int `form:"page" binding:"min=1"`
    PageSize int `form:"pageSize" binding:"min=1,max=100"`
    SortBy   string `form:"sortBy"`
    SortDir  string `form:"sortDir" binding:"oneof=asc desc"`
}
```

### API Response Examples

#### User Creation Response
```json
{
  "success": true,
  "data": {
    "id": 123,
    "firstName": "John",
    "lastName": "Doe",
    "email": "john.doe@example.com",
    "createdAt": "2023-12-01T10:30:00Z",
    "updatedAt": "2023-12-01T10:30:00Z"
  }
}
```

#### Error Response
```json
{
  "success": false,
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Invalid input data",
    "details": [
      {
        "field": "firstName",
        "message": "First name is required"
      },
      {
        "field": "email",
        "message": "Email format is invalid"
      }
    ]
  },
  "requestId": "req_123456789"
}
```

#### Paginated List Response
```json
{
  "success": true,
  "data": [
    {
      "id": 123,
      "firstName": "John",
      "lastName": "Doe",
      "email": "john.doe@example.com"
    }
  ],
  "pagination": {
    "page": 1,
    "pageSize": 10,
    "totalCount": 1,
    "totalPages": 1,
    "hasNext": false,
    "hasPrevious": false
  }
}
```

### Query Parameters

Use camel-case for query parameters:

```
GET /api/users?page=1&pageSize=10&sortBy=firstName&sortDir=asc&createdAfter=2023-01-01
```

### URL Path Parameters

Use camel-case for complex path parameters:

```
GET /api/users/{userId}/orders/{orderId}
POST /api/users/{userId}/preferences
```

### Frontend Integration (JavaScript)

With camel-case APIs, frontend code becomes cleaner:

```javascript
// API response can be used directly without conversion
const createUser = async (userData) => {
  const response = await fetch('/api/users', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      firstName: userData.firstName,
      lastName: userData.lastName,
      email: userData.email
    })
  });
  
  const result = await response.json();
  
  if (result.success) {
    // Direct property access without conversion
    console.log(`User created: ${result.data.firstName} ${result.data.lastName}`);
    return result.data;
  } else {
    throw new Error(result.error.message);
  }
};

// Query parameters
const fetchUsers = async (filters) => {
  const params = new URLSearchParams({
    page: filters.page,
    pageSize: filters.pageSize,
    sortBy: filters.sortBy,
    sortDir: filters.sortDir
  });
  
  const response = await fetch(`/api/users?${params}`);
  return response.json();
};
```

## Validation and Testing

### API Contract Testing

Ensure consistent camel-case usage with contract tests:

```go
func TestUserAPIResponseFormat(t *testing.T) {
    // Create test user
    user := &User{
        ID:        123,
        FirstName: "John",
        LastName:  "Doe",
        Email:     "john.doe@example.com",
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
    }
    
    // Serialize to JSON
    jsonBytes, err := json.Marshal(user)
    require.NoError(t, err)
    
    // Parse back to verify field names
    var result map[string]interface{}
    err = json.Unmarshal(jsonBytes, &result)
    require.NoError(t, err)
    
    // Verify camel-case fields exist
    assert.Contains(t, result, "firstName")
    assert.Contains(t, result, "lastName")
    assert.Contains(t, result, "createdAt")
    assert.Contains(t, result, "updatedAt")
    
    // Verify snake-case fields don't exist
    assert.NotContains(t, result, "first_name")
    assert.NotContains(t, result, "last_name")
    assert.NotContains(t, result, "created_at")
    assert.NotContains(t, result, "updated_at")
}
```

### Automated Linting

Add linting rules to enforce camel-case in API responses:

```yaml
# .golangci.yml
linters-settings:
  tagliatelle:
    case:
      rules:
        json: camel
        yaml: camel
        xml: camel
```

## Migration Strategy

For existing APIs using snake-case:

1. **Gradual Migration**: Support both formats during transition period
2. **Versioning**: Introduce new API versions with camel-case
3. **Deprecation**: Announce deprecation timeline for snake-case APIs
4. **Documentation**: Update API documentation with examples

```go
// Support both formats during migration
type UserResponse struct {
    ID        int64     `json:"id"`
    FirstName string    `json:"firstName"`
    LastName  string    `json:"lastName"`
    Email     string    `json:"email"`
    CreatedAt time.Time `json:"createdAt"`
    
    // Deprecated: Use camel-case fields
    FirstNameDeprecated string    `json:"first_name,omitempty"`
    LastNameDeprecated  string    `json:"last_name,omitempty"`
    CreatedAtDeprecated time.Time `json:"created_at,omitempty"`
}
```

## Consequences

### Positive

- **Consistency**: Unified naming convention across all REST APIs
- **Developer Experience**: Reduced cognitive load when switching between frontend and backend
- **Maintainability**: Fewer conversion functions and mapping logic
- **Standards Compliance**: Follows modern REST API conventions

### Negative

- **Migration Effort**: Existing APIs need to be updated or versioned
- **Database Mismatch**: Database columns typically use snake-case, requiring mapping
- **Legacy System Integration**: May require additional conversion for older systems

## Exceptions

- **Database Field Names**: Keep snake-case for database columns as per SQL conventions
- **Environment Variables**: Continue using UPPER_SNAKE_CASE for environment variables
- **Log Fields**: May use snake-case for structured logging compatibility
- **Third-Party Integrations**: Match the naming convention of external APIs when proxying
