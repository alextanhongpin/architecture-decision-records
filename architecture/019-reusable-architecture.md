# Reusable Architecture

## Status

`accepted`

## Context

After experimenting with various architecture patterns like Clean Architecture, Onion Architecture, and Hexagonal Architecture, none seemed to perfectly fit our development needs. Each had their merits but also introduced unnecessary complexity or didn't align well with our team's working style and project requirements.

There's often a tendency among engineers to create overly complex code organization that only the author understands, leading to confusion and reduced productivity. This architectural complexity can become a barrier rather than an enabler.

The need for a standardized, reusable architecture pattern arises from several pain points:

- **High cognitive load** when starting new projects
- **Analysis paralysis** when deciding on best practices
- **Inconsistent patterns** across different projects and teams
- **Repeated architectural decisions** that could be standardized
- **Difficult knowledge transfer** between team members

## Decision

Adopt the **CAGE Architecture** - a modern, pragmatic approach to clean architecture specifically designed for Go applications, emphasizing simplicity, reusability, and developer productivity.

## CAGE Architecture

CAGE stands for **Controller, Action, Gateway, Entity** - four core components that provide clear separation of concerns while maintaining simplicity.

### Core Components

#### Controller
The interface between external clients and internal business logic. Controllers handle HTTP requests, validate input, and delegate to actions.

```go
// authentication/login_controller.go
package authentication

import (
    "encoding/json"
    "net/http"
)

type LoginController struct {
    loginAction *LoginAction
}

func NewLoginController(loginAction *LoginAction) *LoginController {
    return &LoginController{
        loginAction: loginAction,
    }
}

func (c *LoginController) Handle(w http.ResponseWriter, r *http.Request) {
    var req LoginRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "Invalid request body", http.StatusBadRequest)
        return
    }
    
    resp, err := c.loginAction.Execute(r.Context(), req)
    if err != nil {
        c.handleError(w, err)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(resp)
}

func (c *LoginController) handleError(w http.ResponseWriter, err error) {
    switch err {
    case ErrInvalidCredentials:
        http.Error(w, "Invalid credentials", http.StatusUnauthorized)
    case ErrAccountLocked:
        http.Error(w, "Account is locked", http.StatusForbidden)
    default:
        http.Error(w, "Internal server error", http.StatusInternalServerError)
    }
}
```

#### Action
Business logic implementation - the verbs of your system. Actions contain the core business rules and orchestrate the flow of data.

```go
// authentication/login.go
package authentication

import (
    "context"
    "fmt"
    "time"
    
    "golang.org/x/crypto/bcrypt"
)

type LoginRequest struct {
    Email    string `json:"email" validate:"required,email"`
    Password string `json:"password" validate:"required"`
}

type LoginResponse struct {
    User  *User  `json:"user"`
    Token string `json:"token"`
}

type LoginAction struct {
    gateway *Gateway
}

func NewLoginAction(gateway *Gateway) *LoginAction {
    return &LoginAction{
        gateway: gateway,
    }
}

func (a *LoginAction) Execute(ctx context.Context, req LoginRequest) (*LoginResponse, error) {
    // Validate input
    if err := a.validateRequest(req); err != nil {
        return nil, err
    }
    
    // Get user by email
    user, err := a.gateway.GetUserByEmail(ctx, req.Email)
    if err != nil {
        return nil, ErrInvalidCredentials
    }
    
    // Check if account is locked
    if user.IsLocked() {
        return nil, ErrAccountLocked
    }
    
    // Verify password
    if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
        // Log failed attempt
        a.gateway.LogFailedLogin(ctx, user.ID)
        return nil, ErrInvalidCredentials
    }
    
    // Generate JWT token
    token, err := a.gateway.GenerateToken(ctx, user.ID)
    if err != nil {
        return nil, fmt.Errorf("failed to generate token: %w", err)
    }
    
    // Update last login
    a.gateway.UpdateLastLogin(ctx, user.ID, time.Now())
    
    return &LoginResponse{
        User:  user,
        Token: token,
    }, nil
}

func (a *LoginAction) validateRequest(req LoginRequest) error {
    if req.Email == "" {
        return ErrMissingEmail
    }
    if req.Password == "" {
        return ErrMissingPassword
    }
    return nil
}
```

#### Gateway
Handles external communications including database operations, API calls, and third-party integrations. Ensures atomicity through transaction management.

