# Backend Application Structure

## Status

`accepted`

## Context

Consistent application structure is crucial for maintainability, developer productivity, and code quality. Without standardized patterns, projects become difficult to navigate, test, and extend. Learning from mature frameworks provides proven patterns for organizing backend applications.

### Current Challenges

Backend applications often suffer from:
- **Inconsistent organization**: Different projects use different structures
- **Poor separation of concerns**: Business logic mixed with infrastructure code
- **Difficult testing**: Tightly coupled components are hard to unit test
- **Unclear dependencies**: Hard to understand component relationships
- **Scaling difficulties**: Structure doesn't support growth and team expansion

### Framework Analysis

Successful frameworks provide common patterns:

**Ruby on Rails**: Convention over configuration, MVC pattern
**Django**: Apps-based organization, clear separation of concerns
**NestJS**: Modular architecture, dependency injection, decorators
**Clean Architecture**: Domain-centric design, dependency inversion

## Decision

We will adopt a layered, domain-driven backend structure that promotes separation of concerns, testability, and maintainability.

### Directory Structure

```
project-root/
├── cmd/                          # Application entry points
│   ├── server/                   # HTTP server
│   │   └── main.go
│   ├── worker/                   # Background worker
│   │   └── main.go
│   └── migrate/                  # Database migrations
│       └── main.go
├── internal/                     # Private application code
│   ├── api/                      # API layer (handlers, middleware)
│   │   ├── handlers/
│   │   │   ├── auth_handler.go
│   │   │   ├── user_handler.go
│   │   │   └── order_handler.go
│   │   ├── middleware/
│   │   │   ├── auth.go
│   │   │   ├── cors.go
│   │   │   └── logging.go
│   │   └── routes.go
│   ├── domain/                   # Business logic and entities
│   │   ├── user/
│   │   │   ├── user.go           # Entity
│   │   │   ├── repository.go     # Interface
│   │   │   └── service.go        # Business logic
│   │   ├── order/
│   │   │   ├── order.go
│   │   │   ├── repository.go
│   │   │   └── service.go
│   │   └── shared/               # Shared domain concepts
│   │       ├── errors.go
│   │       ├── events.go
│   │       └── value_objects.go
│   ├── infrastructure/           # External concerns
│   │   ├── database/
│   │   │   ├── postgres/
│   │   │   │   ├── user_repo.go
│   │   │   │   └── order_repo.go
│   │   │   └── migrations/
│   │   ├── cache/
│   │   │   └── redis/
│   │   ├── messaging/
│   │   │   └── kafka/
│   │   └── external/
│   │       ├── payment_client.go
│   │       └── email_client.go
│   ├── application/              # Application services
│   │   ├── services/
│   │   │   ├── user_service.go
│   │   │   └── order_service.go
│   │   └── queries/
│   │       ├── user_queries.go
│   │       └── order_queries.go
│   └── config/                   # Configuration
│       ├── config.go
│       └── database.go
├── pkg/                          # Public packages (reusable)
│   ├── logger/
│   ├── validator/
│   ├── httputil/
│   └── timeutil/
├── migrations/                   # Database migration files
├── docs/                         # Documentation
├── scripts/                      # Build and deployment scripts
├── tests/                        # Integration and e2e tests
│   ├── integration/
│   └── fixtures/
├── go.mod
├── go.sum
├── Dockerfile
├── docker-compose.yml
└── README.md
```

### Layer Responsibilities

#### 1. API Layer (`internal/api/`)

Handles HTTP concerns and request/response transformation:

```go
// internal/api/handlers/user_handler.go
package handlers

import (
    "encoding/json"
    "net/http"
    
    "myapp/internal/application/services"
    "myapp/internal/domain/user"
)

type UserHandler struct {
    userService *services.UserService
}

func NewUserHandler(userService *services.UserService) *UserHandler {
    return &UserHandler{
        userService: userService,
    }
}

func (h *UserHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
    var req CreateUserRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "Invalid request body", http.StatusBadRequest)
        return
    }
    
    userEntity := &user.User{
        Email:    req.Email,
        Name:     req.Name,
        Password: req.Password,
    }
    
    createdUser, err := h.userService.CreateUser(r.Context(), userEntity)
    if err != nil {
        handleError(w, err)
        return
    }
    
    response := CreateUserResponse{
        ID:    createdUser.ID,
        Email: createdUser.Email,
        Name:  createdUser.Name,
    }
    
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusCreated)
    json.NewEncoder(w).Encode(response)
}

type CreateUserRequest struct {
    Email    string `json:"email" validate:"required,email"`
    Name     string `json:"name" validate:"required,min=2,max=100"`
    Password string `json:"password" validate:"required,min=8"`
}

type CreateUserResponse struct {
    ID    string `json:"id"`
    Email string `json:"email"`
    Name  string `json:"name"`
}
```

