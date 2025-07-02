# ADR 003: Constructor and Factory Patterns in Go

## Status

**Accepted**

## Context

Go doesn't have built-in constructors like object-oriented languages, but we need standardized patterns for creating and initializing structs safely. Without clear patterns, teams often:

- Create inconsistent initialization methods
- Skip essential validation during object creation
- Expose internal struct details unnecessarily
- Create constructors that are difficult to test or extend

We need clear guidelines for when and how to use different creation patterns:
- Simple constructors
- Factory methods
- Builder patterns
- Functional options

## Decision

We will adopt a structured approach to object creation patterns based on complexity and requirements:

### 1. Constructor Naming Conventions

```go
// Use "New" prefix for constructors returning pointers
func NewUser(name string, age int) *User

// Use "Make" prefix for constructors returning values  
func MakePoint(x, y float64) Point

// Use descriptive names for specialized constructors
func NewUserFromEmail(email string) (*User, error)
func NewAdminUser(name string) *User
```

### 2. Simple Constructors

Use for structs with 1-3 required parameters and simple validation:

```go
package user

import (
    "errors"
    "fmt"
    "time"
)

type User struct {
    id        string
    name      string
    email     string
    age       int
    createdAt time.Time
}

// NewUser creates a new user with validation
func NewUser(name, email string, age int) (*User, error) {
    if name == "" {
        return nil, errors.New("name cannot be empty")
    }
    if email == "" {
        return nil, errors.New("email cannot be empty")
    }
    if age < 0 || age > 150 {
        return nil, errors.New("age must be between 0 and 150")
    }
    
    return &User{
        id:        generateID(),
        name:      name,
        email:     email,
        age:       age,
        createdAt: time.Now(),
    }, nil
}

// Getters for encapsulated fields
func (u *User) ID() string        { return u.id }
func (u *User) Name() string      { return u.name }
func (u *User) Email() string     { return u.email }
func (u *User) Age() int          { return u.age }
func (u *User) CreatedAt() time.Time { return u.createdAt }

func generateID() string {
    // Implementation for generating unique ID
    return fmt.Sprintf("user_%d", time.Now().UnixNano())
}
```

### 3. Factory Methods

Use for complex object creation, dependency injection, or when multiple creation strategies exist:

```go
package database

import (
    "database/sql"
    "fmt"
    "time"
)

type ConnectionPool struct {
    db          *sql.DB
    maxOpen     int
    maxIdle     int
    maxLifetime time.Duration
}

type DatabaseConfig struct {
    Host     string
    Port     int
    Database string
    Username string
    Password string
    SSLMode  string
}

// Factory for different database types
type ConnectionFactory struct{}

func NewConnectionFactory() *ConnectionFactory {
    return &ConnectionFactory{}
}

func (f *ConnectionFactory) CreatePostgresPool(config DatabaseConfig, poolConfig PoolConfig) (*ConnectionPool, error) {
    dsn := fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=%s",
        config.Host, config.Port, config.Username, config.Password, config.Database, config.SSLMode)
    
    db, err := sql.Open("postgres", dsn)
    if err != nil {
        return nil, fmt.Errorf("failed to open database: %w", err)
    }
    
    return f.configurePool(db, poolConfig)
}

func (f *ConnectionFactory) CreateMySQLPool(config DatabaseConfig, poolConfig PoolConfig) (*ConnectionPool, error) {
    dsn := fmt.Sprintf("%s:%s@tcp(%s:%d)/%s",
        config.Username, config.Password, config.Host, config.Port, config.Database)
    
    db, err := sql.Open("mysql", dsn)
    if err != nil {
        return nil, fmt.Errorf("failed to open database: %w", err)
    }
    
    return f.configurePool(db, poolConfig)
}

type PoolConfig struct {
    MaxOpenConns    int
    MaxIdleConns    int
    ConnMaxLifetime time.Duration
}

func (f *ConnectionFactory) configurePool(db *sql.DB, config PoolConfig) (*ConnectionPool, error) {
    db.SetMaxOpenConns(config.MaxOpenConns)
    db.SetMaxIdleConns(config.MaxIdleConns)
    db.SetConnMaxLifetime(config.ConnMaxLifetime)
    
    if err := db.Ping(); err != nil {
        return nil, fmt.Errorf("failed to ping database: %w", err)
    }
    
    return &ConnectionPool{
        db:          db,
        maxOpen:     config.MaxOpenConns,
        maxIdle:     config.MaxIdleConns,
        maxLifetime: config.ConnMaxLifetime,
    }, nil
}
```