```go
// authentication/gateway.go
package authentication

import (
    "context"
    "database/sql"
    "fmt"
    "time"
)

type Gateway struct {
    db       *sql.DB
    tokenGen TokenGenerator
    logger   Logger
}

func NewGateway(db *sql.DB, tokenGen TokenGenerator, logger Logger) *Gateway {
    return &Gateway{
        db:       db,
        tokenGen: tokenGen,
        logger:   logger,
    }
}

func (g *Gateway) GetUserByEmail(ctx context.Context, email string) (*User, error) {
    query := `
        SELECT id, email, password_hash, first_name, last_name, status, 
               failed_login_attempts, locked_until, created_at, updated_at
        FROM users 
        WHERE email = $1`
    
    var user User
    err := g.db.QueryRowContext(ctx, query, email).Scan(
        &user.ID, &user.Email, &user.PasswordHash,
        &user.FirstName, &user.LastName, &user.Status,
        &user.FailedLoginAttempts, &user.LockedUntil,
        &user.CreatedAt, &user.UpdatedAt,
    )
    
    if err == sql.ErrNoRows {
        return nil, ErrUserNotFound
    }
    if err != nil {
        return nil, fmt.Errorf("failed to get user: %w", err)
    }
    
    return &user, nil
}

func (g *Gateway) LogFailedLogin(ctx context.Context, userID string) error {
    tx, err := g.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Increment failed attempts
    query := `
        UPDATE users 
        SET failed_login_attempts = failed_login_attempts + 1,
            locked_until = CASE 
                WHEN failed_login_attempts + 1 >= 5 
                THEN NOW() + INTERVAL '30 minutes'
                ELSE locked_until
            END
        WHERE id = $1`
    
    _, err = tx.ExecContext(ctx, query, userID)
    if err != nil {
        return err
    }
    
    // Log the failed attempt
    logQuery := `
        INSERT INTO login_attempts (user_id, success, ip_address, user_agent, created_at)
        VALUES ($1, $2, $3, $4, $5)`
    
    _, err = tx.ExecContext(ctx, logQuery, userID, false, 
        g.getIPFromContext(ctx), g.getUserAgentFromContext(ctx), time.Now())
    if err != nil {
        return err
    }
    
    return tx.Commit()
}

func (g *Gateway) GenerateToken(ctx context.Context, userID string) (string, error) {
    return g.tokenGen.Generate(userID, 24*time.Hour)
}

func (g *Gateway) UpdateLastLogin(ctx context.Context, userID string, timestamp time.Time) error {
    query := `
        UPDATE users 
        SET last_login_at = $1, failed_login_attempts = 0, locked_until = NULL
        WHERE id = $2`
    
    _, err := g.db.ExecContext(ctx, query, timestamp, userID)
    return err
}
```

#### Entity
Domain objects that represent the core business concepts. Entities contain business logic and maintain data integrity.

```go
// authentication/user.go
package authentication

import (
    "time"
)

type User struct {
    ID                  string     `json:"id"`
    Email               string     `json:"email"`
    PasswordHash        string     `json:"-"` // Never serialize password
    FirstName           string     `json:"first_name"`
    LastName            string     `json:"last_name"`
    Status              string     `json:"status"`
    FailedLoginAttempts int        `json:"failed_login_attempts"`
    LockedUntil         *time.Time `json:"locked_until,omitempty"`
    LastLoginAt         *time.Time `json:"last_login_at,omitempty"`
    CreatedAt           time.Time  `json:"created_at"`
    UpdatedAt           time.Time  `json:"updated_at"`
}

// Business logic methods
func (u *User) IsLocked() bool {
    if u.LockedUntil == nil {
        return false
    }
    return time.Now().Before(*u.LockedUntil)
}

func (u *User) IsActive() bool {
    return u.Status == "active"
}

func (u *User) FullName() string {
    return u.FirstName + " " + u.LastName
}

func (u *User) CanLogin() bool {
    return u.IsActive() && !u.IsLocked()
}

func (u *User) RequiresPasswordReset() bool {
    return u.Status == "password_reset_required"
}

type Token struct {
    Value     string    `json:"token"`
    UserID    string    `json:"user_id"`
    ExpiresAt time.Time `json:"expires_at"`
    CreatedAt time.Time `json:"created_at"`
}

func (t *Token) IsExpired() bool {
    return time.Now().After(t.ExpiresAt)
}

func (t *Token) IsValid() bool {
    return !t.IsExpired() && t.Value != ""
}
```

### Feature Organization

Organize code by business features rather than technical layers:

