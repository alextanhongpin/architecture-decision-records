# Database ORM Strategy and Selection

## Status
**Accepted**

## Context
Selecting the appropriate database access pattern is crucial for application maintainability, performance, and team productivity. In Go, we have several options ranging from raw SQL to feature-rich ORMs, each with distinct trade-offs.

The main approaches include:
- **Raw SQL with database/sql**: Maximum control and performance
- **Query Builders** (Squirrel, Sqlx): SQL generation with some abstraction
- **Lightweight ORMs** (Bun, Ent): Modern, type-safe database access
- **Traditional ORMs** (GORM): Feature-rich but complex abstractions

Our decision impacts code maintainability, performance, testing strategies, and team onboarding complexity.

## Decision
We will use a **hybrid approach** with **Bun ORM** as the primary tool for standard operations, complemented by raw SQL for complex queries and performance-critical operations.

## Implementation

### 1. Bun ORM Configuration and Setup

```go
// pkg/database/connection.go
package database

import (
    "database/sql"
    "fmt"
    
    "github.com/uptrace/bun"
    "github.com/uptrace/bun/dialect/pgdialect"
    "github.com/uptrace/bun/driver/pgdriver"
    "github.com/uptrace/bun/extra/bundebug"
)

type Config struct {
    Host     string
    Port     int
    Database string
    Username string
    Password string
    SSLMode  string
    
    // Performance settings
    MaxOpenConns    int
    MaxIdleConns    int
    ConnMaxLifetime time.Duration
    
    // Development settings
    Debug bool
}

func NewConnection(config Config) (*bun.DB, error) {
    // Configure PostgreSQL connection
    dsn := fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=%s",
        config.Username, config.Password, config.Host, config.Port,
        config.Database, config.SSLMode)
    
    sqldb := sql.OpenDB(pgdriver.NewConnector(pgdriver.WithDSN(dsn)))
    
    // Configure connection pool
    sqldb.SetMaxOpenConns(config.MaxOpenConns)
    sqldb.SetMaxIdleConns(config.MaxIdleConns)
    sqldb.SetConnMaxLifetime(config.ConnMaxLifetime)
    
    // Create Bun DB instance
    db := bun.NewDB(sqldb, pgdialect.New())
    
    // Add debug hooks for development
    if config.Debug {
        db.AddQueryHook(bundebug.NewQueryHook(
            bundebug.WithVerbose(true),
            bundebug.FromEnv("BUNDEBUG"),
        ))
    }
    
    // Test connection
    if err := db.Ping(); err != nil {
        return nil, fmt.Errorf("failed to ping database: %w", err)
    }
    
    return db, nil
}

// Repository interface for dependency injection
type Repository interface {
    GetDB() *bun.DB
    BeginTx(ctx context.Context) (*bun.Tx, error)
}

type repository struct {
    db *bun.DB
}

func NewRepository(db *bun.DB) Repository {
    return &repository{db: db}
}

func (r *repository) GetDB() *bun.DB {
    return r.db
}

func (r *repository) BeginTx(ctx context.Context) (*bun.Tx, error) {
    return r.db.BeginTx(ctx, &sql.TxOptions{})
}
```

### 2. Model Definition and Schema Management

