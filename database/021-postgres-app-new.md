# PostgreSQL-Centric Application Architecture (DApp)

## Status

`accepted`

## Context

Modern applications require sophisticated database integration patterns that go beyond simple CRUD operations. PostgreSQL-centric applications (DApps) leverage the database as a primary component for business logic, state management, and coordination. This approach maximizes PostgreSQL's capabilities while maintaining clean application architecture.

The challenge is building applications that use PostgreSQL effectively for complex operations like distributed transactions, idempotency, locking, and state management while keeping the codebase maintainable and extensible.

## Decision

Implement a comprehensive PostgreSQL-centric application framework (DApp) that provides reusable components for common database patterns, supports extensibility through hooks, and maintains clean separation of concerns while leveraging PostgreSQL's advanced features.

## Architecture

### Core Components

1. **Transaction Manager**: Unified transaction handling
2. **Repository Pattern**: Swappable data access layer
3. **Hook System**: Pre/post operation extensibility
4. **Component Library**: Reusable database-backed components
5. **Migration System**: Database schema management
6. **Configuration Management**: Runtime configuration

### Framework Structure

```go
// Core framework interfaces
type DApp interface {
    Initialize(ctx context.Context) error
    Migrate(ctx context.Context) error
    Components() ComponentRegistry
    Transaction(ctx context.Context, fn func(Tx) error) error
}

type ComponentRegistry interface {
    Register(name string, component Component) error
    Get(name string) (Component, error)
    List() []string
}

type Component interface {
    Initialize(ctx context.Context, tx Tx) error
    Name() string
    Dependencies() []string
}

type Tx interface {
    Exec(query string, args ...interface{}) (sql.Result, error)
    Query(query string, args ...interface{}) (*sql.Rows, error)
    QueryRow(query string, args ...interface{}) *sql.Row
    Prepare(query string) (*sql.Stmt, error)
    Rollback() error
    Commit() error
}
```

## Implementation

### Core DApp Framework

```go
package dapp

import (
    "context"
    "database/sql"
    "fmt"
    "sort"
    "sync"
    "time"
    
    "github.com/lib/pq"
    _ "github.com/lib/pq"
)

type App struct {
    db          *sql.DB
    components  map[string]Component
    hooks       map[string][]Hook
    config      *Config
    mu          sync.RWMutex
    initialized bool
}

type Config struct {
    DatabaseURL     string                 `json:"database_url"`
    MigrationsPath  string                 `json:"migrations_path"`
    Components      map[string]interface{} `json:"components"`
    Hooks           map[string][]string    `json:"hooks"`
    MaxConnections  int                    `json:"max_connections"`
    MaxIdleConns    int                    `json:"max_idle_conns"`
    ConnMaxLifetime string                 `json:"conn_max_lifetime"`
}

type Hook interface {
    Execute(ctx context.Context, tx Tx, data interface{}) error
    Priority() int
}

type hookList []Hook

func (h hookList) Len() int           { return len(h) }
func (h hookList) Less(i, j int) bool { return h[i].Priority() < h[j].Priority() }
func (h hookList) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }

func NewApp(config *Config) (*App, error) {
    db, err := sql.Open("postgres", config.DatabaseURL)
    if err != nil {
        return nil, fmt.Errorf("open database: %w", err)
    }
    
    // Configure connection pool
    db.SetMaxOpenConns(config.MaxConnections)
    db.SetMaxIdleConns(config.MaxIdleConns)
    if config.ConnMaxLifetime != "" {
        if duration, err := time.ParseDuration(config.ConnMaxLifetime); err == nil {
            db.SetConnMaxLifetime(duration)
        }
    }
    
    return &App{
        db:         db,
        components: make(map[string]Component),
        hooks:      make(map[string][]Hook),
        config:     config,
    }, nil
}

func (a *App) Initialize(ctx context.Context) error {
    a.mu.Lock()
    defer a.mu.Unlock()
    
    if a.initialized {
        return nil
    }
    
    // Test database connection
    if err := a.db.PingContext(ctx); err != nil {
        return fmt.Errorf("ping database: %w", err)
    }
    
    // Run migrations
    if err := a.runMigrations(ctx); err != nil {
        return fmt.Errorf("run migrations: %w", err)
    }
    
    // Initialize components in dependency order
    if err := a.initializeComponents(ctx); err != nil {
        return fmt.Errorf("initialize components: %w", err)
    }
    
    a.initialized = true
    return nil
}

func (a *App) Register(component Component) error {
    a.mu.Lock()
    defer a.mu.Unlock()
    
    if a.initialized {
        return fmt.Errorf("cannot register component after initialization")
    }
    
    a.components[component.Name()] = component
    return nil
}

func (a *App) RegisterHook(event string, hook Hook) error {
    a.mu.Lock()
    defer a.mu.Unlock()
    
    a.hooks[event] = append(a.hooks[event], hook)
    sort.Sort(hookList(a.hooks[event]))
    return nil
}

func (a *App) Transaction(ctx context.Context, fn func(Tx) error) error {
    tx, err := a.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }
    
    defer func() {
        if r := recover(); r != nil {
            tx.Rollback()
            panic(r)
        }
    }()
    
    wrapper := &txWrapper{tx: tx}
    
    if err := fn(wrapper); err != nil {
        tx.Rollback()
        return err
    }
    
    return tx.Commit()
}

func (a *App) executeHooks(ctx context.Context, event string, tx Tx, data interface{}) error {
    a.mu.RLock()
    hooks := a.hooks[event]
    a.mu.RUnlock()
    
    for _, hook := range hooks {
        if err := hook.Execute(ctx, tx, data); err != nil {
            return fmt.Errorf("hook %T failed: %w", hook, err)
        }
    }
    
    return nil
}

func (a *App) initializeComponents(ctx context.Context) error {
    // Topological sort based on dependencies
    ordered, err := a.topologicalSort()
    if err != nil {
        return fmt.Errorf("resolve dependencies: %w", err)
    }
    
    return a.Transaction(ctx, func(tx Tx) error {
        for _, component := range ordered {
            if err := component.Initialize(ctx, tx); err != nil {
                return fmt.Errorf("initialize %s: %w", component.Name(), err)
            }
        }
        return nil
    })
}

func (a *App) topologicalSort() ([]Component, error) {
    visited := make(map[string]bool)
    temp := make(map[string]bool)
    var result []Component
    
    var visit func(string) error
    visit = func(name string) error {
        if temp[name] {
            return fmt.Errorf("circular dependency detected: %s", name)
        }
        if visited[name] {
            return nil
        }
        
        component, exists := a.components[name]
        if !exists {
            return fmt.Errorf("component not found: %s", name)
        }
        
        temp[name] = true
        
        for _, dep := range component.Dependencies() {
            if err := visit(dep); err != nil {
                return err
            }
        }
        
        temp[name] = false
        visited[name] = true
        result = append([]Component{component}, result...)
        
        return nil
    }
    
    for name := range a.components {
        if err := visit(name); err != nil {
            return nil, err
        }
    }
    
    return result, nil
}

type txWrapper struct {
    tx *sql.Tx
}

func (t *txWrapper) Exec(query string, args ...interface{}) (sql.Result, error) {
    return t.tx.Exec(query, args...)
}

func (t *txWrapper) Query(query string, args ...interface{}) (*sql.Rows, error) {
    return t.tx.Query(query, args...)
}

func (t *txWrapper) QueryRow(query string, args ...interface{}) *sql.Row {
    return t.tx.QueryRow(query, args...)
}

func (t *txWrapper) Prepare(query string) (*sql.Stmt, error) {
    return t.tx.Prepare(query)
}

func (t *txWrapper) Rollback() error {
    return t.tx.Rollback()
}

func (t *txWrapper) Commit() error {
    return t.tx.Commit()
}
```

