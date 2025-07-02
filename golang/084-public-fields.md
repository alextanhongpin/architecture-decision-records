# Public Fields vs Private Fields Design Pattern

## Status

`accepted`

## Context

Go's visibility model uses capitalization to determine public vs private access. This creates design decisions about field visibility that affect API usability, testing, and maintainability. While encapsulation is important, Go's approach to simplicity and practicality sometimes favors public fields when combined with interfaces for behavior control.

Key considerations:
- **Constructor complexity**: Large constructors with many parameters
- **Testing flexibility**: Easy mocking and dependency injection
- **Interface boundaries**: Using interfaces to limit behavior while allowing field access
- **Performance**: Direct field access vs getter/setter overhead
- **Maintainability**: Balance between encapsulation and simplicity

## Decision

**Use public fields strategically, combined with interfaces to control behavior while maintaining simplicity:**

### 1. Public Fields for Configuration Structs

```go
package config

import (
    "time"
)

// Config structs benefit from public fields for easy initialization
type DatabaseConfig struct {
    Host            string        `json:"host" yaml:"host"`
    Port            int           `json:"port" yaml:"port"`
    Database        string        `json:"database" yaml:"database"`
    Username        string        `json:"username" yaml:"username"`
    Password        string        `json:"password" yaml:"password"`
    MaxConnections  int           `json:"max_connections" yaml:"max_connections"`
    ConnMaxLifetime time.Duration `json:"conn_max_lifetime" yaml:"conn_max_lifetime"`
    SSLMode         string        `json:"ssl_mode" yaml:"ssl_mode"`
}

// Easy initialization without complex constructors
func NewDatabaseConfig() *DatabaseConfig {
    return &DatabaseConfig{
        Host:            "localhost",
        Port:            5432,
        MaxConnections:  25,
        ConnMaxLifetime: time.Hour,
        SSLMode:         "prefer",
    }
}

// HTTPConfig demonstrates validation in a simple Validate method
type HTTPConfig struct {
    Host         string        `json:"host" yaml:"host"`
    Port         int           `json:"port" yaml:"port"`
    ReadTimeout  time.Duration `json:"read_timeout" yaml:"read_timeout"`
    WriteTimeout time.Duration `json:"write_timeout" yaml:"write_timeout"`
    IdleTimeout  time.Duration `json:"idle_timeout" yaml:"idle_timeout"`
    TLS          *TLSConfig    `json:"tls,omitempty" yaml:"tls,omitempty"`
}

type TLSConfig struct {
    Enabled  bool   `json:"enabled" yaml:"enabled"`
    CertFile string `json:"cert_file" yaml:"cert_file"`
    KeyFile  string `json:"key_file" yaml:"key_file"`
}

func (c *HTTPConfig) Validate() error {
    if c.Port < 1 || c.Port > 65535 {
        return fmt.Errorf("invalid port: %d", c.Port)
    }
    
    if c.ReadTimeout <= 0 {
        return fmt.Errorf("read timeout must be positive")
    }
    
    if c.TLS != nil && c.TLS.Enabled {
        if c.TLS.CertFile == "" || c.TLS.KeyFile == "" {
            return fmt.Errorf("TLS enabled but cert or key file not specified")
        }
    }
    
    return nil
}

// Usage: Simple and clear
func ExampleConfigUsage() {
    config := &HTTPConfig{
        Host:         "0.0.0.0",
        Port:         8080,
        ReadTimeout:  30 * time.Second,
        WriteTimeout: 30 * time.Second,
        IdleTimeout:  120 * time.Second,
        TLS: &TLSConfig{
            Enabled:  true,
            CertFile: "/path/to/cert.pem",
            KeyFile:  "/path/to/key.pem",
        },
    }
    
    if err := config.Validate(); err != nil {
        log.Fatal(err)
    }
}
```

### 2. Repository Pattern with Public Dependencies

