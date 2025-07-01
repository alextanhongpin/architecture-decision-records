# Business Logic Architecture and Implementation

## Status

`accepted`

## Context

Business logic is the core of any application, representing the rules, validations, transformations, and workflows that define how the business operates. Proper organization and implementation of business logic is crucial for maintainability, testability, and scalability.

Business logic should be clearly separated from infrastructure concerns, well-organized into appropriate layers, and implemented using patterns that promote reusability and maintainability.

## Decision

We will implement a layered business logic architecture that separates concerns across request, model, aggregate, and database levels, using domain-driven design principles and clean architecture patterns.

## Business Logic Layers

### 1. Request Level Logic

Handles HTTP request validation, sanitization, and transformation:

```go
package request

import (
    "context"
    "fmt"
    "net/http"
    "strconv"
    "strings"
    "time"

    "github.com/go-playground/validator/v10"
)

// RequestValidator handles request-level validation and constraints
type RequestValidator struct {
    validator *validator.Validate
}

// NewRequestValidator creates a new request validator
func NewRequestValidator() *RequestValidator {
    v := validator.New()
    
    // Register custom validators
    v.RegisterValidation("username", validateUsername)
    v.RegisterValidation("phone", validatePhone)
    v.RegisterValidation("future_date", validateFutureDate)
    
    return &RequestValidator{
        validator: v,
    }
}

// CreateUserRequest represents a user creation request
type CreateUserRequest struct {
    Username  string    `json:"username" validate:"required,username,min=3,max=20"`
    Email     string    `json:"email" validate:"required,email"`
    Phone     string    `json:"phone" validate:"omitempty,phone"`
    BirthDate string    `json:"birth_date" validate:"omitempty,datetime=2006-01-02"`
    Role      string    `json:"role" validate:"required,oneof=user admin manager"`
    Tags      []string  `json:"tags" validate:"max=10,dive,max=20"`
}

// Validate validates the request
func (r *CreateUserRequest) Validate(ctx context.Context) error {
    // Structural validation
    if err := validator.New().Struct(r); err != nil {
        return fmt.Errorf("validation failed: %w", err)
    }
    
    // Business rule validation
    if err := r.validateBusinessRules(ctx); err != nil {
        return fmt.Errorf("business rules validation failed: %w", err)
    }
    
    return nil
}

// validateBusinessRules validates business-specific rules
func (r *CreateUserRequest) validateBusinessRules(ctx context.Context) error {
    // Age validation
    if r.BirthDate != "" {
        birthDate, err := time.Parse("2006-01-02", r.BirthDate)
        if err != nil {
            return fmt.Errorf("invalid birth date format")
        }
        
        age := time.Since(birthDate).Hours() / 24 / 365.25
        if age < 13 {
            return fmt.Errorf("user must be at least 13 years old")
        }
        if age > 120 {
            return fmt.Errorf("invalid birth date: age cannot exceed 120 years")
        }
    }
    
    // Role-specific validation
    if r.Role == "admin" && len(r.Tags) == 0 {
        return fmt.Errorf("admin users must have at least one tag")
    }
    
    return nil
}

// Sanitize cleans and normalizes the request data
func (r *CreateUserRequest) Sanitize() {
    r.Username = strings.ToLower(strings.TrimSpace(r.Username))
    r.Email = strings.ToLower(strings.TrimSpace(r.Email))
    r.Phone = strings.ReplaceAll(r.Phone, " ", "")
    
    // Normalize tags
    uniqueTags := make(map[string]bool)
    var normalizedTags []string
    for _, tag := range r.Tags {
        normalized := strings.ToLower(strings.TrimSpace(tag))
        if normalized != "" && !uniqueTags[normalized] {
            uniqueTags[normalized] = true
            normalizedTags = append(normalizedTags, normalized)
        }
    }
    r.Tags = normalizedTags
}

// Transform converts request to domain model
func (r *CreateUserRequest) Transform() (*User, error) {
    user := &User{
        Username: r.Username,
        Email:    r.Email,
        Phone:    r.Phone,
        Role:     UserRole(r.Role),
        Tags:     r.Tags,
        Status:   UserStatusActive,
        CreatedAt: time.Now(),
    }
    
    if r.BirthDate != "" {
        birthDate, err := time.Parse("2006-01-02", r.BirthDate)
        if err != nil {
            return nil, fmt.Errorf("invalid birth date: %w", err)
        }
        user.BirthDate = &birthDate
    }
    
    return user, nil
}

// Custom validators
func validateUsername(fl validator.FieldLevel) bool {
    username := fl.Field().String()
    
    // Username should contain only alphanumeric characters and underscores
    for _, char := range username {
        if !((char >= 'a' && char <= 'z') || 
             (char >= 'A' && char <= 'Z') || 
             (char >= '0' && char <= '9') || 
             char == '_') {
            return false
        }
    }
    
    // Should not start with underscore or number
    return len(username) > 0 && 
           ((username[0] >= 'a' && username[0] <= 'z') || 
            (username[0] >= 'A' && username[0] <= 'Z'))
}

func validatePhone(fl validator.FieldLevel) bool {
    phone := fl.Field().String()
    // Simple phone validation (can be enhanced)
    if len(phone) < 10 || len(phone) > 15 {
        return false
    }
    
    for _, char := range phone {
        if char < '0' || char > '9' {
            return false
        }
    }
    
    return true
}

func validateFutureDate(fl validator.FieldLevel) bool {
    date, err := time.Parse("2006-01-02", fl.Field().String())
    if err != nil {
        return false
    }
    return date.After(time.Now())
}
```