```
authentication/
├── login.go              # Login action
├── login_controller.go   # Login HTTP controller
├── register.go           # Registration action  
├── register_controller.go # Registration HTTP controller
├── password_reset.go     # Password reset action
├── gateway.go            # External communications
├── user.go              # User entity
├── token.go             # Token entity
└── errors.go            # Feature-specific errors

search/
├── search.go            # Search action
├── search_controller.go # Search HTTP controller
├── gateway.go           # Search gateway
├── job.go              # Search job entity
└── errors.go           # Search errors

order/
├── create.go           # Create order action
├── fulfill.go          # Fulfill order action
├── cancel.go           # Cancel order action
├── gateway.go          # Order gateway
├── order.go           # Order entity
└── errors.go          # Order errors
```

### Dependency Injection

Use constructor injection for clear dependencies:

```go
// main.go
package main

import (
    "database/sql"
    "log"
    "net/http"
    
    "github.com/gorilla/mux"
    _ "github.com/lib/pq"
)

func main() {
    // Infrastructure setup
    db, err := sql.Open("postgres", "postgresql://...")
    if err != nil {
        log.Fatal(err)
    }
    defer db.Close()
    
    tokenGen := NewJWTTokenGenerator("secret-key")
    logger := NewLogger()
    
    // Authentication feature
    authGateway := authentication.NewGateway(db, tokenGen, logger)
    loginAction := authentication.NewLoginAction(authGateway)
    registerAction := authentication.NewRegisterAction(authGateway)
    
    loginController := authentication.NewLoginController(loginAction)
    registerController := authentication.NewRegisterController(registerAction)
    
    // Order feature
    orderGateway := order.NewGateway(db, logger)
    createOrderAction := order.NewCreateAction(orderGateway)
    fulfillOrderAction := order.NewFulfillAction(orderGateway)
    
    createOrderController := order.NewCreateController(createOrderAction)
    fulfillOrderController := order.NewFulfillController(fulfillOrderAction)
    
    // HTTP routing
    r := mux.NewRouter()
    r.HandleFunc("/api/auth/login", loginController.Handle).Methods("POST")
    r.HandleFunc("/api/auth/register", registerController.Handle).Methods("POST")
    r.HandleFunc("/api/orders", createOrderController.Handle).Methods("POST")
    r.HandleFunc("/api/orders/{id}/fulfill", fulfillOrderController.Handle).Methods("POST")
    
    log.Println("Server starting on :8080")
    log.Fatal(http.ListenAndServe(":8080", r))
}
```

### Testing Strategy

Test each component independently:

```go
// authentication/login_test.go
package authentication

import (
    "context"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
)

type MockGateway struct {
    mock.Mock
}

func (m *MockGateway) GetUserByEmail(ctx context.Context, email string) (*User, error) {
    args := m.Called(ctx, email)
    return args.Get(0).(*User), args.Error(1)
}

func (m *MockGateway) GenerateToken(ctx context.Context, userID string) (string, error) {
    args := m.Called(ctx, userID)
    return args.String(0), args.Error(1)
}

func (m *MockGateway) UpdateLastLogin(ctx context.Context, userID string, timestamp time.Time) error {
    args := m.Called(ctx, userID, timestamp)
    return args.Error(0)
}

func (m *MockGateway) LogFailedLogin(ctx context.Context, userID string) error {
    args := m.Called(ctx, userID)
    return args.Error(0)
}

func TestLoginAction_Execute(t *testing.T) {
    tests := []struct {
        name        string
        request     LoginRequest
        setupMocks  func(*MockGateway)
        expectError error
    }{
        {
            name: "successful login",
            request: LoginRequest{
                Email:    "test@example.com",
                Password: "password123",
            },
            setupMocks: func(gateway *MockGateway) {
                user := &User{
                    ID:           "user-123",
                    Email:        "test@example.com",
                    PasswordHash: "$2a$10$...", // bcrypt hash of "password123"
                    Status:       "active",
                }
                gateway.On("GetUserByEmail", mock.Anything, "test@example.com").Return(user, nil)
                gateway.On("GenerateToken", mock.Anything, "user-123").Return("jwt-token", nil)
                gateway.On("UpdateLastLogin", mock.Anything, "user-123", mock.AnythingOfType("time.Time")).Return(nil)
            },
            expectError: nil,
        },
        {
            name: "invalid credentials",
            request: LoginRequest{
                Email:    "test@example.com",
                Password: "wrongpassword",
            },
            setupMocks: func(gateway *MockGateway) {
                user := &User{
                    ID:           "user-123",
                    Email:        "test@example.com",
                    PasswordHash: "$2a$10$...", // bcrypt hash of "password123"
                    Status:       "active",
                }
                gateway.On("GetUserByEmail", mock.Anything, "test@example.com").Return(user, nil)
                gateway.On("LogFailedLogin", mock.Anything, "user-123").Return(nil)
            },
            expectError: ErrInvalidCredentials,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Setup
            mockGateway := &MockGateway{}
            tt.setupMocks(mockGateway)
            
            action := NewLoginAction(mockGateway)
            
            // Execute
            resp, err := action.Execute(context.Background(), tt.request)
            
            // Assert
            if tt.expectError != nil {
                assert.Error(t, err)
                assert.Equal(t, tt.expectError, err)
                assert.Nil(t, resp)
            } else {
                assert.NoError(t, err)
                assert.NotNil(t, resp)
                assert.Equal(t, tt.request.Email, resp.User.Email)
                assert.NotEmpty(t, resp.Token)
            }
            
            mockGateway.AssertExpectations(t)
        })
    }
}
```