```go
package repository

import (
    "context"
    "database/sql"
    "time"
    
    "github.com/redis/go-redis/v9"
)

// UserRepository with public dependencies for testing flexibility
type UserRepository struct {
    DB    *sql.DB           // Public for easy mocking
    Cache redis.Cmdable     // Interface type for easy testing
    Logger Logger           // Interface for logging
}

type Logger interface {
    Info(msg string, fields ...interface{})
    Error(msg string, fields ...interface{})
    Debug(msg string, fields ...interface{})
}

// Constructor is simple - no need for complex parameter objects
func NewUserRepository(db *sql.DB, cache redis.Cmdable, logger Logger) *UserRepository {
    return &UserRepository{
        DB:     db,
        Cache:  cache,
        Logger: logger,
    }
}

// Business logic remains encapsulated in methods
func (r *UserRepository) GetByID(ctx context.Context, id string) (*User, error) {
    // Try cache first
    cacheKey := fmt.Sprintf("user:%s", id)
    
    cached, err := r.Cache.Get(ctx, cacheKey).Result()
    if err == nil {
        var user User
        if err := json.Unmarshal([]byte(cached), &user); err == nil {
            r.Logger.Debug("cache hit for user", "id", id)
            return &user, nil
        }
    }
    
    // Query database
    query := `
        SELECT id, email, name, created_at, updated_at 
        FROM users 
        WHERE id = $1 AND deleted_at IS NULL
    `
    
    var user User
    err = r.DB.QueryRowContext(ctx, query, id).Scan(
        &user.ID, &user.Email, &user.Name,
        &user.CreatedAt, &user.UpdatedAt,
    )
    
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, ErrUserNotFound
        }
        r.Logger.Error("database query failed", "error", err, "id", id)
        return nil, fmt.Errorf("querying user: %w", err)
    }
    
    // Cache the result
    go func() {
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        
        if data, err := json.Marshal(user); err == nil {
            _ = r.Cache.Set(ctx, cacheKey, data, time.Hour).Err()
        }
    }()
    
    return &user, nil
}

func (r *UserRepository) Create(ctx context.Context, user *User) error {
    query := `
        INSERT INTO users (id, email, name, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5)
    `
    
    now := time.Now()
    user.CreatedAt = now
    user.UpdatedAt = now
    
    _, err := r.DB.ExecContext(ctx, query,
        user.ID, user.Email, user.Name,
        user.CreatedAt, user.UpdatedAt,
    )
    
    if err != nil {
        r.Logger.Error("failed to create user", "error", err, "user", user)
        return fmt.Errorf("creating user: %w", err)
    }
    
    r.Logger.Info("user created", "id", user.ID)
    return nil
}
```

### 3. Interface-Controlled Access Pattern

```go
package service

// Define behavior through interfaces, not field access
type UserService interface {
    GetUser(ctx context.Context, id string) (*User, error)
    CreateUser(ctx context.Context, req CreateUserRequest) (*User, error)
    UpdateUser(ctx context.Context, id string, req UpdateUserRequest) (*User, error)
}

// Implementation with public fields for dependency injection
type userService struct {
    Repo      UserRepository  // Public for testing
    Validator Validator       // Public for testing
    Events    EventPublisher  // Public for testing
    Cache     CacheService    // Public for testing
}

// Factory function enforces dependencies
func NewUserService(
    repo UserRepository,
    validator Validator,
    events EventPublisher,
    cache CacheService,
) UserService {
    return &userService{
        Repo:      repo,
        Validator: validator,
        Events:    events,
        Cache:     cache,
    }
}

func (s *userService) CreateUser(ctx context.Context, req CreateUserRequest) (*User, error) {
    // Validation
    if err := s.Validator.ValidateCreateUser(req); err != nil {
        return nil, fmt.Errorf("validation failed: %w", err)
    }
    
    // Create user entity
    user := &User{
        ID:    generateID(),
        Email: strings.ToLower(strings.TrimSpace(req.Email)),
        Name:  strings.TrimSpace(req.Name),
    }
    
    // Persist
    if err := s.Repo.Create(ctx, user); err != nil {
        return nil, err
    }
    
    // Publish event
    go func() {
        event := UserCreatedEvent{
            UserID:    user.ID,
            Email:     user.Email,
            Timestamp: time.Now(),
        }
        _ = s.Events.Publish(ctx, event)
    }()
    
    return user, nil
}

// Usage: Interface limits access to behavior only
func ExampleServiceUsage() {
    var service UserService = NewUserService(repo, validator, events, cache)
    
    // Can only call defined interface methods
    user, err := service.CreateUser(ctx, req)
    
    // Cannot access internal fields - this would not compile:
    // service.Repo.SomeMethod() // Error: UserService has no field Repo
}
```

### 4. Easy Testing with Public Fields

