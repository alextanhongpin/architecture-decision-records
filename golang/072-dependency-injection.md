# Dependency Injection in Go

## Status

`production`

## Context

Dependency injection is crucial for creating testable, maintainable, and loosely coupled Go applications. Without proper dependency management, applications become difficult to test, tightly coupled, and hard to maintain.

This ADR establishes patterns for managing dependencies in Go applications, focusing on simplicity, testability, and clear separation of concerns.

## Decision

We will implement a container-based dependency injection approach that emphasizes explicit dependency declaration and lifecycle management.

### Core Dependency Container

```go
package container

import (
    "context"
    "database/sql"
    "fmt"
    "log/slog"
    "net/http"
    "sync"
    "time"
    
    "github.com/redis/go-redis/v9"
    _ "github.com/lib/pq"
)

// Container manages application dependencies
type Container struct {
    config     *Config
    logger     *slog.Logger
    db         *sql.DB
    redisClient *redis.Client
    httpClient *http.Client
    
    // Sync primitives for singleton initialization
    dbOnce     sync.Once
    redisOnce  sync.Once
    loggerOnce sync.Once
    httpOnce   sync.Once
    
    // Cleanup functions
    cleanupFuncs []func() error
    mu           sync.RWMutex
}

// Config holds application configuration
type Config struct {
    DatabaseURL   string
    RedisURL      string
    LogLevel      string
    HTTPTimeout   time.Duration
    MaxDBConns    int
    RedisPoolSize int
    Environment   string
}

// New creates a new container with configuration
func New() *Container {
    return &Container{
        config:       loadConfig(),
        cleanupFuncs: make([]func() error, 0),
    }
}

// Logger returns a singleton logger instance
func (c *Container) Logger() *slog.Logger {
    c.loggerOnce.Do(func() {
        level := slog.LevelInfo
        switch c.config.LogLevel {
        case "debug":
            level = slog.LevelDebug
        case "warn":
            level = slog.LevelWarn
        case "error":
            level = slog.LevelError
        }
        
        opts := &slog.HandlerOptions{
            Level: level,
            AddSource: c.config.Environment != "production",
        }
        
        handler := slog.NewJSONHandler(os.Stdout, opts)
        c.logger = slog.New(handler)
    })
    return c.logger
}

// DB returns a singleton database connection
func (c *Container) DB() *sql.DB {
    c.dbOnce.Do(func() {
        db, err := sql.Open("postgres", c.config.DatabaseURL)
        if err != nil {
            c.Logger().Error("failed to open database", "error", err)
            panic(fmt.Sprintf("failed to open database: %v", err))
        }
        
        db.SetMaxOpenConns(c.config.MaxDBConns)
        db.SetMaxIdleConns(c.config.MaxDBConns / 2)
        db.SetConnMaxLifetime(time.Hour)
        
        if err := db.Ping(); err != nil {
            c.Logger().Error("failed to ping database", "error", err)
            panic(fmt.Sprintf("failed to ping database: %v", err))
        }
        
        c.db = db
        c.addCleanup(func() error {
            return db.Close()
        })
        
        c.Logger().Info("database connection established")
    })
    return c.db
}

// Redis returns a singleton Redis client
func (c *Container) Redis() *redis.Client {
    c.redisOnce.Do(func() {
        opts, err := redis.ParseURL(c.config.RedisURL)
        if err != nil {
            c.Logger().Error("failed to parse Redis URL", "error", err)
            panic(fmt.Sprintf("failed to parse Redis URL: %v", err))
        }
        
        opts.PoolSize = c.config.RedisPoolSize
        opts.MaxRetries = 3
        opts.MinRetryBackoff = time.Millisecond * 100
        opts.MaxRetryBackoff = time.Second * 2
        
        client := redis.NewClient(opts)
        
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        
        if err := client.Ping(ctx).Err(); err != nil {
            c.Logger().Error("failed to ping Redis", "error", err)
            panic(fmt.Sprintf("failed to ping Redis: %v", err))
        }
        
        c.redisClient = client
        c.addCleanup(func() error {
            return client.Close()
        })
        
        c.Logger().Info("Redis connection established")
    })
    return c.redisClient
}

// HTTPClient returns a singleton HTTP client
func (c *Container) HTTPClient() *http.Client {
    c.httpOnce.Do(func() {
        transport := &http.Transport{
            MaxIdleConns:        100,
            MaxIdleConnsPerHost: 10,
            IdleConnTimeout:     90 * time.Second,
            DisableCompression:  false,
        }
        
        c.httpClient = &http.Client{
            Transport: transport,
            Timeout:   c.config.HTTPTimeout,
        }
        
        c.addCleanup(func() error {
            transport.CloseIdleConnections()
            return nil
        })
    })
    return c.httpClient
}

// NewUserRepository creates a new user repository instance
func (c *Container) NewUserRepository() *UserRepository {
    return &UserRepository{
        db:     c.DB(),
        logger: c.Logger(),
        redis:  c.Redis(),
    }
}

// NewUserService creates a new user service instance
func (c *Container) NewUserService() *UserService {
    return &UserService{
        repo:   c.NewUserRepository(),
        logger: c.Logger(),
        cache:  c.NewCacheService(),
    }
}

// NewUserHandler creates a new user handler instance
func (c *Container) NewUserHandler() *UserHandler {
    return &UserHandler{
        service: c.NewUserService(),
        logger:  c.Logger(),
    }
}

// NewCacheService creates a new cache service instance
func (c *Container) NewCacheService() *CacheService {
    return &CacheService{
        redis:  c.Redis(),
        logger: c.Logger(),
    }
}

// addCleanup adds a cleanup function to be called on shutdown
func (c *Container) addCleanup(fn func() error) {
    c.mu.Lock()
    defer c.mu.Unlock()
    c.cleanupFuncs = append(c.cleanupFuncs, fn)
}

// Cleanup closes all resources
func (c *Container) Cleanup() error {
    c.mu.RLock()
    defer c.mu.RUnlock()
    
    var errors []error
    for i := len(c.cleanupFuncs) - 1; i >= 0; i-- {
        if err := c.cleanupFuncs[i](); err != nil {
            errors = append(errors, err)
            c.Logger().Error("cleanup error", "error", err)
        }
    }
    
    if len(errors) > 0 {
        return fmt.Errorf("cleanup errors: %v", errors)
    }
    
    return nil
}

func loadConfig() *Config {
    return &Config{
        DatabaseURL:   getEnv("DATABASE_URL", "postgres://localhost/myapp?sslmode=disable"),
        RedisURL:      getEnv("REDIS_URL", "redis://localhost:6379"),
        LogLevel:      getEnv("LOG_LEVEL", "info"),
        HTTPTimeout:   getDurationEnv("HTTP_TIMEOUT", 30*time.Second),
        MaxDBConns:    getIntEnv("MAX_DB_CONNS", 25),
        RedisPoolSize: getIntEnv("REDIS_POOL_SIZE", 10),
        Environment:   getEnv("ENVIRONMENT", "development"),
    }
}
```

