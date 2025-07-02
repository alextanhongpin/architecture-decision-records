# ADR 010: Domain-Driven Design Implementation in Go

## Status

**Accepted**

## Context

Modern Go applications often struggle with organizing business logic, leading to anemic domain models, business logic scattered across service layers, and tight coupling between business rules and infrastructure concerns. Domain-Driven Design (DDD) provides a structured approach to modeling complex business domains while maintaining clean architecture principles.

In Go, we need clear patterns for:
- Organizing domain entities and value objects
- Implementing business rules and invariants
- Separating domain logic from infrastructure
- Managing domain events and aggregates
- Testing business logic in isolation

## Decision

We will implement Domain-Driven Design patterns in Go with a focus on pragmatic application rather than theoretical purity, emphasizing business logic encapsulation and clear domain boundaries.

### 1. Domain Layer Structure

```
internal/
  domain/
    user/           # User aggregate
      entity.go     # User entity
      repository.go # Repository interface
      service.go    # Domain service
      events.go     # Domain events
    order/          # Order aggregate  
      entity.go
      valueobjects.go
      repository.go
      service.go
    shared/         # Shared domain concepts
      valueobjects/ # Common value objects
      events/       # Domain event interfaces
      errors/       # Domain errors
```

### 2. Domain Entities

Entities represent objects with identity that persist over time:

```go
package user

import (
    "errors"
    "time"
    "github.com/google/uuid"
)

// User represents a user in the system
type User struct {
    id          UserID
    email       Email
    profile     Profile
    status      Status
    permissions []Permission
    createdAt   time.Time
    updatedAt   time.Time
    version     int // For optimistic locking
    events      []DomainEvent // Uncommitted events
}

// UserID is a strongly-typed identifier
type UserID struct {
    value string
}

func NewUserID() UserID {
    return UserID{value: uuid.New().String()}
}

func UserIDFromString(s string) (UserID, error) {
    if s == "" {
        return UserID{}, errors.New("user ID cannot be empty")
    }
    if _, err := uuid.Parse(s); err != nil {
        return UserID{}, errors.New("invalid user ID format")
    }
    return UserID{value: s}, nil
}

func (id UserID) String() string {
    return id.value
}

func (id UserID) Equals(other UserID) bool {
    return id.value == other.value
}

// NewUser creates a new user with business rule validation
func NewUser(email Email, profile Profile) (*User, error) {
    if err := validateUserCreation(email, profile); err != nil {
        return nil, err
    }
    
    user := &User{
        id:        NewUserID(),
        email:     email,
        profile:   profile,
        status:    StatusActive,
        createdAt: time.Now(),
        updatedAt: time.Now(),
        version:   1,
        events:    make([]DomainEvent, 0),
    }
    
    // Raise domain event
    user.raiseEvent(NewUserCreatedEvent(user.id, user.email))
    
    return user, nil
}

// Business methods
func (u *User) ChangeEmail(newEmail Email) error {
    if u.status == StatusDeactivated {
        return errors.New("cannot change email for deactivated user")
    }
    
    if u.email.Equals(newEmail) {
        return nil // No change needed
    }
    
    oldEmail := u.email
    u.email = newEmail
    u.updatedAt = time.Now()
    u.version++
    
    u.raiseEvent(NewUserEmailChangedEvent(u.id, oldEmail, newEmail))
    
    return nil
}

func (u *User) GrantPermission(permission Permission) error {
    if u.status != StatusActive {
        return errors.New("cannot grant permission to inactive user")
    }
    
    if u.hasPermission(permission) {
        return nil // Already has permission
    }
    
    u.permissions = append(u.permissions, permission)
    u.updatedAt = time.Now()
    u.version++
    
    u.raiseEvent(NewPermissionGrantedEvent(u.id, permission))
    
    return nil
}

func (u *User) Deactivate() error {
    if u.status == StatusDeactivated {
        return errors.New("user is already deactivated")
    }
    
    u.status = StatusDeactivated
    u.updatedAt = time.Now()
    u.version++
    
    u.raiseEvent(NewUserDeactivatedEvent(u.id))
    
    return nil
}

// Query methods
func (u *User) ID() UserID                 { return u.id }
func (u *User) Email() Email               { return u.email }
func (u *User) Profile() Profile           { return u.profile }
func (u *User) Status() Status             { return u.status }
func (u *User) Permissions() []Permission  { return append([]Permission(nil), u.permissions...) }
func (u *User) CreatedAt() time.Time       { return u.createdAt }
func (u *User) UpdatedAt() time.Time       { return u.updatedAt }
func (u *User) Version() int               { return u.version }

func (u *User) hasPermission(permission Permission) bool {
    for _, p := range u.permissions {
        if p == permission {
            return true
        }
    }
    return false
}

func (u *User) raiseEvent(event DomainEvent) {
    u.events = append(u.events, event)
}

func (u *User) UncommittedEvents() []DomainEvent {
    return append([]DomainEvent(nil), u.events...)
}

func (u *User) MarkEventsAsCommitted() {
    u.events = u.events[:0]
}

func validateUserCreation(email Email, profile Profile) error {
    if !email.IsValid() {
        return errors.New("invalid email address")
    }
    if !profile.IsValid() {
        return errors.New("invalid user profile")
    }
    return nil
}
```