### 2. Model Level Logic

Handles individual model validation, constraints, and business rules:

```go
package model

import (
    "context"
    "fmt"
    "regexp"
    "time"
)

// UserRole represents user role types
type UserRole string

const (
    UserRoleUser    UserRole = "user"
    UserRoleAdmin   UserRole = "admin"
    UserRoleManager UserRole = "manager"
)

// UserStatus represents user status
type UserStatus string

const (
    UserStatusActive    UserStatus = "active"
    UserStatusInactive  UserStatus = "inactive"
    UserStatusSuspended UserStatus = "suspended"
)

// User represents a user in the system
type User struct {
    ID          string     `json:"id"`
    Username    string     `json:"username"`
    Email       string     `json:"email"`
    Phone       string     `json:"phone"`
    BirthDate   *time.Time `json:"birth_date"`
    Role        UserRole   `json:"role"`
    Status      UserStatus `json:"status"`
    Tags        []string   `json:"tags"`
    CreatedAt   time.Time  `json:"created_at"`
    UpdatedAt   time.Time  `json:"updated_at"`
    LastLoginAt *time.Time `json:"last_login_at"`
    
    // Derived fields
    age *int `json:"age,omitempty"`
}

// UserValidator handles model-level validation
type UserValidator struct {
    emailRegex *regexp.Regexp
}

// NewUserValidator creates a new user validator
func NewUserValidator() *UserValidator {
    return &UserValidator{
        emailRegex: regexp.MustCompile(`^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`),
    }
}

// Validate validates the user model
func (u *User) Validate(ctx context.Context) error {
    var errors []string
    
    // Required field validation
    if u.Username == "" {
        errors = append(errors, "username is required")
    }
    if u.Email == "" {
        errors = append(errors, "email is required")
    }
    
    // Format validation
    if u.Email != "" && !u.isValidEmail() {
        errors = append(errors, "invalid email format")
    }
    
    // Business rule validation
    if err := u.validateBusinessRules(ctx); err != nil {
        errors = append(errors, err.Error())
    }
    
    if len(errors) > 0 {
        return fmt.Errorf("validation errors: %v", errors)
    }
    
    return nil
}

// validateBusinessRules validates business-specific rules
func (u *User) validateBusinessRules(ctx context.Context) error {
    // Role-specific validation
    if u.Role == UserRoleAdmin && u.Status == UserStatusInactive {
        return fmt.Errorf("admin users cannot be inactive")
    }
    
    // Age-based validation
    if u.BirthDate != nil {
        age := u.GetAge()
        if age < 13 {
            return fmt.Errorf("user must be at least 13 years old")
        }
    }
    
    // Username constraints
    if len(u.Username) < 3 || len(u.Username) > 20 {
        return fmt.Errorf("username must be between 3 and 20 characters")
    }
    
    // Tag constraints
    if len(u.Tags) > 10 {
        return fmt.Errorf("user cannot have more than 10 tags")
    }
    
    return nil
}

// GetAge calculates and returns the user's age
func (u *User) GetAge() int {
    if u.age != nil {
        return *u.age
    }
    
    if u.BirthDate == nil {
        return 0
    }
    
    age := int(time.Since(*u.BirthDate).Hours() / 24 / 365.25)
    u.age = &age
    return age
}

// CanPerformAction checks if user can perform a specific action
func (u *User) CanPerformAction(action string) bool {
    if u.Status != UserStatusActive {
        return false
    }
    
    switch action {
    case "create_user":
        return u.Role == UserRoleAdmin || u.Role == UserRoleManager
    case "delete_user":
        return u.Role == UserRoleAdmin
    case "view_reports":
        return u.Role == UserRoleAdmin || u.Role == UserRoleManager
    default:
        return true // Default allow for basic actions
    }
}

// UpdateStatus updates user status with business rules
func (u *User) UpdateStatus(newStatus UserStatus) error {
    // Business rules for status transitions
    if u.Status == UserStatusSuspended && newStatus == UserStatusActive {
        // Suspended users can only be activated by admins
        return fmt.Errorf("suspended users require admin approval to reactivate")
    }
    
    if u.Role == UserRoleAdmin && newStatus == UserStatusInactive {
        return fmt.Errorf("admin users cannot be deactivated")
    }
    
    u.Status = newStatus
    u.UpdatedAt = time.Now()
    return nil
}

// isValidEmail validates email format
func (u *User) isValidEmail() bool {
    validator := NewUserValidator()
    return validator.emailRegex.MatchString(u.Email)
}

// ApplyPolicy applies business policies to the user
func (u *User) ApplyPolicy(policy UserPolicy) error {
    switch policy.Type {
    case PolicyTypeRoleChange:
        return u.applyRoleChangePolicy(policy)
    case PolicyTypePasswordExpiry:
        return u.applyPasswordExpiryPolicy(policy)
    case PolicyTypeTagRestriction:
        return u.applyTagRestrictionPolicy(policy)
    default:
        return fmt.Errorf("unknown policy type: %s", policy.Type)
    }
}

// UserPolicy represents a business policy
type UserPolicy struct {
    Type       PolicyType             `json:"type"`
    Parameters map[string]interface{} `json:"parameters"`
}

type PolicyType string

const (
    PolicyTypeRoleChange      PolicyType = "role_change"
    PolicyTypePasswordExpiry  PolicyType = "password_expiry"
    PolicyTypeTagRestriction  PolicyType = "tag_restriction"
)

func (u *User) applyRoleChangePolicy(policy UserPolicy) error {
    newRole, ok := policy.Parameters["role"].(string)
    if !ok {
        return fmt.Errorf("role parameter is required")
    }
    
    // Business rule: Only admins can promote to admin
    if UserRole(newRole) == UserRoleAdmin && u.Role != UserRoleAdmin {
        return fmt.Errorf("only admins can promote users to admin role")
    }
    
    u.Role = UserRole(newRole)
    u.UpdatedAt = time.Now()
    return nil
}

func (u *User) applyPasswordExpiryPolicy(policy UserPolicy) error {
    // Implementation for password expiry policy
    return nil
}

func (u *User) applyTagRestrictionPolicy(policy UserPolicy) error {
    allowedTags, ok := policy.Parameters["allowed_tags"].([]string)
    if !ok {
        return fmt.Errorf("allowed_tags parameter is required")
    }
    
    // Filter user tags to only include allowed ones
    var filteredTags []string
    for _, tag := range u.Tags {
        for _, allowed := range allowedTags {
            if tag == allowed {
                filteredTags = append(filteredTags, tag)
                break
            }
        }
    }
    
    u.Tags = filteredTags
    u.UpdatedAt = time.Now()
    return nil
}
```

