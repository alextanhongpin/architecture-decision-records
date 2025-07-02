# ADR 015: Better API Integration

## Status

**Accepted**

## Context

When integrating with third-party APIs, we need robust patterns that handle data transformation, error handling, retries, and testing while maintaining clean separation between external dependencies and business logic.

### Problem Statement

API integrations often suffer from:

- **Tight coupling**: Business logic mixed with HTTP concerns
- **Poor error handling**: Generic errors without context
- **Testing difficulties**: Hard to mock external dependencies
- **Data transformation issues**: Inconsistent mapping between API and domain models
- **Resilience gaps**: No retry, timeout, or circuit breaker patterns

## Decision

We will implement API integrations using:

1. **API Client abstraction** with clean interfaces
2. **Domain model separation** from API responses
3. **Comprehensive error handling** with typed errors
4. **Resilience patterns** (retries, timeouts, circuit breakers)
5. **Testability** with mock servers and contract testing

## Implementation

### API Client Pattern

```go
package client

import (
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "time"
)

// APIClient provides a configurable HTTP client for API interactions
type APIClient struct {
    baseURL    string
    httpClient *http.Client
    headers    map[string]string
    retrier    *Retrier
    limiter    RateLimiter
}

// Config configures the API client
type Config struct {
    BaseURL     string
    Timeout     time.Duration
    MaxRetries  int
    RetryDelay  time.Duration
    RateLimit   int // requests per second
    Headers     map[string]string
}

// NewAPIClient creates a new API client
func NewAPIClient(config Config) *APIClient {
    httpClient := &http.Client{
        Timeout: config.Timeout,
        Transport: &http.Transport{
            MaxIdleConns:        100,
            MaxIdleConnsPerHost: 10,
            IdleConnTimeout:     90 * time.Second,
        },
    }
    
    retrier := NewRetrier(config.MaxRetries, config.RetryDelay)
    limiter := NewTokenBucketLimiter(config.RateLimit)
    
    return &APIClient{
        baseURL:    config.BaseURL,
        httpClient: httpClient,
        headers:    config.Headers,
        retrier:    retrier,
        limiter:    limiter,
    }
}

// Request represents an API request
type Request struct {
    Method      string
    Path        string
    Body        interface{}
    Headers     map[string]string
    QueryParams map[string]string
}

// Response represents an API response
type Response struct {
    StatusCode int
    Headers    http.Header
    Body       []byte
}

// Do executes an HTTP request with retries and rate limiting
func (c *APIClient) Do(ctx context.Context, req Request) (*Response, error) {
    // Apply rate limiting
    if err := c.limiter.Wait(ctx); err != nil {
        return nil, fmt.Errorf("rate limit exceeded: %w", err)
    }
    
    // Execute with retries
    return c.retrier.Do(ctx, func() (*Response, error) {
        return c.executeRequest(ctx, req)
    })
}

// executeRequest performs the actual HTTP request
func (c *APIClient) executeRequest(ctx context.Context, req Request) (*Response, error) {
    url := c.baseURL + req.Path
    
    // Prepare request body
    var body io.Reader
    if req.Body != nil {
        jsonData, err := json.Marshal(req.Body)
        if err != nil {
            return nil, fmt.Errorf("marshaling request body: %w", err)
        }
        body = bytes.NewReader(jsonData)
    }
    
    // Create HTTP request
    httpReq, err := http.NewRequestWithContext(ctx, req.Method, url, body)
    if err != nil {
        return nil, fmt.Errorf("creating HTTP request: %w", err)
    }
    
    // Add headers
    for key, value := range c.headers {
        httpReq.Header.Set(key, value)
    }
    for key, value := range req.Headers {
        httpReq.Header.Set(key, value)
    }
    
    if req.Body != nil {
        httpReq.Header.Set("Content-Type", "application/json")
    }
    
    // Add query parameters
    if len(req.QueryParams) > 0 {
        q := httpReq.URL.Query()
        for key, value := range req.QueryParams {
            q.Add(key, value)
        }
        httpReq.URL.RawQuery = q.Encode()
    }
    
    // Execute request
    resp, err := c.httpClient.Do(httpReq)
    if err != nil {
        return nil, &NetworkError{
            Operation: fmt.Sprintf("%s %s", req.Method, url),
            Err:       err,
        }
    }
    defer resp.Body.Close()
    
    // Read response body
    respBody, err := io.ReadAll(resp.Body)
    if err != nil {
        return nil, fmt.Errorf("reading response body: %w", err)
    }
    
    response := &Response{
        StatusCode: resp.StatusCode,
        Headers:    resp.Header,
        Body:       respBody,
    }
    
    // Handle HTTP errors
    if resp.StatusCode >= 400 {
        return response, c.handleHTTPError(response)
    }
    
    return response, nil
}
```

