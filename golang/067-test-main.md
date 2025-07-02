# TestMain Pattern for Integration Test Setup

## Status

**Accepted** - Use `TestMain` pattern for setting up and tearing down global test dependencies like databases, external services, and shared resources.

## Context

Integration tests in Go often require external dependencies such as databases, Redis instances, message queues, or other services. Setting up and tearing down these dependencies for each test is expensive and can make test suites slow and unreliable.

The `TestMain` function provides a mechanism to:

- **Initialize Global Dependencies**: Set up databases, containers, or external services once
- **Control Test Execution**: Run setup before and cleanup after all tests
- **Optimize Test Performance**: Avoid repeated expensive setup/teardown operations
- **Manage Test Isolation**: Provide clean state for each test while sharing infrastructure
- **Handle Resource Cleanup**: Ensure proper cleanup even when tests fail or panic

Without proper test infrastructure setup, teams often face:
- Slow test suites due to repeated setup
- Flaky tests due to shared state
- Resource leaks from improper cleanup
- Complex test environment management

## Decision

We will use `TestMain` pattern for:

1. **Database Integration Tests**: PostgreSQL, MySQL, SQLite test instances
2. **Cache Integration Tests**: Redis, Memcached test instances  
3. **Message Queue Tests**: RabbitMQ, Kafka test instances
4. **External Service Tests**: Mock HTTP servers, gRPC services
5. **File System Tests**: Temporary directories and file resources

### Implementation Guidelines

#### 1. Core TestMain Infrastructure

```go
package testinfra

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/DATA-DOG/go-txdb"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/postgres"
	"github.com/testcontainers/testcontainers-go/wait"
)

// TestInfra manages test infrastructure
type TestInfra struct {
	containers map[string]testcontainers.Container
	dsns       map[string]string
	mu         sync.RWMutex
	once       sync.Once
}

var globalInfra *TestInfra

// Option configures test infrastructure
type Option func(*TestInfra)

// WithPostgres adds PostgreSQL container
func WithPostgres(image string, migrationHook func(dsn string) error) Option {
	return func(ti *TestInfra) {
		if err := ti.setupPostgres(image, migrationHook); err != nil {
			log.Fatalf("Failed to setup PostgreSQL: %v", err)
		}
	}
}

// WithRedis adds Redis container
func WithRedis(image string) Option {
	return func(ti *TestInfra) {
		if err := ti.setupRedis(image); err != nil {
			log.Fatalf("Failed to setup Redis: %v", err)
		}
	}
}

// Initialize sets up test infrastructure (call from TestMain)
func Initialize(opts ...Option) func() {
	globalInfra = &TestInfra{
		containers: make(map[string]testcontainers.Container),
		dsns:       make(map[string]string),
	}
	
	for _, opt := range opts {
		opt(globalInfra)
	}
	
	return globalInfra.Cleanup
}

// setupPostgres initializes PostgreSQL test container
func (ti *TestInfra) setupPostgres(image string, migrationHook func(dsn string) error) error {
	ctx := context.Background()
	
	container, err := postgres.RunContainer(ctx,
		testcontainers.WithImage(image),
		postgres.WithDatabase("testdb"),
		postgres.WithUsername("testuser"),
		postgres.WithPassword("testpass"),
		testcontainers.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).
				WithStartupTimeout(5*time.Minute)),
	)
	if err != nil {
		return fmt.Errorf("failed to start PostgreSQL container: %w", err)
	}
	
	ti.containers["postgres"] = container
	
	// Get connection details
	host, err := container.Host(ctx)
	if err != nil {
		return err
	}
	
	port, err := container.MappedPort(ctx, "5432")
	if err != nil {
		return err
	}
	
	dsn := fmt.Sprintf("postgres://testuser:testpass@%s:%s/testdb?sslmode=disable", 
		host, port.Port())
	ti.dsns["postgres"] = dsn
	
	// Run migrations if provided
	if migrationHook != nil {
		if err := migrationHook(dsn); err != nil {
			return fmt.Errorf("migration failed: %w", err)
		}
	}
	
	// Register transaction database for isolated tests
	txdb.Register("txdb", "postgres", dsn)
	
	return nil
}

// setupRedis initializes Redis test container
func (ti *TestInfra) setupRedis(image string) error {
	ctx := context.Background()
	
	req := testcontainers.ContainerRequest{
		Image:        image,
		ExposedPorts: []string{"6379/tcp"},
		WaitingFor:   wait.ForLog("Ready to accept connections"),
	}
	
	container, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: req,
		Started:          true,
	})
	if err != nil {
		return fmt.Errorf("failed to start Redis container: %w", err)
	}
	
	ti.containers["redis"] = container
	
	host, err := container.Host(ctx)
	if err != nil {
		return err
	}
	
	port, err := container.MappedPort(ctx, "6379")
	if err != nil {
		return err
	}
	
	dsn := fmt.Sprintf("redis://%s:%s", host, port.Port())
	ti.dsns["redis"] = dsn
	
	return nil
}

// Cleanup shuts down all test infrastructure
func (ti *TestInfra) Cleanup() {
	ctx := context.Background()
	
	ti.mu.Lock()
	defer ti.mu.Unlock()
	
	for name, container := range ti.containers {
		if err := container.Terminate(ctx); err != nil {
			log.Printf("Failed to terminate %s container: %v", name, err)
		}
	}
}

// GetDSN returns connection string for a service
func GetDSN(service string) string {
	if globalInfra == nil {
		panic("test infrastructure not initialized - call Initialize() from TestMain")
	}
	
	globalInfra.mu.RLock()
	defer globalInfra.mu.RUnlock()
	
	dsn, exists := globalInfra.dsns[service]
	if !exists {
		panic(fmt.Sprintf("service %s not configured", service))
	}
	
	return dsn
}

// GetDB returns a database connection
func GetDB(t *testing.T, service string) *sql.DB {
	dsn := GetDSN(service)
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("Failed to connect to database: %v", err)
	}
	
	t.Cleanup(func() {
		db.Close()
	})
	
	return db
}

// GetTxDB returns an isolated transaction database
func GetTxDB(t *testing.T) *sql.DB {
	if globalInfra == nil {
		t.Fatal("test infrastructure not initialized")
	}
	
	// Each test gets its own isolated transaction
	db, err := sql.Open("txdb", fmt.Sprintf("test_%d", time.Now().UnixNano()))
	if err != nil {
		t.Fatalf("Failed to open transaction database: %v", err)
	}
	
	t.Cleanup(func() {
		db.Close()
	})
	
	return db
}
```