### 3. Aggregate Level Logic

Handles complex business logic involving multiple entities:

```go
package aggregate

import (
    "context"
    "fmt"
    "time"
)

// UserAggregate handles complex user-related business logic
type UserAggregate struct {
    user         *User
    permissions  []Permission
    subscriptions []Subscription
    auditLog     []AuditEntry
}

// Permission represents a user permission
type Permission struct {
    ID       string    `json:"id"`
    UserID   string    `json:"user_id"`
    Resource string    `json:"resource"`
    Action   string    `json:"action"`
    Granted  bool      `json:"granted"`
    ExpiresAt *time.Time `json:"expires_at"`
}

// Subscription represents a user subscription
type Subscription struct {
    ID        string    `json:"id"`
    UserID    string    `json:"user_id"`
    PlanID    string    `json:"plan_id"`
    Status    string    `json:"status"`
    StartsAt  time.Time `json:"starts_at"`
    ExpiresAt time.Time `json:"expires_at"`
}

// AuditEntry represents an audit log entry
type AuditEntry struct {
    ID        string    `json:"id"`
    UserID    string    `json:"user_id"`
    Action    string    `json:"action"`
    Details   string    `json:"details"`
    Timestamp time.Time `json:"timestamp"`
}

// NewUserAggregate creates a new user aggregate
func NewUserAggregate(user *User) *UserAggregate {
    return &UserAggregate{
        user:         user,
        permissions:  []Permission{},
        subscriptions: []Subscription{},
        auditLog:     []AuditEntry{},
    }
}

// UpgradeUserRole upgrades user role with comprehensive business logic
func (ua *UserAggregate) UpgradeUserRole(ctx context.Context, newRole UserRole, upgradedBy string) error {
    // Business rules for role upgrade
    if ua.user.Role == newRole {
        return fmt.Errorf("user already has role: %s", newRole)
    }
    
    // Check if user can be upgraded
    if err := ua.validateRoleUpgrade(newRole); err != nil {
        return fmt.Errorf("role upgrade validation failed: %w", err)
    }
    
    // Check subscription requirements
    if err := ua.validateSubscriptionRequirements(newRole); err != nil {
        return fmt.Errorf("subscription requirements not met: %w", err)
    }
    
    // Perform the upgrade
    oldRole := ua.user.Role
    ua.user.Role = newRole
    ua.user.UpdatedAt = time.Now()
    
    // Grant new permissions
    if err := ua.grantRolePermissions(newRole); err != nil {
        // Rollback
        ua.user.Role = oldRole
        return fmt.Errorf("failed to grant permissions: %w", err)
    }
    
    // Log the change
    ua.logAuditEntry(fmt.Sprintf("Role upgraded from %s to %s by %s", oldRole, newRole, upgradedBy))
    
    return nil
}

// validateRoleUpgrade validates role upgrade business rules
func (ua *UserAggregate) validateRoleUpgrade(newRole UserRole) error {
    // Age requirements
    if newRole == UserRoleAdmin && ua.user.GetAge() < 18 {
        return fmt.Errorf("admin role requires user to be at least 18 years old")
    }
    
    // Account age requirements
    accountAge := time.Since(ua.user.CreatedAt)
    if newRole == UserRoleManager && accountAge < 30*24*time.Hour {
        return fmt.Errorf("manager role requires account to be at least 30 days old")
    }
    
    // Activity requirements
    if ua.user.LastLoginAt == nil {
        return fmt.Errorf("user must have logged in at least once")
    }
    
    lastLogin := time.Since(*ua.user.LastLoginAt)
    if lastLogin > 7*24*time.Hour {
        return fmt.Errorf("user must have logged in within the last 7 days")
    }
    
    return nil
}

// validateSubscriptionRequirements validates subscription requirements for role
func (ua *UserAggregate) validateSubscriptionRequirements(newRole UserRole) error {
    if newRole == UserRoleAdmin || newRole == UserRoleManager {
        // Check for active premium subscription
        hasActiveSubscription := false
        for _, subscription := range ua.subscriptions {
            if subscription.Status == "active" && subscription.ExpiresAt.After(time.Now()) {
                hasActiveSubscription = true
                break
            }
        }
        
        if !hasActiveSubscription {
            return fmt.Errorf("premium subscription required for role: %s", newRole)
        }
    }
    
    return nil
}

// grantRolePermissions grants permissions based on role
func (ua *UserAggregate) grantRolePermissions(role UserRole) error {
    var newPermissions []Permission
    
    switch role {
    case UserRoleManager:
        newPermissions = []Permission{
            {ID: generateID(), UserID: ua.user.ID, Resource: "users", Action: "read", Granted: true},
            {ID: generateID(), UserID: ua.user.ID, Resource: "reports", Action: "read", Granted: true},
        }
    case UserRoleAdmin:
        newPermissions = []Permission{
            {ID: generateID(), UserID: ua.user.ID, Resource: "users", Action: "read", Granted: true},
            {ID: generateID(), UserID: ua.user.ID, Resource: "users", Action: "write", Granted: true},
            {ID: generateID(), UserID: ua.user.ID, Resource: "users", Action: "delete", Granted: true},
            {ID: generateID(), UserID: ua.user.ID, Resource: "reports", Action: "read", Granted: true},
            {ID: generateID(), UserID: ua.user.ID, Resource: "system", Action: "admin", Granted: true},
        }
    }
    
    ua.permissions = append(ua.permissions, newPermissions...)
    return nil
}

// ProcessUserLifecycle handles user lifecycle events
func (ua *UserAggregate) ProcessUserLifecycle(ctx context.Context, event UserLifecycleEvent) error {
    switch event.Type {
    case EventTypeUserCreated:
        return ua.handleUserCreated(ctx, event)
    case EventTypeUserActivated:
        return ua.handleUserActivated(ctx, event)
    case EventTypeUserDeactivated:
        return ua.handleUserDeactivated(ctx, event)
    case EventTypeUserDeleted:
        return ua.handleUserDeleted(ctx, event)
    default:
        return fmt.Errorf("unknown lifecycle event: %s", event.Type)
    }
}

// UserLifecycleEvent represents a user lifecycle event
type UserLifecycleEvent struct {
    Type      EventType              `json:"type"`
    UserID    string                 `json:"user_id"`
    Timestamp time.Time              `json:"timestamp"`
    Data      map[string]interface{} `json:"data"`
}

type EventType string

const (
    EventTypeUserCreated     EventType = "user_created"
    EventTypeUserActivated   EventType = "user_activated"
    EventTypeUserDeactivated EventType = "user_deactivated"
    EventTypeUserDeleted     EventType = "user_deleted"
)

func (ua *UserAggregate) handleUserCreated(ctx context.Context, event UserLifecycleEvent) error {
    // Grant default permissions
    defaultPermissions := []Permission{
        {ID: generateID(), UserID: ua.user.ID, Resource: "profile", Action: "read", Granted: true},
        {ID: generateID(), UserID: ua.user.ID, Resource: "profile", Action: "write", Granted: true},
    }
    
    ua.permissions = append(ua.permissions, defaultPermissions...)
    ua.logAuditEntry("User created with default permissions")
    
    return nil
}

func (ua *UserAggregate) handleUserActivated(ctx context.Context, event UserLifecycleEvent) error {
    ua.user.Status = UserStatusActive
    ua.user.UpdatedAt = time.Now()
    ua.logAuditEntry("User activated")
    
    return nil
}

func (ua *UserAggregate) handleUserDeactivated(ctx context.Context, event UserLifecycleEvent) error {
    // Revoke all permissions except basic ones
    var basicPermissions []Permission
    for _, perm := range ua.permissions {
        if perm.Resource == "profile" && perm.Action == "read" {
            basicPermissions = append(basicPermissions, perm)
        }
    }
    
    ua.permissions = basicPermissions
    ua.user.Status = UserStatusInactive
    ua.user.UpdatedAt = time.Now()
    ua.logAuditEntry("User deactivated and permissions revoked")
    
    return nil
}

func (ua *UserAggregate) handleUserDeleted(ctx context.Context, event UserLifecycleEvent) error {
    // Clear all permissions
    ua.permissions = []Permission{}
    
    // Cancel all subscriptions
    for i := range ua.subscriptions {
        ua.subscriptions[i].Status = "cancelled"
    }
    
    ua.logAuditEntry("User deleted, all permissions revoked and subscriptions cancelled")
    
    return nil
}

func (ua *UserAggregate) logAuditEntry(details string) {
    entry := AuditEntry{
        ID:        generateID(),
        UserID:    ua.user.ID,
        Action:    "user_management",
        Details:   details,
        Timestamp: time.Now(),
    }
    
    ua.auditLog = append(ua.auditLog, entry)
}

func generateID() string {
    // Simple ID generation for example
    return fmt.Sprintf("id_%d", time.Now().UnixNano())
}
```

