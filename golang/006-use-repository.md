# Use Repository Pattern

## Status

`accepted`

## Context

The Repository pattern provides a uniform interface for accessing data sources, encapsulating the persistence layer logic and creating a more maintainable architecture. In Go applications, repositories abstract database operations and enable better testing through dependency injection.

## Problem

Without a repository pattern, domain logic becomes tightly coupled to specific database implementations, making code difficult to:
- Test with different data sources
- Migrate between database technologies
- Maintain consistent data access patterns
- Mock for unit testing
- Scale with complex query requirements

## Solution

Implement repositories as interfaces that define data access contracts, with concrete implementations that handle specific persistence technologies. Use dependency injection to provide repository implementations to business logic layers.

## Go Repository Pattern Implementation

### Basic Repository Interface

```go
package domain

import (
    "context"
    "time"
)

// User represents the domain entity
type User struct {
    ID        string    `json:"id"`
    Email     string    `json:"email"`
    Name      string    `json:"name"`
    CreatedAt time.Time `json:"created_at"`
    UpdatedAt time.Time `json:"updated_at"`
}

// UserRepository defines the data access contract
type UserRepository interface {
    Create(ctx context.Context, user *User) error
    GetByID(ctx context.Context, id string) (*User, error)
    GetByEmail(ctx context.Context, email string) (*User, error)
    List(ctx context.Context, limit, offset int) ([]*User, error)
    Update(ctx context.Context, user *User) error
    Delete(ctx context.Context, id string) error
    Count(ctx context.Context) (int64, error)
}
```

### SQL Repository Implementation

```go
package postgres

import (
    "context"
    "database/sql"
    "fmt"
    "myapp/domain"
    "time"

    "github.com/lib/pq"
)

type userRepository struct {
    db *sql.DB
}

// NewUserRepository creates a new PostgreSQL user repository
func NewUserRepository(db *sql.DB) domain.UserRepository {
    return &userRepository{db: db}
}

func (r *userRepository) Create(ctx context.Context, user *User) error {
    query := `
        INSERT INTO users (id, email, name, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5)`
    
    now := time.Now()
    user.CreatedAt = now
    user.UpdatedAt = now
    
    _, err := r.db.ExecContext(ctx, query, 
        user.ID, user.Email, user.Name, user.CreatedAt, user.UpdatedAt)
    if err != nil {
        if pqErr, ok := err.(*pq.Error); ok && pqErr.Code == "23505" {
            return domain.ErrUserAlreadyExists
        }
        return fmt.Errorf("failed to create user: %w", err)
    }
    
    return nil
}

func (r *userRepository) GetByID(ctx context.Context, id string) (*User, error) {
    query := `
        SELECT id, email, name, created_at, updated_at 
        FROM users WHERE id = $1`
    
    user := &User{}
    err := r.db.QueryRowContext(ctx, query, id).Scan(
        &user.ID, &user.Email, &user.Name, &user.CreatedAt, &user.UpdatedAt)
    
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, domain.ErrUserNotFound
        }
        return nil, fmt.Errorf("failed to get user by ID: %w", err)
    }
    
    return user, nil
}

func (r *userRepository) GetByEmail(ctx context.Context, email string) (*User, error) {
    query := `
        SELECT id, email, name, created_at, updated_at 
        FROM users WHERE email = $1`
    
    user := &User{}
    err := r.db.QueryRowContext(ctx, query, email).Scan(
        &user.ID, &user.Email, &user.Name, &user.CreatedAt, &user.UpdatedAt)
    
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, domain.ErrUserNotFound
        }
        return nil, fmt.Errorf("failed to get user by email: %w", err)
    }
    
    return user, nil
}

func (r *userRepository) List(ctx context.Context, limit, offset int) ([]*User, error) {
    query := `
        SELECT id, email, name, created_at, updated_at 
        FROM users 
        ORDER BY created_at DESC
        LIMIT $1 OFFSET $2`
    
    rows, err := r.db.QueryContext(ctx, query, limit, offset)
    if err != nil {
        return nil, fmt.Errorf("failed to list users: %w", err)
    }
    defer rows.Close()
    
    var users []*User
    for rows.Next() {
        user := &User{}
        err := rows.Scan(&user.ID, &user.Email, &user.Name, 
            &user.CreatedAt, &user.UpdatedAt)
        if err != nil {
            return nil, fmt.Errorf("failed to scan user: %w", err)
        }
        users = append(users, user)
    }
    
    return users, rows.Err()
}

func (r *userRepository) Update(ctx context.Context, user *User) error {
    query := `
        UPDATE users 
        SET email = $2, name = $3, updated_at = $4 
        WHERE id = $1`
    
    user.UpdatedAt = time.Now()
    result, err := r.db.ExecContext(ctx, query, 
        user.ID, user.Email, user.Name, user.UpdatedAt)
    if err != nil {
        return fmt.Errorf("failed to update user: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return fmt.Errorf("failed to get rows affected: %w", err)
    }
    
    if rowsAffected == 0 {
        return domain.ErrUserNotFound
    }
    
    return nil
}

func (r *userRepository) Delete(ctx context.Context, id string) error {
    query := `DELETE FROM users WHERE id = $1`
    
    result, err := r.db.ExecContext(ctx, query, id)
    if err != nil {
        return fmt.Errorf("failed to delete user: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return fmt.Errorf("failed to get rows affected: %w", err)
    }
    
    if rowsAffected == 0 {
        return domain.ErrUserNotFound
    }
    
    return nil
}

func (r *userRepository) Count(ctx context.Context) (int64, error) {
    query := `SELECT COUNT(*) FROM users`
    
    var count int64
    err := r.db.QueryRowContext(ctx, query).Scan(&count)
    if err != nil {
        return 0, fmt.Errorf("failed to count users: %w", err)
    }
    
    return count, nil
}
```