### Error Handling

```go
package client

import (
    "encoding/json"
    "fmt"
    "net"
    "net/http"
    "time"
)

// APIError represents different types of API errors
type APIError interface {
    error
    StatusCode() int
    RetryableError() bool
}

// NetworkError represents network-related errors
type NetworkError struct {
    Operation string
    Err       error
}

func (e *NetworkError) Error() string {
    return fmt.Sprintf("network error during %s: %v", e.Operation, e.Err)
}

func (e *NetworkError) RetryableError() bool {
    if netErr, ok := e.Err.(net.Error); ok {
        return netErr.Timeout() || netErr.Temporary()
    }
    return false
}

func (e *NetworkError) StatusCode() int {
    return 0 // No HTTP status for network errors
}

// HTTPError represents HTTP-level errors (4xx, 5xx)
type HTTPError struct {
    Status     int
    Message    string
    Details    map[string]interface{}
    RetryAfter time.Duration
}

func (e *HTTPError) Error() string {
    return fmt.Sprintf("HTTP %d: %s", e.Status, e.Message)
}

func (e *HTTPError) StatusCode() int {
    return e.Status
}

func (e *HTTPError) RetryableError() bool {
    // 5xx errors are generally retryable, some 4xx are not
    switch e.Status {
    case http.StatusTooManyRequests, http.StatusServiceUnavailable, 
         http.StatusBadGateway, http.StatusGatewayTimeout:
        return true
    case http.StatusInternalServerError:
        return true
    default:
        return e.Status >= 500
    }
}

// ValidationError represents validation failures
type ValidationError struct {
    Errors []FieldError `json:"errors"`
}

type FieldError struct {
    Field   string `json:"field"`
    Message string `json:"message"`
    Code    string `json:"code"`
}

func (e *ValidationError) Error() string {
    return fmt.Sprintf("validation failed: %d errors", len(e.Errors))
}

func (e *ValidationError) StatusCode() int {
    return http.StatusBadRequest
}

func (e *ValidationError) RetryableError() bool {
    return false
}

// handleHTTPError parses HTTP error responses
func (c *APIClient) handleHTTPError(resp *Response) error {
    httpErr := &HTTPError{
        Status:  resp.StatusCode,
        Message: http.StatusText(resp.StatusCode),
    }
    
    // Parse retry-after header
    if retryAfter := resp.Headers.Get("Retry-After"); retryAfter != "" {
        if duration, err := time.ParseDuration(retryAfter + "s"); err == nil {
            httpErr.RetryAfter = duration
        }
    }
    
    // Try to parse error response body
    if len(resp.Body) > 0 {
        var errorResponse struct {
            Message string                 `json:"message"`
            Error   string                 `json:"error"`
            Details map[string]interface{} `json:"details"`
            Errors  []FieldError           `json:"errors"`
        }
        
        if err := json.Unmarshal(resp.Body, &errorResponse); err == nil {
            if errorResponse.Message != "" {
                httpErr.Message = errorResponse.Message
            } else if errorResponse.Error != "" {
                httpErr.Message = errorResponse.Error
            }
            
            httpErr.Details = errorResponse.Details
            
            // Return validation error for field-level errors
            if len(errorResponse.Errors) > 0 {
                return &ValidationError{Errors: errorResponse.Errors}
            }
        }
    }
    
    return httpErr
}
```

### User Service Example