```go
// pkg/models/user.go
package models

import (
    "time"
    
    "github.com/uptrace/bun"
    "github.com/google/uuid"
)

// User model with Bun tags and validation
type User struct {
    bun.BaseModel `bun:"table:users,alias:u"`
    
    ID        uuid.UUID  `bun:"id,pk,type:uuid,default:gen_random_uuid()" json:"id"`
    Email     string     `bun:"email,notnull,unique" json:"email" validate:"required,email"`
    Username  string     `bun:"username,notnull,unique" json:"username" validate:"required,min=3,max=50"`
    FirstName string     `bun:"first_name,notnull" json:"first_name" validate:"required,max=100"`
    LastName  string     `bun:"last_name,notnull" json:"last_name" validate:"required,max=100"`
    
    // Password should never be serialized to JSON
    PasswordHash string `bun:"password_hash,notnull" json:"-" validate:"required"`
    
    // Status fields
    IsActive      bool      `bun:"is_active,notnull,default:true" json:"is_active"`
    EmailVerified bool      `bun:"email_verified,notnull,default:false" json:"email_verified"`
    LastLoginAt   *time.Time `bun:"last_login_at" json:"last_login_at"`
    
    // Timestamps
    CreatedAt time.Time `bun:"created_at,nullzero,notnull,default:current_timestamp" json:"created_at"`
    UpdatedAt time.Time `bun:"updated_at,nullzero,notnull,default:current_timestamp" json:"updated_at"`
    
    // Relationships
    Profile *UserProfile `bun:"rel:has-one,join:id=user_id" json:"profile,omitempty"`
    Orders  []*Order     `bun:"rel:has-many,join:id=user_id" json:"orders,omitempty"`
    Roles   []*Role      `bun:"m2m:user_roles,join:User=Role" json:"roles,omitempty"`
}

// UserProfile for additional user information
type UserProfile struct {
    bun.BaseModel `bun:"table:user_profiles,alias:up"`
    
    ID          uuid.UUID `bun:"id,pk,type:uuid,default:gen_random_uuid()"`
    UserID      uuid.UUID `bun:"user_id,notnull,unique"`
    Bio         string    `bun:"bio,type:text"`
    Avatar      string    `bun:"avatar"`
    Timezone    string    `bun:"timezone,default:'UTC'"`
    Language    string    `bun:"language,default:'en'"`
    Preferences map[string]interface{} `bun:"preferences,type:jsonb"`
    
    CreatedAt time.Time `bun:"created_at,nullzero,notnull,default:current_timestamp"`
    UpdatedAt time.Time `bun:"updated_at,nullzero,notnull,default:current_timestamp"`
    
    // Relationships
    User *User `bun:"rel:belongs-to,join:user_id=id"`
}

// Order represents user orders
type Order struct {
    bun.BaseModel `bun:"table:orders,alias:o"`
    
    ID          uuid.UUID `bun:"id,pk,type:uuid,default:gen_random_uuid()"`
    UserID      uuid.UUID `bun:"user_id,notnull"`
    OrderNumber string    `bun:"order_number,notnull,unique"`
    Status      string    `bun:"status,notnull,default:'pending'"`
    TotalAmount float64   `bun:"total_amount,type:decimal(15,2)"`
    
    CreatedAt time.Time `bun:"created_at,nullzero,notnull,default:current_timestamp"`
    UpdatedAt time.Time `bun:"updated_at,nullzero,notnull,default:current_timestamp"`
    
    // Relationships
    User  *User        `bun:"rel:belongs-to,join:user_id=id"`
    Items []*OrderItem `bun:"rel:has-many,join:id=order_id"`
}

// Role for user permissions
type Role struct {
    bun.BaseModel `bun:"table:roles,alias:r"`
    
    ID          int       `bun:"id,pk,autoincrement"`
    Name        string    `bun:"name,notnull,unique"`
    Description string    `bun:"description"`
    Permissions []string  `bun:"permissions,type:text[]"`
    
    CreatedAt time.Time `bun:"created_at,nullzero,notnull,default:current_timestamp"`
    UpdatedAt time.Time `bun:"updated_at,nullzero,notnull,default:current_timestamp"`
    
    // Many-to-many relationship
    Users []*User `bun:"m2m:user_roles,join:Role=User"`
}

// Junction table for many-to-many relationship
type UserRole struct {
    bun.BaseModel `bun:"table:user_roles,alias:ur"`
    
    UserID uuid.UUID `bun:"user_id,pk"`
    RoleID int       `bun:"role_id,pk"`
    
    AssignedAt time.Time `bun:"assigned_at,nullzero,notnull,default:current_timestamp"`
    AssignedBy uuid.UUID `bun:"assigned_by"`
    
    // Relationships
    User *User `bun:"rel:belongs-to,join:user_id=id"`
    Role *Role `bun:"rel:belongs-to,join:role_id=id"`
}
```

### 3. Repository Pattern Implementation