### Repository with Transaction Support

```go
package postgres

import (
    "context"
    "database/sql"
    "myapp/domain"
)

// TransactionalUserRepository extends repository with transaction support
type TransactionalUserRepository struct {
    *userRepository
    tx *sql.Tx
}

// NewTransactionalUserRepository creates a transactional repository
func NewTransactionalUserRepository(tx *sql.Tx) domain.UserRepository {
    return &TransactionalUserRepository{
        userRepository: &userRepository{},
        tx:             tx,
    }
}

// execContext chooses between transaction and direct DB execution
func (r *TransactionalUserRepository) execContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error) {
    if r.tx != nil {
        return r.tx.ExecContext(ctx, query, args...)
    }
    return r.db.ExecContext(ctx, query, args...)
}

// queryRowContext chooses between transaction and direct DB execution
func (r *TransactionalUserRepository) queryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row {
    if r.tx != nil {
        return r.tx.QueryRowContext(ctx, query, args...)
    }
    return r.db.QueryRowContext(ctx, query, args...)
}

// queryContext chooses between transaction and direct DB execution
func (r *TransactionalUserRepository) queryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error) {
    if r.tx != nil {
        return r.tx.QueryContext(ctx, query, args...)
    }
    return r.db.QueryContext(ctx, query, args...)
}
```

### Generic Repository Pattern

```go
package repository

import (
    "context"
    "fmt"
    "reflect"
)

// Repository provides generic CRUD operations
type Repository[T any] interface {
    Create(ctx context.Context, entity *T) error
    GetByID(ctx context.Context, id string) (*T, error)
    List(ctx context.Context, filter ListFilter) ([]*T, error)
    Update(ctx context.Context, entity *T) error
    Delete(ctx context.Context, id string) error
    Count(ctx context.Context, filter CountFilter) (int64, error)
}

// ListFilter defines filtering options for list operations
type ListFilter struct {
    Limit  int
    Offset int
    Sort   string
    Order  string
    Where  map[string]interface{}
}

// CountFilter defines filtering options for count operations
type CountFilter struct {
    Where map[string]interface{}
}

// BaseRepository provides common repository functionality
type BaseRepository[T any] struct {
    tableName string
    db        QueryExecutor
}

// QueryExecutor interface for database operations
type QueryExecutor interface {
    ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error)
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
    QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row
}

// NewBaseRepository creates a new base repository
func NewBaseRepository[T any](tableName string, db QueryExecutor) *BaseRepository[T] {
    return &BaseRepository[T]{
        tableName: tableName,
        db:        db,
    }
}

func (r *BaseRepository[T]) GetTableName() string {
    if r.tableName != "" {
        return r.tableName
    }
    
    var entity T
    t := reflect.TypeOf(entity)
    if t.Kind() == reflect.Ptr {
        t = t.Elem()
    }
    return strings.ToLower(t.Name()) + "s"
}
```

