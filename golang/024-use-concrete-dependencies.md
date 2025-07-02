# Use Concrete Dependencies Over Interfaces for External Services

## Status

`accepted`

## Context

In Go, there's often debate about when to use interfaces versus concrete types for dependencies. While interfaces provide flexibility and enable mocking, they add complexity and abstraction that isn't always necessary. For many external services like HTTP clients, Redis clients, and database connections, concrete dependencies with proper test infrastructure provide better developer experience without sacrificing testability.

The Go testing ecosystem provides excellent testing utilities that eliminate the need for interface-based mocking in many scenarios:
- `httptest` for HTTP client testing
- `miniredis` for Redis testing  
- `testcontainers` for database testing
- In-memory implementations for various services

## Decision

**Use concrete dependencies for external services where robust testing infrastructure exists:**

### 1. HTTP Client Testing with httptest

Instead of wrapping `*http.Client` in an interface, use `httptest` for testing:

```go
// Good: Use concrete http.Client
type UserService struct {
    client   *http.Client
    baseURL  string
    apiKey   string
}

func NewUserService(baseURL, apiKey string) *UserService {
    return &UserService{
        client:  &http.Client{Timeout: 30 * time.Second},
        baseURL: baseURL,
        apiKey:  apiKey,
    }
}

func (s *UserService) GetUser(ctx context.Context, id string) (*User, error) {
    req, err := http.NewRequestWithContext(ctx, "GET", 
        s.baseURL+"/users/"+id, nil)
    if err != nil {
        return nil, fmt.Errorf("creating request: %w", err)
    }
    
    req.Header.Set("Authorization", "Bearer "+s.apiKey)
    req.Header.Set("Accept", "application/json")
    
    resp, err := s.client.Do(req)
    if err != nil {
        return nil, fmt.Errorf("executing request: %w", err)
    }
    defer resp.Body.Close()
    
    if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("unexpected status: %d", resp.StatusCode)
    }
    
    var user User
    if err := json.NewDecoder(resp.Body).Decode(&user); err != nil {
        return nil, fmt.Errorf("decoding response: %w", err)
    }
    
    return &user, nil
}

// Test using httptest
func TestUserService_GetUser(t *testing.T) {
    // Create test server
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Verify request
        assert.Equal(t, "/users/123", r.URL.Path)
        assert.Equal(t, "Bearer test-key", r.Header.Get("Authorization"))
        
        // Return mock response
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(User{
            ID:   "123",
            Name: "John Doe",
            Email: "john@example.com",
        })
    }))
    defer server.Close()
    
    service := NewUserService(server.URL, "test-key")
    
    user, err := service.GetUser(context.Background(), "123")
    require.NoError(t, err)
    assert.Equal(t, "123", user.ID)
    assert.Equal(t, "John Doe", user.Name)
}

// Test error scenarios
func TestUserService_GetUser_ErrorHandling(t *testing.T) {
    tests := []struct {
        name           string
        serverHandler  http.HandlerFunc
        expectedError  string
    }{
        {
            name: "server returns 404",
            serverHandler: func(w http.ResponseWriter, r *http.Request) {
                w.WriteHeader(http.StatusNotFound)
            },
            expectedError: "unexpected status: 404",
        },
        {
            name: "invalid JSON response",
            serverHandler: func(w http.ResponseWriter, r *http.Request) {
                w.Write([]byte("invalid json"))
            },
            expectedError: "decoding response",
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            server := httptest.NewServer(tt.serverHandler)
            defer server.Close()
            
            service := NewUserService(server.URL, "test-key")
            _, err := service.GetUser(context.Background(), "123")
            
            require.Error(t, err)
            assert.Contains(t, err.Error(), tt.expectedError)
        })
    }
}
```

### 2. Redis Client Testing with miniredis

Instead of wrapping `*redis.Client` in an interface, use `miniredis` for testing:

```go
// Good: Use concrete redis.Client
type CacheService struct {
    client *redis.Client
    prefix string
}

func NewCacheService(addr, password, prefix string) *CacheService {
    client := redis.NewClient(&redis.Options{
        Addr:     addr,
        Password: password,
        DB:       0,
    })
    
    return &CacheService{
        client: client,
        prefix: prefix,
    }
}

func (s *CacheService) Set(ctx context.Context, key string, value interface{}, ttl time.Duration) error {
    data, err := json.Marshal(value)
    if err != nil {
        return fmt.Errorf("marshaling value: %w", err)
    }
    
    fullKey := s.prefix + ":" + key
    return s.client.Set(ctx, fullKey, data, ttl).Err()
}

func (s *CacheService) Get(ctx context.Context, key string, dest interface{}) error {
    fullKey := s.prefix + ":" + key
    data, err := s.client.Get(ctx, fullKey).Result()
    if err != nil {
        if errors.Is(err, redis.Nil) {
            return ErrCacheNotFound
        }
        return fmt.Errorf("getting from cache: %w", err)
    }
    
    if err := json.Unmarshal([]byte(data), dest); err != nil {
        return fmt.Errorf("unmarshaling value: %w", err)
    }
    
    return nil
}

// Test using miniredis
func TestCacheService(t *testing.T) {
    // Start miniredis server
    mr := miniredis.RunT(t)
    
    service := NewCacheService(mr.Addr(), "", "test")
    
    t.Run("set and get", func(t *testing.T) {
        user := User{ID: "123", Name: "John"}
        
        err := service.Set(context.Background(), "user:123", user, time.Hour)
        require.NoError(t, err)
        
        var retrieved User
        err = service.Get(context.Background(), "user:123", &retrieved)
        require.NoError(t, err)
        assert.Equal(t, user, retrieved)
    })
    
    t.Run("get non-existent key", func(t *testing.T) {
        var user User
        err := service.Get(context.Background(), "nonexistent", &user)
        assert.ErrorIs(t, err, ErrCacheNotFound)
    })
    
    t.Run("TTL expiration", func(t *testing.T) {
        err := service.Set(context.Background(), "temp", "value", time.Millisecond)
        require.NoError(t, err)
        
        // Fast forward time in miniredis
        mr.FastForward(time.Second)
        
        var result string
        err = service.Get(context.Background(), "temp", &result)
        assert.ErrorIs(t, err, ErrCacheNotFound)
    })
}
```