```go
// pkg/repositories/user_repository.go
package repositories

import (
    "context"
    "fmt"
    
    "github.com/uptrace/bun"
    "github.com/google/uuid"
    
    "your-project/pkg/models"
)

type UserRepository interface {
    Create(ctx context.Context, user *models.User) error
    GetByID(ctx context.Context, id uuid.UUID) (*models.User, error)
    GetByEmail(ctx context.Context, email string) (*models.User, error)
    GetByUsername(ctx context.Context, username string) (*models.User, error)
    Update(ctx context.Context, user *models.User) error
    Delete(ctx context.Context, id uuid.UUID) error
    List(ctx context.Context, filters UserFilters) ([]*models.User, int, error)
    GetWithProfile(ctx context.Context, id uuid.UUID) (*models.User, error)
    GetWithOrders(ctx context.Context, id uuid.UUID) (*models.User, error)
    BulkCreate(ctx context.Context, users []*models.User) error
    UpdateLastLogin(ctx context.Context, id uuid.UUID) error
}

type userRepository struct {
    db *bun.DB
}

func NewUserRepository(db *bun.DB) UserRepository {
    return &userRepository{db: db}
}

type UserFilters struct {
    IsActive      *bool
    EmailVerified *bool
    Search        string
    Limit         int
    Offset        int
    OrderBy       string
    OrderDir      string
}

func (r *userRepository) Create(ctx context.Context, user *models.User) error {
    _, err := r.db.NewInsert().Model(user).Exec(ctx)
    if err != nil {
        return fmt.Errorf("failed to create user: %w", err)
    }
    return nil
}

func (r *userRepository) GetByID(ctx context.Context, id uuid.UUID) (*models.User, error) {
    user := new(models.User)
    err := r.db.NewSelect().
        Model(user).
        Where("id = ?", id).
        Scan(ctx)
    
    if err != nil {
        return nil, fmt.Errorf("failed to get user by ID: %w", err)
    }
    
    return user, nil
}

func (r *userRepository) GetByEmail(ctx context.Context, email string) (*models.User, error) {
    user := new(models.User)
    err := r.db.NewSelect().
        Model(user).
        Where("email = ?", email).
        Scan(ctx)
    
    if err != nil {
        return nil, fmt.Errorf("failed to get user by email: %w", err)
    }
    
    return user, nil
}

func (r *userRepository) Update(ctx context.Context, user *models.User) error {
    _, err := r.db.NewUpdate().
        Model(user).
        Where("id = ?", user.ID).
        Exec(ctx)
    
    if err != nil {
        return fmt.Errorf("failed to update user: %w", err)
    }
    
    return nil
}

func (r *userRepository) List(ctx context.Context, filters UserFilters) ([]*models.User, int, error) {
    query := r.db.NewSelect().Model((*models.User)(nil))
    
    // Apply filters
    if filters.IsActive != nil {
        query = query.Where("is_active = ?", *filters.IsActive)
    }
    
    if filters.EmailVerified != nil {
        query = query.Where("email_verified = ?", *filters.EmailVerified)
    }
    
    if filters.Search != "" {
        searchTerm := "%" + filters.Search + "%"
        query = query.Where("(first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ? OR username ILIKE ?)",
            searchTerm, searchTerm, searchTerm, searchTerm)
    }
    
    // Count total
    total, err := query.Count(ctx)
    if err != nil {
        return nil, 0, fmt.Errorf("failed to count users: %w", err)
    }
    
    // Apply ordering
    orderBy := "created_at"
    if filters.OrderBy != "" {
        orderBy = filters.OrderBy
    }
    
    orderDir := "DESC"
    if filters.OrderDir != "" {
        orderDir = filters.OrderDir
    }
    
    query = query.Order(fmt.Sprintf("%s %s", orderBy, orderDir))
    
    // Apply pagination
    if filters.Limit > 0 {
        query = query.Limit(filters.Limit)
    }
    
    if filters.Offset > 0 {
        query = query.Offset(filters.Offset)
    }
    
    var users []*models.User
    err = query.Scan(ctx, &users)
    if err != nil {
        return nil, 0, fmt.Errorf("failed to list users: %w", err)
    }
    
    return users, total, nil
}

func (r *userRepository) GetWithProfile(ctx context.Context, id uuid.UUID) (*models.User, error) {
    user := new(models.User)
    err := r.db.NewSelect().
        Model(user).
        Relation("Profile").
        Where("u.id = ?", id).
        Scan(ctx)
    
    if err != nil {
        return nil, fmt.Errorf("failed to get user with profile: %w", err)
    }
    
    return user, nil
}

func (r *userRepository) GetWithOrders(ctx context.Context, id uuid.UUID) (*models.User, error) {
    user := new(models.User)
    err := r.db.NewSelect().
        Model(user).
        Relation("Orders", func(q *bun.SelectQuery) *bun.SelectQuery {
            return q.Order("created_at DESC").Limit(10)
        }).
        Where("u.id = ?", id).
        Scan(ctx)
    
    if err != nil {
        return nil, fmt.Errorf("failed to get user with orders: %w", err)
    }
    
    return user, nil
}

func (r *userRepository) BulkCreate(ctx context.Context, users []*models.User) error {
    _, err := r.db.NewInsert().
        Model(&users).
        Exec(ctx)
    
    if err != nil {
        return fmt.Errorf("failed to bulk create users: %w", err)
    }
    
    return nil
}

func (r *userRepository) UpdateLastLogin(ctx context.Context, id uuid.UUID) error {
    _, err := r.db.NewUpdate().
        Model((*models.User)(nil)).
        Set("last_login_at = CURRENT_TIMESTAMP").
        Where("id = ?", id).
        Exec(ctx)
    
    return err
}
```