### Memory Repository for Testing

```go
package memory

import (
    "context"
    "myapp/domain"
    "sync"
    "time"
)

// userRepository in-memory implementation for testing
type userRepository struct {
    users map[string]*domain.User
    mutex sync.RWMutex
}

// NewUserRepository creates an in-memory user repository
func NewUserRepository() domain.UserRepository {
    return &userRepository{
        users: make(map[string]*domain.User),
    }
}

func (r *userRepository) Create(ctx context.Context, user *domain.User) error {
    r.mutex.Lock()
    defer r.mutex.Unlock()
    
    // Check if user already exists
    for _, existingUser := range r.users {
        if existingUser.Email == user.Email {
            return domain.ErrUserAlreadyExists
        }
    }
    
    now := time.Now()
    user.CreatedAt = now
    user.UpdatedAt = now
    
    r.users[user.ID] = user
    return nil
}

func (r *userRepository) GetByID(ctx context.Context, id string) (*domain.User, error) {
    r.mutex.RLock()
    defer r.mutex.RUnlock()
    
    user, exists := r.users[id]
    if !exists {
        return nil, domain.ErrUserNotFound
    }
    
    // Return a copy to prevent external modifications
    userCopy := *user
    return &userCopy, nil
}

func (r *userRepository) GetByEmail(ctx context.Context, email string) (*domain.User, error) {
    r.mutex.RLock()
    defer r.mutex.RUnlock()
    
    for _, user := range r.users {
        if user.Email == email {
            userCopy := *user
            return &userCopy, nil
        }
    }
    
    return nil, domain.ErrUserNotFound
}

func (r *userRepository) List(ctx context.Context, limit, offset int) ([]*domain.User, error) {
    r.mutex.RLock()
    defer r.mutex.RUnlock()
    
    users := make([]*domain.User, 0, len(r.users))
    for _, user := range r.users {
        userCopy := *user
        users = append(users, &userCopy)
    }
    
    // Simple pagination
    start := offset
    if start > len(users) {
        return []*domain.User{}, nil
    }
    
    end := start + limit
    if end > len(users) {
        end = len(users)
    }
    
    return users[start:end], nil
}

func (r *userRepository) Update(ctx context.Context, user *domain.User) error {
    r.mutex.Lock()
    defer r.mutex.Unlock()
    
    if _, exists := r.users[user.ID]; !exists {
        return domain.ErrUserNotFound
    }
    
    user.UpdatedAt = time.Now()
    r.users[user.ID] = user
    return nil
}

func (r *userRepository) Delete(ctx context.Context, id string) error {
    r.mutex.Lock()
    defer r.mutex.Unlock()
    
    if _, exists := r.users[id]; !exists {
        return domain.ErrUserNotFound
    }
    
    delete(r.users, id)
    return nil
}

func (r *userRepository) Count(ctx context.Context) (int64, error) {
    r.mutex.RLock()
    defer r.mutex.RUnlock()
    
    return int64(len(r.users)), nil
}
```

### Repository Testing