### DApp Components

Available DApp components for common database patterns:

1. **Authentication** - User authentication and session management
2. **Idempotency** - Idempotent operation handling
3. **Saga** - Distributed transaction management
4. **Locking** - Distributed locking mechanisms
5. **Config** - Dynamic configuration management
6. **Feature Flags** - Feature toggle management
7. **A/B Testing** - Experiment management
8. **Queue** - Job queue implementation
9. **Tagging** - Entity tagging system
10. **Audit** - Change tracking and audit trails

### Usage Examples

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"
    "net/http"
    
    "your-app/dapp"
    "your-app/dapp/auth"
    "your-app/dapp/idempotency"
)

func main() {
    // Initialize DApp
    config := &dapp.Config{
        DatabaseURL:     "postgres://user:pass@localhost/db?sslmode=disable",
        MigrationsPath:  "./migrations",
        MaxConnections:  25,
        MaxIdleConns:    10,
        ConnMaxLifetime: "5m",
    }
    
    app, err := dapp.NewApp(config)
    if err != nil {
        log.Fatal(err)
    }
    
    // Register components
    app.Register(auth.NewAuthComponent(app))
    app.Register(idempotency.NewIdempotencyComponent(app))
    
    // Register hooks
    app.RegisterHook("auth.pre_register", &EmailValidationHook{})
    app.RegisterHook("auth.post_register", &WelcomeEmailHook{})
    
    // Initialize
    if err := app.Initialize(context.Background()); err != nil {
        log.Fatal(err)
    }
    
    // Create services
    authService := auth.NewAuthService(app)
    idempotencyService := idempotency.NewIdempotencyService(app)
    
    // Setup HTTP handlers
    http.HandleFunc("/register", handleRegister(authService))
    http.HandleFunc("/login", handleLogin(authService))
    http.HandleFunc("/transfer", handleTransfer(idempotencyService))
    
    log.Fatal(http.ListenAndServe(":8080", nil))
}

// Custom hooks
type EmailValidationHook struct{}