#### 2. Example TestMain Implementation

```go
package main

import (
	"database/sql"
	"os"
	"testing"
	
	"yourapp/testinfra"
	_ "github.com/lib/pq"
)

func TestMain(m *testing.M) {
	// Initialize test infrastructure
	cleanup := testinfra.Initialize(
		testinfra.WithPostgres("postgres:15", runMigrations),
		testinfra.WithRedis("redis:7-alpine"),
	)
	
	// Run tests
	code := m.Run()
	
	// Cleanup (can't use defer with os.Exit)
	cleanup()
	
	// Exit with test result code
	os.Exit(code)
}

// runMigrations applies database migrations for testing
func runMigrations(dsn string) error {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	
	// Apply test schema
	schema := `
		CREATE TABLE users (
			id SERIAL PRIMARY KEY,
			name VARCHAR(255) NOT NULL,
			email VARCHAR(255) UNIQUE NOT NULL,
			created_at TIMESTAMP DEFAULT NOW()
		);
		
		CREATE TABLE posts (
			id SERIAL PRIMARY KEY,
			user_id INTEGER REFERENCES users(id),
			title VARCHAR(255) NOT NULL,
			content TEXT,
			created_at TIMESTAMP DEFAULT NOW()
		);
	`
	
	_, err = db.Exec(schema)
	return err
}

// Example integration tests
func TestUserRepository(t *testing.T) {
	// Get isolated transaction database
	db := testinfra.GetTxDB(t)
	
	repo := NewUserRepository(db)
	
	// Test user creation
	user := &User{
		Name:  "John Doe",
		Email: "john@example.com",
	}
	
	id, err := repo.Create(user)
	if err != nil {
		t.Fatalf("Failed to create user: %v", err)
	}
	
	// Test user retrieval
	retrieved, err := repo.GetByID(id)
	if err != nil {
		t.Fatalf("Failed to get user: %v", err)
	}
	
	if retrieved.Name != user.Name {
		t.Errorf("Expected name %s, got %s", user.Name, retrieved.Name)
	}
}

func TestRedisCache(t *testing.T) {
	// Get Redis connection string
	redisURL := testinfra.GetDSN("redis")
	
	cache := NewRedisCache(redisURL)
	
	// Test cache operations
	key := "test_key"
	value := "test_value"
	
	err := cache.Set(key, value)
	if err != nil {
		t.Fatalf("Failed to set cache value: %v", err)
	}
	
	retrieved, err := cache.Get(key)
	if err != nil {
		t.Fatalf("Failed to get cache value: %v", err)
	}
	
	if retrieved != value {
		t.Errorf("Expected value %s, got %s", value, retrieved)
	}
}
```