### Repository Pattern Implementation

```go
// UserRepository handles data access for users
type UserRepository struct {
    db     *sql.DB
    logger *slog.Logger
    redis  *redis.Client
}

type User struct {
    ID        string    `json:"id" db:"id"`
    Email     string    `json:"email" db:"email"`
    Name      string    `json:"name" db:"name"`
    CreatedAt time.Time `json:"created_at" db:"created_at"`
    UpdatedAt time.Time `json:"updated_at" db:"updated_at"`
}

func (r *UserRepository) GetByID(ctx context.Context, id string) (*User, error) {
    query := `
        SELECT id, email, name, created_at, updated_at 
        FROM users 
        WHERE id = $1 AND deleted_at IS NULL
    `
    
    user := &User{}
    err := r.db.QueryRowContext(ctx, query, id).Scan(
        &user.ID, &user.Email, &user.Name,
        &user.CreatedAt, &user.UpdatedAt,
    )
    
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, errors.New(errors.ErrCodeNotFound, "User not found").
                WithDetail("user_id", id).
                WithContext(ctx)
        }
        return nil, errors.Wrap(err, errors.ErrCodeInternal, "Failed to get user").
            WithDetail("user_id", id).
            WithContext(ctx)
    }
    
    return user, nil
}

func (r *UserRepository) Create(ctx context.Context, user *User) error {
    query := `
        INSERT INTO users (id, email, name, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5)
    `
    
    now := time.Now()
    user.CreatedAt = now
    user.UpdatedAt = now
    
    _, err := r.db.ExecContext(ctx, query,
        user.ID, user.Email, user.Name,
        user.CreatedAt, user.UpdatedAt,
    )
    
    if err != nil {
        // Check for unique constraint violations
        if isUniqueViolation(err) {
            return errors.New(errors.ErrCodeConflict, "User with this email already exists").
                WithDetail("email", user.Email).
                WithContext(ctx)
        }
        
        return errors.Wrap(err, errors.ErrCodeInternal, "Failed to create user").
            WithDetail("user", user).
            WithContext(ctx)
    }
    
    r.logger.InfoContext(ctx, "user created", "user_id", user.ID)
    return nil
}

func (r *UserRepository) Update(ctx context.Context, user *User) error {
    query := `
        UPDATE users 
        SET email = $2, name = $3, updated_at = $4
        WHERE id = $1 AND deleted_at IS NULL
    `
    
    user.UpdatedAt = time.Now()
    
    result, err := r.db.ExecContext(ctx, query,
        user.ID, user.Email, user.Name, user.UpdatedAt,
    )
    
    if err != nil {
        return errors.Wrap(err, errors.ErrCodeInternal, "Failed to update user").
            WithDetail("user_id", user.ID).
            WithContext(ctx)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return errors.Wrap(err, errors.ErrCodeInternal, "Failed to get rows affected").
            WithContext(ctx)
    }
    
    if rowsAffected == 0 {
        return errors.New(errors.ErrCodeNotFound, "User not found").
            WithDetail("user_id", user.ID).
            WithContext(ctx)
    }
    
    r.logger.InfoContext(ctx, "user updated", "user_id", user.ID)
    return nil
}
```