```go
package service_test

import (
    "context"
    "testing"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
)

// Mock implementations are simple to create
type MockUserRepository struct {
    mock.Mock
}

func (m *MockUserRepository) GetByID(ctx context.Context, id string) (*User, error) {
    args := m.Called(ctx, id)
    return args.Get(0).(*User), args.Error(1)
}

func (m *MockUserRepository) Create(ctx context.Context, user *User) error {
    args := m.Called(ctx, user)
    return args.Error(0)
}

type MockValidator struct {
    mock.Mock
}

func (m *MockValidator) ValidateCreateUser(req CreateUserRequest) error {
    args := m.Called(req)
    return args.Error(0)
}

type MockEventPublisher struct {
    mock.Mock
}

func (m *MockEventPublisher) Publish(ctx context.Context, event interface{}) error {
    args := m.Called(ctx, event)
    return args.Error(0)
}

type MockCacheService struct {
    mock.Mock
}

func (m *MockCacheService) Get(ctx context.Context, key string) (interface{}, error) {
    args := m.Called(ctx, key)
    return args.Get(0), args.Error(1)
}

func TestUserService_CreateUser(t *testing.T) {
    // Easy setup with public fields
    mockRepo := &MockUserRepository{}
    mockValidator := &MockValidator{}
    mockEvents := &MockEventPublisher{}
    mockCache := &MockCacheService{}
    
    // Create service - simple constructor
    service := NewUserService(mockRepo, mockValidator, mockEvents, mockCache)
    
    // Cast to concrete type to access fields if needed for testing
    impl := service.(*userService)
    
    t.Run("successful creation", func(t *testing.T) {
        req := CreateUserRequest{
            Email: "test@example.com",
            Name:  "Test User",
        }
        
        // Setup mocks
        mockValidator.On("ValidateCreateUser", req).Return(nil)
        mockRepo.On("Create", mock.Anything, mock.AnythingOfType("*User")).Return(nil)
        mockEvents.On("Publish", mock.Anything, mock.AnythingOfType("UserCreatedEvent")).Return(nil)
        
        // Execute
        user, err := service.CreateUser(context.Background(), req)
        
        // Assert
        assert.NoError(t, err)
        assert.NotNil(t, user)
        assert.Equal(t, "test@example.com", user.Email)
        assert.Equal(t, "Test User", user.Name)
        
        // Verify all mocks were called
        mockValidator.AssertExpectations(t)
        mockRepo.AssertExpectations(t)
        // Note: Events might be called asynchronously
    })
    
    t.Run("validation error", func(t *testing.T) {
        req := CreateUserRequest{
            Email: "invalid-email",
            Name:  "",
        }
        
        validationErr := errors.New("invalid email format")
        mockValidator.On("ValidateCreateUser", req).Return(validationErr)
        
        user, err := service.CreateUser(context.Background(), req)
        
        assert.Error(t, err)
        assert.Nil(t, user)
        assert.Contains(t, err.Error(), "validation failed")
        
        mockValidator.AssertExpectations(t)
    })
    
    t.Run("direct field access for testing", func(t *testing.T) {
        // Can access fields directly for advanced testing scenarios
        assert.Same(t, mockRepo, impl.Repo)
        assert.Same(t, mockValidator, impl.Validator)
        
        // This enables white-box testing when needed
        originalRepo := impl.Repo
        impl.Repo = &MockUserRepository{} // Swap dependency
        
        // Test with swapped dependency...
        
        // Restore
        impl.Repo = originalRepo
    })
}
```

### 5. Builder Pattern with Public Fields