### 3. Value Objects

Value objects represent descriptive aspects without identity:

```go
package user

import (
    "errors"
    "regexp"
    "strings"
    "time"
)

// Email value object
type Email struct {
    value string
}

var emailRegex = regexp.MustCompile(`^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`)

func NewEmail(value string) (Email, error) {
    normalized := strings.ToLower(strings.TrimSpace(value))
    if !emailRegex.MatchString(normalized) {
        return Email{}, errors.New("invalid email format")
    }
    return Email{value: normalized}, nil
}

func (e Email) String() string {
    return e.value
}

func (e Email) IsValid() bool {
    return emailRegex.MatchString(e.value)
}

func (e Email) Equals(other Email) bool {
    return e.value == other.value
}

func (e Email) Domain() string {
    parts := strings.Split(e.value, "@")
    if len(parts) != 2 {
        return ""
    }
    return parts[1]
}

// Profile value object
type Profile struct {
    firstName string
    lastName  string
    birthDate *time.Time
    bio       string
}

func NewProfile(firstName, lastName string, birthDate *time.Time, bio string) (Profile, error) {
    if strings.TrimSpace(firstName) == "" {
        return Profile{}, errors.New("first name is required")
    }
    if strings.TrimSpace(lastName) == "" {
        return Profile{}, errors.New("last name is required")
    }
    if len(bio) > 500 {
        return Profile{}, errors.New("bio cannot exceed 500 characters")
    }
    if birthDate != nil && birthDate.After(time.Now()) {
        return Profile{}, errors.New("birth date cannot be in the future")
    }
    
    return Profile{
        firstName: strings.TrimSpace(firstName),
        lastName:  strings.TrimSpace(lastName),
        birthDate: birthDate,
        bio:       strings.TrimSpace(bio),
    }, nil
}

func (p Profile) FirstName() string    { return p.firstName }
func (p Profile) LastName() string     { return p.lastName }
func (p Profile) BirthDate() *time.Time { return p.birthDate }
func (p Profile) Bio() string          { return p.bio }

func (p Profile) FullName() string {
    return p.firstName + " " + p.lastName
}

func (p Profile) Age() *int {
    if p.birthDate == nil {
        return nil
    }
    age := int(time.Since(*p.birthDate).Hours() / 24 / 365.25)
    return &age
}

func (p Profile) IsValid() bool {
    return strings.TrimSpace(p.firstName) != "" && 
           strings.TrimSpace(p.lastName) != ""
}

func (p Profile) Equals(other Profile) bool {
    return p.firstName == other.firstName &&
           p.lastName == other.lastName &&
           ((p.birthDate == nil && other.birthDate == nil) || 
            (p.birthDate != nil && other.birthDate != nil && p.birthDate.Equal(*other.birthDate))) &&
           p.bio == other.bio
}

// Money value object for financial contexts
type Money struct {
    amount   int64  // Store as cents to avoid floating point issues
    currency string
}

func NewMoney(amount float64, currency string) (Money, error) {
    if currency == "" {
        return Money{}, errors.New("currency is required")
    }
    if len(currency) != 3 {
        return Money{}, errors.New("currency must be 3 characters")
    }
    
    return Money{
        amount:   int64(amount * 100), // Convert to cents
        currency: strings.ToUpper(currency),
    }, nil
}

func (m Money) Amount() float64 {
    return float64(m.amount) / 100
}

func (m Money) Currency() string {
    return m.currency
}

func (m Money) Add(other Money) (Money, error) {
    if m.currency != other.currency {
        return Money{}, errors.New("cannot add money with different currencies")
    }
    return Money{
        amount:   m.amount + other.amount,
        currency: m.currency,
    }, nil
}

func (m Money) Equals(other Money) bool {
    return m.amount == other.amount && m.currency == other.currency
}
```