### Service Layer Implementation

```go
// UserService handles business logic for users
type UserService struct {
    repo   *UserRepository
    logger *slog.Logger
    cache  *CacheService
}

type CreateUserRequest struct {
    Email string `json:"email" validate:"required,email"`
    Name  string `json:"name" validate:"required,min=2,max=100"`
}

type UpdateUserRequest struct {
    Email string `json:"email" validate:"omitempty,email"`
    Name  string `json:"name" validate:"omitempty,min=2,max=100"`
}

func (s *UserService) CreateUser(ctx context.Context, req CreateUserRequest) (*User, error) {
    // Validate request
    if err := s.validateCreateRequest(req); err != nil {
        return nil, err
    }
    
    // Create user entity
    user := &User{
        ID:    generateID(),
        Email: strings.ToLower(strings.TrimSpace(req.Email)),
        Name:  strings.TrimSpace(req.Name),
    }
    
    // Create in repository
    if err := s.repo.Create(ctx, user); err != nil {
        return nil, err
    }
    
    // Cache the user
    if err := s.cache.SetUser(ctx, user); err != nil {
        s.logger.WarnContext(ctx, "failed to cache user", "error", err, "user_id", user.ID)
    }
    
    s.logger.InfoContext(ctx, "user service: user created", "user_id", user.ID)
    return user, nil
}

func (s *UserService) GetUser(ctx context.Context, id string) (*User, error) {
    // Try cache first
    if user, err := s.cache.GetUser(ctx, id); err == nil && user != nil {
        return user, nil
    }
    
    // Get from repository
    user, err := s.repo.GetByID(ctx, id)
    if err != nil {
        return nil, err
    }
    
    // Cache for next time
    if err := s.cache.SetUser(ctx, user); err != nil {
        s.logger.WarnContext(ctx, "failed to cache user", "error", err, "user_id", id)
    }
    
    return user, nil
}

func (s *UserService) UpdateUser(ctx context.Context, id string, req UpdateUserRequest) (*User, error) {
    // Get existing user
    user, err := s.GetUser(ctx, id)
    if err != nil {
        return nil, err
    }
    
    // Validate update request
    if err := s.validateUpdateRequest(req); err != nil {
        return nil, err
    }
    
    // Apply updates
    if req.Email != "" {
        user.Email = strings.ToLower(strings.TrimSpace(req.Email))
    }
    if req.Name != "" {
        user.Name = strings.TrimSpace(req.Name)
    }
    
    // Update in repository
    if err := s.repo.Update(ctx, user); err != nil {
        return nil, err
    }
    
    // Update cache
    if err := s.cache.SetUser(ctx, user); err != nil {
        s.logger.WarnContext(ctx, "failed to update cached user", "error", err, "user_id", id)
    }
    
    s.logger.InfoContext(ctx, "user service: user updated", "user_id", id)
    return user, nil
}

func (s *UserService) validateCreateRequest(req CreateUserRequest) error {
    validationErr := errors.NewValidationError("Invalid user data")
    
    if req.Email == "" {
        validationErr.AddField("email", "Email is required")
    } else if !isValidEmail(req.Email) {
        validationErr.AddField("email", "Invalid email format")
    }
    
    if req.Name == "" {
        validationErr.AddField("name", "Name is required")
    } else if len(req.Name) < 2 {
        validationErr.AddField("name", "Name must be at least 2 characters")
    } else if len(req.Name) > 100 {
        validationErr.AddField("name", "Name must be less than 100 characters")
    }
    
    if validationErr.HasErrors() {
        return validationErr
    }
    
    return nil
}

func (s *UserService) validateUpdateRequest(req UpdateUserRequest) error {
    validationErr := errors.NewValidationError("Invalid update data")
    
    if req.Email != "" && !isValidEmail(req.Email) {
        validationErr.AddField("email", "Invalid email format")
    }
    
    if req.Name != "" && (len(req.Name) < 2 || len(req.Name) > 100) {
        validationErr.AddField("name", "Name must be between 2 and 100 characters")
    }
    
    if validationErr.HasErrors() {
        return validationErr
    }
    
    return nil
}
```