```go
package user

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
)

// User represents the domain model
type User struct {
    ID        string    `json:"id"`
    Email     string    `json:"email"`
    Name      string    `json:"name"`
    CreatedAt time.Time `json:"created_at"`
    UpdatedAt time.Time `json:"updated_at"`
    Active    bool      `json:"active"`
}

// CreateUserRequest represents a user creation request
type CreateUserRequest struct {
    Email string `json:"email" validate:"required,email"`
    Name  string `json:"name" validate:"required,min=2"`
}

// UserService provides user operations via external API
type UserService struct {
    client APIClient
    mapper UserMapper
}

// UserMapper handles conversion between API and domain models
type UserMapper struct{}

// apiUser represents the API response format
type apiUser struct {
    ID          string `json:"id"`
    EmailAddr   string `json:"email_address"`
    FullName    string `json:"full_name"`
    IsActive    bool   `json:"is_active"`
    CreatedDate string `json:"created_date"`
    UpdatedDate string `json:"updated_date"`
}

// ToDomain converts API user to domain user
func (m UserMapper) ToDomain(apiUser apiUser) (*User, error) {
    createdAt, err := time.Parse(time.RFC3339, apiUser.CreatedDate)
    if err != nil {
        return nil, fmt.Errorf("parsing created_date: %w", err)
    }
    
    updatedAt, err := time.Parse(time.RFC3339, apiUser.UpdatedDate)
    if err != nil {
        return nil, fmt.Errorf("parsing updated_date: %w", err)
    }
    
    return &User{
        ID:        apiUser.ID,
        Email:     apiUser.EmailAddr,
        Name:      apiUser.FullName,
        Active:    apiUser.IsActive,
        CreatedAt: createdAt,
        UpdatedAt: updatedAt,
    }, nil
}

// ToAPIRequest converts domain request to API request
func (m UserMapper) ToAPIRequest(req CreateUserRequest) map[string]interface{} {
    return map[string]interface{}{
        "email_address": req.Email,
        "full_name":     req.Name,
        "is_active":     true,
    }
}

// NewUserService creates a new user service
func NewUserService(client APIClient) *UserService {
    return &UserService{
        client: client,
        mapper: UserMapper{},
    }
}

// CreateUser creates a new user
func (s *UserService) CreateUser(ctx context.Context, req CreateUserRequest) (*User, error) {
    // Validate input
    if err := s.validateCreateRequest(req); err != nil {
        return nil, fmt.Errorf("validation failed: %w", err)
    }
    
    // Convert to API format
    apiReq := s.mapper.ToAPIRequest(req)
    
    // Make API call
    resp, err := s.client.Do(ctx, Request{
        Method: "POST",
        Path:   "/api/v1/users",
        Body:   apiReq,
        Headers: map[string]string{
            "X-Client-Version": "1.0.0",
        },
    })
    
    if err != nil {
        return nil, s.handleError("create user", err)
    }
    
    // Parse response
    var apiUser apiUser
    if err := json.Unmarshal(resp.Body, &apiUser); err != nil {
        return nil, fmt.Errorf("unmarshaling user response: %w", err)
    }
    
    // Convert to domain model
    user, err := s.mapper.ToDomain(apiUser)
    if err != nil {
        return nil, fmt.Errorf("converting to domain model: %w", err)
    }
    
    return user, nil
}

// GetUser retrieves a user by ID
func (s *UserService) GetUser(ctx context.Context, userID string) (*User, error) {
    if userID == "" {
        return nil, fmt.Errorf("user ID is required")
    }
    
    resp, err := s.client.Do(ctx, Request{
        Method: "GET",
        Path:   fmt.Sprintf("/api/v1/users/%s", userID),
    })
    
    if err != nil {
        return nil, s.handleError("get user", err)
    }
    
    var apiUser apiUser
    if err := json.Unmarshal(resp.Body, &apiUser); err != nil {
        return nil, fmt.Errorf("unmarshaling user response: %w", err)
    }
    
    return s.mapper.ToDomain(apiUser)
}

// ListUsers retrieves users with pagination
func (s *UserService) ListUsers(ctx context.Context, offset, limit int) ([]*User, error) {
    resp, err := s.client.Do(ctx, Request{
        Method: "GET",
        Path:   "/api/v1/users",
        QueryParams: map[string]string{
            "offset": fmt.Sprintf("%d", offset),
            "limit":  fmt.Sprintf("%d", limit),
        },
    })
    
    if err != nil {
        return nil, s.handleError("list users", err)
    }
    
    var apiResponse struct {
        Users []apiUser `json:"users"`
        Total int       `json:"total"`
    }
    
    if err := json.Unmarshal(resp.Body, &apiResponse); err != nil {
        return nil, fmt.Errorf("unmarshaling users response: %w", err)
    }
    
    users := make([]*User, len(apiResponse.Users))
    for i, apiUser := range apiResponse.Users {
        user, err := s.mapper.ToDomain(apiUser)
        if err != nil {
            return nil, fmt.Errorf("converting user %d to domain model: %w", i, err)
        }
        users[i] = user
    }
    
    return users, nil
}

// handleError converts API errors to domain errors
func (s *UserService) handleError(operation string, err error) error {
    var apiErr APIError
    if errors.As(err, &apiErr) {
        switch apiErr.StatusCode() {
        case 404:
            return &UserNotFoundError{Operation: operation}
        case 409:
            return &UserConflictError{Operation: operation}
        case 400:
            if validationErr, ok := err.(*ValidationError); ok {
                return &UserValidationError{
                    Operation: operation,
                    Errors:    validationErr.Errors,
                }
            }
        }
    }
    
    return fmt.Errorf("%s failed: %w", operation, err)
}

// Domain-specific errors
type UserNotFoundError struct {
    Operation string
}

func (e *UserNotFoundError) Error() string {
    return fmt.Sprintf("user not found during %s", e.Operation)
}

type UserConflictError struct {
    Operation string
}

func (e *UserConflictError) Error() string {
    return fmt.Sprintf("user conflict during %s", e.Operation)
}

type UserValidationError struct {
    Operation string
    Errors    []FieldError
}

func (e *UserValidationError) Error() string {
    return fmt.Sprintf("validation failed during %s: %d errors", e.Operation, len(e.Errors))
}
```