### 4. Database Level Logic

Handles database constraints, validation, and data integrity:

```go
package database

import (
    "context"
    "database/sql"
    "fmt"
    "strings"
    "time"
)

// DatabaseConstraints handles database-level validation and constraints
type DatabaseConstraints struct {
    db *sql.DB
}

// NewDatabaseConstraints creates a new database constraints handler
func NewDatabaseConstraints(db *sql.DB) *DatabaseConstraints {
    return &DatabaseConstraints{db: db}
}

// ValidateUserConstraints validates database-level user constraints
func (dc *DatabaseConstraints) ValidateUserConstraints(ctx context.Context, user *User) error {
    // Check uniqueness constraints
    if err := dc.validateUniqueConstraints(ctx, user); err != nil {
        return fmt.Errorf("uniqueness validation failed: %w", err)
    }
    
    // Check foreign key constraints
    if err := dc.validateForeignKeyConstraints(ctx, user); err != nil {
        return fmt.Errorf("foreign key validation failed: %w", err)
    }
    
    // Check custom database constraints
    if err := dc.validateCustomConstraints(ctx, user); err != nil {
        return fmt.Errorf("custom constraint validation failed: %w", err)
    }
    
    return nil
}

// validateUniqueConstraints validates unique constraints
func (dc *DatabaseConstraints) validateUniqueConstraints(ctx context.Context, user *User) error {
    // Check username uniqueness
    if err := dc.checkUniqueness(ctx, "users", "username", user.Username, user.ID); err != nil {
        return fmt.Errorf("username already exists: %w", err)
    }
    
    // Check email uniqueness
    if err := dc.checkUniqueness(ctx, "users", "email", user.Email, user.ID); err != nil {
        return fmt.Errorf("email already exists: %w", err)
    }
    
    // Check phone uniqueness (if provided)
    if user.Phone != "" {
        if err := dc.checkUniqueness(ctx, "users", "phone", user.Phone, user.ID); err != nil {
            return fmt.Errorf("phone number already exists: %w", err)
        }
    }
    
    return nil
}

// checkUniqueness checks if a value is unique in a table
func (dc *DatabaseConstraints) checkUniqueness(ctx context.Context, table, column, value, excludeID string) error {
    query := fmt.Sprintf("SELECT COUNT(*) FROM %s WHERE %s = $1", table, column)
    args := []interface{}{value}
    
    if excludeID != "" {
        query += " AND id != $2"
        args = append(args, excludeID)
    }
    
    var count int
    err := dc.db.QueryRowContext(ctx, query, args...).Scan(&count)
    if err != nil {
        return fmt.Errorf("failed to check uniqueness: %w", err)
    }
    
    if count > 0 {
        return fmt.Errorf("value already exists")
    }
    
    return nil
}

// validateForeignKeyConstraints validates foreign key constraints
func (dc *DatabaseConstraints) validateForeignKeyConstraints(ctx context.Context, user *User) error {
    // Validate that referenced entities exist
    // This is typically handled by database FK constraints, but we can add custom logic
    
    return nil
}

// validateCustomConstraints validates custom business constraints at database level
func (dc *DatabaseConstraints) validateCustomConstraints(ctx context.Context, user *User) error {
    // Check maximum admin users constraint
    if user.Role == UserRoleAdmin {
        if err := dc.checkMaxAdmins(ctx, user.ID); err != nil {
            return err
        }
    }
    
    // Check user creation rate limit
    if err := dc.checkUserCreationRateLimit(ctx, user.Email); err != nil {
        return err
    }
    
    return nil
}

// checkMaxAdmins ensures we don't exceed maximum admin users
func (dc *DatabaseConstraints) checkMaxAdmins(ctx context.Context, excludeID string) error {
    query := "SELECT COUNT(*) FROM users WHERE role = 'admin'"
    args := []interface{}{}
    
    if excludeID != "" {
        query += " AND id != $1"
        args = append(args, excludeID)
    }
    
    var count int
    err := dc.db.QueryRowContext(ctx, query, args...).Scan(&count)
    if err != nil {
        return fmt.Errorf("failed to check admin count: %w", err)
    }
    
    const maxAdmins = 10
    if count >= maxAdmins {
        return fmt.Errorf("maximum number of admin users (%d) reached", maxAdmins)
    }
    
    return nil
}

// checkUserCreationRateLimit checks if user creation rate limit is exceeded
func (dc *DatabaseConstraints) checkUserCreationRateLimit(ctx context.Context, email string) error {
    // Check if too many users were created from the same domain recently
    domain := strings.Split(email, "@")[1]
    
    query := `
        SELECT COUNT(*) 
        FROM users 
        WHERE email LIKE $1 
        AND created_at > $2
    `
    
    cutoff := time.Now().Add(-24 * time.Hour)
    var count int
    err := dc.db.QueryRowContext(ctx, query, "%@"+domain, cutoff).Scan(&count)
    if err != nil {
        return fmt.Errorf("failed to check creation rate limit: %w", err)
    }
    
    const maxUsersPerDomainPerDay = 100
    if count >= maxUsersPerDomainPerDay {
        return fmt.Errorf("too many users created from domain %s in the last 24 hours", domain)
    }
    
    return nil
}

// DatabaseOperations handles database operations with business logic
type DatabaseOperations struct {
    db          *sql.DB
    constraints *DatabaseConstraints
}

// NewDatabaseOperations creates a new database operations handler
func NewDatabaseOperations(db *sql.DB) *DatabaseOperations {
    return &DatabaseOperations{
        db:          db,
        constraints: NewDatabaseConstraints(db),
    }
}

// CreateUser creates a user with all validations
func (do *DatabaseOperations) CreateUser(ctx context.Context, user *User) error {
    // Start transaction
    tx, err := do.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("failed to start transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Validate constraints
    if err := do.constraints.ValidateUserConstraints(ctx, user); err != nil {
        return fmt.Errorf("constraint validation failed: %w", err)
    }
    
    // Insert user
    query := `
        INSERT INTO users (id, username, email, phone, birth_date, role, status, tags, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
    `
    
    _, err = tx.ExecContext(ctx, query,
        user.ID, user.Username, user.Email, user.Phone, user.BirthDate,
        user.Role, user.Status, strings.Join(user.Tags, ","),
        user.CreatedAt, user.UpdatedAt)
    if err != nil {
        return fmt.Errorf("failed to insert user: %w", err)
    }
    
    // Create audit entry
    auditQuery := `
        INSERT INTO audit_log (id, user_id, action, details, timestamp)
        VALUES ($1, $2, $3, $4, $5)
    `
    
    _, err = tx.ExecContext(ctx, auditQuery,
        generateID(), user.ID, "user_created", "User created", time.Now())
    if err != nil {
        return fmt.Errorf("failed to create audit entry: %w", err)
    }
    
    // Commit transaction
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("failed to commit transaction: %w", err)
    }
    
    return nil
}

// UpdateUser updates a user with all validations
func (do *DatabaseOperations) UpdateUser(ctx context.Context, user *User) error {
    // Start transaction
    tx, err := do.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("failed to start transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Validate constraints
    if err := do.constraints.ValidateUserConstraints(ctx, user); err != nil {
        return fmt.Errorf("constraint validation failed: %w", err)
    }
    
    // Update user
    query := `
        UPDATE users 
        SET username = $2, email = $3, phone = $4, birth_date = $5, 
            role = $6, status = $7, tags = $8, updated_at = $9
        WHERE id = $1
    `
    
    user.UpdatedAt = time.Now()
    _, err = tx.ExecContext(ctx, query,
        user.ID, user.Username, user.Email, user.Phone, user.BirthDate,
        user.Role, user.Status, strings.Join(user.Tags, ","),
        user.UpdatedAt)
    if err != nil {
        return fmt.Errorf("failed to update user: %w", err)
    }
    
    // Create audit entry
    auditQuery := `
        INSERT INTO audit_log (id, user_id, action, details, timestamp)
        VALUES ($1, $2, $3, $4, $5)
    `
    
    _, err = tx.ExecContext(ctx, auditQuery,
        generateID(), user.ID, "user_updated", "User updated", time.Now())
    if err != nil {
        return fmt.Errorf("failed to create audit entry: %w", err)
    }
    
    // Commit transaction
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("failed to commit transaction: %w", err)
    }
    
    return nil
}
```

## Integration Layer

```go
package service

import (
    "context"
    "fmt"
)

// UserService integrates all business logic layers
type UserService struct {
    requestValidator *RequestValidator
    userValidator    *UserValidator
    dbOperations     *DatabaseOperations
}

// NewUserService creates a new user service
func NewUserService(
    requestValidator *RequestValidator,
    userValidator *UserValidator,
    dbOperations *DatabaseOperations,
) *UserService {
    return &UserService{
        requestValidator: requestValidator,
        userValidator:    userValidator,
        dbOperations:     dbOperations,
    }
}

// CreateUser creates a user with full business logic validation
func (us *UserService) CreateUser(ctx context.Context, req *CreateUserRequest) (*User, error) {
    // Request level validation
    if err := req.Validate(ctx); err != nil {
        return nil, fmt.Errorf("request validation failed: %w", err)
    }
    
    // Sanitize request
    req.Sanitize()
    
    // Transform to domain model
    user, err := req.Transform()
    if err != nil {
        return nil, fmt.Errorf("transformation failed: %w", err)
    }
    
    // Model level validation
    if err := user.Validate(ctx); err != nil {
        return nil, fmt.Errorf("model validation failed: %w", err)
    }
    
    // Database level validation and creation
    if err := us.dbOperations.CreateUser(ctx, user); err != nil {
        return nil, fmt.Errorf("database operation failed: %w", err)
    }
    
    return user, nil
}

// UpdateUser updates a user with full business logic validation
func (us *UserService) UpdateUser(ctx context.Context, userID string, req *UpdateUserRequest) (*User, error) {
    // Similar validation chain as CreateUser
    // Implementation details omitted for brevity
    return nil, nil
}
```

## Benefits

1. **Clear Separation of Concerns**: Each layer handles specific types of business logic
2. **Maintainability**: Easy to locate and modify specific business rules
3. **Testability**: Each layer can be tested independently
4. **Reusability**: Business logic can be reused across different interfaces
5. **Consistency**: Uniform validation and business rule enforcement

## Consequences

### Positive

- **Organized Code**: Clear structure makes code easier to understand and maintain
- **Comprehensive Validation**: Multiple layers ensure data integrity
- **Flexible Architecture**: Easy to modify business rules without affecting other layers
- **Audit Trail**: Complete tracking of business logic decisions
- **Performance**: Efficient validation with early exit on failures

### Negative

- **Complexity**: Multiple layers can make simple operations complex
- **Performance Overhead**: Multiple validation steps can add latency
- **Learning Curve**: Team needs to understand the layered architecture
- **Debugging**: Issues may span multiple layers
- **Coordination**: Changes may require updates across multiple layers

## Implementation Checklist

- [ ] Define clear boundaries between business logic layers
- [ ] Implement request-level validation and sanitization
- [ ] Create comprehensive model validation
- [ ] Design aggregate-level business logic for complex operations
- [ ] Implement database-level constraints and validation
- [ ] Create integration service layer
- [ ] Add comprehensive error handling and logging
- [ ] Implement audit trail for business logic decisions
- [ ] Add unit tests for each layer
- [ ] Document business rules and their locations
- [ ] Set up performance monitoring for business logic layers
- [ ] Create business rule documentation

## Best Practices

1. **Single Responsibility**: Each layer should have a single, well-defined responsibility
2. **Fail Fast**: Validate at the earliest appropriate layer
3. **Comprehensive Testing**: Test business logic thoroughly at each layer
4. **Clear Error Messages**: Provide actionable error messages for validation failures
5. **Performance Monitoring**: Monitor the performance impact of business logic
6. **Documentation**: Document business rules and their rationale
7. **Consistency**: Apply business rules consistently across all interfaces
8. **Audit Logging**: Log all business logic decisions for compliance and debugging

## References

- [Domain-Driven Design](https://martinfowler.com/tags/domain%20driven%20design.html)
- [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Hexagonal Architecture](https://alistair.cockburn.us/hexagonal-architecture/)
- [Enterprise Integration Patterns](https://www.enterpriseintegrationpatterns.com/)
