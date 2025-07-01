# JSON Response Format

## Status
Accepted

## Context
RESTful APIs need consistent response formats to provide predictable interfaces for clients. A well-designed response format should handle both successful and error scenarios while supporting pagination and validation feedback.

## Problem
Without standardized response formats, APIs suffer from:

1. **Inconsistent error handling**: Different endpoints return errors in different formats
2. **Poor client experience**: Clients must handle multiple response patterns
3. **Lack of metadata**: No standardized way to include pagination or additional context
4. **Type safety issues**: Strongly typed languages struggle with varying response structures

## Decision
We will use a standardized JSON response format with the following structure:

### Standard Response Format

```json5
{
  "data": null,           // The actual response data or null on error
  "error": {              // Error information (null on success)
    "code": "",           // Error code for programmatic handling
    "message": "",        // Human-readable error message
    "details": {}         // Additional error context
  },
  "meta": {               // Response metadata
    "timestamp": "",      // ISO 8601 timestamp
    "requestId": "",      // Correlation ID for tracing
    "version": "v1"       // API version
  },
  "pagination": {         // Pagination info (for collection endpoints)
    "hasNextPage": false,
    "hasPrevPage": true,
    "nextCursor": "",
    "prevCursor": "",
    "totalCount": 0       // Optional: total items
  }
}
```

## Implementation

### Response Builder

```go
package response

import (
    "encoding/json"
    "net/http"
    "time"
    
    "github.com/google/uuid"
)

// APIResponse represents the standard API response format
type APIResponse struct {
    Data       interface{}  `json:"data"`
    Error      *APIError    `json:"error"`
    Meta       *Meta        `json:"meta"`
    Pagination *Pagination  `json:"pagination,omitempty"`
}

// APIError represents error information
type APIError struct {
    Code    string      `json:"code"`
    Message string      `json:"message"`
    Details interface{} `json:"details,omitempty"`
}

// Meta represents response metadata
type Meta struct {
    Timestamp string `json:"timestamp"`
    RequestID string `json:"requestId"`
    Version   string `json:"version"`
}

// Pagination represents pagination information
type Pagination struct {
    HasNextPage bool   `json:"hasNextPage"`
    HasPrevPage bool   `json:"hasPrevPage"`
    NextCursor  string `json:"nextCursor,omitempty"`
    PrevCursor  string `json:"prevCursor,omitempty"`
    TotalCount  *int64 `json:"totalCount,omitempty"`
}

// ResponseBuilder helps construct API responses
type ResponseBuilder struct {
    requestID string
    version   string
}

// NewResponseBuilder creates a new response builder
func NewResponseBuilder(requestID, version string) *ResponseBuilder {
    if requestID == "" {
        requestID = uuid.New().String()
    }
    if version == "" {
        version = "v1"
    }
    
    return &ResponseBuilder{
        requestID: requestID,
        version:   version,
    }
}

// Success creates a successful response
func (rb *ResponseBuilder) Success(data interface{}) *APIResponse {
    return &APIResponse{
        Data:  data,
        Error: nil,
        Meta: &Meta{
            Timestamp: time.Now().UTC().Format(time.RFC3339),
            RequestID: rb.requestID,
            Version:   rb.version,
        },
    }
}

// SuccessWithPagination creates a successful response with pagination
func (rb *ResponseBuilder) SuccessWithPagination(data interface{}, pagination *Pagination) *APIResponse {
    response := rb.Success(data)
    response.Pagination = pagination
    return response
}

// Error creates an error response
func (rb *ResponseBuilder) Error(code, message string, details interface{}) *APIResponse {
    return &APIResponse{
        Data: nil,
        Error: &APIError{
            Code:    code,
            Message: message,
            Details: details,
        },
        Meta: &Meta{
            Timestamp: time.Now().UTC().Format(time.RFC3339),
            RequestID: rb.requestID,
            Version:   rb.version,
        },
    }
}

// ValidationError creates a validation error response
func (rb *ResponseBuilder) ValidationError(validationErrors map[string][]string) *APIResponse {
    return rb.Error(
        "VALIDATION_FAILED",
        "Request validation failed",
        map[string]interface{}{
            "validationErrors": validationErrors,
        },
    )
}

// WriteJSON writes the response as JSON to the HTTP response writer
func (r *APIResponse) WriteJSON(w http.ResponseWriter, statusCode int) error {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(statusCode)
    
    return json.NewEncoder(w).Encode(r)
}
```