func (h *EmailValidationHook) Execute(ctx context.Context, tx dapp.Tx, data interface{}) error {
    hookData := data.(map[string]interface{})
    email := hookData["email"].(string)
    
    // Custom email validation logic
    if !isValidEmail(email) {
        return fmt.Errorf("invalid email format")
    }
    
    // Check if email is blacklisted
    var count int
    err := tx.QueryRow("SELECT COUNT(*) FROM email_blacklist WHERE email = $1", email).Scan(&count)
    if err != nil {
        return err
    }
    
    if count > 0 {
        return fmt.Errorf("email is blacklisted")
    }
    
    return nil
}

func (h *EmailValidationHook) Priority() int {
    return 10
}

type WelcomeEmailHook struct{}

func (h *WelcomeEmailHook) Execute(ctx context.Context, tx dapp.Tx, data interface{}) error {
    hookData := data.(map[string]interface{})
    user := hookData["user"].(*auth.User)
    
    // Queue welcome email
    _, err := tx.Exec(`
        INSERT INTO email_queue (user_id, template, data)
        VALUES ($1, 'welcome', $2)`,
        user.ID, fmt.Sprintf(`{"name": "%s"}`, user.Email))
    
    return err
}

func (h *WelcomeEmailHook) Priority() int {
    return 20
}

// HTTP handlers
func handleRegister(authService *auth.AuthService) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        var req struct {
            Email    string `json:"email"`
            Password string `json:"password"`
        }
        
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            http.Error(w, "Invalid request", http.StatusBadRequest)
            return
        }
        
        user, err := authService.Register(r.Context(), req.Email, req.Password)
        if err != nil {
            http.Error(w, err.Error(), http.StatusBadRequest)
            return
        }
        
        json.NewEncoder(w).Encode(user)
    }
}

func handleTransfer(idempotencyService *idempotency.IdempotencyService) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        var req struct {
            IdempotencyKey string  `json:"idempotency_key"`
            FromAccount    string  `json:"from_account"`
            ToAccount      string  `json:"to_account"`
            Amount         float64 `json:"amount"`
        }
        
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            http.Error(w, "Invalid request", http.StatusBadRequest)
            return
        }
        
        idempotentReq := &idempotency.IdempotentRequest{
            Key:       req.IdempotencyKey,
            Operation: "transfer",
            Data:      req,
        }
        
        response, err := idempotencyService.Execute(r.Context(), idempotentReq, 
            func(ctx context.Context) (interface{}, error) {
                // Perform actual transfer
                return performTransfer(ctx, req.FromAccount, req.ToAccount, req.Amount)
            })
        
        if err != nil {
            http.Error(w, err.Error(), http.StatusInternalServerError)
            return
        }
        
        json.NewEncoder(w).Encode(response)
    }
}

func isValidEmail(email string) bool {
    // Email validation logic
    return true
}

func performTransfer(ctx context.Context, from, to string, amount float64) (interface{}, error) {
    // Transfer logic
    return map[string]interface{}{
        "transaction_id": "txn_123",
        "status":         "completed",
        "amount":         amount,
    }, nil
}
```

## Best Practices

### Component Design

1. **Single Responsibility**: Each component handles one domain
2. **Clear Dependencies**: Explicitly declare component dependencies
3. **Initialization Safety**: Handle initialization errors gracefully
4. **Schema Versioning**: Use migrations for schema changes
5. **Resource Cleanup**: Implement proper cleanup mechanisms

### Hook System

1. **Priority Ordering**: Use priority to control hook execution order
2. **Error Handling**: Hooks should fail fast on errors
3. **Data Validation**: Validate hook data before processing
4. **Idempotency**: Hooks should be idempotent when possible
5. **Performance**: Keep hooks lightweight and fast

### Transaction Management

1. **Keep Transactions Short**: Minimize transaction duration
2. **Avoid Nested Transactions**: Use savepoints if needed
3. **Error Recovery**: Implement proper rollback mechanisms
4. **Connection Pooling**: Configure appropriate pool settings
5. **Deadlock Handling**: Implement retry logic for deadlocks

### Security Considerations

1. **Input Validation**: Validate all inputs at component boundaries
2. **SQL Injection**: Use parameterized queries
3. **Password Security**: Use strong hashing algorithms
4. **Session Management**: Implement secure session handling
5. **Audit Logging**: Log security-relevant events

## Consequences

### Positive

- **Reusability**: Components can be reused across projects
- **Consistency**: Standardized patterns across the application
- **Extensibility**: Hook system allows customization without modification
- **Reliability**: Built-in transaction management and error handling
- **Performance**: Optimized database usage patterns
- **Maintainability**: Clear separation of concerns

### Negative

- **Complexity**: Framework adds complexity to simple applications
- **Learning Curve**: Developers need to understand the framework
- **Coupling**: Components are coupled to the framework
- **Overhead**: Additional abstraction layers
- **Debugging**: More complex debugging due to framework layers

## Related Patterns

- **Repository Pattern**: For data access abstraction
- **Unit of Work**: For transaction management
- **Plugin Architecture**: For component extensibility
- **Dependency Injection**: For component dependencies
- **Event Sourcing**: For audit trails and event handling
- **CQRS**: For separating read/write operations