### Handler Layer Implementation

```go
// UserHandler handles HTTP requests for users
type UserHandler struct {
    service *UserService
    logger  *slog.Logger
}

func (h *UserHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    
    var req CreateUserRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        h.handleError(w, r, errors.Wrap(err, errors.ErrCodeValidation, "Invalid JSON"))
        return
    }
    
    user, err := h.service.CreateUser(ctx, req)
    if err != nil {
        h.handleError(w, r, err)
        return
    }
    
    h.writeJSON(w, http.StatusCreated, map[string]interface{}{
        "user": user,
    })
}

func (h *UserHandler) GetUser(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    userID := chi.URLParam(r, "id")
    
    if userID == "" {
        h.handleError(w, r, errors.New(errors.ErrCodeValidation, "User ID is required"))
        return
    }
    
    user, err := h.service.GetUser(ctx, userID)
    if err != nil {
        h.handleError(w, r, err)
        return
    }
    
    h.writeJSON(w, http.StatusOK, map[string]interface{}{
        "user": user,
    })
}

func (h *UserHandler) UpdateUser(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    userID := chi.URLParam(r, "id")
    
    if userID == "" {
        h.handleError(w, r, errors.New(errors.ErrCodeValidation, "User ID is required"))
        return
    }
    
    var req UpdateUserRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        h.handleError(w, r, errors.Wrap(err, errors.ErrCodeValidation, "Invalid JSON"))
        return
    }
    
    user, err := h.service.UpdateUser(ctx, userID, req)
    if err != nil {
        h.handleError(w, r, err)
        return
    }
    
    h.writeJSON(w, http.StatusOK, map[string]interface{}{
        "user": user,
    })
}

func (h *UserHandler) handleError(w http.ResponseWriter, r *http.Request, err error) {
    // Use the error handler from the errors package
    errorHandler := errors.NewHTTPErrorHandler(
        errors.NewDefaultTranslator(),
        &errors.StructuredLogger{Logger: h.logger},
    )
    errorHandler.HandleError(w, r, err)
}

func (h *UserHandler) writeJSON(w http.ResponseWriter, status int, data interface{}) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(status)
    
    if err := json.NewEncoder(w).Encode(data); err != nil {
        h.logger.Error("failed to encode JSON response", "error", err)
    }
}
```