### 4. Complex Query Examples with Raw SQL

```go
// pkg/repositories/analytics_repository.go
package repositories

import (
    "context"
    "time"
    
    "github.com/uptrace/bun"
)

type AnalyticsRepository interface {
    GetUserStats(ctx context.Context, period time.Duration) (*UserStats, error)
    GetOrderTrends(ctx context.Context, start, end time.Time) ([]*OrderTrend, error)
    GetTopUsers(ctx context.Context, limit int) ([]*TopUser, error)
}

type analyticsRepository struct {
    db *bun.DB
}

type UserStats struct {
    TotalUsers      int     `json:"total_users"`
    ActiveUsers     int     `json:"active_users"`
    NewUsers        int     `json:"new_users"`
    VerifiedUsers   int     `json:"verified_users"`
    GrowthRate      float64 `json:"growth_rate"`
}

type OrderTrend struct {
    Date        time.Time `json:"date"`
    OrderCount  int       `json:"order_count"`
    TotalAmount float64   `json:"total_amount"`
    AvgAmount   float64   `json:"avg_amount"`
}

type TopUser struct {
    UserID      string  `json:"user_id"`
    Name        string  `json:"name"`
    Email       string  `json:"email"`
    OrderCount  int     `json:"order_count"`
    TotalSpent  float64 `json:"total_spent"`
}

func (r *analyticsRepository) GetUserStats(ctx context.Context, period time.Duration) (*UserStats, error) {
    stats := &UserStats{}
    
    // Complex query better suited for raw SQL
    query := `
        WITH user_metrics AS (
            SELECT 
                COUNT(*) as total_users,
                COUNT(*) FILTER (WHERE is_active = true) as active_users,
                COUNT(*) FILTER (WHERE created_at >= $1) as new_users,
                COUNT(*) FILTER (WHERE email_verified = true) as verified_users,
                COUNT(*) FILTER (WHERE created_at >= $2) as previous_period_users
            FROM users
        )
        SELECT 
            total_users,
            active_users,
            new_users,
            verified_users,
            CASE 
                WHEN previous_period_users > 0 
                THEN (new_users::float / previous_period_users::float - 1) * 100
                ELSE 0
            END as growth_rate
        FROM user_metrics
    `
    
    since := time.Now().Add(-period)
    previousPeriod := time.Now().Add(-period * 2)
    
    err := r.db.NewRaw(query, since, previousPeriod).Scan(ctx,
        &stats.TotalUsers, &stats.ActiveUsers, &stats.NewUsers,
        &stats.VerifiedUsers, &stats.GrowthRate)
    
    if err != nil {
        return nil, fmt.Errorf("failed to get user stats: %w", err)
    }
    
    return stats, nil
}

func (r *analyticsRepository) GetOrderTrends(ctx context.Context, start, end time.Time) ([]*OrderTrend, error) {
    query := `
        SELECT 
            DATE_TRUNC('day', created_at) as date,
            COUNT(*) as order_count,
            SUM(total_amount) as total_amount,
            AVG(total_amount) as avg_amount
        FROM orders 
        WHERE created_at BETWEEN $1 AND $2
        GROUP BY DATE_TRUNC('day', created_at)
        ORDER BY date
    `
    
    var trends []*OrderTrend
    err := r.db.NewRaw(query, start, end).Scan(ctx, &trends)
    if err != nil {
        return nil, fmt.Errorf("failed to get order trends: %w", err)
    }
    
    return trends, nil
}

func (r *analyticsRepository) GetTopUsers(ctx context.Context, limit int) ([]*TopUser, error) {
    // Complex query with window functions
    query := `
        SELECT 
            u.id as user_id,
            u.first_name || ' ' || u.last_name as name,
            u.email,
            COUNT(o.id) as order_count,
            COALESCE(SUM(o.total_amount), 0) as total_spent
        FROM users u
        LEFT JOIN orders o ON u.id = o.user_id
        WHERE u.is_active = true
        GROUP BY u.id, u.first_name, u.last_name, u.email
        HAVING COUNT(o.id) > 0
        ORDER BY total_spent DESC, order_count DESC
        LIMIT $1
    `
    
    var topUsers []*TopUser
    err := r.db.NewRaw(query, limit).Scan(ctx, &topUsers)
    if err != nil {
        return nil, fmt.Errorf("failed to get top users: %w", err)
    }
    
    return topUsers, nil
}
```