### Circuit Breaker Pattern

```go
package circuit

import (
    "context"
    "errors"
    "sync"
    "time"
)

// CircuitBreaker implements the circuit breaker pattern
type CircuitBreaker struct {
    mu                sync.RWMutex
    state             State
    maxRequests       uint32
    interval          time.Duration
    timeout           time.Duration
    failureThreshold  uint32
    successThreshold  uint32
    requests          uint32
    totalFailures     uint32
    consecutiveFailures uint32
    consecutiveSuccesses uint32
    lastStateChange   time.Time
}

// State represents the circuit breaker state
type State int

const (
    StateClosed State = iota
    StateHalfOpen
    StateOpen
)

var (
    ErrCircuitBreakerOpen    = errors.New("circuit breaker is open")
    ErrTooManyRequests       = errors.New("too many requests")
)

// Config configures the circuit breaker
type CircuitBreakerConfig struct {
    MaxRequests      uint32        // Max requests in half-open state
    Interval         time.Duration // Window for failure counting
    Timeout          time.Duration // Time to wait before half-open
    FailureThreshold uint32        // Failures to trigger open state
    SuccessThreshold uint32        // Successes to close from half-open
}

// NewCircuitBreaker creates a new circuit breaker
func NewCircuitBreaker(config CircuitBreakerConfig) *CircuitBreaker {
    return &CircuitBreaker{
        maxRequests:      config.MaxRequests,
        interval:         config.Interval,
        timeout:          config.Timeout,
        failureThreshold: config.FailureThreshold,
        successThreshold: config.SuccessThreshold,
        state:            StateClosed,
        lastStateChange:  time.Now(),
    }
}

// Execute runs the function with circuit breaker protection
func (cb *CircuitBreaker) Execute(fn func() error) error {
    state, generation := cb.currentState()
    
    if state == StateOpen {
        return ErrCircuitBreakerOpen
    }
    
    if state == StateHalfOpen && cb.requests >= cb.maxRequests {
        return ErrTooManyRequests
    }
    
    cb.beforeRequest()
    
    err := fn()
    
    cb.afterRequest(err, generation)
    
    return err
}

// currentState returns the current state and generation
func (cb *CircuitBreaker) currentState() (State, uint32) {
    cb.mu.RLock()
    defer cb.mu.RUnlock()
    
    now := time.Now()
    
    if cb.state == StateOpen && now.Sub(cb.lastStateChange) > cb.timeout {
        // Transition to half-open
        cb.mu.RUnlock()
        cb.mu.Lock()
        
        // Double-check after acquiring write lock
        if cb.state == StateOpen && now.Sub(cb.lastStateChange) > cb.timeout {
            cb.state = StateHalfOpen
            cb.requests = 0
            cb.consecutiveFailures = 0
            cb.consecutiveSuccesses = 0
            cb.lastStateChange = now
        }
        
        cb.mu.Unlock()
        cb.mu.RLock()
    }
    
    return cb.state, cb.requests
}

// beforeRequest increments the request counter
func (cb *CircuitBreaker) beforeRequest() {
    cb.mu.Lock()
    defer cb.mu.Unlock()
    
    cb.requests++
}

// afterRequest handles the request result
func (cb *CircuitBreaker) afterRequest(err error, generation uint32) {
    cb.mu.Lock()
    defer cb.mu.Unlock()
    
    now := time.Now()
    
    if err != nil {
        cb.consecutiveFailures++
        cb.consecutiveSuccesses = 0
        cb.totalFailures++
        
        if cb.state == StateClosed && cb.shouldOpen(now) {
            cb.state = StateOpen
            cb.lastStateChange = now
        } else if cb.state == StateHalfOpen {
            cb.state = StateOpen
            cb.lastStateChange = now
        }
    } else {
        cb.consecutiveSuccesses++
        cb.consecutiveFailures = 0
        
        if cb.state == StateHalfOpen && cb.consecutiveSuccesses >= cb.successThreshold {
            cb.state = StateClosed
            cb.lastStateChange = now
            cb.reset()
        }
    }
}

// shouldOpen determines if the circuit should open
func (cb *CircuitBreaker) shouldOpen(now time.Time) bool {
    return cb.consecutiveFailures >= cb.failureThreshold ||
           (now.Sub(cb.lastStateChange) >= cb.interval && 
            cb.totalFailures >= cb.failureThreshold)
}

// reset resets the counters
func (cb *CircuitBreaker) reset() {
    cb.requests = 0
    cb.totalFailures = 0
    cb.consecutiveFailures = 0
    cb.consecutiveSuccesses = 0
}
```

