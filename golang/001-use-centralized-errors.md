# ADR 001: Use Centralized Errors

## Status

**Deprecated** → **Superseded by ADR 018: Errors Management**

This pattern has been superseded by domain-specific error handling. Each package or layer should define its own errors for better context and maintainability.

## Context

Centralized error management was initially proposed to create a single source of truth for all application errors. However, this approach has proven to create tight coupling and reduce context specificity.

### Problems with Centralized Errors

- **Tight Coupling**: All packages must depend on a central errors package
- **Loss of Context**: Generic errors lose domain-specific meaning
- **Maintenance Overhead**: Changes require updating the central package
- **Import Cycles**: Can create circular dependencies
- **Poor Discoverability**: Hard to find relevant errors for specific domains

## Decision

**DO NOT** centralize all errors in a single package. Instead:

1. **Domain-Specific Errors**: Each domain/package defines its own errors
2. **Error Interfaces**: Use interfaces for error categorization
3. **Error Wrapping**: Use `fmt.Errorf` and `errors.Join` for context
4. **Sentinel Errors**: Define package-level sentinel errors for specific conditions

## Implementation

### Domain-Specific Error Pattern

```go
// package user
package user

import (
    "errors"
    "fmt"
)

// Domain-specific errors
var (
    ErrUserNotFound     = errors.New("user not found")
    ErrInvalidEmail     = errors.New("invalid email format")
    ErrUserAlreadyExists = errors.New("user already exists")
)

// Error types for rich context
type ValidationError struct {
    Field   string
    Value   interface{}
    Message string
}

func (e ValidationError) Error() string {
    return fmt.Sprintf("validation failed for field %s: %s", e.Field, e.Message)
}

type Service struct {
    repo Repository
}

func (s *Service) CreateUser(email string) (*User, error) {
    if !isValidEmail(email) {
        return nil, &ValidationError{
            Field:   "email",
            Value:   email,
            Message: "must be a valid email address",
        }
    }
    
    if exists, err := s.repo.UserExists(email); err != nil {
        return nil, fmt.Errorf("checking user existence: %w", err)
    } else if exists {
        return nil, fmt.Errorf("%w: %s", ErrUserAlreadyExists, email)
    }
    
    user, err := s.repo.Create(email)
    if err != nil {
        return nil, fmt.Errorf("creating user: %w", err)
    }
    
    return user, nil
}
```

### Error Interface Pattern

```go
// package errors
package errors

// Categorization interfaces
type TemporaryError interface {
    error
    Temporary() bool
}

type ValidationError interface {
    error
    ValidationError() bool
}

type NotFoundError interface {
    error
    NotFound() bool
}

// Helper functions
func IsTemporary(err error) bool {
    var te TemporaryError
    return errors.As(err, &te) && te.Temporary()
}

func IsValidation(err error) bool {
    var ve ValidationError
    return errors.As(err, &ve) && ve.ValidationError()
}

func IsNotFound(err error) bool {
    var nfe NotFoundError
    return errors.As(err, &nfe) && nfe.NotFound()
}
```

### Repository Error Pattern

```go
// package repository
package repository

import (
    "database/sql"
    "errors"
    "fmt"
)

var (
    ErrNotFound = errors.New("record not found")
    ErrConflict = errors.New("record conflict")
)

type DatabaseError struct {
    Operation string
    Table     string
    Err       error
}

func (e DatabaseError) Error() string {
    return fmt.Sprintf("database error during %s on %s: %v", 
        e.Operation, e.Table, e.Err)
}

func (e DatabaseError) Unwrap() error {
    return e.Err
}

func (e DatabaseError) Temporary() bool {
    // Check if the underlying error is temporary
    return isTemporaryDBError(e.Err)
}

type UserRepository struct {
    db *sql.DB
}

func (r *UserRepository) GetByID(id string) (*User, error) {
    var user User
    err := r.db.QueryRow("SELECT id, email FROM users WHERE id = ?", id).
        Scan(&user.ID, &user.Email)
    
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return nil, fmt.Errorf("%w: user with id %s", ErrNotFound, id)
        }
        return nil, &DatabaseError{
            Operation: "select",
            Table:     "users",
            Err:       err,
        }
    }
    
    return &user, nil
}
```

### Error Wrapping and Context