#### 2. Domain Layer (`internal/domain/`)

Contains business entities and core business logic:

```go
// internal/domain/user/user.go
package user

import (
    "errors"
    "time"
    "golang.org/x/crypto/bcrypt"
)

type User struct {
    ID        string
    Email     string
    Name      string
    Password  string
    CreatedAt time.Time
    UpdatedAt time.Time
}

func (u *User) Validate() error {
    if u.Email == "" {
        return errors.New("email is required")
    }
    
    if u.Name == "" {
        return errors.New("name is required")
    }
    
    if len(u.Password) < 8 {
        return errors.New("password must be at least 8 characters")
    }
    
    return nil
}

func (u *User) HashPassword() error {
    hashedPassword, err := bcrypt.GenerateFromPassword([]byte(u.Password), bcrypt.DefaultCost)
    if err != nil {
        return err
    }
    
    u.Password = string(hashedPassword)
    return nil
}

func (u *User) CheckPassword(password string) bool {
    err := bcrypt.CompareHashAndPassword([]byte(u.Password), []byte(password))
    return err == nil
}

// Repository interface - defined in domain, implemented in infrastructure
type Repository interface {
    Create(ctx context.Context, user *User) error
    FindByID(ctx context.Context, id string) (*User, error)
    FindByEmail(ctx context.Context, email string) (*User, error)
    Update(ctx context.Context, user *User) error
    Delete(ctx context.Context, id string) error
}

// Domain service for complex business logic
type Service struct {
    repo Repository
}

func NewService(repo Repository) *Service {
    return &Service{repo: repo}
}

func (s *Service) ValidateUniqueEmail(ctx context.Context, email string) error {
    existingUser, err := s.repo.FindByEmail(ctx, email)
    if err != nil && !errors.Is(err, ErrUserNotFound) {
        return err
    }
    
    if existingUser != nil {
        return ErrEmailAlreadyExists
    }
    
    return nil
}
```

#### 3. Application Layer (`internal/application/`)

Orchestrates business operations and manages transactions:

```go
// internal/application/services/user_service.go
package services

import (
    "context"
    "fmt"
    
    "myapp/internal/domain/user"
    "myapp/pkg/logger"
)

type UserService struct {
    userRepo   user.Repository
    logger     logger.Logger
    eventBus   EventBus
}

func NewUserService(userRepo user.Repository, logger logger.Logger, eventBus EventBus) *UserService {
    return &UserService{
        userRepo: userRepo,
        logger:   logger,
        eventBus: eventBus,
    }
}

func (s *UserService) CreateUser(ctx context.Context, u *user.User) (*user.User, error) {
    // Validate business rules
    if err := u.Validate(); err != nil {
        return nil, fmt.Errorf("validation failed: %w", err)
    }
    
    // Check if email already exists
    domainService := user.NewService(s.userRepo)
    if err := domainService.ValidateUniqueEmail(ctx, u.Email); err != nil {
        return nil, fmt.Errorf("email validation failed: %w", err)
    }
    
    // Hash password
    if err := u.HashPassword(); err != nil {
        return nil, fmt.Errorf("password hashing failed: %w", err)
    }
    
    // Generate ID and timestamps
    u.ID = generateID()
    u.CreatedAt = time.Now()
    u.UpdatedAt = time.Now()
    
    // Persist to database
    if err := s.userRepo.Create(ctx, u); err != nil {
        s.logger.Error("Failed to create user", "error", err, "email", u.Email)
        return nil, fmt.Errorf("failed to create user: %w", err)
    }
    
    // Publish event
    event := UserCreatedEvent{
        UserID: u.ID,
        Email:  u.Email,
        Name:   u.Name,
    }
    s.eventBus.Publish("user.created", event)
    
    s.logger.Info("User created successfully", "user_id", u.ID, "email", u.Email)
    return u, nil
}

func (s *UserService) GetUser(ctx context.Context, id string) (*user.User, error) {
    u, err := s.userRepo.FindByID(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("failed to get user: %w", err)
    }
    
    return u, nil
}
```

#### 4. Infrastructure Layer (`internal/infrastructure/`)

Implements external concerns and repository interfaces:

```go
// internal/infrastructure/database/postgres/user_repo.go
package postgres

import (
    "context"
    "database/sql"
    "fmt"
    
    "myapp/internal/domain/user"
)

type UserRepository struct {
    db *sql.DB
}

func NewUserRepository(db *sql.DB) *UserRepository {
    return &UserRepository{db: db}
}

func (r *UserRepository) Create(ctx context.Context, u *user.User) error {
    query := `
        INSERT INTO users (id, email, name, password, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6)
    `
    
    _, err := r.db.ExecContext(ctx, query, u.ID, u.Email, u.Name, u.Password, u.CreatedAt, u.UpdatedAt)
    if err != nil {
        return fmt.Errorf("failed to insert user: %w", err)
    }
    
    return nil
}

func (r *UserRepository) FindByID(ctx context.Context, id string) (*user.User, error) {
    query := `
        SELECT id, email, name, password, created_at, updated_at
        FROM users
        WHERE id = $1
    `
    
    u := &user.User{}
    err := r.db.QueryRowContext(ctx, query, id).Scan(
        &u.ID, &u.Email, &u.Name, &u.Password, &u.CreatedAt, &u.UpdatedAt,
    )
    
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, user.ErrUserNotFound
        }
        return nil, fmt.Errorf("failed to query user: %w", err)
    }
    
    return u, nil
}

func (r *UserRepository) FindByEmail(ctx context.Context, email string) (*user.User, error) {
    query := `
        SELECT id, email, name, password, created_at, updated_at
        FROM users
        WHERE email = $1
    `
    
    u := &user.User{}
    err := r.db.QueryRowContext(ctx, query, email).Scan(
        &u.ID, &u.Email, &u.Name, &u.Password, &u.CreatedAt, &u.UpdatedAt,
    )
    
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, user.ErrUserNotFound
        }
        return nil, fmt.Errorf("failed to query user: %w", err)
    }
    
    return u, nil
}
```

### Dependency Injection

```go
// internal/config/dependencies.go
package config

import (
    "database/sql"
    
    "myapp/internal/application/services"
    "myapp/internal/api/handlers"
    "myapp/internal/infrastructure/database/postgres"
    "myapp/pkg/logger"
)

type Dependencies struct {
    // Handlers
    UserHandler  *handlers.UserHandler
    OrderHandler *handlers.OrderHandler
    
    // Services
    UserService  *services.UserService
    OrderService *services.OrderService
    
    // Infrastructure
    Database *sql.DB
    Logger   logger.Logger
}

func NewDependencies(cfg *Config) (*Dependencies, error) {
    // Initialize infrastructure
    db, err := NewDatabase(cfg.Database)
    if err != nil {
        return nil, err
    }
    
    logger := NewLogger(cfg.Logging)
    eventBus := NewEventBus(cfg.Messaging)
    
    // Initialize repositories
    userRepo := postgres.NewUserRepository(db)
    orderRepo := postgres.NewOrderRepository(db)
    
    // Initialize services
    userService := services.NewUserService(userRepo, logger, eventBus)
    orderService := services.NewOrderService(orderRepo, userRepo, logger, eventBus)
    
    // Initialize handlers
    userHandler := handlers.NewUserHandler(userService)
    orderHandler := handlers.NewOrderHandler(orderService)
    
    return &Dependencies{
        UserHandler:  userHandler,
        OrderHandler: orderHandler,
        UserService:  userService,
        OrderService: orderService,
        Database:     db,
        Logger:       logger,
    }, nil
}

func (d *Dependencies) Close() error {
    return d.Database.Close()
}
```

### Testing Structure

```go
// tests/integration/user_test.go
package integration

import (
    "bytes"
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "testing"
    
    "myapp/internal/api/handlers"
    "myapp/tests/fixtures"
)

func TestUserCreation(t *testing.T) {
    // Setup test database and dependencies
    testDB := fixtures.SetupTestDB(t)
    defer testDB.Close()
    
    deps := fixtures.NewTestDependencies(testDB)
    userHandler := deps.UserHandler
    
    tests := []struct {
        name           string
        requestBody    interface{}
        expectedStatus int
        expectedError  string
    }{
        {
            name: "valid user creation",
            requestBody: handlers.CreateUserRequest{
                Email:    "test@example.com",
                Name:     "Test User",
                Password: "password123",
            },
            expectedStatus: http.StatusCreated,
        },
        {
            name: "invalid email",
            requestBody: handlers.CreateUserRequest{
                Email:    "invalid-email",
                Name:     "Test User",
                Password: "password123",
            },
            expectedStatus: http.StatusBadRequest,
            expectedError:  "validation failed",
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            body, _ := json.Marshal(tt.requestBody)
            req := httptest.NewRequest(http.MethodPost, "/users", bytes.NewBuffer(body))
            rec := httptest.NewRecorder()
            
            userHandler.CreateUser(rec, req)
            
            assert.Equal(t, tt.expectedStatus, rec.Code)
            
            if tt.expectedError != "" {
                assert.Contains(t, rec.Body.String(), tt.expectedError)
            }
        })
    }
}
```

### Package Organization Guidelines

#### Internal vs. External Packages

- **`internal/`**: Private application code, cannot be imported by external projects
- **`pkg/`**: Public packages that can be imported and reused
- **`cmd/`**: Application entry points for different executables

#### Import Rules