### Test Container

```go
package container

import (
    "database/sql"
    "testing"
    
    "github.com/testcontainers/testcontainers-go"
    "github.com/testcontainers/testcontainers-go/modules/postgres"
    "github.com/testcontainers/testcontainers-go/modules/redis"
)

// TestContainer provides dependencies for testing
type TestContainer struct {
    *Container
    pgContainer    *postgres.PostgresContainer
    redisContainer *redis.RedisContainer
}

// NewTestContainer creates a container for testing
func NewTestContainer(t *testing.T) *TestContainer {
    t.Helper()
    
    ctx := context.Background()
    
    // Start PostgreSQL container
    pgContainer, err := postgres.RunContainer(ctx,
        testcontainers.WithImage("postgres:15-alpine"),
        postgres.WithDatabase("testdb"),
        postgres.WithUsername("testuser"),
        postgres.WithPassword("testpass"),
    )
    require.NoError(t, err)
    
    // Start Redis container
    redisContainer, err := redis.RunContainer(ctx,
        testcontainers.WithImage("redis:7-alpine"),
    )
    require.NoError(t, err)
    
    // Get connection strings
    pgURL, err := pgContainer.ConnectionString(ctx, "sslmode=disable")
    require.NoError(t, err)
    
    redisURL, err := redisContainer.ConnectionString(ctx)
    require.NoError(t, err)
    
    // Create container with test configuration
    container := &Container{
        config: &Config{
            DatabaseURL:   pgURL,
            RedisURL:      redisURL,
            LogLevel:      "debug",
            HTTPTimeout:   10 * time.Second,
            MaxDBConns:    5,
            RedisPoolSize: 5,
            Environment:   "test",
        },
        cleanupFuncs: make([]func() error, 0),
    }
    
    testContainer := &TestContainer{
        Container:      container,
        pgContainer:    pgContainer,
        redisContainer: redisContainer,
    }
    
    // Run migrations
    testContainer.runMigrations(t)
    
    // Register cleanup
    t.Cleanup(func() {
        testContainer.Cleanup()
        pgContainer.Terminate(ctx)
        redisContainer.Terminate(ctx)
    })
    
    return testContainer
}

func (tc *TestContainer) runMigrations(t *testing.T) {
    t.Helper()
    
    db := tc.DB()
    
    migrations := []string{
        `CREATE TABLE users (
            id UUID PRIMARY KEY,
            email VARCHAR(255) UNIQUE NOT NULL,
            name VARCHAR(255) NOT NULL,
            created_at TIMESTAMP NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
            deleted_at TIMESTAMP
        )`,
        `CREATE INDEX idx_users_email ON users(email)`,
        `CREATE INDEX idx_users_deleted_at ON users(deleted_at)`,
    }
    
    for _, migration := range migrations {
        _, err := db.Exec(migration)
        require.NoError(t, err)
    }
}

// ResetDatabase clears all data for test isolation
func (tc *TestContainer) ResetDatabase(t *testing.T) {
    t.Helper()
    
    db := tc.DB()
    
    tables := []string{"users"}
    for _, table := range tables {
        _, err := db.Exec(fmt.Sprintf("TRUNCATE TABLE %s CASCADE", table))
        require.NoError(t, err)
    }
}
```

### Integration Test Example

