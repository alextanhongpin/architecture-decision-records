# Modular Monolith Architecture

## Status

`accepted`

## Context

The modular monolith architecture is a way to structure applications that can be split later once domain boundaries are clearly understood. This approach allows teams to start with a single deployable unit while maintaining clear separation of concerns and preparing for potential future microservices extraction.

Most packages will be independent with well-defined interfaces, connected through a glue layer that orchestrates interactions between modules. This architecture provides the simplicity of a monolith with the modularity needed for future scaling.

## Decision

Adopt a modular monolith architecture with clear boundaries, layered dependencies, and interface-based communication between modules.

### Core Components

We structure the application with the following key components:

- **Boundary**: Separates functionality by domain, feature, or business capability
- **Storage**: Data access layer with self-contained types and no external dependencies  
- **Transport**: Entry points (REST, gRPC, GraphQL, CLI) for external communication
- **Config**: Centralized configuration mapping environment variables to typed structures
- **Adapter**: External dependencies (database, cache, message queue, API clients) with interface abstractions

### Boundary Definition

Boundaries should not overlap and have no shared configuration between them. Each boundary represents a cohesive domain or business capability with its own:

```go
// Domain types at the boundary root
type User struct {
    ID        string    `json:"id"`
    Email     string    `json:"email"`
    CreatedAt time.Time `json:"created_at"`
}

type UserRepository interface {
    Create(ctx context.Context, user *User) error
    GetByID(ctx context.Context, id string) (*User, error)
    GetByEmail(ctx context.Context, email string) (*User, error)
}

type UserService interface {
    Register(ctx context.Context, req RegisterRequest) (*User, error)
    Authenticate(ctx context.Context, email, password string) (*User, error)
}
```

Each boundary contains:
- Domain types and business logic
- Use cases (application layer)  
- Repository interfaces
- Service interfaces

### Repository Pattern

Repository acts as the glue layer between the application layer (use cases) and external data sources. Repository is **not** just a database access layer - it abstracts all external data access and maps to domain types.

```go
type UserRepositoryImpl struct {
    db    *sql.DB
    cache Cache
    audit AuditLogger
}

func (r *UserRepositoryImpl) Create(ctx context.Context, user *User) error {
    // Start transaction for atomicity
    tx, err := r.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("failed to start transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Insert user
    query := `INSERT INTO users (id, email, created_at) VALUES ($1, $2, $3)`
    if _, err := tx.ExecContext(ctx, query, user.ID, user.Email, user.CreatedAt); err != nil {
        return fmt.Errorf("failed to insert user: %w", err)
    }
    
    // Log audit event
    if err := r.audit.LogCreate(ctx, "user", user.ID); err != nil {
        return fmt.Errorf("failed to log audit: %w", err)
    }
    
    // Commit transaction
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("failed to commit transaction: %w", err)
    }
    
    // Update cache
    r.cache.Set(ctx, fmt.Sprintf("user:%s", user.ID), user, time.Hour)
    
    return nil
}
```

### Layered Architecture

Apply strict dependency rules within each boundary:

```
boundary/
├── auth/                    # Boundary root - domain types
│   ├── user.go             # Domain entities  
│   ├── errors.go           # Domain-specific errors
│   ├── usecase/            # Application layer
│   │   ├── register.go     # Registration use case
│   │   ├── login.go        # Authentication use case
│   │   └── repository/     # Data access layer
│   │       ├── user.go     # Repository interfaces
│   │       └── impl/       # Repository implementations
│   │           ├── postgres.go
│   │           └── memory.go
│   └── transport/          # Presentation layer
│       ├── http/
│       │   └── auth.go     # HTTP handlers
│       └── grpc/
│           └── auth.go     # gRPC service
```

### Dependency Rules

When structuring packages, apply these rules:

1. **Outer packages cannot access inner packages** (except main program)
2. **Inner packages can access outer packages** (dependency inversion)
3. **Interfaces belong to the consumer** (no types from other packages in interfaces)
4. **No circular dependencies** between boundaries

```go
// ✅ Correct: Interface defined in use case layer
type UserRepository interface {
    Create(ctx context.Context, user *User) error  // Uses domain type
}

// ❌ Wrong: Interface with external types
type UserRepository interface {
    Create(ctx context.Context, user *sql.User) error  // External dependency
}

// ✅ Correct: Use case depends on repository interface
type RegisterUseCase struct {
    repo UserRepository  // Interface from same layer
}

// ❌ Wrong: Use case depends on concrete implementation
type RegisterUseCase struct {
    repo *PostgresUserRepository  // Concrete implementation
}
```

### Module Communication

Modules communicate through well-defined interfaces and events:

```go
// Event-driven communication between boundaries
type EventBus interface {
    Publish(event Event) error
    Subscribe(eventType string, handler EventHandler) error
}

type UserRegisteredEvent struct {
    UserID    string    `json:"user_id"`
    Email     string    `json:"email"`
    Timestamp time.Time `json:"timestamp"`
}

// In auth boundary
func (uc *RegisterUseCase) Execute(ctx context.Context, req RegisterRequest) (*User, error) {
    user, err := uc.createUser(ctx, req)
    if err != nil {
        return nil, err
    }
    
    // Publish event for other boundaries
    event := UserRegisteredEvent{
        UserID:    user.ID,
        Email:     user.Email,
        Timestamp: time.Now(),
    }
    
    if err := uc.eventBus.Publish(event); err != nil {
        log.Printf("failed to publish user registered event: %v", err)
        // Don't fail the registration for event publishing errors
    }
    
    return user, nil
}

// In notification boundary
func (nh *NotificationHandler) HandleUserRegistered(event UserRegisteredEvent) error {
    return nh.sendWelcomeEmail(event.Email)
}
```

### Configuration Management

Centralized configuration with environment-specific overrides:

```go
type Config struct {
    Database DatabaseConfig `json:"database"`
    Cache    CacheConfig    `json:"cache"`
    Auth     AuthConfig     `json:"auth"`
    Features FeatureFlags   `json:"features"`
}

type DatabaseConfig struct {
    Host     string `json:"host" env:"DB_HOST"`
    Port     int    `json:"port" env:"DB_PORT"`
    Database string `json:"database" env:"DB_NAME"`
    Username string `json:"username" env:"DB_USER"`
    Password string `json:"password" env:"DB_PASS"`
}

func LoadConfig() (*Config, error) {
    cfg := &Config{}
    
    // Load from file
    if err := loadFromFile("config.json", cfg); err != nil {
        return nil, err
    }
    
    // Override with environment variables
    if err := loadFromEnv(cfg); err != nil {
        return nil, err
    }
    
    return cfg, nil
}
```

### Testing Strategy

Test each layer independently with appropriate mocks:

```go
func TestRegisterUseCase(t *testing.T) {
    // Arrange
    mockRepo := &MockUserRepository{}
    mockEventBus := &MockEventBus{}
    
    useCase := &RegisterUseCase{
        repo:     mockRepo,
        eventBus: mockEventBus,
    }
    
    req := RegisterRequest{
        Email:    "test@example.com",
        Password: "password123",
    }
    
    mockRepo.On("Create", mock.Anything, mock.AnythingOfType("*User")).Return(nil)
    mockEventBus.On("Publish", mock.AnythingOfType("UserRegisteredEvent")).Return(nil)
    
    // Act
    user, err := useCase.Execute(context.Background(), req)
    
    // Assert
    assert.NoError(t, err)
    assert.NotNil(t, user)
    assert.Equal(t, req.Email, user.Email)
    
    mockRepo.AssertExpectations(t)
    mockEventBus.AssertExpectations(t)
}
```

### Migration to Microservices

When boundaries are well-defined, extraction becomes straightforward:

```go
// 1. Extract boundary as separate service
// 2. Replace in-process calls with HTTP/gRPC calls
// 3. Replace shared database with service-owned database
// 4. Replace in-memory events with message queue

// Before (in-process)
user, err := userUseCase.GetByID(ctx, userID)

// After (service call)
user, err := userServiceClient.GetUser(ctx, &pb.GetUserRequest{Id: userID})
```

## Consequences

### Positive

- **Clear Boundaries**: Well-defined module boundaries prevent coupling
- **Independent Development**: Teams can work on different modules simultaneously  
- **Easy Testing**: Interface-based design enables comprehensive unit testing
- **Future-Ready**: Clean separation facilitates microservices extraction
- **Single Deployment**: Simplified deployment and operational overhead
- **Shared Infrastructure**: Common concerns (logging, monitoring, config) handled once

### Negative

- **Initial Complexity**: More upfront design work compared to simple layered architecture
- **Over-Engineering Risk**: May be overkill for simple applications
- **Boundary Decisions**: Incorrect boundary identification can lead to tight coupling
- **Refactoring Cost**: Moving functionality between boundaries requires careful planning

## Anti-patterns

- **Shared Database Entities**: Using the same database models across boundaries
- **Circular Dependencies**: Boundaries depending on each other directly
- **Leaky Abstractions**: Repository interfaces exposing implementation details
- **God Modules**: Boundaries that handle too many responsibilities
- **Premature Extraction**: Splitting to microservices before boundaries stabilize