#### 3. Repository Testing Pattern

```go
package repository_test

import (
	"testing"
	"context"
	
	"yourapp/testinfra"
	"yourapp/repository"
)

func TestUserRepository_Create(t *testing.T) {
	db := testinfra.GetTxDB(t)
	repo := repository.NewUserRepository(db)
	
	ctx := context.Background()
	
	user := &repository.User{
		Name:  "Alice Smith",
		Email: "alice@example.com",
	}
	
	id, err := repo.Create(ctx, user)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	
	if id <= 0 {
		t.Error("Expected positive ID")
	}
	
	// Verify user was created
	created, err := repo.GetByID(ctx, id)
	if err != nil {
		t.Fatalf("GetByID failed: %v", err)
	}
	
	if created.Name != user.Name {
		t.Errorf("Expected name %q, got %q", user.Name, created.Name)
	}
	
	if created.Email != user.Email {
		t.Errorf("Expected email %q, got %q", user.Email, created.Email)
	}
}

func TestUserRepository_Update(t *testing.T) {
	db := testinfra.GetTxDB(t)
	repo := repository.NewUserRepository(db)
	
	ctx := context.Background()
	
	// Create initial user
	user := &repository.User{
		Name:  "Bob Wilson",
		Email: "bob@example.com",
	}
	
	id, err := repo.Create(ctx, user)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	
	// Update user
	user.ID = id
	user.Name = "Robert Wilson"
	
	err = repo.Update(ctx, user)
	if err != nil {
		t.Fatalf("Update failed: %v", err)
	}
	
	// Verify update
	updated, err := repo.GetByID(ctx, id)
	if err != nil {
		t.Fatalf("GetByID failed: %v", err)
	}
	
	if updated.Name != "Robert Wilson" {
		t.Errorf("Expected updated name, got %q", updated.Name)
	}
}

func TestUserRepository_Delete(t *testing.T) {
	db := testinfra.GetTxDB(t)
	repo := repository.NewUserRepository(db)
	
	ctx := context.Background()
	
	// Create user to delete
	user := &repository.User{
		Name:  "Charlie Brown",
		Email: "charlie@example.com",
	}
	
	id, err := repo.Create(ctx, user)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	
	// Delete user
	err = repo.Delete(ctx, id)
	if err != nil {
		t.Fatalf("Delete failed: %v", err)
	}
	
	// Verify deletion
	_, err = repo.GetByID(ctx, id)
	if err == nil {
		t.Error("Expected error when getting deleted user")
	}
}
```

#### 4. Service Layer Testing

```go
package service_test

import (
	"context"
	"testing"
	
	"yourapp/testinfra"
	"yourapp/repository"
	"yourapp/service"
)

func TestUserService_CreateUser(t *testing.T) {
	db := testinfra.GetTxDB(t)
	userRepo := repository.NewUserRepository(db)
	userService := service.NewUserService(userRepo)
	
	ctx := context.Background()
	
	req := &service.CreateUserRequest{
		Name:  "David Lee",
		Email: "david@example.com",
	}
	
	user, err := userService.CreateUser(ctx, req)
	if err != nil {
		t.Fatalf("CreateUser failed: %v", err)
	}
	
	if user.ID <= 0 {
		t.Error("Expected positive user ID")
	}
	
	if user.Name != req.Name {
		t.Errorf("Expected name %q, got %q", req.Name, user.Name)
	}
}

func TestUserService_CreateUser_DuplicateEmail(t *testing.T) {
	db := testinfra.GetTxDB(t)
	userRepo := repository.NewUserRepository(db)
	userService := service.NewUserService(userRepo)
	
	ctx := context.Background()
	email := "duplicate@example.com"
	
	// Create first user
	req1 := &service.CreateUserRequest{
		Name:  "User One",
		Email: email,
	}
	
	_, err := userService.CreateUser(ctx, req1)
	if err != nil {
		t.Fatalf("First CreateUser failed: %v", err)
	}
	
	// Try to create second user with same email
	req2 := &service.CreateUserRequest{
		Name:  "User Two",
		Email: email,
	}
	
	_, err = userService.CreateUser(ctx, req2)
	if err == nil {
		t.Error("Expected error for duplicate email")
	}
}
```