```go
// ✅ Good: Domain doesn't depend on infrastructure
package user

import (
    "context"
    "time"
)

// ❌ Bad: Domain importing infrastructure
package user

import (
    "database/sql"  // Infrastructure concern
)

// ✅ Good: Infrastructure depends on domain interfaces
package postgres

import (
    "myapp/internal/domain/user"  // Domain interface
)

// ✅ Good: Application orchestrates domain and infrastructure
package services

import (
    "myapp/internal/domain/user"           // Domain
    "myapp/internal/infrastructure/email"  // Infrastructure
)
```

### Cross-Cutting Concerns

#### Logging

```go
// pkg/logger/logger.go
package logger

import (
    "context"
    "log/slog"
    "os"
)

type Logger interface {
    Debug(msg string, keysAndValues ...interface{})
    Info(msg string, keysAndValues ...interface{})
    Warn(msg string, keysAndValues ...interface{})
    Error(msg string, keysAndValues ...interface{})
    With(keysAndValues ...interface{}) Logger
}

type slogLogger struct {
    logger *slog.Logger
}

func New(level slog.Level) Logger {
    handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
        Level: level,
    })
    
    return &slogLogger{
        logger: slog.New(handler),
    }
}

func (l *slogLogger) Info(msg string, keysAndValues ...interface{}) {
    l.logger.Info(msg, keysAndValues...)
}

// Add context-aware logging
func WithContext(ctx context.Context, logger Logger) Logger {
    // Extract correlation ID, user ID, etc. from context
    if correlationID := ctx.Value("correlation_id"); correlationID != nil {
        logger = logger.With("correlation_id", correlationID)
    }
    
    return logger
}
```

#### Error Handling

```go
// internal/domain/shared/errors.go
package shared

import (
    "errors"
    "fmt"
)

// Domain errors
var (
    ErrNotFound      = errors.New("resource not found")
    ErrAlreadyExists = errors.New("resource already exists")
    ErrInvalidInput  = errors.New("invalid input")
    ErrUnauthorized  = errors.New("unauthorized")
    ErrForbidden     = errors.New("forbidden")
)

// Application error with context
type AppError struct {
    Type    string
    Message string
    Cause   error
    Context map[string]interface{}
}

func (e *AppError) Error() string {
    if e.Cause != nil {
        return fmt.Sprintf("%s: %s: %v", e.Type, e.Message, e.Cause)
    }
    return fmt.Sprintf("%s: %s", e.Type, e.Message)
}

func (e *AppError) Unwrap() error {
    return e.Cause
}

func NewAppError(errorType, message string, cause error) *AppError {
    return &AppError{
        Type:    errorType,
        Message: message,
        Cause:   cause,
        Context: make(map[string]interface{}),
    }
}

func (e *AppError) WithContext(key string, value interface{}) *AppError {
    e.Context[key] = value
    return e
}
```

## Consequences

### Positive

- **Clear separation of concerns**: Each layer has well-defined responsibilities
- **Testability**: Dependencies can be easily mocked and tested in isolation
- **Maintainability**: Consistent structure makes code easier to navigate and modify
- **Scalability**: Structure supports team growth and feature expansion
- **Domain focus**: Business logic is protected from infrastructure concerns
- **Flexibility**: Infrastructure can be changed without affecting business logic

### Negative

- **Initial complexity**: More files and layers to understand initially
- **Boilerplate code**: Interfaces and dependency injection require more setup
- **Learning curve**: Team needs to understand architectural patterns
- **Over-engineering risk**: May be too complex for simple applications

### Mitigation Strategies

- **Start simple**: Begin with basic structure and add layers as needed
- **Document patterns**: Provide clear examples and guidelines
- **Code generation**: Use tools to generate boilerplate code
- **Team training**: Ensure team understands architectural decisions
- **Regular reviews**: Validate structure decisions against actual usage

## Best Practices

1. **Keep domain pure**: Domain layer should not depend on external concerns
2. **Use interfaces**: Define contracts between layers using interfaces
3. **Minimize dependencies**: Reduce coupling between packages
4. **Test each layer**: Write unit tests for domain logic, integration tests for infrastructure
5. **Document structure**: Maintain clear documentation of architectural decisions
6. **Review regularly**: Evaluate structure effectiveness and adjust as needed
7. **Follow naming conventions**: Use consistent naming across layers
8. **Separate concerns**: Keep different responsibilities in different packages

## References

- [Clean Architecture - Robert C. Martin](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Hexagonal Architecture](https://alistair.cockburn.us/hexagonal-architecture/)
- [Domain-Driven Design](https://domainlanguage.com/ddd/)
- [Go Project Layout](https://github.com/golang-standards/project-layout)
- [Cosmic Python](https://www.cosmicpython.com/)
- [NestJS Architecture](https://docs.nestjs.com/fundamentals/custom-providers)
- [Rails Application Structure](https://guides.rubyonrails.org/getting_started.html)