```go
package repository_test

import (
    "context"
    "myapp/domain"
    "myapp/repository/memory"
    "testing"
    "time"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestUserRepository(t *testing.T) {
    repo := memory.NewUserRepository()
    ctx := context.Background()
    
    t.Run("Create user", func(t *testing.T) {
        user := &domain.User{
            ID:    "user-1",
            Email: "test@example.com",
            Name:  "Test User",
        }
        
        err := repo.Create(ctx, user)
        require.NoError(t, err)
        assert.False(t, user.CreatedAt.IsZero())
        assert.False(t, user.UpdatedAt.IsZero())
    })
    
    t.Run("Get user by ID", func(t *testing.T) {
        user, err := repo.GetByID(ctx, "user-1")
        require.NoError(t, err)
        assert.Equal(t, "test@example.com", user.Email)
        assert.Equal(t, "Test User", user.Name)
    })
    
    t.Run("Get user by email", func(t *testing.T) {
        user, err := repo.GetByEmail(ctx, "test@example.com")
        require.NoError(t, err)
        assert.Equal(t, "user-1", user.ID)
    })
    
    t.Run("Update user", func(t *testing.T) {
        user, err := repo.GetByID(ctx, "user-1")
        require.NoError(t, err)
        
        originalUpdatedAt := user.UpdatedAt
        user.Name = "Updated User"
        
        time.Sleep(time.Millisecond) // Ensure time difference
        err = repo.Update(ctx, user)
        require.NoError(t, err)
        assert.True(t, user.UpdatedAt.After(originalUpdatedAt))
    })
    
    t.Run("Delete user", func(t *testing.T) {
        err := repo.Delete(ctx, "user-1")
        require.NoError(t, err)
        
        _, err = repo.GetByID(ctx, "user-1")
        assert.Equal(t, domain.ErrUserNotFound, err)
    })
    
    t.Run("User not found", func(t *testing.T) {
        _, err := repo.GetByID(ctx, "nonexistent")
        assert.Equal(t, domain.ErrUserNotFound, err)
    })
}

// Repository contract test suite
func TestRepositoryContract(t *testing.T) {
    repos := []struct {
        name string
        repo domain.UserRepository
    }{
        {"Memory", memory.NewUserRepository()},
        // Add other implementations here
        // {"PostgreSQL", postgres.NewUserRepository(db)},
    }
    
    for _, tt := range repos {
        t.Run(tt.name, func(t *testing.T) {
            testRepositoryContract(t, tt.repo)
        })
    }
}

func testRepositoryContract(t *testing.T, repo domain.UserRepository) {
    ctx := context.Background()
    
    // Test create and get
    user := &domain.User{
        ID:    "contract-test-1",
        Email: "contract@example.com",
        Name:  "Contract Test User",
    }
    
    err := repo.Create(ctx, user)
    require.NoError(t, err)
    
    retrieved, err := repo.GetByID(ctx, user.ID)
    require.NoError(t, err)
    assert.Equal(t, user.Email, retrieved.Email)
    assert.Equal(t, user.Name, retrieved.Name)
    
    // Test duplicate email
    duplicate := &domain.User{
        ID:    "contract-test-2",
        Email: "contract@example.com",
        Name:  "Duplicate User",
    }
    
    err = repo.Create(ctx, duplicate)
    assert.Equal(t, domain.ErrUserAlreadyExists, err)
    
    // Clean up
    repo.Delete(ctx, user.ID)
}
```

### Domain Errors

```go
package domain

import "errors"

var (
    ErrUserNotFound      = errors.New("user not found")
    ErrUserAlreadyExists = errors.New("user already exists")
    ErrInvalidUserData   = errors.New("invalid user data")
)
```

## Best Practices

### 1. Interface Segregation

```go
// Split large repositories into focused interfaces
type UserReader interface {
    GetByID(ctx context.Context, id string) (*User, error)
    GetByEmail(ctx context.Context, email string) (*User, error)
    List(ctx context.Context, filter ListFilter) ([]*User, error)
}

type UserWriter interface {
    Create(ctx context.Context, user *User) error
    Update(ctx context.Context, user *User) error
    Delete(ctx context.Context, id string) error
}

type UserRepository interface {
    UserReader
    UserWriter
}
```

### 2. Repository Composition

```go
// Compose repositories for complex operations
type UserService struct {
    userRepo    domain.UserRepository
    profileRepo domain.ProfileRepository
    auditRepo   domain.AuditRepository
}

func (s *UserService) CreateUserWithProfile(ctx context.Context, user *domain.User, profile *domain.Profile) error {
    if err := s.userRepo.Create(ctx, user); err != nil {
        return err
    }
    
    profile.UserID = user.ID
    if err := s.profileRepo.Create(ctx, profile); err != nil {
        // Compensate by deleting the user
        s.userRepo.Delete(ctx, user.ID)
        return err
    }
    
    // Log the operation
    audit := &domain.AuditLog{
        Action:   "user_created",
        UserID:   user.ID,
        Metadata: map[string]interface{}{"with_profile": true},
    }
    s.auditRepo.Log(ctx, audit)
    
    return nil
}
```

### 3. Repository Factory Pattern