### 5. Transaction Management

```go
// pkg/services/user_service.go
package services

import (
    "context"
    "fmt"
    
    "github.com/uptrace/bun"
    "github.com/google/uuid"
    
    "your-project/pkg/models"
    "your-project/pkg/repositories"
)

type UserService interface {
    CreateUserWithProfile(ctx context.Context, req CreateUserRequest) (*models.User, error)
    AssignRoles(ctx context.Context, userID uuid.UUID, roleIDs []int) error
    DeactivateUser(ctx context.Context, userID uuid.UUID, reason string) error
}

type userService struct {
    db         *bun.DB
    userRepo   repositories.UserRepository
    roleRepo   repositories.RoleRepository
    auditRepo  repositories.AuditRepository
}

type CreateUserRequest struct {
    Email       string            `json:"email" validate:"required,email"`
    Username    string            `json:"username" validate:"required,min=3,max=50"`
    FirstName   string            `json:"first_name" validate:"required,max=100"`
    LastName    string            `json:"last_name" validate:"required,max=100"`
    Password    string            `json:"password" validate:"required,min=8"`
    Profile     *UserProfileData  `json:"profile,omitempty"`
    InitialRoles []int            `json:"initial_roles,omitempty"`
}

type UserProfileData struct {
    Bio         string                 `json:"bio"`
    Timezone    string                 `json:"timezone"`
    Language    string                 `json:"language"`
    Preferences map[string]interface{} `json:"preferences"`
}

func (s *userService) CreateUserWithProfile(ctx context.Context, req CreateUserRequest) (*models.User, error) {
    // Start transaction
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("failed to begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Create user
    user := &models.User{
        Email:     req.Email,
        Username:  req.Username,
        FirstName: req.FirstName,
        LastName:  req.LastName,
        PasswordHash: hashPassword(req.Password), // Implement password hashing
    }
    
    _, err = tx.NewInsert().Model(user).Exec(ctx)
    if err != nil {
        return nil, fmt.Errorf("failed to create user: %w", err)
    }
    
    // Create profile if provided
    if req.Profile != nil {
        profile := &models.UserProfile{
            UserID:      user.ID,
            Bio:         req.Profile.Bio,
            Timezone:    req.Profile.Timezone,
            Language:    req.Profile.Language,
            Preferences: req.Profile.Preferences,
        }
        
        _, err = tx.NewInsert().Model(profile).Exec(ctx)
        if err != nil {
            return nil, fmt.Errorf("failed to create user profile: %w", err)
        }
    }
    
    // Assign initial roles
    if len(req.InitialRoles) > 0 {
        userRoles := make([]*models.UserRole, len(req.InitialRoles))
        for i, roleID := range req.InitialRoles {
            userRoles[i] = &models.UserRole{
                UserID: user.ID,
                RoleID: roleID,
            }
        }
        
        _, err = tx.NewInsert().Model(&userRoles).Exec(ctx)
        if err != nil {
            return nil, fmt.Errorf("failed to assign roles: %w", err)
        }
    }
    
    // Log user creation
    auditLog := &models.AuditLog{
        EntityType: "user",
        EntityID:   user.ID.String(),
        Action:     "create",
        Details:    map[string]interface{}{"username": user.Username, "email": user.Email},
    }
    
    _, err = tx.NewInsert().Model(auditLog).Exec(ctx)
    if err != nil {
        return nil, fmt.Errorf("failed to create audit log: %w", err)
    }
    
    // Commit transaction
    if err = tx.Commit(); err != nil {
        return nil, fmt.Errorf("failed to commit transaction: %w", err)
    }
    
    return user, nil
}

func (s *userService) AssignRoles(ctx context.Context, userID uuid.UUID, roleIDs []int) error {
    return s.db.RunInTx(ctx, nil, func(ctx context.Context, tx bun.Tx) error {
        // Remove existing roles
        _, err := tx.NewDelete().
            Model((*models.UserRole)(nil)).
            Where("user_id = ?", userID).
            Exec(ctx)
        if err != nil {
            return fmt.Errorf("failed to remove existing roles: %w", err)
        }
        
        // Add new roles
        if len(roleIDs) > 0 {
            userRoles := make([]*models.UserRole, len(roleIDs))
            for i, roleID := range roleIDs {
                userRoles[i] = &models.UserRole{
                    UserID: userID,
                    RoleID: roleID,
                }
            }
            
            _, err = tx.NewInsert().Model(&userRoles).Exec(ctx)
            if err != nil {
                return fmt.Errorf("failed to assign new roles: %w", err)
            }
        }
        
        return nil
    })
}
```