```go
// Service layer error handling
func (s *UserService) GetUserProfile(userID string) (*UserProfile, error) {
    user, err := s.userRepo.GetByID(userID)
    if err != nil {
        if errors.Is(err, repository.ErrNotFound) {
            return nil, fmt.Errorf("%w: user profile", user.ErrUserNotFound)
        }
        return nil, fmt.Errorf("fetching user for profile: %w", err)
    }
    
    profile, err := s.profileRepo.GetByUserID(userID)
    if err != nil {
        return nil, fmt.Errorf("fetching user profile: %w", err)
    }
    
    return profile, nil
}
```

### HTTP Error Mapping

```go
// package handler
package handler

import (
    "encoding/json"
    "net/http"
    
    apperrors "myapp/internal/errors"
    "myapp/internal/user"
)

type ErrorResponse struct {
    Error   string            `json:"error"`
    Code    string            `json:"code"`
    Details map[string]string `json:"details,omitempty"`
}

func (h *Handler) handleError(w http.ResponseWriter, err error) {
    var resp ErrorResponse
    var statusCode int
    
    switch {
    case apperrors.IsNotFound(err):
        statusCode = http.StatusNotFound
        resp.Error = "Resource not found"
        resp.Code = "NOT_FOUND"
        
    case apperrors.IsValidation(err):
        statusCode = http.StatusBadRequest
        resp.Error = "Validation error"
        resp.Code = "VALIDATION_ERROR"
        
        // Extract validation details
        var ve user.ValidationError
        if errors.As(err, &ve) {
            resp.Details = map[string]string{
                ve.Field: ve.Message,
            }
        }
        
    case apperrors.IsTemporary(err):
        statusCode = http.StatusServiceUnavailable
        resp.Error = "Service temporarily unavailable"
        resp.Code = "TEMPORARY_ERROR"
        
    default:
        statusCode = http.StatusInternalServerError
        resp.Error = "Internal server error"
        resp.Code = "INTERNAL_ERROR"
        // Log the actual error for debugging
        h.logger.Error("unhandled error", "error", err)
    }
    
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(statusCode)
    json.NewEncoder(w).Encode(resp)
}
```

## Testing

```go
func TestUserService_CreateUser(t *testing.T) {
    tests := []struct {
        name          string
        email         string
        repoErr       error
        expectedErr   error
        expectedType  interface{}
    }{
        {
            name:         "invalid email",
            email:        "invalid-email",
            expectedType: &user.ValidationError{},
        },
        {
            name:        "user already exists",
            email:       "test@example.com",
            repoErr:     user.ErrUserAlreadyExists,
            expectedErr: user.ErrUserAlreadyExists,
        },
        {
            name:         "database error",
            email:        "test@example.com",
            repoErr:      &repository.DatabaseError{},
            expectedType: &repository.DatabaseError{},
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Test implementation
            service := setupTestService(tt.repoErr)
            
            _, err := service.CreateUser(tt.email)
            
            if tt.expectedErr != nil {
                assert.True(t, errors.Is(err, tt.expectedErr))
            }
            
            if tt.expectedType != nil {
                assert.True(t, errors.As(err, tt.expectedType))
            }
        })
    }
}
```

## Best Practices

### Do

- ✅ Define errors close to where they're used
- ✅ Use error wrapping to preserve context
- ✅ Implement error interfaces for categorization
- ✅ Use sentinel errors for known conditions
- ✅ Add rich context to errors
- ✅ Test error scenarios thoroughly

### Don't

- ❌ Create a global errors package
- ❌ Lose error context when wrapping
- ❌ Ignore error types in tests
- ❌ Return generic errors from domain logic
- ❌ Create error hierarchies that are too deep

## Consequences

### Positive

- **Better Context**: Errors contain domain-specific information
- **Loose Coupling**: Packages are independent of central error definitions
- **Maintainability**: Errors evolve with their domains
- **Testability**: Error scenarios are easier to test
- **Debugging**: Rich error context aids troubleshooting

### Negative

- **Potential Duplication**: Similar error patterns across packages
- **More Boilerplate**: Each package defines its own errors
- **Learning Curve**: Developers need to understand error patterns

## Migration Strategy

1. **Identify Current Centralized Errors**: Audit existing error definitions
2. **Map to Domains**: Assign errors to appropriate domain packages
3. **Implement Error Interfaces**: Create categorization interfaces
4. **Update Error Handling**: Modify error handling code to use new patterns
5. **Update Tests**: Ensure error scenarios are properly tested

## References

- [ADR 018: Errors Management](./018-errors-management.md)
- [Go Error Handling](https://go.dev/blog/error-handling-and-go)
- [Working with Errors in Go 1.13](https://go.dev/blog/go1.13-errors)
- [Error Handling in Go](https://dave.cheney.net/2016/04/27/dont-just-check-errors-handle-them-gracefully)