```go
func TestUserService_Integration(t *testing.T) {
    container := NewTestContainer(t)
    
    userService := container.NewUserService()
    
    t.Run("create and get user", func(t *testing.T) {
        container.ResetDatabase(t)
        
        ctx := context.Background()
        
        // Create user
        req := CreateUserRequest{
            Email: "test@example.com",
            Name:  "Test User",
        }
        
        user, err := userService.CreateUser(ctx, req)
        require.NoError(t, err)
        assert.Equal(t, req.Email, user.Email)
        assert.Equal(t, req.Name, user.Name)
        assert.NotEmpty(t, user.ID)
        
        // Get user
        retrieved, err := userService.GetUser(ctx, user.ID)
        require.NoError(t, err)
        assert.Equal(t, user.ID, retrieved.ID)
        assert.Equal(t, user.Email, retrieved.Email)
        assert.Equal(t, user.Name, retrieved.Name)
    })
    
    t.Run("duplicate email error", func(t *testing.T) {
        container.ResetDatabase(t)
        
        ctx := context.Background()
        
        req := CreateUserRequest{
            Email: "duplicate@example.com",
            Name:  "Test User",
        }
        
        // Create first user
        _, err := userService.CreateUser(ctx, req)
        require.NoError(t, err)
        
        // Try to create duplicate
        _, err = userService.CreateUser(ctx, req)
        require.Error(t, err)
        
        var appErr *errors.Error
        require.True(t, errors.As(err, &appErr))
        assert.Equal(t, errors.ErrCodeConflict, appErr.Code)
    })
}
```

## Best Practices

### 1. Dependency Lifecycle Management

**Singleton for Infrastructure:**
- Database connections
- Redis clients  
- HTTP clients
- Loggers
- Configuration

**Scoped for Business Logic:**
- Services
- Repositories
- Handlers

**Transient for Stateful Objects:**
- Request/response models
- Domain entities
- Value objects

### 2. Configuration Management

```go
// Load configuration directly in container
func loadConfig() *Config {
    return &Config{
        DatabaseURL: mustGetEnv("DATABASE_URL"),
        RedisURL:    getEnv("REDIS_URL", "redis://localhost:6379"),
        LogLevel:    getEnv("LOG_LEVEL", "info"),
    }
}

// Don't create separate config layer
// ❌ Avoid this
type ConfigService struct {
    DatabaseURL string
    RedisURL    string
}

func (c *Container) Config() *ConfigService { ... }
```

### 3. Test Isolation

```go
// Separate test dependencies completely
func NewTestContainer(t *testing.T) *TestContainer {
    // Use test containers or in-memory implementations
    // Never mix with production dependencies
}

// Reset state between tests
func (tc *TestContainer) ResetDatabase(t *testing.T) {
    // Clear all test data
}
```

### 4. Error Handling

```go
// Panic on initialization failures for critical dependencies
func (c *Container) DB() *sql.DB {
    c.dbOnce.Do(func() {
        db, err := sql.Open("postgres", c.config.DatabaseURL)
        if err != nil {
            // This is acceptable for infrastructure failures
            panic(fmt.Sprintf("failed to open database: %v", err))
        }
        c.db = db
    })
    return c.db
}
```

## Implementation Checklist

- [ ] Create container package structure
- [ ] Implement configuration loading
- [ ] Set up singleton infrastructure dependencies
- [ ] Create factory methods for business logic
- [ ] Implement proper cleanup handling
- [ ] Set up test container infrastructure
- [ ] Write integration tests
- [ ] Document dependency relationships

## Consequences

**Benefits:**
- Clear dependency relationships
- Easy testing with dependency substitution
- Centralized configuration management
- Proper resource cleanup
- Simplified application bootstrap

**Challenges:**
- Initial setup complexity
- Need for careful lifecycle management
- Potential for circular dependencies
- Container can become large

**Trade-offs:**
- Explicit vs. implicit dependencies
- Container complexity vs. dependency clarity
- Compile-time vs. runtime dependency resolution