### 6. Testing with Bun

```go
// pkg/repositories/user_repository_test.go
package repositories

import (
    "context"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
    "github.com/google/uuid"
    
    "your-project/pkg/models"
    "your-project/test/testutil"
)

func TestUserRepository_CRUD(t *testing.T) {
    db := testutil.SetupTestDB(t)
    defer testutil.CleanupTestDB(t, db)
    
    repo := NewUserRepository(db)
    ctx := context.Background()
    
    t.Run("Create and Get User", func(t *testing.T) {
        user := &models.User{
            Email:     "test@example.com",
            Username:  "testuser",
            FirstName: "Test",
            LastName:  "User",
            PasswordHash: "hashed_password",
        }
        
        // Create user
        err := repo.Create(ctx, user)
        require.NoError(t, err)
        assert.NotEqual(t, uuid.Nil, user.ID)
        
        // Get user by ID
        retrieved, err := repo.GetByID(ctx, user.ID)
        require.NoError(t, err)
        assert.Equal(t, user.Email, retrieved.Email)
        assert.Equal(t, user.Username, retrieved.Username)
        
        // Get user by email
        byEmail, err := repo.GetByEmail(ctx, user.Email)
        require.NoError(t, err)
        assert.Equal(t, user.ID, byEmail.ID)
    })
    
    t.Run("List Users with Filters", func(t *testing.T) {
        // Create test users
        users := []*models.User{
            {Email: "active@test.com", Username: "active", FirstName: "Active", LastName: "User", IsActive: true},
            {Email: "inactive@test.com", Username: "inactive", FirstName: "Inactive", LastName: "User", IsActive: false},
        }
        
        err := repo.BulkCreate(ctx, users)
        require.NoError(t, err)
        
        // Test filter by active status
        activeOnly := true
        filters := UserFilters{
            IsActive: &activeOnly,
            Limit:    10,
        }
        
        result, total, err := repo.List(ctx, filters)
        require.NoError(t, err)
        assert.GreaterOrEqual(t, total, 1)
        
        for _, user := range result {
            assert.True(t, user.IsActive)
        }
    })
}

func TestUserRepository_Relationships(t *testing.T) {
    db := testutil.SetupTestDB(t)
    defer testutil.CleanupTestDB(t, db)
    
    repo := NewUserRepository(db)
    ctx := context.Background()
    
    // Create user with profile
    user := &models.User{
        Email:     "user@test.com",
        Username:  "testuser",
        FirstName: "Test",
        LastName:  "User",
        PasswordHash: "hash",
    }
    
    err := repo.Create(ctx, user)
    require.NoError(t, err)
    
    // Create profile
    profile := &models.UserProfile{
        UserID:   user.ID,
        Bio:      "Test bio",
        Timezone: "UTC",
        Language: "en",
    }
    
    _, err = db.NewInsert().Model(profile).Exec(ctx)
    require.NoError(t, err)
    
    // Test getting user with profile
    userWithProfile, err := repo.GetWithProfile(ctx, user.ID)
    require.NoError(t, err)
    require.NotNil(t, userWithProfile.Profile)
    assert.Equal(t, "Test bio", userWithProfile.Profile.Bio)
}

// testutil/database.go
package testutil

import (
    "database/sql"
    "testing"
    
    "github.com/uptrace/bun"
    "github.com/uptrace/bun/dialect/pgdialect"
    "github.com/uptrace/bun/driver/pgdriver"
    
    "your-project/pkg/models"
)

func SetupTestDB(t *testing.T) *bun.DB {
    dsn := "postgres://test:test@localhost:5432/test_db?sslmode=disable"
    sqldb := sql.OpenDB(pgdriver.NewConnector(pgdriver.WithDSN(dsn)))
    
    db := bun.NewDB(sqldb, pgdialect.New())
    
    // Create tables
    models := []interface{}{
        (*models.User)(nil),
        (*models.UserProfile)(nil),
        (*models.Order)(nil),
        (*models.Role)(nil),
        (*models.UserRole)(nil),
    }
    
    for _, model := range models {
        _, err := db.NewCreateTable().Model(model).IfNotExists().Exec(context.Background())
        if err != nil {
            t.Fatalf("Failed to create table: %v", err)
        }
    }
    
    return db
}

func CleanupTestDB(t *testing.T, db *bun.DB) {
    // Clean up test data
    tables := []string{"user_roles", "orders", "user_profiles", "users", "roles"}
    
    for _, table := range tables {
        _, err := db.Exec("TRUNCATE TABLE ? CASCADE", bun.Ident(table))
        if err != nil {
            t.Logf("Failed to truncate table %s: %v", table, err)
        }
    }
    
    db.Close()
}
```