### 3. Database Testing with testcontainers

Use real database instances for integration testing:

```go
// Good: Use concrete database connection
type UserRepository struct {
    db *sql.DB
}

func NewUserRepository(db *sql.DB) *UserRepository {
    return &UserRepository{db: db}
}

func (r *UserRepository) CreateUser(ctx context.Context, user User) error {
    query := `INSERT INTO users (id, name, email, created_at) VALUES ($1, $2, $3, $4)`
    _, err := r.db.ExecContext(ctx, query, user.ID, user.Name, user.Email, user.CreatedAt)
    if err != nil {
        return fmt.Errorf("creating user: %w", err)
    }
    return nil
}

// Test using testcontainers
func TestUserRepository(t *testing.T) {
    // Start PostgreSQL container
    ctx := context.Background()
    container, err := postgres.RunContainer(ctx,
        testcontainers.WithImage("postgres:15"),
        postgres.WithDatabase("testdb"),
        postgres.WithUsername("testuser"),
        postgres.WithPassword("testpass"),
        testcontainers.WithWaitStrategy(
            wait.ForLog("database system is ready to accept connections").
                WithOccurrence(2).WithStartupTimeout(5*time.Second)),
    )
    require.NoError(t, err)
    defer container.Terminate(ctx)
    
    // Get connection string
    connStr, err := container.ConnectionString(ctx, "sslmode=disable")
    require.NoError(t, err)
    
    // Connect to database
    db, err := sql.Open("postgres", connStr)
    require.NoError(t, err)
    defer db.Close()
    
    // Run migrations
    _, err = db.ExecContext(ctx, `
        CREATE TABLE users (
            id VARCHAR(255) PRIMARY KEY,
            name VARCHAR(255) NOT NULL,
            email VARCHAR(255) UNIQUE NOT NULL,
            created_at TIMESTAMP NOT NULL
        )
    `)
    require.NoError(t, err)
    
    repo := NewUserRepository(db)
    
    t.Run("create user", func(t *testing.T) {
        user := User{
            ID:        "123",
            Name:      "John Doe",
            Email:     "john@example.com",
            CreatedAt: time.Now(),
        }
        
        err := repo.CreateUser(ctx, user)
        require.NoError(t, err)
        
        // Verify user was created
        var count int
        err = db.QueryRowContext(ctx, 
            "SELECT COUNT(*) FROM users WHERE id = $1", user.ID).Scan(&count)
        require.NoError(t, err)
        assert.Equal(t, 1, count)
    })
}
```

### 4. When to Still Use Interfaces

**Use interfaces for:**
- Domain boundaries and business logic abstractions
- When multiple implementations are needed
- Third-party services without good testing libraries
- Complex internal logic that benefits from mocking

```go
// Good: Interface for domain abstraction
type PaymentProcessor interface {
    ProcessPayment(ctx context.Context, payment Payment) (*Receipt, error)
}

type StripePaymentProcessor struct {
    client *stripe.Client
    // Use concrete Stripe client, test with Stripe test mode
}

type PayPalPaymentProcessor struct {
    client *paypal.Client
    // Use concrete PayPal client, test with PayPal sandbox
}

// Service depends on interface for business logic
type OrderService struct {
    processor PaymentProcessor
    repo      *OrderRepository // Concrete dependency
}
```

## Consequences

**Benefits:**
- **Simpler code**: Fewer interfaces and abstractions
- **Better IDE support**: Full type information and autocomplete
- **Realistic testing**: Tests run against actual implementations
- **Performance**: Direct method calls without interface dispatch
- **Easier debugging**: Clear call stacks without interface indirection

**Trade-offs:**
- **Less flexibility**: Harder to swap implementations at runtime
- **Test dependencies**: Requires external testing infrastructure
- **Slower tests**: Integration tests take longer than unit tests with mocks

**Best Practices:**
- Use concrete dependencies for external services with good testing support
- Keep interfaces for domain boundaries and business logic
- Invest in proper test infrastructure (containers, test databases)
- Use dependency injection for configuration, not abstraction
- Consider hybrid approaches: concrete dependencies with interface adapters when needed

## References

- [Go Proverbs: "A little copying is better than a little dependency"](https://go-proverbs.github.io/)
- [Testcontainers Go Documentation](https://golang.testcontainers.org/)
- [miniredis GitHub Repository](https://github.com/alicebob/miniredis)
- [Go httptest Package](https://pkg.go.dev/net/http/httptest)