### Metrics and Observability

Track feature adoption and performance:

```go
// metrics/feature_metrics.go
package metrics

import (
    "context"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

type FeatureMetrics struct {
    actionCounter   *prometheus.CounterVec
    actionDuration  *prometheus.HistogramVec
    actionErrors    *prometheus.CounterVec
    uniqueUsers     *prometheus.GaugeVec
}

func NewFeatureMetrics() *FeatureMetrics {
    return &FeatureMetrics{
        actionCounter: promauto.NewCounterVec(
            prometheus.CounterOpts{
                Name: "cage_action_requests_total",
                Help: "Total number of action requests",
            },
            []string{"feature", "action", "status"},
        ),
        actionDuration: promauto.NewHistogramVec(
            prometheus.HistogramOpts{
                Name: "cage_action_duration_seconds",
                Help: "Duration of action execution",
            },
            []string{"feature", "action"},
        ),
        actionErrors: promauto.NewCounterVec(
            prometheus.CounterOpts{
                Name: "cage_action_errors_total",
                Help: "Total number of action errors",
            },
            []string{"feature", "action", "error_type"},
        ),
        uniqueUsers: promauto.NewGaugeVec(
            prometheus.GaugeOpts{
                Name: "cage_feature_unique_users",
                Help: "Number of unique users per feature",
            },
            []string{"feature", "period"},
        ),
    }
}

func (m *FeatureMetrics) RecordAction(feature, action string, duration time.Duration, err error) {
    status := "success"
    if err != nil {
        status = "error"
        m.actionErrors.WithLabelValues(feature, action, err.Error()).Inc()
    }
    
    m.actionCounter.WithLabelValues(feature, action, status).Inc()
    m.actionDuration.WithLabelValues(feature, action).Observe(duration.Seconds())
}

func (m *FeatureMetrics) RecordUniqueUser(feature, userID string) {
    // Implementation for tracking unique users
    // This would typically involve a time-series database
}
```

## Shared Nothing Architecture

Each action is completely self-contained:

```go
// Each action defines its own errors
var (
    // Login-specific errors
    ErrInvalidCredentials = errors.New("invalid credentials")
    ErrAccountLocked      = errors.New("account is locked")
    
    // Registration-specific errors  
    ErrEmailAlreadyExists = errors.New("email already exists")
    ErrWeakPassword      = errors.New("password is too weak")
    
    // Order-specific errors
    ErrInsufficientInventory = errors.New("insufficient inventory")
    ErrInvalidOrderStatus    = errors.New("invalid order status")
)
```

This approach allows for:
- **Independent evolution** of features
- **Clear error boundaries** between different business capabilities
- **Easier debugging** as errors are localized to specific features
- **Better metrics** on feature-specific error rates

## Consequences

### Positive

- **Reduced Complexity**: Simpler mental model compared to traditional layered architectures
- **Faster Development**: Clear patterns reduce decision fatigue
- **Better Testability**: Each component can be tested in isolation
- **Improved Maintainability**: Feature-focused organization makes code easier to understand
- **Metrics-Driven**: Built-in observability for feature adoption and performance
- **Scalable Team Structure**: Features can be owned by different teams

### Negative

- **Potential Duplication**: Some logic may be repeated across features
- **Gateway Complexity**: Gateways can become large if not properly organized
- **Learning Curve**: Team needs to understand the CAGE principles
- **Discipline Required**: Requires consistent application of architectural patterns

### Trade-offs

- **Simplicity vs Flexibility**: Prioritizes simplicity over architectural flexibility
- **Speed vs Purity**: Emphasizes development velocity over perfect abstraction
- **Pragmatism vs Idealism**: Accepts some trade-offs for practical benefits

## Anti-patterns

- **Shared Gateways**: Multiple features sharing the same gateway instance
- **Cross-Feature Dependencies**: Actions in one feature directly calling actions in another
- **Leaky Abstractions**: Exposing database or external service details in actions
- **God Actions**: Single actions handling too many responsibilities
- **Inconsistent Error Handling**: Different error patterns across features