### 4. Builder Pattern

Use for objects with many optional parameters or complex construction logic:

```go
package http

import (
    "context"
    "net/http"
    "time"
)

type Client struct {
    httpClient  *http.Client
    baseURL     string
    userAgent   string
    timeout     time.Duration
    retryCount  int
    headers     map[string]string
    middleware  []Middleware
}

type ClientBuilder struct {
    baseURL    string
    userAgent  string
    timeout    time.Duration
    retryCount int
    headers    map[string]string
    middleware []Middleware
    transport  http.RoundTripper
}

func NewClientBuilder() *ClientBuilder {
    return &ClientBuilder{
        userAgent:  "go-client/1.0",
        timeout:    30 * time.Second,
        retryCount: 3,
        headers:    make(map[string]string),
        middleware: make([]Middleware, 0),
    }
}

func (b *ClientBuilder) BaseURL(url string) *ClientBuilder {
    b.baseURL = url
    return b
}

func (b *ClientBuilder) UserAgent(ua string) *ClientBuilder {
    b.userAgent = ua
    return b
}

func (b *ClientBuilder) Timeout(timeout time.Duration) *ClientBuilder {
    b.timeout = timeout
    return b
}

func (b *ClientBuilder) RetryCount(count int) *ClientBuilder {
    b.retryCount = count
    return b
}

func (b *ClientBuilder) Header(key, value string) *ClientBuilder {
    b.headers[key] = value
    return b
}

func (b *ClientBuilder) Middleware(mw Middleware) *ClientBuilder {
    b.middleware = append(b.middleware, mw)
    return b
}

func (b *ClientBuilder) Transport(transport http.RoundTripper) *ClientBuilder {
    b.transport = transport
    return b
}

func (b *ClientBuilder) Build() *Client {
    httpClient := &http.Client{
        Timeout:   b.timeout,
        Transport: b.transport,
    }
    
    return &Client{
        httpClient: httpClient,
        baseURL:    b.baseURL,
        userAgent:  b.userAgent,
        timeout:    b.timeout,
        retryCount: b.retryCount,
        headers:    b.headers,
        middleware: b.middleware,
    }
}

type Middleware func(http.RoundTripper) http.RoundTripper

// Usage example
func createHTTPClient() *Client {
    return NewClientBuilder().
        BaseURL("https://api.example.com").
        UserAgent("my-app/1.0").
        Timeout(10 * time.Second).
        RetryCount(5).
        Header("Authorization", "Bearer token").
        Header("Content-Type", "application/json").
        Build()
}
```

### 5. Registry Pattern

Use for managing multiple factories or when you need runtime factory selection:

```go
package logger

import (
    "fmt"
    "os"
)

type Logger interface {
    Info(msg string)
    Error(msg string)
    Debug(msg string)
}

type LoggerFactory func(config map[string]interface{}) (Logger, error)

type LoggerRegistry struct {
    factories map[string]LoggerFactory
}

func NewLoggerRegistry() *LoggerRegistry {
    registry := &LoggerRegistry{
        factories: make(map[string]LoggerFactory),
    }
    
    // Register built-in factories
    registry.Register("console", NewConsoleLogger)
    registry.Register("file", NewFileLogger)
    registry.Register("json", NewJSONLogger)
    
    return registry
}

func (r *LoggerRegistry) Register(name string, factory LoggerFactory) {
    r.factories[name] = factory
}

func (r *LoggerRegistry) Create(loggerType string, config map[string]interface{}) (Logger, error) {
    factory, exists := r.factories[loggerType]
    if !exists {
        return nil, fmt.Errorf("unknown logger type: %s", loggerType)
    }
    
    return factory(config)
}

func (r *LoggerRegistry) ListTypes() []string {
    types := make([]string, 0, len(r.factories))
    for name := range r.factories {
        types = append(types, name)
    }
    return types
}

// Factory implementations
func NewConsoleLogger(config map[string]interface{}) (Logger, error) {
    return &ConsoleLogger{output: os.Stdout}, nil
}

func NewFileLogger(config map[string]interface{}) (Logger, error) {
    filename, ok := config["filename"].(string)
    if !ok {
        return nil, fmt.Errorf("filename required for file logger")
    }
    
    file, err := os.OpenFile(filename, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
    if err != nil {
        return nil, fmt.Errorf("failed to open log file: %w", err)
    }
    
    return &FileLogger{file: file}, nil
}

func NewJSONLogger(config map[string]interface{}) (Logger, error) {
    return &JSONLogger{output: os.Stdout}, nil
}
```