### HTTP Handler Integration

```go
package handlers

import (
    "context"
    "encoding/json"
    "net/http"
    "strconv"
    
    "your-app/pkg/response"
    "your-app/pkg/middleware"
)

type UserHandler struct {
    userService UserService
}

type User struct {
    ID       int64  `json:"id"`
    Name     string `json:"name"`
    Email    string `json:"email"`
    Created  string `json:"created"`
}

type CreateUserRequest struct {
    Name  string `json:"name" validate:"required,min=2,max=100"`
    Email string `json:"email" validate:"required,email"`
}

// GetUser handles GET /users/{id}
func (h *UserHandler) GetUser(w http.ResponseWriter, r *http.Request) {
    rb := response.NewResponseBuilder(
        middleware.GetRequestID(r.Context()),
        "v1",
    )
    
    // Extract user ID from URL
    userID, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
    if err != nil {
        rb.Error("INVALID_USER_ID", "Invalid user ID format", nil).
            WriteJSON(w, http.StatusBadRequest)
        return
    }
    
    // Fetch user
    user, err := h.userService.GetUser(r.Context(), userID)
    if err != nil {
        switch err {
        case ErrUserNotFound:
            rb.Error("USER_NOT_FOUND", "User not found", nil).
                WriteJSON(w, http.StatusNotFound)
        default:
            rb.Error("INTERNAL_ERROR", "An internal error occurred", nil).
                WriteJSON(w, http.StatusInternalServerError)
        }
        return
    }
    
    // Return success response
    rb.Success(user).WriteJSON(w, http.StatusOK)
}

// CreateUser handles POST /users
func (h *UserHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
    rb := response.NewResponseBuilder(
        middleware.GetRequestID(r.Context()),
        "v1",
    )
    
    var req CreateUserRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        rb.Error("INVALID_JSON", "Invalid JSON format", nil).
            WriteJSON(w, http.StatusBadRequest)
        return
    }
    
    // Validate request
    if validationErrors := validateCreateUserRequest(req); len(validationErrors) > 0 {
        rb.ValidationError(validationErrors).WriteJSON(w, http.StatusBadRequest)
        return
    }
    
    // Create user
    user, err := h.userService.CreateUser(r.Context(), req.Name, req.Email)
    if err != nil {
        switch err {
        case ErrEmailAlreadyExists:
            rb.Error("EMAIL_EXISTS", "Email already exists", nil).
                WriteJSON(w, http.StatusConflict)
        default:
            rb.Error("INTERNAL_ERROR", "An internal error occurred", nil).
                WriteJSON(w, http.StatusInternalServerError)
        }
        return
    }
    
    // Return created user
    rb.Success(user).WriteJSON(w, http.StatusCreated)
}
```

### Error Code Registry

```go
package response

// Standard error codes
const (
    // Client errors (4xx)
    ErrCodeBadRequest          = "BAD_REQUEST"
    ErrCodeUnauthorized        = "UNAUTHORIZED"
    ErrCodeForbidden          = "FORBIDDEN"
    ErrCodeNotFound           = "NOT_FOUND"
    ErrCodeConflict           = "CONFLICT"
    ErrCodeValidationFailed   = "VALIDATION_FAILED"
    ErrCodeRateLimited        = "RATE_LIMITED"
    
    // Server errors (5xx)
    ErrCodeInternalError      = "INTERNAL_ERROR"
    ErrCodeServiceUnavailable = "SERVICE_UNAVAILABLE"
    ErrCodeTimeout            = "TIMEOUT"
    
    // Business logic errors
    ErrCodeUserNotFound       = "USER_NOT_FOUND"
    ErrCodeEmailExists        = "EMAIL_EXISTS"
    ErrCodeInsufficientFunds  = "INSUFFICIENT_FUNDS"
    ErrCodeExpiredToken       = "EXPIRED_TOKEN"
)

// ErrorCodeToHTTPStatus maps error codes to HTTP status codes
var ErrorCodeToHTTPStatus = map[string]int{
    ErrCodeBadRequest:          http.StatusBadRequest,
    ErrCodeUnauthorized:        http.StatusUnauthorized,
    ErrCodeForbidden:          http.StatusForbidden,
    ErrCodeNotFound:           http.StatusNotFound,
    ErrCodeConflict:           http.StatusConflict,
    ErrCodeValidationFailed:   http.StatusBadRequest,
    ErrCodeRateLimited:        http.StatusTooManyRequests,
    ErrCodeInternalError:      http.StatusInternalServerError,
    ErrCodeServiceUnavailable: http.StatusServiceUnavailable,
    ErrCodeTimeout:            http.StatusGatewayTimeout,
    ErrCodeUserNotFound:       http.StatusNotFound,
    ErrCodeEmailExists:        http.StatusConflict,
    ErrCodeInsufficientFunds:  http.StatusBadRequest,
    ErrCodeExpiredToken:       http.StatusUnauthorized,
}
```