### 4. Domain Services

Domain services contain business logic that doesn't naturally fit in entities:

```go
package user

import (
    "context"
    "errors"
)

// UserDomainService handles complex business operations
type UserDomainService struct {
    userRepo Repository
    emailSvc EmailService
}

func NewUserDomainService(userRepo Repository, emailSvc EmailService) *UserDomainService {
    return &UserDomainService{
        userRepo: userRepo,
        emailSvc: emailSvc,
    }
}

// CheckEmailUniqueness ensures email is unique across all users
func (s *UserDomainService) CheckEmailUniqueness(ctx context.Context, email Email) error {
    existingUser, err := s.userRepo.FindByEmail(ctx, email)
    if err != nil && !errors.Is(err, ErrUserNotFound) {
        return err
    }
    if existingUser != nil {
        return errors.New("email address is already in use")
    }
    return nil
}

// TransferPermissions moves permissions from one user to another
func (s *UserDomainService) TransferPermissions(ctx context.Context, fromUserID, toUserID UserID) error {
    fromUser, err := s.userRepo.FindByID(ctx, fromUserID)
    if err != nil {
        return err
    }
    
    toUser, err := s.userRepo.FindByID(ctx, toUserID)
    if err != nil {
        return err
    }
    
    if fromUser.Status() != StatusActive || toUser.Status() != StatusActive {
        return errors.New("both users must be active for permission transfer")
    }
    
    permissions := fromUser.Permissions()
    for _, permission := range permissions {
        if err := toUser.GrantPermission(permission); err != nil {
            return err
        }
    }
    
    if err := fromUser.Deactivate(); err != nil {
        return err
    }
    
    return nil
}

// BulkUserCreation handles creating multiple users with business rules
func (s *UserDomainService) BulkUserCreation(ctx context.Context, requests []CreateUserRequest) error {
    // Validate all emails are unique
    emails := make(map[string]bool)
    for _, req := range requests {
        emailStr := req.Email.String()
        if emails[emailStr] {
            return errors.New("duplicate emails in request")
        }
        emails[emailStr] = true
        
        if err := s.CheckEmailUniqueness(ctx, req.Email); err != nil {
            return err
        }
    }
    
    // Create users in transaction
    return s.userRepo.CreateBatch(ctx, requests)
}
```

### 5. Repository Interface

```go
package user

import (
    "context"
    "errors"
)

var (
    ErrUserNotFound = errors.New("user not found")
    ErrEmailExists  = errors.New("email already exists")
)

// Repository defines the contract for user persistence
type Repository interface {
    FindByID(ctx context.Context, id UserID) (*User, error)
    FindByEmail(ctx context.Context, email Email) (*User, error)
    FindByStatus(ctx context.Context, status Status) ([]*User, error)
    Save(ctx context.Context, user *User) error
    CreateBatch(ctx context.Context, requests []CreateUserRequest) error
    Delete(ctx context.Context, id UserID) error
    Count(ctx context.Context) (int, error)
}

type CreateUserRequest struct {
    Email   Email
    Profile Profile
}

// Specification pattern for complex queries
type Specification interface {
    IsSatisfiedBy(user *User) bool
    ToSQL() (string, []interface{})
}

type ActiveUserSpec struct{}

func (s ActiveUserSpec) IsSatisfiedBy(user *User) bool {
    return user.Status() == StatusActive
}

func (s ActiveUserSpec) ToSQL() (string, []interface{}) {
    return "status = ?", []interface{}{StatusActive}
}

type UserWithPermissionSpec struct {
    permission Permission
}

func (s UserWithPermissionSpec) IsSatisfiedBy(user *User) bool {
    for _, p := range user.Permissions() {
        if p == s.permission {
            return true
        }
    }
    return false
}

func (s UserWithPermissionSpec) ToSQL() (string, []interface{}) {
    return "permissions @> ?", []interface{}{s.permission}
}
```