#### 5. HTTP Handler Testing

```go
package handler_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	
	"yourapp/testinfra"
	"yourapp/handler"
	"yourapp/repository"
	"yourapp/service"
)

func TestUserHandler_CreateUser(t *testing.T) {
	db := testinfra.GetTxDB(t)
	userRepo := repository.NewUserRepository(db)
	userService := service.NewUserService(userRepo)
	userHandler := handler.NewUserHandler(userService)
	
	// Prepare request
	req := map[string]string{
		"name":  "Emma Davis",
		"email": "emma@example.com",
	}
	
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("Failed to marshal request: %v", err)
	}
	
	// Create HTTP request
	httpReq := httptest.NewRequest(http.MethodPost, "/users", bytes.NewReader(body))
	httpReq.Header.Set("Content-Type", "application/json")
	
	// Record response
	recorder := httptest.NewRecorder()
	
	// Execute handler
	userHandler.CreateUser(recorder, httpReq)
	
	// Check response
	if recorder.Code != http.StatusCreated {
		t.Errorf("Expected status %d, got %d", http.StatusCreated, recorder.Code)
	}
	
	var response map[string]interface{}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("Failed to unmarshal response: %v", err)
	}
	
	if response["name"] != req["name"] {
		t.Errorf("Expected name %q, got %q", req["name"], response["name"])
	}
}
```

#### 6. Performance and Benchmark Tests

```go
package benchmark_test

import (
	"context"
	"testing"
	
	"yourapp/testinfra"
	"yourapp/repository"
)

func BenchmarkUserRepository_Create(b *testing.B) {
	db := testinfra.GetDB(b, "postgres")
	repo := repository.NewUserRepository(db)
	
	ctx := context.Background()
	
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		i := 0
		for pb.Next() {
			user := &repository.User{
				Name:  fmt.Sprintf("User %d", i),
				Email: fmt.Sprintf("user%d@example.com", i),
			}
			
			_, err := repo.Create(ctx, user)
			if err != nil {
				b.Fatalf("Create failed: %v", err)
			}
			i++
		}
	})
}

func BenchmarkUserRepository_GetByID(b *testing.B) {
	db := testinfra.GetDB(b, "postgres")
	repo := repository.NewUserRepository(db)
	
	ctx := context.Background()
	
	// Create test user
	user := &repository.User{
		Name:  "Benchmark User",
		Email: "benchmark@example.com",
	}
	
	id, err := repo.Create(ctx, user)
	if err != nil {
		b.Fatalf("Setup failed: %v", err)
	}
	
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			_, err := repo.GetByID(ctx, id)
			if err != nil {
				b.Fatalf("GetByID failed: %v", err)
			}
		}
	})
}
```

## Consequences

### Positive

- **Improved Test Performance**: Shared infrastructure reduces setup/teardown overhead
- **Better Test Isolation**: Transaction-based testing ensures clean state
- **Realistic Testing**: Tests run against real database/service instances
- **Resource Management**: Proper cleanup prevents resource leaks
- **Consistent Environment**: All tests use the same infrastructure setup
- **CI/CD Friendly**: Works well in containerized CI environments

### Negative

- **Initial Complexity**: More complex setup compared to simple unit tests
- **External Dependencies**: Requires Docker or external services
- **Slower Startup**: Initial container startup adds time to test runs
- **Resource Overhead**: Containers consume system resources
- **Debugging Complexity**: More moving parts can complicate debugging

### Trade-offs

- **Realism vs. Speed**: More realistic tests but slower than pure unit tests
- **Isolation vs. Performance**: Better isolation but requires more resources
- **Setup vs. Maintenance**: Comprehensive setup but ongoing maintenance needs

## Best Practices

1. **Use TestMain for Expensive Setup**: Only for database connections, containers, etc.
2. **Provide Test Isolation**: Use transactions or separate test databases
3. **Clean Up Resources**: Always implement proper cleanup in TestMain
4. **Cache Connections**: Reuse database connections across tests
5. **Fail Fast**: Exit immediately if infrastructure setup fails
6. **Document Requirements**: Clearly document external dependencies
7. **Optimize for CI**: Consider parallel test execution and resource limits

## References

- [Go Testing Package](https://pkg.go.dev/testing)
- [Testcontainers Go](https://golang.testcontainers.org/)
- [Go TxDB](https://github.com/DATA-DOG/go-txdb)
- [Integration Testing Best Practices](https://martinfowler.com/articles/integration-testing.html)