## Response Examples

### Success Response

```json
{
  "data": {
    "id": 123,
    "name": "John Doe",
    "email": "john@example.com",
    "created": "2024-01-15T10:30:00Z"
  },
  "error": null,
  "meta": {
    "timestamp": "2024-01-15T10:30:45Z",
    "requestId": "550e8400-e29b-41d4-a716-446655440000",
    "version": "v1"
  }
}
```

### Error Response

```json
{
  "data": null,
  "error": {
    "code": "USER_NOT_FOUND",
    "message": "User not found",
    "details": null
  },
  "meta": {
    "timestamp": "2024-01-15T10:30:45Z",
    "requestId": "550e8400-e29b-41d4-a716-446655440000",
    "version": "v1"
  }
}
```

### Validation Error Response

```json
{
  "data": null,
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "Request validation failed",
    "details": {
      "validationErrors": {
        "name": ["Name is required"],
        "email": ["Email format is invalid"]
      }
    }
  },
  "meta": {
    "timestamp": "2024-01-15T10:30:45Z",
    "requestId": "550e8400-e29b-41d4-a716-446655440000",
    "version": "v1"
  }
}
```

### Paginated Response

```json
{
  "data": [
    {
      "id": 1,
      "name": "John Doe",
      "email": "john@example.com"
    },
    {
      "id": 2,
      "name": "Jane Smith",
      "email": "jane@example.com"
    }
  ],
  "error": null,
  "meta": {
    "timestamp": "2024-01-15T10:30:45Z",
    "requestId": "550e8400-e29b-41d4-a716-446655440000",
    "version": "v1"
  },
  "pagination": {
    "hasNextPage": true,
    "hasPrevPage": false,
    "nextCursor": "eyJpZCI6MiwibmFtZSI6IkphbmUgU21pdGgifQ==",
    "prevCursor": "",
    "totalCount": 50
  }
}
```

## Special Cases

### Minimal Error Responses

For common errors (401, 403, 404), we can return minimal responses:

```go
// Simplified error responses for common cases
func (rb *ResponseBuilder) MinimalError(statusCode int) *APIResponse {
    var code, message string
    
    switch statusCode {
    case http.StatusUnauthorized:
        code = "UNAUTHORIZED"
        message = "Authentication required"
    case http.StatusForbidden:
        code = "FORBIDDEN"
        message = "Access denied"
    case http.StatusNotFound:
        code = "NOT_FOUND"
        message = "Resource not found"
    default:
        code = "ERROR"
        message = "An error occurred"
    }
    
    return &APIResponse{
        Data: nil,
        Error: &APIError{
            Code:    code,
            Message: message,
        },
        Meta: &Meta{
            Timestamp: time.Now().UTC().Format(time.RFC3339),
            RequestID: rb.requestID,
            Version:   rb.version,
        },
    }
}
```

## Consequences

### Advantages
- **Consistent client experience**: Predictable response format across all endpoints
- **Better error handling**: Structured error information with codes and details
- **Enhanced debugging**: Request IDs and metadata aid in troubleshooting
- **Type safety**: Strongly typed responses improve client-side development
- **Pagination support**: Built-in pagination metadata for collection endpoints

### Disadvantages
- **Response size overhead**: Additional metadata increases response size
- **Breaking changes**: Changing response format requires client updates
- **Over-engineering**: Simple endpoints may not need full response structure
- **Learning curve**: Teams need to understand the response format convention

## Alternative Considered

### Type-specific responses
```json
{
  "type": "user",
  "user": {},
  "error": {}
}
```

**Rejected because:**
- Requires separate type handling for each entity
- More complex for strongly typed languages
- Inconsistent data access patterns
- Harder to create generic client libraries