### 6. Abstract Factory Pattern

Use when you need to create families of related objects:

```go
package notification

import "fmt"

// Abstract products
type EmailSender interface {
    SendEmail(to, subject, body string) error
}

type SMSSender interface {
    SendSMS(to, message string) error
}

type PushSender interface {
    SendPush(deviceID, message string) error
}

// Abstract factory
type NotificationFactory interface {
    CreateEmailSender() EmailSender
    CreateSMSSender() SMSSender  
    CreatePushSender() PushSender
}

// Concrete factory for production
type ProductionNotificationFactory struct {
    apiKey    string
    baseURL   string
}

func NewProductionNotificationFactory(apiKey, baseURL string) *ProductionNotificationFactory {
    return &ProductionNotificationFactory{
        apiKey:  apiKey,
        baseURL: baseURL,
    }
}

func (f *ProductionNotificationFactory) CreateEmailSender() EmailSender {
    return &ProductionEmailSender{
        apiKey:  f.apiKey,
        baseURL: f.baseURL,
    }
}

func (f *ProductionNotificationFactory) CreateSMSSender() SMSSender {
    return &ProductionSMSSender{
        apiKey:  f.apiKey,
        baseURL: f.baseURL,
    }
}

func (f *ProductionNotificationFactory) CreatePushSender() PushSender {
    return &ProductionPushSender{
        apiKey:  f.apiKey,
        baseURL: f.baseURL,
    }
}

// Concrete factory for testing
type MockNotificationFactory struct{}

func NewMockNotificationFactory() *MockNotificationFactory {
    return &MockNotificationFactory{}
}

func (f *MockNotificationFactory) CreateEmailSender() EmailSender {
    return &MockEmailSender{}
}

func (f *MockNotificationFactory) CreateSMSSender() SMSSender {
    return &MockSMSSender{}
}

func (f *MockNotificationFactory) CreatePushSender() PushSender {
    return &MockPushSender{}
}
```

### 7. Testing Constructors

```go
package user_test

import (
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestNewUser(t *testing.T) {
    tests := []struct {
        name        string
        userName    string
        email       string
        age         int
        expectError bool
        errorMsg    string
    }{
        {
            name:     "valid user",
            userName: "John Doe",
            email:    "john@example.com", 
            age:      25,
        },
        {
            name:        "empty name",
            userName:    "",
            email:       "john@example.com",
            age:         25,
            expectError: true,
            errorMsg:    "name cannot be empty",
        },
        {
            name:        "empty email",
            userName:    "John Doe",
            email:       "",
            age:         25,
            expectError: true,
            errorMsg:    "email cannot be empty",
        },
        {
            name:        "negative age",
            userName:    "John Doe", 
            email:       "john@example.com",
            age:         -1,
            expectError: true,
            errorMsg:    "age must be between 0 and 150",
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            user, err := NewUser(tt.userName, tt.email, tt.age)
            
            if tt.expectError {
                require.Error(t, err)
                assert.Contains(t, err.Error(), tt.errorMsg)
                assert.Nil(t, user)
            } else {
                require.NoError(t, err)
                require.NotNil(t, user)
                assert.Equal(t, tt.userName, user.Name())
                assert.Equal(t, tt.email, user.Email())
                assert.Equal(t, tt.age, user.Age())
                assert.NotEmpty(t, user.ID())
                assert.False(t, user.CreatedAt().IsZero())
            }
        })
    }
}

func TestBuilderPattern(t *testing.T) {
    client := NewClientBuilder().
        BaseURL("https://api.test.com").
        Timeout(5 * time.Second).
        RetryCount(2).
        Header("Authorization", "Bearer test").
        Build()
    
    assert.NotNil(t, client)
    // Additional assertions for built client
}
```

