# Use Unit of Work Pattern

## Status

`accepted`

## Context

The Unit of Work pattern maintains a list of objects affected by a business transaction and coordinates writing out changes and resolving concurrency problems. In Go applications, this pattern is essential for managing database transactions across multiple repository operations while maintaining data consistency.

[Reference implementation](https://github.com/alextanhongpin/uow)

## Problem

Traditional repository implementations often operate in isolation, making it difficult to:
- **Coordinate transactions** across multiple repositories
- **Ensure atomicity** for complex business operations
- **Manage transaction boundaries** in application services
- **Handle nested transactions** properly
- **Rollback changes** during testing or error scenarios
- **Pass transaction context** through application layers

Most repositories are designed to work with separate connections, making transactional operations challenging and error-prone.

## Solution

Implement a Unit of Work pattern that:
- Uses Go's `context.Context` to propagate transaction state
- Provides transaction management at the application service layer
- Enables repositories to automatically detect and use active transactions
- Supports nested transaction scenarios
- Ensures proper transaction lifecycle management

## Go Unit of Work Implementation

### Core Unit of Work Interface

```go
package uow

import (
    "context"
    "database/sql"
)

// UnitOfWork interface defines transaction management contract
type UnitOfWork interface {
    // Execute runs a function within a transaction
    Execute(ctx context.Context, fn func(ctx context.Context) error) error
    
    // ExecuteWithTx runs a function with explicit transaction access
    ExecuteWithTx(ctx context.Context, fn func(ctx context.Context, tx *sql.Tx) error) error
    
    // Begin starts a new transaction and returns a context with the transaction
    Begin(ctx context.Context) (context.Context, error)
    
    // Commit commits the transaction from the context
    Commit(ctx context.Context) error
    
    // Rollback rolls back the transaction from the context
    Rollback(ctx context.Context) error
    
    // GetTx extracts transaction from context
    GetTx(ctx context.Context) *sql.Tx
}

// contextKey is used for storing transaction in context
type contextKey string

const txKey contextKey = "transaction"

// WithTx adds a transaction to the context
func WithTx(ctx context.Context, tx *sql.Tx) context.Context {
    return context.WithValue(ctx, txKey, tx)
}

// TxFromContext extracts transaction from context
func TxFromContext(ctx context.Context) (*sql.Tx, bool) {
    tx, ok := ctx.Value(txKey).(*sql.Tx)
    return tx, ok
}
```

### SQL Unit of Work Implementation

```go
package uow

import (
    "context"
    "database/sql"
    "fmt"
)

// sqlUnitOfWork implements UnitOfWork for SQL databases
type sqlUnitOfWork struct {
    db *sql.DB
}

// NewSQLUnitOfWork creates a new SQL unit of work
func NewSQLUnitOfWork(db *sql.DB) UnitOfWork {
    return &sqlUnitOfWork{db: db}
}

// Execute runs a function within a transaction with automatic commit/rollback
func (u *sqlUnitOfWork) Execute(ctx context.Context, fn func(ctx context.Context) error) error {
    return u.ExecuteWithTx(ctx, func(ctx context.Context, tx *sql.Tx) error {
        return fn(ctx)
    })
}

// ExecuteWithTx runs a function with explicit transaction access
func (u *sqlUnitOfWork) ExecuteWithTx(ctx context.Context, fn func(ctx context.Context, tx *sql.Tx) error) error {
    // Check if we're already in a transaction (nested transaction)
    if existingTx, ok := TxFromContext(ctx); ok {
        // Use existing transaction for nested operations
        return fn(ctx, existingTx)
    }
    
    // Start new transaction
    tx, err := u.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("failed to begin transaction: %w", err)
    }
    
    // Add transaction to context
    txCtx := WithTx(ctx, tx)
    
    // Setup panic recovery and transaction cleanup
    defer func() {
        if p := recover(); p != nil {
            tx.Rollback()
            panic(p) // Re-throw panic after cleanup
        }
    }()
    
    // Execute function with transaction context
    if err := fn(txCtx, tx); err != nil {
        if rbErr := tx.Rollback(); rbErr != nil {
            return fmt.Errorf("transaction error: %w, rollback error: %v", err, rbErr)
        }
        return err
    }
    
    // Commit transaction
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("failed to commit transaction: %w", err)
    }
    
    return nil
}

// Begin starts a new transaction and returns a context with the transaction
func (u *sqlUnitOfWork) Begin(ctx context.Context) (context.Context, error) {
    tx, err := u.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("failed to begin transaction: %w", err)
    }
    
    return WithTx(ctx, tx), nil
}

// Commit commits the transaction from the context
func (u *sqlUnitOfWork) Commit(ctx context.Context) error {
    tx, ok := TxFromContext(ctx)
    if !ok {
        return fmt.Errorf("no transaction found in context")
    }
    
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("failed to commit transaction: %w", err)
    }
    
    return nil
}

// Rollback rolls back the transaction from the context
func (u *sqlUnitOfWork) Rollback(ctx context.Context) error {
    tx, ok := TxFromContext(ctx)
    if !ok {
        return fmt.Errorf("no transaction found in context")
    }
    
    if err := tx.Rollback(); err != nil {
        return fmt.Errorf("failed to rollback transaction: %w", err)
    }
    
    return nil
}

// GetTx extracts transaction from context
func (u *sqlUnitOfWork) GetTx(ctx context.Context) *sql.Tx {
    tx, _ := TxFromContext(ctx)
    return tx
}
```

### Transaction-Aware Repository

```go
package repository

import (
    "context"
    "database/sql"
    "fmt"
    "myapp/domain"
    "myapp/uow"
)

// QueryExecutor interface abstracts database operations
type QueryExecutor interface {
    ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error)
    QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error)
    QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row
}

// userRepository implements transaction-aware repository
type userRepository struct {
    db *sql.DB
}

// NewUserRepository creates a new user repository
func NewUserRepository(db *sql.DB) domain.UserRepository {
    return &userRepository{db: db}
}

// getExecutor returns appropriate executor based on context
func (r *userRepository) getExecutor(ctx context.Context) QueryExecutor {
    if tx, ok := uow.TxFromContext(ctx); ok {
        return tx
    }
    return r.db
}

// Create creates a new user using transaction-aware executor
func (r *userRepository) Create(ctx context.Context, user *domain.User) error {
    query := `
        INSERT INTO users (id, email, name, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5)`
    
    executor := r.getExecutor(ctx)
    _, err := executor.ExecContext(ctx, query, 
        user.ID, user.Email, user.Name, user.CreatedAt, user.UpdatedAt)
    
    if err != nil {
        return fmt.Errorf("failed to create user: %w", err)
    }
    
    return nil
}

// GetByID retrieves user by ID using transaction-aware executor
func (r *userRepository) GetByID(ctx context.Context, id string) (*domain.User, error) {
    query := `
        SELECT id, email, name, created_at, updated_at 
        FROM users WHERE id = $1`
    
    executor := r.getExecutor(ctx)
    user := &domain.User{}
    
    err := executor.QueryRowContext(ctx, query, id).Scan(
        &user.ID, &user.Email, &user.Name, &user.CreatedAt, &user.UpdatedAt)
    
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, domain.ErrUserNotFound
        }
        return nil, fmt.Errorf("failed to get user by ID: %w", err)
    }
    
    return user, nil
}

// Update updates user using transaction-aware executor
func (r *userRepository) Update(ctx context.Context, user *domain.User) error {
    query := `
        UPDATE users 
        SET email = $2, name = $3, updated_at = $4 
        WHERE id = $1`
    
    executor := r.getExecutor(ctx)
    result, err := executor.ExecContext(ctx, query, 
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

// Delete deletes user using transaction-aware executor
func (r *userRepository) Delete(ctx context.Context, id string) error {
    query := `DELETE FROM users WHERE id = $1`
    
    executor := r.getExecutor(ctx)
    result, err := executor.ExecContext(ctx, query, id)
    
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
```

### Application Service with Unit of Work

```go
package service

import (
    "context"
    "fmt"
    "myapp/domain"
    "myapp/uow"
    "time"

    "github.com/google/uuid"
)

// UserService handles user business operations
type UserService struct {
    uow      uow.UnitOfWork
    userRepo domain.UserRepository
    auditRepo domain.AuditRepository
}

// NewUserService creates a new user service
func NewUserService(
    uow uow.UnitOfWork,
    userRepo domain.UserRepository,
    auditRepo domain.AuditRepository,
) *UserService {
    return &UserService{
        uow:       uow,
        userRepo:  userRepo,
        auditRepo: auditRepo,
    }
}

// CreateUser creates a new user with audit logging
func (s *UserService) CreateUser(ctx context.Context, req CreateUserRequest) (*domain.User, error) {
    var createdUser *domain.User
    
    err := s.uow.Execute(ctx, func(ctx context.Context) error {
        // Create user within transaction
        user := &domain.User{
            ID:        uuid.New().String(),
            Email:     req.Email,
            Name:      req.Name,
            CreatedAt: time.Now(),
            UpdatedAt: time.Now(),
        }
        
        if err := s.userRepo.Create(ctx, user); err != nil {
            return fmt.Errorf("failed to create user: %w", err)
        }
        
        // Log audit event within same transaction
        auditLog := &domain.AuditLog{
            ID:        uuid.New().String(),
            Action:    "user_created",
            UserID:    user.ID,
            Metadata:  map[string]interface{}{"email": user.Email},
            CreatedAt: time.Now(),
        }
        
        if err := s.auditRepo.Create(ctx, auditLog); err != nil {
            return fmt.Errorf("failed to create audit log: %w", err)
        }
        
        createdUser = user
        return nil
    })
    
    if err != nil {
        return nil, err
    }
    
    return createdUser, nil
}

// UpdateUser updates user information with audit logging
func (s *UserService) UpdateUser(ctx context.Context, id string, req UpdateUserRequest) (*domain.User, error) {
    var updatedUser *domain.User
    
    err := s.uow.Execute(ctx, func(ctx context.Context) error {
        // Get existing user
        user, err := s.userRepo.GetByID(ctx, id)
        if err != nil {
            return err
        }
        
        // Update user fields
        oldEmail := user.Email
        user.Email = req.Email
        user.Name = req.Name
        user.UpdatedAt = time.Now()
        
        if err := s.userRepo.Update(ctx, user); err != nil {
            return fmt.Errorf("failed to update user: %w", err)
        }
        
        // Log audit event
        auditLog := &domain.AuditLog{
            ID:     uuid.New().String(),
            Action: "user_updated",
            UserID: user.ID,
            Metadata: map[string]interface{}{
                "old_email": oldEmail,
                "new_email": user.Email,
            },
            CreatedAt: time.Now(),
        }
        
        if err := s.auditRepo.Create(ctx, auditLog); err != nil {
            return fmt.Errorf("failed to create audit log: %w", err)
        }
        
        updatedUser = user
        return nil
    })
    
    if err != nil {
        return nil, err
    }
    
    return updatedUser, nil
}

// TransferData performs complex operations across multiple repositories
func (s *UserService) TransferData(ctx context.Context, fromUserID, toUserID string) error {
    return s.uow.Execute(ctx, func(ctx context.Context) error {
        // Get both users
        fromUser, err := s.userRepo.GetByID(ctx, fromUserID)
        if err != nil {
            return fmt.Errorf("failed to get from user: %w", err)
        }
        
        toUser, err := s.userRepo.GetByID(ctx, toUserID)
        if err != nil {
            return fmt.Errorf("failed to get to user: %w", err)
        }
        
        // Perform complex business operations
        // This could involve multiple repository calls
        // All within the same transaction
        
        // Log audit events
        auditLog := &domain.AuditLog{
            ID:     uuid.New().String(),
            Action: "data_transfer",
            UserID: fromUserID,
            Metadata: map[string]interface{}{
                "from_user": fromUser.ID,
                "to_user":   toUser.ID,
            },
            CreatedAt: time.Now(),
        }
        
        return s.auditRepo.Create(ctx, auditLog)
    })
}

// CreateUserRequest represents user creation request
type CreateUserRequest struct {
    Email string `json:"email" validate:"required,email"`
    Name  string `json:"name" validate:"required"`
}

// UpdateUserRequest represents user update request
type UpdateUserRequest struct {
    Email string `json:"email" validate:"required,email"`
    Name  string `json:"name" validate:"required"`
}
```

### Testing with Unit of Work

```go
package service_test

import (
    "context"
    "database/sql"
    "myapp/repository"
    "myapp/service"
    "myapp/uow"
    "testing"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestUserService_WithTransaction(t *testing.T) {
    db := setupTestDB(t) // Setup test database
    defer db.Close()
    
    unitOfWork := uow.NewSQLUnitOfWork(db)
    userRepo := repository.NewUserRepository(db)
    auditRepo := repository.NewAuditRepository(db)
    userService := service.NewUserService(unitOfWork, userRepo, auditRepo)
    
    ctx := context.Background()
    
    t.Run("CreateUser - Success", func(t *testing.T) {
        req := service.CreateUserRequest{
            Email: "test@example.com",
            Name:  "Test User",
        }
        
        user, err := userService.CreateUser(ctx, req)
        require.NoError(t, err)
        assert.Equal(t, req.Email, user.Email)
        assert.Equal(t, req.Name, user.Name)
        
        // Verify user was created
        retrievedUser, err := userRepo.GetByID(ctx, user.ID)
        require.NoError(t, err)
        assert.Equal(t, user.Email, retrievedUser.Email)
        
        // Verify audit log was created
        auditLogs, err := auditRepo.GetByUserID(ctx, user.ID)
        require.NoError(t, err)
        assert.Len(t, auditLogs, 1)
        assert.Equal(t, "user_created", auditLogs[0].Action)
    })
    
    t.Run("CreateUser - Rollback on Error", func(t *testing.T) {
        // Create a scenario that will cause audit logging to fail
        // This should rollback the entire transaction
        
        req := service.CreateUserRequest{
            Email: "rollback@example.com",
            Name:  "Rollback User",
        }
        
        // Mock audit repository to return error
        failingAuditRepo := &FailingAuditRepository{}
        failingUserService := service.NewUserService(unitOfWork, userRepo, failingAuditRepo)
        
        _, err := failingUserService.CreateUser(ctx, req)
        require.Error(t, err)
        
        // Verify user was not created (transaction rolled back)
        _, err = userRepo.GetByEmail(ctx, req.Email)
        assert.Error(t, err) // Should not exist
    })
}

func TestUnitOfWork_NestedTransactions(t *testing.T) {
    db := setupTestDB(t)
    defer db.Close()
    
    unitOfWork := uow.NewSQLUnitOfWork(db)
    userRepo := repository.NewUserRepository(db)
    
    ctx := context.Background()
    
    t.Run("Nested transactions share same tx", func(t *testing.T) {
        err := unitOfWork.Execute(ctx, func(ctx context.Context) error {
            // Create user in outer transaction
            user := &domain.User{
                ID:    "nested-test-1",
                Email: "nested@example.com",
                Name:  "Nested User",
            }
            
            if err := userRepo.Create(ctx, user); err != nil {
                return err
            }
            
            // Nested transaction operation
            return unitOfWork.Execute(ctx, func(ctx context.Context) error {
                // This should use the same transaction
                retrievedUser, err := userRepo.GetByID(ctx, user.ID)
                if err != nil {
                    return err
                }
                
                assert.Equal(t, user.Email, retrievedUser.Email)
                return nil
            })
        })
        
        require.NoError(t, err)
    })
}

func TestUnitOfWork_ManualTransactionControl(t *testing.T) {
    db := setupTestDB(t)
    defer db.Close()
    
    unitOfWork := uow.NewSQLUnitOfWork(db)
    userRepo := repository.NewUserRepository(db)
    
    t.Run("Manual transaction control", func(t *testing.T) {
        ctx := context.Background()
        
        // Begin transaction manually
        txCtx, err := unitOfWork.Begin(ctx)
        require.NoError(t, err)
        
        // Create user within transaction
        user := &domain.User{
            ID:    "manual-test-1",
            Email: "manual@example.com",
            Name:  "Manual User",
        }
        
        err = userRepo.Create(txCtx, user)
        require.NoError(t, err)
        
        // User should exist within transaction
        _, err = userRepo.GetByID(txCtx, user.ID)
        require.NoError(t, err)
        
        // User should not exist outside transaction before commit
        _, err = userRepo.GetByID(ctx, user.ID)
        assert.Error(t, err)
        
        // Commit transaction
        err = unitOfWork.Commit(txCtx)
        require.NoError(t, err)
        
        // User should now exist outside transaction
        _, err = userRepo.GetByID(ctx, user.ID)
        require.NoError(t, err)
    })
    
    t.Run("Manual rollback", func(t *testing.T) {
        ctx := context.Background()
        
        // Begin transaction manually
        txCtx, err := unitOfWork.Begin(ctx)
        require.NoError(t, err)
        
        // Create user within transaction
        user := &domain.User{
            ID:    "rollback-test-1",
            Email: "rollback@example.com",
            Name:  "Rollback User",
        }
        
        err = userRepo.Create(txCtx, user)
        require.NoError(t, err)
        
        // Rollback transaction
        err = unitOfWork.Rollback(txCtx)
        require.NoError(t, err)
        
        // User should not exist after rollback
        _, err = userRepo.GetByID(ctx, user.ID)
        assert.Error(t, err)
    })
}

// Test helpers
type FailingAuditRepository struct{}

func (r *FailingAuditRepository) Create(ctx context.Context, audit *domain.AuditLog) error {
    return fmt.Errorf("simulated audit repository failure")
}

func (r *FailingAuditRepository) GetByUserID(ctx context.Context, userID string) ([]*domain.AuditLog, error) {
    return nil, fmt.Errorf("simulated audit repository failure")
}

func setupTestDB(t *testing.T) *sql.DB {
    // Setup test database connection
    // This would typically use a test database or in-memory SQLite
    db, err := sql.Open("sqlite3", ":memory:")
    require.NoError(t, err)
    
    // Create tables
    createTables(t, db)
    
    return db
}

func createTables(t *testing.T, db *sql.DB) {
    userTable := `
    CREATE TABLE users (
        id TEXT PRIMARY KEY,
        email TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL,
        created_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL
    )`
    
    auditTable := `
    CREATE TABLE audit_logs (
        id TEXT PRIMARY KEY,
        action TEXT NOT NULL,
        user_id TEXT NOT NULL,
        metadata TEXT,
        created_at DATETIME NOT NULL
    )`
    
    _, err := db.Exec(userTable)
    require.NoError(t, err)
    
    _, err = db.Exec(auditTable)
    require.NoError(t, err)
}
```

### Specialized Unit of Work Implementations

```go
package uow

import (
    "context"
    "fmt"
    "sync"
)

// MemoryUnitOfWork provides in-memory transaction simulation
type MemoryUnitOfWork struct {
    operations []Operation
    mutex      sync.RWMutex
}

// Operation represents a unit of work operation
type Operation struct {
    Type   string
    Entity interface{}
    Action func() error
    Undo   func() error
}

// NewMemoryUnitOfWork creates a new memory-based unit of work
func NewMemoryUnitOfWork() UnitOfWork {
    return &MemoryUnitOfWork{
        operations: make([]Operation, 0),
    }
}

// Execute executes operations with rollback support
func (u *MemoryUnitOfWork) Execute(ctx context.Context, fn func(ctx context.Context) error) error {
    u.mutex.Lock()
    defer u.mutex.Unlock()
    
    // Clear previous operations
    u.operations = u.operations[:0]
    
    // Execute function
    if err := fn(ctx); err != nil {
        // Rollback operations in reverse order
        for i := len(u.operations) - 1; i >= 0; i-- {
            if undoErr := u.operations[i].Undo(); undoErr != nil {
                // Log undo error but return original error
                fmt.Printf("Failed to undo operation: %v\n", undoErr)
            }
        }
        return err
    }
    
    // Commit all operations
    for _, op := range u.operations {
        if err := op.Action(); err != nil {
            return fmt.Errorf("failed to commit operation: %w", err)
        }
    }
    
    return nil
}

// AddOperation adds an operation to the unit of work
func (u *MemoryUnitOfWork) AddOperation(op Operation) {
    u.operations = append(u.operations, op)
}
```

## Best Practices

### 1. Transaction Boundary Management

```go
// Good: Transaction boundaries at service layer
func (s *OrderService) CreateOrder(ctx context.Context, req CreateOrderRequest) (*Order, error) {
    return s.uow.Execute(ctx, func(ctx context.Context) error {
        // All repository operations use the same transaction
        order := &Order{...}
        if err := s.orderRepo.Create(ctx, order); err != nil {
            return err
        }
        
        // Update inventory in same transaction
        return s.inventoryRepo.Reserve(ctx, order.Items)
    })
}

// Bad: Transaction management in repository layer
func (r *orderRepository) Create(ctx context.Context, order *Order) error {
    // Don't manage transactions in repository
    tx, err := r.db.Begin()
    if err != nil {
        return err
    }
    // ... rest of implementation
}
```

### 2. Context Propagation

```go
// Good: Use context to propagate transaction
func (s *UserService) processUser(ctx context.Context, userID string) error {
    // Transaction context is passed down automatically
    user, err := s.userRepo.GetByID(ctx, userID)
    if err != nil {
        return err
    }
    
    // Nested service calls use same transaction
    return s.profileService.UpdateProfile(ctx, user.ProfileID)
}

// Bad: Passing transaction explicitly
func (s *UserService) processUser(tx *sql.Tx, userID string) error {
    // Forces all layers to know about transactions
    user, err := s.userRepo.GetByIDWithTx(tx, userID)
    if err != nil {
        return err
    }
    
    return s.profileService.UpdateProfileWithTx(tx, user.ProfileID)
}
```

### 3. Error Handling

```go
// Good: Comprehensive error handling
func (u *sqlUnitOfWork) Execute(ctx context.Context, fn func(ctx context.Context) error) error {
    tx, err := u.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("failed to begin transaction: %w", err)
    }
    
    defer func() {
        if p := recover(); p != nil {
            if rbErr := tx.Rollback(); rbErr != nil {
                fmt.Printf("Failed to rollback after panic: %v\n", rbErr)
            }
            panic(p)
        }
    }()
    
    txCtx := WithTx(ctx, tx)
    
    if err := fn(txCtx); err != nil {
        if rbErr := tx.Rollback(); rbErr != nil {
            return fmt.Errorf("transaction error: %w, rollback error: %v", err, rbErr)
        }
        return err
    }
    
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("failed to commit transaction: %w", err)
    }
    
    return nil
}
```

## Decision

1. **Use context.Context** to propagate transaction state
2. **Manage transaction boundaries** at the application service layer
3. **Design repositories** to be transaction-aware but not transaction-dependent
4. **Support nested transactions** by reusing existing transaction context
5. **Implement proper error handling** with automatic rollback
6. **Provide both automatic and manual** transaction control options
7. **Create specialized implementations** for different storage backends

## Consequences

### Positive
- **Clean interface**: Application services don't need explicit transaction parameters
- **Automatic transaction management**: Reduces boilerplate and human error
- **Nested transaction support**: Enables complex business operations
- **Better testing**: Easy to rollback transactions in tests
- **Consistent patterns**: Standardized approach across the application

### Negative
- **Context dependency**: Relies on Go's context pattern understanding
- **Hidden complexity**: Transaction state is implicit in context
- **Learning curve**: Team needs to understand the pattern properly
- **Debugging challenges**: Transaction flow may be less visible

### Trade-offs
- **Performance**: Slight overhead from context value lookups
- **Flexibility**: Less explicit control over transaction boundaries
- **Complexity**: Additional abstraction layer to maintain