## Comparison with Alternative Approaches

### Bun vs GORM vs Raw SQL

| Aspect | Bun | GORM | Raw SQL |
|--------|-----|------|---------|
| **Learning Curve** | Moderate | Steep | Easy |
| **Type Safety** | High | Medium | Low |
| **Performance** | High | Medium | Highest |
| **Code Generation** | Manual | Auto | Manual |
| **Query Flexibility** | High | Medium | Highest |
| **Relationship Handling** | Excellent | Excellent | Manual |
| **Migration Support** | External | Built-in | External |
| **Debugging** | Good | Difficult | Excellent |

### When to Use Each Approach

```go
// Use Bun for standard CRUD operations
func (r *userRepository) GetActiveUsers(ctx context.Context) ([]*models.User, error) {
    var users []*models.User
    err := r.db.NewSelect().
        Model(&users).
        Where("is_active = ?", true).
        Order("created_at DESC").
        Scan(ctx)
    return users, err
}

// Use Raw SQL for complex analytics
func (r *analyticsRepository) GetComplexReport(ctx context.Context) (*Report, error) {
    query := `
        WITH monthly_stats AS (
            SELECT 
                DATE_TRUNC('month', created_at) as month,
                COUNT(*) as user_count,
                COUNT(*) FILTER (WHERE email_verified) as verified_count
            FROM users 
            WHERE created_at >= NOW() - INTERVAL '12 months'
            GROUP BY DATE_TRUNC('month', created_at)
        ),
        cohort_analysis AS (
            SELECT 
                DATE_TRUNC('month', u.created_at) as cohort_month,
                DATE_TRUNC('month', o.created_at) as order_month,
                COUNT(DISTINCT u.id) as users,
                COUNT(o.id) as orders
            FROM users u
            LEFT JOIN orders o ON u.id = o.user_id
            GROUP BY cohort_month, order_month
        )
        SELECT 
            ms.month,
            ms.user_count,
            ms.verified_count,
            COALESCE(ca.orders, 0) as orders_in_month
        FROM monthly_stats ms
        LEFT JOIN cohort_analysis ca ON ms.month = ca.cohort_month
        ORDER BY ms.month
    `
    
    var report Report
    err := r.db.NewRaw(query).Scan(ctx, &report)
    return &report, err
}
```