```go
package repository

import (
    "database/sql"
    "myapp/domain"
)

// Factory creates repository instances
type Factory struct {
    db *sql.DB
}

// NewFactory creates a new repository factory
func NewFactory(db *sql.DB) *Factory {
    return &Factory{db: db}
}

// CreateUserRepository creates a user repository
func (f *Factory) CreateUserRepository() domain.UserRepository {
    return postgres.NewUserRepository(f.db)
}

// CreateProfileRepository creates a profile repository
func (f *Factory) CreateProfileRepository() domain.ProfileRepository {
    return postgres.NewProfileRepository(f.db)
}

// WithTransaction creates repositories within a transaction
func (f *Factory) WithTransaction(ctx context.Context, fn func(RepositoryTransaction) error) error {
    tx, err := f.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    
    defer func() {
        if p := recover(); p != nil {
            tx.Rollback()
            panic(p)
        } else if err != nil {
            tx.Rollback()
        } else {
            tx.Commit()
        }
    }()
    
    repoTx := &repositoryTransaction{
        userRepo:    postgres.NewTransactionalUserRepository(tx),
        profileRepo: postgres.NewTransactionalProfileRepository(tx),
    }
    
    err = fn(repoTx)
    return err
}

type RepositoryTransaction interface {
    UserRepository() domain.UserRepository
    ProfileRepository() domain.ProfileRepository
}

type repositoryTransaction struct {
    userRepo    domain.UserRepository
    profileRepo domain.ProfileRepository
}

func (rt *repositoryTransaction) UserRepository() domain.UserRepository {
    return rt.userRepo
}

func (rt *repositoryTransaction) ProfileRepository() domain.ProfileRepository {
    return rt.profileRepo
}
```

## Anti-patterns to Avoid

### 1. Anemic Repository

```go
// Bad: Repository only provides CRUD operations
type UserRepository interface {
    Create(ctx context.Context, user *User) error
    Read(ctx context.Context, id string) (*User, error)
    Update(ctx context.Context, user *User) error
    Delete(ctx context.Context, id string) error
}

// Good: Repository provides domain-specific operations
type UserRepository interface {
    Create(ctx context.Context, user *User) error
    GetByID(ctx context.Context, id string) (*User, error)
    GetByEmail(ctx context.Context, email string) (*User, error)
    GetActiveUsers(ctx context.Context) ([]*User, error)
    GetUsersByRole(ctx context.Context, role string) ([]*User, error)
    MarkAsInactive(ctx context.Context, id string) error
    CountActiveUsers(ctx context.Context) (int64, error)
}
```

### 2. Repository Leaking Database Concerns

```go
// Bad: Repository exposes database-specific types
type UserRepository interface {
    FindWithRawSQL(ctx context.Context, query string, args ...interface{}) ([]*User, error)
    GetConnection() *sql.DB
}

// Good: Repository abstracts database implementation
type UserRepository interface {
    FindByFilter(ctx context.Context, filter UserFilter) ([]*User, error)
    GetBySpecification(ctx context.Context, spec Specification) ([]*User, error)
}
```

### 3. God Repository

```go
// Bad: Single repository handling multiple concerns
type Repository interface {
    // User operations
    CreateUser(ctx context.Context, user *User) error
    GetUser(ctx context.Context, id string) (*User, error)
    
    // Order operations
    CreateOrder(ctx context.Context, order *Order) error
    GetOrder(ctx context.Context, id string) (*Order, error)
    
    // Product operations
    CreateProduct(ctx context.Context, product *Product) error
    GetProduct(ctx context.Context, id string) (*Product, error)
}

// Good: Focused repositories per aggregate
type UserRepository interface {
    Create(ctx context.Context, user *User) error
    GetByID(ctx context.Context, id string) (*User, error)
}

type OrderRepository interface {
    Create(ctx context.Context, order *Order) error
    GetByID(ctx context.Context, id string) (*Order, error)
}

type ProductRepository interface {
    Create(ctx context.Context, product *Product) error
    GetByID(ctx context.Context, id string) (*Product, error)
}
```

## Decision

1. **Always use interfaces** for repository contracts
2. **Implement domain-specific methods** beyond basic CRUD
3. **Support both transactional and non-transactional** operations
4. **Use dependency injection** to provide repository implementations
5. **Create in-memory implementations** for testing
6. **Follow single responsibility principle** per aggregate root
7. **Handle database-specific errors** and convert to domain errors
8. **Use generic patterns** where appropriate to reduce boilerplate

## Consequences

### Positive
- **Testability**: Easy to mock and test business logic
- **Flexibility**: Can switch between different data sources
- **Maintainability**: Clear separation of concerns
- **Domain focus**: Business logic remains clean of persistence concerns

### Negative
- **Additional abstraction**: Increases code complexity
- **Potential over-engineering**: Simple CRUD might not need repositories
- **Learning curve**: Team needs to understand the pattern properly