## Implementation Guidelines

### When to Use Each Pattern

1. **Simple Constructor** (`NewX`):
   - 1-3 required parameters
   - Simple validation
   - Single creation strategy

2. **Factory Method**:
   - Complex initialization logic
   - Multiple creation strategies
   - Dependency injection needed

3. **Builder Pattern**:
   - Many optional parameters (>4)
   - Complex configuration
   - Fluent API desired

4. **Abstract Factory**:
   - Creating families of related objects
   - Runtime factory selection
   - Environment-specific implementations

### Error Handling

```go
// Constructor with validation
func NewUser(name string, age int) (*User, error) {
    if name == "" {
        return nil, errors.New("name is required")
    }
    if age < 0 {
        return nil, errors.New("age must be non-negative")
    }
    return &User{name: name, age: age}, nil
}

// Must constructor for cases where failure is not expected
func MustNewUser(name string, age int) *User {
    user, err := NewUser(name, age)
    if err != nil {
        panic(fmt.Sprintf("failed to create user: %v", err))
    }
    return user
}
```

### Zero Values and Optional Fields

```go
type Config struct {
    Host     string        // required
    Port     int           // required  
    Timeout  time.Duration // optional, has default
    Debug    bool          // optional, zero value is fine
}

func NewConfig(host string, port int) *Config {
    return &Config{
        Host:    host,
        Port:    port,
        Timeout: 30 * time.Second, // sensible default
        Debug:   false,            // explicit zero value
    }
}
```

## Consequences

### Positive
- **Consistent object creation**: Standardized patterns across codebase
- **Better encapsulation**: Private fields with controlled initialization
- **Improved validation**: Required parameters are validated at creation
- **Enhanced testability**: Constructors can be easily mocked and tested
- **Clear API contracts**: Explicit requirements for object creation

### Negative
- **Additional complexity**: More code required for simple objects
- **Potential over-engineering**: Risk of using complex patterns unnecessarily
- **Learning curve**: Team needs to understand when to use each pattern

## Best Practices

1. **Prefer constructors over exported fields** for any non-trivial struct
2. **Always validate required parameters** in constructors
3. **Use meaningful names** that indicate the creation strategy
4. **Return errors for validation failures** rather than panicking
5. **Provide Must variants** only when failure indicates programmer error
6. **Keep builders immutable** - return new instances rather than modifying
7. **Document constructor requirements** clearly in comments

## Anti-patterns to Avoid

```go
// ❌ Bad: Too many parameters
func NewUser(name, email, phone, address, city, state, zip, country string, age int, active bool) *User

// ✅ Good: Use builder or config struct
func NewUser(config UserConfig) (*User, error)

// ❌ Bad: Mutable builder
func (b *Builder) SetName(name string) { b.name = name }

// ✅ Good: Immutable builder  
func (b *Builder) WithName(name string) *Builder { ... }

// ❌ Bad: No validation
func NewUser(name string, age int) *User {
    return &User{name: name, age: age}
}

// ✅ Good: With validation
func NewUser(name string, age int) (*User, error) {
    if name == "" {
        return nil, errors.New("name required")
    }
    return &User{name: name, age: age}, nil
}
```

## References

- [Effective Go - Constructors and composite literals](https://golang.org/doc/effective_go.html#composite_literals)
- [Go Code Review Comments - Constructors](https://github.com/golang/go/wiki/CodeReviewComments#constructor)
- [Design Patterns in Go](https://github.com/tmrts/go-patterns)
- [Builder Pattern in Go](https://golang.cafe/blog/golang-builder-pattern.html)