### 6. Domain Events

```go
package user

import (
    "time"
    "github.com/google/uuid"
)

// DomainEvent represents something that happened in the domain
type DomainEvent interface {
    EventID() string
    EventType() string
    OccurredAt() time.Time
    AggregateID() string
    Version() int
}

// Base event struct
type baseEvent struct {
    id          string
    eventType   string
    occurredAt  time.Time
    aggregateID string
    version     int
}

func newBaseEvent(eventType, aggregateID string, version int) baseEvent {
    return baseEvent{
        id:          uuid.New().String(),
        eventType:   eventType,
        occurredAt:  time.Now(),
        aggregateID: aggregateID,
        version:     version,
    }
}

func (e baseEvent) EventID() string     { return e.id }
func (e baseEvent) EventType() string   { return e.eventType }
func (e baseEvent) OccurredAt() time.Time { return e.occurredAt }
func (e baseEvent) AggregateID() string { return e.aggregateID }
func (e baseEvent) Version() int        { return e.version }

// Specific domain events
type UserCreatedEvent struct {
    baseEvent
    Email Email
}

func NewUserCreatedEvent(userID UserID, email Email) UserCreatedEvent {
    return UserCreatedEvent{
        baseEvent: newBaseEvent("UserCreated", userID.String(), 1),
        Email:     email,
    }
}

type UserEmailChangedEvent struct {
    baseEvent
    OldEmail Email
    NewEmail Email
}

func NewUserEmailChangedEvent(userID UserID, oldEmail, newEmail Email) UserEmailChangedEvent {
    return UserEmailChangedEvent{
        baseEvent: newBaseEvent("UserEmailChanged", userID.String(), 1),
        OldEmail:  oldEmail,
        NewEmail:  newEmail,
    }
}

type PermissionGrantedEvent struct {
    baseEvent
    Permission Permission
}

func NewPermissionGrantedEvent(userID UserID, permission Permission) PermissionGrantedEvent {
    return PermissionGrantedEvent{
        baseEvent:  newBaseEvent("PermissionGranted", userID.String(), 1),
        Permission: permission,
    }
}

type UserDeactivatedEvent struct {
    baseEvent
}

func NewUserDeactivatedEvent(userID UserID) UserDeactivatedEvent {
    return UserDeactivatedEvent{
        baseEvent: newBaseEvent("UserDeactivated", userID.String(), 1),
    }
}
```

### 7. Domain Enums and Constants

```go
package user

// Status represents user account status
type Status int

const (
    StatusActive Status = iota + 1
    StatusInactive
    StatusDeactivated
    StatusSuspended
)

func (s Status) String() string {
    switch s {
    case StatusActive:
        return "active"
    case StatusInactive:
        return "inactive"
    case StatusDeactivated:
        return "deactivated"
    case StatusSuspended:
        return "suspended"
    default:
        return "unknown"
    }
}

// Permission represents what a user can do
type Permission int

const (
    PermissionRead Permission = iota + 1
    PermissionWrite
    PermissionDelete
    PermissionAdmin
)

func (p Permission) String() string {
    switch p {
    case PermissionRead:
        return "read"
    case PermissionWrite:
        return "write"
    case PermissionDelete:
        return "delete"
    case PermissionAdmin:
        return "admin"
    default:
        return "unknown"
    }
}
```

### 8. Testing Domain Logic