## Best Practices

### 1. Model Design
- Use proper Bun tags for database mapping
- Implement validation tags for input validation
- Use pointer types for nullable foreign keys
- Define relationships clearly with proper join tags

### 2. Repository Pattern
- Keep business logic out of repositories
- Use interfaces for dependency injection
- Implement proper error handling
- Use transactions for multi-step operations

### 3. Performance Optimization
```go
// Use select specific columns for large datasets
func (r *userRepository) GetUserSummaries(ctx context.Context) ([]*UserSummary, error) {
    var summaries []*UserSummary
    err := r.db.NewSelect().
        Model((*models.User)(nil)).
        Column("id", "first_name", "last_name", "email").
        Where("is_active = ?", true).
        Scan(ctx, &summaries)
    return summaries, err
}

// Use proper indexing hints for complex queries
func (r *orderRepository) GetRecentOrders(ctx context.Context, limit int) ([]*models.Order, error) {
    var orders []*models.Order
    err := r.db.NewSelect().
        Model(&orders).
        Relation("User", func(q *bun.SelectQuery) *bun.SelectQuery {
            return q.Column("id", "first_name", "last_name")
        }).
        Order("created_at DESC").
        Limit(limit).
        Scan(ctx)
    return orders, err
}
```

## Consequences

### Advantages
- **Type Safety**: Compile-time checking of queries and models
- **Relationship Handling**: Excellent support for nested associations and eager loading
- **Performance**: Generated queries are efficient and optimized
- **Flexibility**: Easy transition between ORM queries and raw SQL
- **Modern API**: Clean, fluent interface that's easy to understand
- **Migration Compatibility**: Works well with external migration tools

### Disadvantages
- **Learning Curve**: Team needs to learn Bun-specific patterns and APIs
- **Abstraction Layer**: Additional complexity compared to raw SQL
- **Version Dependencies**: Potential for breaking changes in ORM updates
- **Debug Complexity**: Generated queries can be harder to debug
- **Magic Behavior**: Implicit behaviors may not be immediately obvious

### Mitigation Strategies
- **Comprehensive Testing**: Test all repository methods thoroughly
- **Raw SQL Fallback**: Use raw SQL for complex queries where ORM becomes cumbersome
- **Query Logging**: Enable query logging in development for debugging
- **Documentation**: Document ORM patterns and conventions clearly
- **Performance Monitoring**: Monitor query performance and optimize as needed

## Related Patterns
- [Migration Files](002-migration-files.md) - Database schema management
- [Database Design Record](009-database-design-record.md) - Schema documentation
- [Optimistic Locking](007-optimistic-locking.md) - Concurrent access control
- [Testing Patterns](004-dockertest.md) - Database testing strategies