```go
package builder

// HTTPServerBuilder demonstrates public fields for configuration
type HTTPServerBuilder struct {
    Host            string
    Port            int
    ReadTimeout     time.Duration
    WriteTimeout    time.Duration
    MaxHeaderBytes  int
    TLSConfig       *tls.Config
    Middlewares     []func(http.Handler) http.Handler
    ErrorHandler    func(http.ResponseWriter, *http.Request, error)
}

func NewHTTPServerBuilder() *HTTPServerBuilder {
    return &HTTPServerBuilder{
        Host:           "localhost",
        Port:           8080,
        ReadTimeout:    30 * time.Second,
        WriteTimeout:   30 * time.Second,
        MaxHeaderBytes: 1 << 20, // 1 MB
    }
}

// Fluent API methods for common configurations
func (b *HTTPServerBuilder) WithHost(host string) *HTTPServerBuilder {
    b.Host = host
    return b
}

func (b *HTTPServerBuilder) WithPort(port int) *HTTPServerBuilder {
    b.Port = port
    return b
}

func (b *HTTPServerBuilder) WithTLS(certFile, keyFile string) *HTTPServerBuilder {
    cert, err := tls.LoadX509KeyPair(certFile, keyFile)
    if err != nil {
        panic(fmt.Sprintf("loading TLS cert: %v", err))
    }
    
    b.TLSConfig = &tls.Config{
        Certificates: []tls.Certificate{cert},
    }
    return b
}

func (b *HTTPServerBuilder) WithMiddleware(middleware func(http.Handler) http.Handler) *HTTPServerBuilder {
    b.Middlewares = append(b.Middlewares, middleware)
    return b
}

func (b *HTTPServerBuilder) Build(handler http.Handler) *http.Server {
    // Chain middlewares
    for i := len(b.Middlewares) - 1; i >= 0; i-- {
        handler = b.Middlewares[i](handler)
    }
    
    server := &http.Server{
        Addr:           fmt.Sprintf("%s:%d", b.Host, b.Port),
        Handler:        handler,
        ReadTimeout:    b.ReadTimeout,
        WriteTimeout:   b.WriteTimeout,
        MaxHeaderBytes: b.MaxHeaderBytes,
        TLSConfig:      b.TLSConfig,
    }
    
    if b.ErrorHandler != nil {
        // Custom error handling would be implemented here
    }
    
    return server
}

// Usage: Flexible configuration with public fields
func ExampleBuilderUsage() {
    // Direct field access for complex configuration
    builder := NewHTTPServerBuilder()
    builder.Host = "0.0.0.0"
    builder.Port = 8443
    builder.ReadTimeout = 60 * time.Second
    builder.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
        log.Printf("HTTP error: %v", err)
        http.Error(w, "Internal Server Error", http.StatusInternalServerError)
    }
    
    // Or fluent API
    server := NewHTTPServerBuilder().
        WithHost("0.0.0.0").
        WithPort(8443).
        WithTLS("cert.pem", "key.pem").
        WithMiddleware(loggingMiddleware).
        Build(myHandler)
    
    log.Fatal(server.ListenAndServeTLS("", ""))
}
```

### 6. When to Use Private Fields

```go
package counter

import (
    "sync/atomic"
    "time"
)

// Counter shows when private fields make sense
type Counter struct {
    // Private: Internal state that should not be accessed directly
    value    int64
    created  time.Time
    lastSeen int64 // Unix timestamp
}

func NewCounter() *Counter {
    return &Counter{
        created:  time.Now(),
        lastSeen: time.Now().Unix(),
    }
}

// Controlled access through methods
func (c *Counter) Increment() int64 {
    atomic.StoreInt64(&c.lastSeen, time.Now().Unix())
    return atomic.AddInt64(&c.value, 1)
}

func (c *Counter) Get() int64 {
    return atomic.LoadInt64(&c.value)
}

func (c *Counter) Reset() {
    atomic.StoreInt64(&c.value, 0)
    atomic.StoreInt64(&c.lastSeen, time.Now().Unix())
}

// Public read-only access where appropriate
func (c *Counter) Created() time.Time {
    return c.created
}

func (c *Counter) LastActivity() time.Time {
    timestamp := atomic.LoadInt64(&c.lastSeen)
    return time.Unix(timestamp, 0)
}
```

## Guidelines for Field Visibility

### Use Public Fields When:
1. **Configuration structs** - Easy initialization and testing
2. **Data transfer objects** - Simple value containers
3. **Dependencies in services** - Enable easy mocking and testing
4. **Builder patterns** - Flexible configuration
5. **Testing utilities** - Direct access for test setup

### Use Private Fields When:
1. **Internal state** - Values that must be controlled (counters, caches)
2. **Complex invariants** - State that requires validation
3. **Thread safety** - Fields accessed with synchronization
4. **Computed values** - Derived from other fields
5. **Implementation details** - May change without notice

## Consequences

**Benefits:**
- **Simplicity**: Reduce boilerplate constructors and getters/setters
- **Testing**: Easy mocking and dependency injection
- **Flexibility**: Direct field access when needed
- **Performance**: No method call overhead for field access
- **Clarity**: Clear data structures without excessive encapsulation

**Trade-offs:**
- **Encapsulation**: Less control over field access and modification
- **API stability**: Public fields become part of the API contract
- **Validation**: Need explicit validation methods
- **Thread safety**: Direct field access may bypass synchronization

**Best Practices:**
1. Use interfaces to control behavior regardless of field visibility
2. Provide validation methods for public fields when needed
3. Document thread-safety requirements clearly
4. Consider backward compatibility when making fields public
5. Use public fields for configuration, private for internal state

## References

- [Effective Go](https://golang.org/doc/effective_go.html#names)
- [Go Code Review Comments](https://github.com/golang/go/wiki/CodeReviewComments)
- [API Design Best Practices](https://github.com/golang/go/wiki/APIChecklist)