```go
package user_test

import (
    "testing"
    "time"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestUserCreation(t *testing.T) {
    email, err := NewEmail("test@example.com")
    require.NoError(t, err)
    
    birthDate := time.Date(1990, 1, 1, 0, 0, 0, 0, time.UTC)
    profile, err := NewProfile("John", "Doe", &birthDate, "Software developer")
    require.NoError(t, err)
    
    user, err := NewUser(email, profile)
    require.NoError(t, err)
    
    assert.Equal(t, email, user.Email())
    assert.Equal(t, profile, user.Profile())
    assert.Equal(t, StatusActive, user.Status())
    assert.Empty(t, user.Permissions())
    assert.Len(t, user.UncommittedEvents(), 1)
    
    events := user.UncommittedEvents()
    assert.IsType(t, UserCreatedEvent{}, events[0])
}

func TestEmailChange(t *testing.T) {
    // Setup
    user := createTestUser(t)
    
    newEmail, err := NewEmail("newemail@example.com")
    require.NoError(t, err)
    
    // Execute
    err = user.ChangeEmail(newEmail)
    require.NoError(t, err)
    
    // Verify
    assert.Equal(t, newEmail, user.Email())
    assert.Len(t, user.UncommittedEvents(), 2) // UserCreated + UserEmailChanged
}

func TestPermissionGrant(t *testing.T) {
    user := createTestUser(t)
    
    err := user.GrantPermission(PermissionWrite)
    require.NoError(t, err)
    
    permissions := user.Permissions()
    assert.Contains(t, permissions, PermissionWrite)
    assert.Len(t, user.UncommittedEvents(), 2)
}

func TestDeactivatedUserCannotChangeEmail(t *testing.T) {
    user := createTestUser(t)
    
    err := user.Deactivate()
    require.NoError(t, err)
    
    newEmail, err := NewEmail("new@example.com")
    require.NoError(t, err)
    
    err = user.ChangeEmail(newEmail)
    assert.Error(t, err)
    assert.Contains(t, err.Error(), "deactivated user")
}

func TestValueObjectImmutability(t *testing.T) {
    email1, err := NewEmail("test@example.com")
    require.NoError(t, err)
    
    email2, err := NewEmail("test@example.com")
    require.NoError(t, err)
    
    assert.True(t, email1.Equals(email2))
    assert.Equal(t, email1.String(), email2.String())
}

func createTestUser(t *testing.T) *User {
    email, err := NewEmail("test@example.com")
    require.NoError(t, err)
    
    profile, err := NewProfile("John", "Doe", nil, "")
    require.NoError(t, err)
    
    user, err := NewUser(email, profile)
    require.NoError(t, err)
    
    user.MarkEventsAsCommitted() // Clear initial events for clean testing
    return user
}
```

## Implementation Guidelines

### Entity Guidelines
1. **Identity**: Entities must have unique, immutable identifiers
2. **Encapsulation**: Keep internal state private, expose through methods
3. **Business rules**: Implement invariants within entity methods
4. **Events**: Raise domain events for significant state changes

### Value Object Guidelines  
1. **Immutability**: Value objects should be immutable after creation
2. **Equality**: Implement equality based on value, not identity
3. **Validation**: Validate invariants during construction
4. **Self-contained**: Should not reference entities or other aggregates

### Repository Guidelines
1. **Interface in domain**: Repository interfaces belong in the domain layer
2. **Aggregate roots**: Repositories should only work with aggregate roots
3. **Rich queries**: Support domain-meaningful queries, not just CRUD
4. **Specifications**: Use specification pattern for complex query logic

## Consequences

### Positive
- **Clear business logic**: Domain rules are explicit and testable
- **Better organization**: Business logic is separated from infrastructure
- **Rich models**: Entities contain behavior, not just data
- **Testability**: Domain logic can be tested in isolation
- **Expressiveness**: Code reads like business requirements

### Negative  
- **Complexity**: More layers and abstractions to manage
- **Learning curve**: Team needs to understand DDD concepts
- **Over-engineering**: Risk of applying DDD where simple CRUD suffices

## Best Practices

1. **Start simple**: Begin with entities and value objects, add complexity as needed
2. **Focus on invariants**: Identify and enforce business rules consistently
3. **Rich vocabulary**: Use domain language in code (ubiquitous language)
4. **Event-driven**: Use domain events to decouple aggregates
5. **Test behavior**: Focus tests on business logic, not implementation details

## Anti-patterns to Avoid

```go
// ❌ Bad: Anemic domain model
type User struct {
    ID    string
    Name  string  
    Email string
}

// ✅ Good: Rich domain model
type User struct {
    id      UserID
    profile Profile
    // ... methods that enforce business rules
}

// ❌ Bad: Exposing internals
func (u *User) SetEmail(email string) {
    u.email = email
}

// ✅ Good: Business-meaningful operations
func (u *User) ChangeEmail(email Email) error {
    // Validation and business rules
    return nil
}
```

## References

- [Domain-Driven Design by Eric Evans](https://domainlanguage.com/ddd/)
- [Implementing Domain-Driven Design by Vaughn Vernon](https://vaughnvernon.co/?page_id=168)
- [Clean Architecture by Robert Martin](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Go DDD Example Repository](https://github.com/marcusolsson/goddd)