## Testing

### Mock Server Testing

```go
package user_test

import (
    "context"
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestUserService_CreateUser(t *testing.T) {
    tests := []struct {
        name           string
        request        CreateUserRequest
        mockResponse   func(w http.ResponseWriter, r *http.Request)
        expectedError  string
        expectedUser   *User
    }{
        {
            name: "successful creation",
            request: CreateUserRequest{
                Email: "test@example.com",
                Name:  "Test User",
            },
            mockResponse: func(w http.ResponseWriter, r *http.Request) {
                // Validate request
                var req map[string]interface{}
                json.NewDecoder(r.Body).Decode(&req)
                
                assert.Equal(t, "test@example.com", req["email_address"])
                assert.Equal(t, "Test User", req["full_name"])
                
                // Return success response
                response := apiUser{
                    ID:          "user-123",
                    EmailAddr:   "test@example.com",
                    FullName:    "Test User",
                    IsActive:    true,
                    CreatedDate: time.Now().Format(time.RFC3339),
                    UpdatedDate: time.Now().Format(time.RFC3339),
                }
                
                w.Header().Set("Content-Type", "application/json")
                json.NewEncoder(w).Encode(response)
            },
            expectedUser: &User{
                ID:     "user-123",
                Email:  "test@example.com",
                Name:   "Test User",
                Active: true,
            },
        },
        {
            name: "validation error",
            request: CreateUserRequest{
                Email: "invalid-email",
                Name:  "",
            },
            mockResponse: func(w http.ResponseWriter, r *http.Request) {
                w.WriteHeader(http.StatusBadRequest)
                json.NewEncoder(w).Encode(map[string]interface{}{
                    "errors": []FieldError{
                        {Field: "email_address", Message: "invalid email format", Code: "INVALID_EMAIL"},
                        {Field: "full_name", Message: "name is required", Code: "REQUIRED"},
                    },
                })
            },
            expectedError: "validation failed",
        },
        {
            name: "server error",
            request: CreateUserRequest{
                Email: "test@example.com",
                Name:  "Test User",
            },
            mockResponse: func(w http.ResponseWriter, r *http.Request) {
                w.WriteHeader(http.StatusInternalServerError)
                json.NewEncoder(w).Encode(map[string]string{
                    "error": "internal server error",
                })
            },
            expectedError: "HTTP 500",
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Create mock server
            server := httptest.NewServer(http.HandlerFunc(tt.mockResponse))
            defer server.Close()
            
            // Create service with mock server
            client := NewAPIClient(Config{
                BaseURL: server.URL,
                Timeout: 5 * time.Second,
            })
            service := NewUserService(client)
            
            // Execute test
            user, err := service.CreateUser(context.Background(), tt.request)
            
            if tt.expectedError != "" {
                require.Error(t, err)
                assert.Contains(t, err.Error(), tt.expectedError)
                assert.Nil(t, user)
            } else {
                require.NoError(t, err)
                require.NotNil(t, user)
                assert.Equal(t, tt.expectedUser.ID, user.ID)
                assert.Equal(t, tt.expectedUser.Email, user.Email)
                assert.Equal(t, tt.expectedUser.Name, user.Name)
                assert.Equal(t, tt.expectedUser.Active, user.Active)
            }
        })
    }
}

func TestCircuitBreaker_Integration(t *testing.T) {
    callCount := 0
    failureCount := 3
    
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        callCount++
        if callCount <= failureCount {
            w.WriteHeader(http.StatusInternalServerError)
            return
        }
        w.WriteHeader(http.StatusOK)
        json.NewEncoder(w).Encode(map[string]string{"status": "success"})
    }))
    defer server.Close()
    
    // Create client with circuit breaker
    client := NewAPIClientWithCircuitBreaker(Config{
        BaseURL: server.URL,
        Timeout: time.Second,
    }, CircuitBreakerConfig{
        FailureThreshold: 2,
        Timeout:          100 * time.Millisecond,
        MaxRequests:      1,
    })
    
    // First two requests should fail and trigger circuit breaker
    for i := 0; i < 2; i++ {
        _, err := client.Do(context.Background(), Request{
            Method: "GET",
            Path:   "/test",
        })
        assert.Error(t, err)
    }
    
    // Third request should be rejected by circuit breaker
    _, err := client.Do(context.Background(), Request{
        Method: "GET",
        Path:   "/test",
    })
    assert.ErrorIs(t, err, ErrCircuitBreakerOpen)
    
    // Wait for circuit breaker to half-open
    time.Sleep(150 * time.Millisecond)
    
    // Request should succeed and close the circuit
    resp, err := client.Do(context.Background(), Request{
        Method: "GET",
        Path:   "/test",
    })
    assert.NoError(t, err)
    assert.Equal(t, 200, resp.StatusCode)
}
```

## Best Practices

### Do

- ✅ Separate API models from domain models
- ✅ Implement comprehensive error handling
- ✅ Use circuit breakers for resilience
- ✅ Add request/response logging
- ✅ Implement rate limiting
- ✅ Use timeouts for all requests
- ✅ Test with mock servers
- ✅ Implement retry with exponential backoff

### Don't

- ❌ Expose API models in business logic
- ❌ Ignore HTTP error status codes
- ❌ Make API calls without timeouts
- ❌ Skip input validation
- ❌ Hard-code API endpoints
- ❌ Test against real APIs in unit tests

## Consequences

### Positive

- **Clean Architecture**: Clear separation between API and domain
- **Resilience**: Built-in error handling and retry mechanisms
- **Testability**: Easy to mock and test API interactions
- **Maintainability**: Centralized API configuration and error handling
- **Observability**: Comprehensive logging and monitoring

### Negative

- **Complexity**: Additional abstraction layers
- **Boilerplate**: More code for mapping and error handling
- **Performance**: Additional overhead from resilience patterns

## References

- [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Circuit Breaker Pattern](https://martinfowler.com/bliki/CircuitBreaker.html)
- [API Design Guidelines](https://github.com/microsoft/api-guidelines)
- [HTTP Client Best Practices](https://blog.golang.org/context)
    url := fmt.Sprintf("https://api.example.com/users/%d", userID)
    req, err := http.NewRequest("GET", url, nil)
    if err != nil {
        return nil, err
    }

    resp, err := s.client.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
    }

    var user User
    err = json.NewDecoder(resp.Body).Decode(&user)
    if err != nil {
        return nil, err
    }

    return &user, nil
}

func TestGetUser(t *testing.T) {
    // Create a test server that mimics the third-party API
    ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path != "/users/1" {
            http.NotFound(w, r)
            return
        }

        userJSON := `{
            "id": 1,
            "name": "John Doe",
            "email": "johndoe@example.com",
            "isActive": true
        }`

        fmt.Fprint(w, userJSON)
    }))
    defer ts.Close()

    // Create a UserService instance with the test server URL
    userService := NewUserService()
    userService.client.Transport = &http.Transport{
        DisableKeepAlives: true,
    }

    // Use the UserService to get a user
    user, err := userService.GetUser(1)
    if err != nil {
        t.Error(err)
    }

    // Verify that the user data is correct
    if user.ID != 1 {
        t.Error("unexpected user ID:", user.ID)
    }

    if user.Name != "John Doe" {
        t.Error("unexpected user name:", user.Name)
    }

    if user.Email != "johndoe@example.com" {
        t.Error("unexpected user email:", user.Email)
    }

    if !user.isActive {
        t.Error("user is not active")
    }
}
```

This code demonstrates how to integrate a third-party API by creating an abstraction layer (UserService) that simplifies API interaction. It also shows how to use a test server to ensure proper serialization and deserialization.
