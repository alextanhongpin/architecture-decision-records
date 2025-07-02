# Mapper Layer Pattern for Clean Architecture

## Status

**Accepted** - Use mapper layer pattern to decouple architectural layers and manage data transformation between domain models and external representations.

## Context

In layered architectures, different layers often need to work with different representations of the same data. For example:

- **Domain Layer**: Uses rich domain models with business logic
- **Persistence Layer**: Uses database-specific models optimized for storage
- **API Layer**: Uses DTOs/request/response models optimized for serialization
- **External Services**: Use third-party API models with different structures

Direct coupling between these layers creates several problems:

- **Tight Coupling**: Changes in one layer force changes in others
- **Import Cycles**: Circular dependencies between packages
- **Model Pollution**: Domain models become polluted with serialization tags
- **Testing Difficulties**: Hard to test layers in isolation
- **Evolution Resistance**: Difficulty evolving different representations independently

The mapper layer pattern provides a solution by:
- Decoupling layers through abstraction
- Centralizing data transformation logic
- Enabling independent evolution of layer-specific models
- Improving testability and maintainability

## Decision

We will implement mapper layer pattern for:

1. **Domain ↔ Persistence**: Converting between domain models and database entities
2. **Domain ↔ API**: Converting between domain models and DTOs
3. **Domain ↔ External Services**: Converting between domain models and third-party APIs
4. **Cross-Bounded Context**: Converting between different domain contexts

### Implementation Guidelines

#### 1. Core Mapper Interface

```go
package mapper

import (
	"context"
)

// Mapper defines the interface for data transformation
type Mapper[From, To any] interface {
	Map(ctx context.Context, from From) (To, error)
	MapSlice(ctx context.Context, from []From) ([]To, error)
}

// BidirectionalMapper supports mapping in both directions
type BidirectionalMapper[A, B any] interface {
	MapAToB(ctx context.Context, a A) (B, error)
	MapBToA(ctx context.Context, b B) (A, error)
	MapASliceToB(ctx context.Context, a []A) ([]B, error)
	MapBSliceToA(ctx context.Context, b []B) ([]A, error)
}

// MapperFunc provides a function-based mapper implementation
type MapperFunc[From, To any] func(context.Context, From) (To, error)

func (f MapperFunc[From, To]) Map(ctx context.Context, from From) (To, error) {
	return f(ctx, from)
}

func (f MapperFunc[From, To]) MapSlice(ctx context.Context, from []From) ([]To, error) {
	result := make([]To, len(from))
	for i, item := range from {
		mapped, err := f(ctx, item)
		if err != nil {
			var zero []To
			return zero, err
		}
		result[i] = mapped
	}
	return result, nil
}

// ConditionalMapper applies mapping based on conditions
type ConditionalMapper[From, To any] struct {
	condition func(From) bool
	mapper    Mapper[From, To]
	fallback  Mapper[From, To]
}

func NewConditionalMapper[From, To any](
	condition func(From) bool,
	mapper Mapper[From, To],
	fallback Mapper[From, To],
) *ConditionalMapper[From, To] {
	return &ConditionalMapper[From, To]{
		condition: condition,
		mapper:    mapper,
		fallback:  fallback,
	}
}

func (cm *ConditionalMapper[From, To]) Map(ctx context.Context, from From) (To, error) {
	if cm.condition(from) {
		return cm.mapper.Map(ctx, from)
	}
	return cm.fallback.Map(ctx, from)
}

func (cm *ConditionalMapper[From, To]) MapSlice(ctx context.Context, from []From) ([]To, error) {
	result := make([]To, len(from))
	for i, item := range from {
		mapped, err := cm.Map(ctx, item)
		if err != nil {
			var zero []To
			return zero, err
		}
		result[i] = mapped
	}
	return result, nil
}
```

#### 2. Domain to Database Mapper

```go
package persistence

import (
	"context"
	"database/sql/driver"
	"encoding/json"
	"time"
	
	"yourapp/domain"
	"yourapp/mapper"
)

// UserEntity represents database model
type UserEntity struct {
	ID        int64     `db:"id"`
	Name      string    `db:"name"`
	Email     string    `db:"email"`
	Status    string    `db:"status"`
	Tags      JSONArray `db:"tags"`
	CreatedAt time.Time `db:"created_at"`
	UpdatedAt time.Time `db:"updated_at"`
}

// JSONArray handles JSON array storage in database
type JSONArray []string

func (ja *JSONArray) Scan(value interface{}) error {
	if value == nil {
		*ja = nil
		return nil
	}
	
	bytes, ok := value.([]byte)
	if !ok {
		return fmt.Errorf("cannot scan %T into JSONArray", value)
	}
	
	return json.Unmarshal(bytes, ja)
}

func (ja JSONArray) Value() (driver.Value, error) {
	if ja == nil {
		return nil, nil
	}
	return json.Marshal(ja)
}

// UserMapper handles User domain ↔ database mapping
type UserMapper struct{}

func NewUserMapper() *UserMapper {
	return &UserMapper{}
}

// DomainToEntity converts domain user to database entity
func (um *UserMapper) DomainToEntity(ctx context.Context, user *domain.User) (*UserEntity, error) {
	if user == nil {
		return nil, nil
	}
	
	return &UserEntity{
		ID:        user.ID.Value(),
		Name:      user.Profile.Name,
		Email:     user.Profile.Email,
		Status:    string(user.Status),
		Tags:      JSONArray(user.Tags),
		CreatedAt: user.Timestamps.CreatedAt,
		UpdatedAt: user.Timestamps.UpdatedAt,
	}, nil
}

// EntityToDomain converts database entity to domain user
func (um *UserMapper) EntityToDomain(ctx context.Context, entity *UserEntity) (*domain.User, error) {
	if entity == nil {
		return nil, nil
	}
	
	userID, err := domain.NewUserID(entity.ID)
	if err != nil {
		return nil, fmt.Errorf("invalid user ID: %w", err)
	}
	
	profile, err := domain.NewUserProfile(entity.Name, entity.Email)
	if err != nil {
		return nil, fmt.Errorf("invalid user profile: %w", err)
	}
	
	status, err := domain.ParseUserStatus(entity.Status)
	if err != nil {
		return nil, fmt.Errorf("invalid user status: %w", err)
	}
	
	return &domain.User{
		ID:      userID,
		Profile: profile,
		Status:  status,
		Tags:    []string(entity.Tags),
		Timestamps: domain.Timestamps{
			CreatedAt: entity.CreatedAt,
			UpdatedAt: entity.UpdatedAt,
		},
	}, nil
}

// DomainSliceToEntitySlice converts slice of domain users to entities
func (um *UserMapper) DomainSliceToEntitySlice(ctx context.Context, users []*domain.User) ([]*UserEntity, error) {
	entities := make([]*UserEntity, len(users))
	for i, user := range users {
		entity, err := um.DomainToEntity(ctx, user)
		if err != nil {
			return nil, fmt.Errorf("failed to map user %d: %w", i, err)
		}
		entities[i] = entity
	}
	return entities, nil
}

// EntitySliceToDomainSlice converts slice of entities to domain users
func (um *UserMapper) EntitySliceToDomainSlice(ctx context.Context, entities []*UserEntity) ([]*domain.User, error) {
	users := make([]*domain.User, len(entities))
	for i, entity := range entities {
		user, err := um.EntityToDomain(ctx, entity)
		if err != nil {
			return nil, fmt.Errorf("failed to map entity %d: %w", i, err)
		}
		users[i] = user
	}
	return users, nil
}

// Repository with mapper injection
type UserRepository struct {
	db     Database
	mapper *UserMapper
}

func NewUserRepository(db Database, mapper *UserMapper) *UserRepository {
	return &UserRepository{
		db:     db,
		mapper: mapper,
	}
}

func (ur *UserRepository) Create(ctx context.Context, user *domain.User) error {
	entity, err := ur.mapper.DomainToEntity(ctx, user)
	if err != nil {
		return fmt.Errorf("mapping to entity failed: %w", err)
	}
	
	query := `
		INSERT INTO users (name, email, status, tags, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING id`
	
	err = ur.db.QueryRowContext(ctx, query,
		entity.Name, entity.Email, entity.Status, entity.Tags,
		entity.CreatedAt, entity.UpdatedAt,
	).Scan(&entity.ID)
	if err != nil {
		return fmt.Errorf("database insert failed: %w", err)
	}
	
	// Update domain object with generated ID
	user.ID = domain.UserID(entity.ID)
	
	return nil
}

func (ur *UserRepository) GetByID(ctx context.Context, id domain.UserID) (*domain.User, error) {
	query := `
		SELECT id, name, email, status, tags, created_at, updated_at
		FROM users WHERE id = $1`
	
	var entity UserEntity
	err := ur.db.QueryRowContext(ctx, query, id.Value()).Scan(
		&entity.ID, &entity.Name, &entity.Email, &entity.Status,
		&entity.Tags, &entity.CreatedAt, &entity.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("database query failed: %w", err)
	}
	
	user, err := ur.mapper.EntityToDomain(ctx, &entity)
	if err != nil {
		return nil, fmt.Errorf("mapping to domain failed: %w", err)
	}
	
	return user, nil
}
```

#### 3. Domain to API Mapper

```go
package api

import (
	"context"
	"time"
	
	"yourapp/domain"
	"yourapp/mapper"
)

// UserResponse represents API response model
type UserResponse struct {
	ID        int64     `json:"id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	Status    string    `json:"status"`
	Tags      []string  `json:"tags"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// CreateUserRequest represents API request model
type CreateUserRequest struct {
	Name  string   `json:"name" validate:"required,min=2,max=100"`
	Email string   `json:"email" validate:"required,email"`
	Tags  []string `json:"tags,omitempty"`
}

// UpdateUserRequest represents API update model
type UpdateUserRequest struct {
	Name  *string  `json:"name,omitempty" validate:"omitempty,min=2,max=100"`
	Tags  []string `json:"tags,omitempty"`
}

// UserAPIMapper handles User domain ↔ API mapping
type UserAPIMapper struct{}

func NewUserAPIMapper() *UserAPIMapper {
	return &UserAPIMapper{}
}

// DomainToResponse converts domain user to API response
func (uam *UserAPIMapper) DomainToResponse(ctx context.Context, user *domain.User) (*UserResponse, error) {
	if user == nil {
		return nil, nil
	}
	
	return &UserResponse{
		ID:        user.ID.Value(),
		Name:      user.Profile.Name,
		Email:     user.Profile.Email,
		Status:    string(user.Status),
		Tags:      user.Tags,
		CreatedAt: user.Timestamps.CreatedAt,
		UpdatedAt: user.Timestamps.UpdatedAt,
	}, nil
}

// CreateRequestToDomain converts API request to domain user
func (uam *UserAPIMapper) CreateRequestToDomain(ctx context.Context, req *CreateUserRequest) (*domain.User, error) {
	if req == nil {
		return nil, fmt.Errorf("request cannot be nil")
	}
	
	profile, err := domain.NewUserProfile(req.Name, req.Email)
	if err != nil {
		return nil, fmt.Errorf("invalid user profile: %w", err)
	}
	
	now := time.Now()
	
	return &domain.User{
		Profile: profile,
		Status:  domain.UserStatusActive,
		Tags:    req.Tags,
		Timestamps: domain.Timestamps{
			CreatedAt: now,
			UpdatedAt: now,
		},
	}, nil
}

// ApplyUpdateRequest applies update request to domain user
func (uam *UserAPIMapper) ApplyUpdateRequest(ctx context.Context, user *domain.User, req *UpdateUserRequest) error {
	if req == nil {
		return fmt.Errorf("update request cannot be nil")
	}
	
	if req.Name != nil {
		profile, err := domain.NewUserProfile(*req.Name, user.Profile.Email)
		if err != nil {
			return fmt.Errorf("invalid updated name: %w", err)
		}
		user.Profile = profile
	}
	
	if req.Tags != nil {
		user.Tags = req.Tags
	}
	
	user.Timestamps.UpdatedAt = time.Now()
	
	return nil
}

// DomainSliceToResponseSlice converts slice of domain users to responses
func (uam *UserAPIMapper) DomainSliceToResponseSlice(ctx context.Context, users []*domain.User) ([]*UserResponse, error) {
	responses := make([]*UserResponse, len(users))
	for i, user := range users {
		response, err := uam.DomainToResponse(ctx, user)
		if err != nil {
			return nil, fmt.Errorf("failed to map user %d: %w", i, err)
		}
		responses[i] = response
	}
	return responses, nil
}

// Handler with mapper injection
type UserHandler struct {
	service domain.UserService
	mapper  *UserAPIMapper
}

func NewUserHandler(service domain.UserService, mapper *UserAPIMapper) *UserHandler {
	return &UserHandler{
		service: service,
		mapper:  mapper,
	}
}

func (uh *UserHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
	var req CreateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}
	
	// Map request to domain
	user, err := uh.mapper.CreateRequestToDomain(r.Context(), &req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	
	// Call service
	if err := uh.service.CreateUser(r.Context(), user); err != nil {
		http.Error(w, "Failed to create user", http.StatusInternalServerError)
		return
	}
	
	// Map domain to response
	response, err := uh.mapper.DomainToResponse(r.Context(), user)
	if err != nil {
		http.Error(w, "Failed to prepare response", http.StatusInternalServerError)
		return
	}
	
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(response)
}

func (uh *UserHandler) GetUser(w http.ResponseWriter, r *http.Request) {
	idStr := r.URL.Query().Get("id")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		http.Error(w, "Invalid user ID", http.StatusBadRequest)
		return
	}
	
	userID := domain.UserID(id)
	user, err := uh.service.GetUser(r.Context(), userID)
	if err != nil {
		http.Error(w, "User not found", http.StatusNotFound)
		return
	}
	
	response, err := uh.mapper.DomainToResponse(r.Context(), user)
	if err != nil {
		http.Error(w, "Failed to prepare response", http.StatusInternalServerError)
		return
	}
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}
```

#### 4. External Service Mapper

```go
package external

import (
	"context"
	"time"
	
	"yourapp/domain"
)

// ThirdPartyUser represents external API user model
type ThirdPartyUser struct {
	UserID       string            `json:"user_id"`
	DisplayName  string            `json:"display_name"`
	EmailAddress string            `json:"email_address"`
	UserStatus   string            `json:"user_status"`
	Labels       []string          `json:"labels"`
	Metadata     map[string]string `json:"metadata"`
	CreatedDate  string            `json:"created_date"`
	ModifiedDate string            `json:"modified_date"`
}

// ExternalUserMapper handles external API ↔ domain mapping
type ExternalUserMapper struct{}

func NewExternalUserMapper() *ExternalUserMapper {
	return &ExternalUserMapper{}
}

// ExternalToDomain converts external user to domain user
func (eum *ExternalUserMapper) ExternalToDomain(ctx context.Context, external *ThirdPartyUser) (*domain.User, error) {
	if external == nil {
		return nil, nil
	}
	
	// Parse external ID (assuming it's numeric)
	id, err := strconv.ParseInt(external.UserID, 10, 64)
	if err != nil {
		return nil, fmt.Errorf("invalid external user ID: %w", err)
	}
	
	userID, err := domain.NewUserID(id)
	if err != nil {
		return nil, fmt.Errorf("invalid user ID: %w", err)
	}
	
	profile, err := domain.NewUserProfile(external.DisplayName, external.EmailAddress)
	if err != nil {
		return nil, fmt.Errorf("invalid user profile: %w", err)
	}
	
	status, err := eum.mapExternalStatus(external.UserStatus)
	if err != nil {
		return nil, fmt.Errorf("invalid user status: %w", err)
	}
	
	createdAt, err := time.Parse(time.RFC3339, external.CreatedDate)
	if err != nil {
		createdAt = time.Now() // Fallback
	}
	
	updatedAt, err := time.Parse(time.RFC3339, external.ModifiedDate)
	if err != nil {
		updatedAt = time.Now() // Fallback
	}
	
	return &domain.User{
		ID:      userID,
		Profile: profile,
		Status:  status,
		Tags:    external.Labels,
		Timestamps: domain.Timestamps{
			CreatedAt: createdAt,
			UpdatedAt: updatedAt,
		},
	}, nil
}

// DomainToExternal converts domain user to external format
func (eum *ExternalUserMapper) DomainToExternal(ctx context.Context, user *domain.User) (*ThirdPartyUser, error) {
	if user == nil {
		return nil, nil
	}
	
	externalStatus, err := eum.mapDomainStatus(user.Status)
	if err != nil {
		return nil, fmt.Errorf("cannot map user status: %w", err)
	}
	
	return &ThirdPartyUser{
		UserID:       strconv.FormatInt(user.ID.Value(), 10),
		DisplayName:  user.Profile.Name,
		EmailAddress: user.Profile.Email,
		UserStatus:   externalStatus,
		Labels:       user.Tags,
		Metadata:     map[string]string{}, // Default empty
		CreatedDate:  user.Timestamps.CreatedAt.Format(time.RFC3339),
		ModifiedDate: user.Timestamps.UpdatedAt.Format(time.RFC3339),
	}, nil
}

// mapExternalStatus maps external status to domain status
func (eum *ExternalUserMapper) mapExternalStatus(externalStatus string) (domain.UserStatus, error) {
	switch externalStatus {
	case "ACTIVE":
		return domain.UserStatusActive, nil
	case "INACTIVE":
		return domain.UserStatusInactive, nil
	case "SUSPENDED":
		return domain.UserStatusSuspended, nil
	default:
		return "", fmt.Errorf("unknown external status: %s", externalStatus)
	}
}

// mapDomainStatus maps domain status to external status
func (eum *ExternalUserMapper) mapDomainStatus(status domain.UserStatus) (string, error) {
	switch status {
	case domain.UserStatusActive:
		return "ACTIVE", nil
	case domain.UserStatusInactive:
		return "INACTIVE", nil
	case domain.UserStatusSuspended:
		return "SUSPENDED", nil
	default:
		return "", fmt.Errorf("unknown domain status: %s", status)
	}
}

// External service with mapper
type ExternalUserService struct {
	client HTTPClient
	mapper *ExternalUserMapper
}

func NewExternalUserService(client HTTPClient, mapper *ExternalUserMapper) *ExternalUserService {
	return &ExternalUserService{
		client: client,
		mapper: mapper,
	}
}

func (eus *ExternalUserService) GetUser(ctx context.Context, userID domain.UserID) (*domain.User, error) {
	// Call external API
	url := fmt.Sprintf("/api/users/%d", userID.Value())
	var externalUser ThirdPartyUser
	
	if err := eus.client.Get(ctx, url, &externalUser); err != nil {
		return nil, fmt.Errorf("external API call failed: %w", err)
	}
	
	// Map to domain
	user, err := eus.mapper.ExternalToDomain(ctx, &externalUser)
	if err != nil {
		return nil, fmt.Errorf("mapping from external failed: %w", err)
	}
	
	return user, nil
}

func (eus *ExternalUserService) SyncUser(ctx context.Context, user *domain.User) error {
	// Map to external format
	externalUser, err := eus.mapper.DomainToExternal(ctx, user)
	if err != nil {
		return fmt.Errorf("mapping to external failed: %w", err)
	}
	
	// Send to external API
	url := fmt.Sprintf("/api/users/%s", externalUser.UserID)
	if err := eus.client.Put(ctx, url, externalUser); err != nil {
		return fmt.Errorf("external API sync failed: %w", err)
	}
	
	return nil
}
```

#### 5. Testing Mappers

```go
package mapper_test

import (
	"context"
	"testing"
	"time"
	
	"yourapp/domain"
	"yourapp/persistence"
	"yourapp/api"
)

func TestUserMapper_DomainToEntity(t *testing.T) {
	mapper := persistence.NewUserMapper()
	
	user := &domain.User{
		ID: domain.UserID(123),
		Profile: domain.UserProfile{
			Name:  "John Doe",
			Email: "john@example.com",
		},
		Status: domain.UserStatusActive,
		Tags:   []string{"vip", "premium"},
		Timestamps: domain.Timestamps{
			CreatedAt: time.Date(2023, 1, 1, 0, 0, 0, 0, time.UTC),
			UpdatedAt: time.Date(2023, 1, 2, 0, 0, 0, 0, time.UTC),
		},
	}
	
	entity, err := mapper.DomainToEntity(context.Background(), user)
	if err != nil {
		t.Fatalf("Mapping failed: %v", err)
	}
	
	if entity.ID != 123 {
		t.Errorf("Expected ID 123, got %d", entity.ID)
	}
	
	if entity.Name != "John Doe" {
		t.Errorf("Expected name 'John Doe', got %s", entity.Name)
	}
	
	if entity.Status != "active" {
		t.Errorf("Expected status 'active', got %s", entity.Status)
	}
	
	if len(entity.Tags) != 2 {
		t.Errorf("Expected 2 tags, got %d", len(entity.Tags))
	}
}

func TestUserMapper_EntityToDomain(t *testing.T) {
	mapper := persistence.NewUserMapper()
	
	entity := &persistence.UserEntity{
		ID:        123,
		Name:      "Jane Smith",
		Email:     "jane@example.com",
		Status:    "active",
		Tags:      []string{"staff"},
		CreatedAt: time.Date(2023, 1, 1, 0, 0, 0, 0, time.UTC),
		UpdatedAt: time.Date(2023, 1, 2, 0, 0, 0, 0, time.UTC),
	}
	
	user, err := mapper.EntityToDomain(context.Background(), entity)
	if err != nil {
		t.Fatalf("Mapping failed: %v", err)
	}
	
	if user.ID.Value() != 123 {
		t.Errorf("Expected ID 123, got %d", user.ID.Value())
	}
	
	if user.Profile.Name != "Jane Smith" {
		t.Errorf("Expected name 'Jane Smith', got %s", user.Profile.Name)
	}
	
	if user.Status != domain.UserStatusActive {
		t.Errorf("Expected status active, got %s", user.Status)
	}
}

func TestUserAPIMapper_CreateRequestToDomain(t *testing.T) {
	mapper := api.NewUserAPIMapper()
	
	req := &api.CreateUserRequest{
		Name:  "Alice Johnson",
		Email: "alice@example.com",
		Tags:  []string{"customer"},
	}
	
	user, err := mapper.CreateRequestToDomain(context.Background(), req)
	if err != nil {
		t.Fatalf("Mapping failed: %v", err)
	}
	
	if user.Profile.Name != req.Name {
		t.Errorf("Expected name %s, got %s", req.Name, user.Profile.Name)
	}
	
	if user.Profile.Email != req.Email {
		t.Errorf("Expected email %s, got %s", req.Email, user.Profile.Email)
	}
	
	if user.Status != domain.UserStatusActive {
		t.Errorf("Expected default status active, got %s", user.Status)
	}
}

func TestUserAPIMapper_DomainToResponse(t *testing.T) {
	mapper := api.NewUserAPIMapper()
	
	user := &domain.User{
		ID: domain.UserID(456),
		Profile: domain.UserProfile{
			Name:  "Bob Wilson",
			Email: "bob@example.com",
		},
		Status: domain.UserStatusActive,
		Tags:   []string{"admin"},
		Timestamps: domain.Timestamps{
			CreatedAt: time.Date(2023, 1, 1, 0, 0, 0, 0, time.UTC),
			UpdatedAt: time.Date(2023, 1, 2, 0, 0, 0, 0, time.UTC),
		},
	}
	
	response, err := mapper.DomainToResponse(context.Background(), user)
	if err != nil {
		t.Fatalf("Mapping failed: %v", err)
	}
	
	if response.ID != 456 {
		t.Errorf("Expected ID 456, got %d", response.ID)
	}
	
	if response.Name != "Bob Wilson" {
		t.Errorf("Expected name 'Bob Wilson', got %s", response.Name)
	}
	
	if response.Status != "active" {
		t.Errorf("Expected status 'active', got %s", response.Status)
	}
}

func BenchmarkUserMapper_DomainToEntity(b *testing.B) {
	mapper := persistence.NewUserMapper()
	
	user := &domain.User{
		ID: domain.UserID(123),
		Profile: domain.UserProfile{
			Name:  "Benchmark User",
			Email: "bench@example.com",
		},
		Status: domain.UserStatusActive,
		Tags:   []string{"test"},
		Timestamps: domain.Timestamps{
			CreatedAt: time.Now(),
			UpdatedAt: time.Now(),
		},
	}
	
	ctx := context.Background()
	
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := mapper.DomainToEntity(ctx, user)
		if err != nil {
			b.Fatalf("Mapping failed: %v", err)
		}
	}
}
```

## Consequences

### Positive

- **Layer Decoupling**: Clean separation between architectural layers
- **Independent Evolution**: Each layer can evolve its models independently
- **Testing Isolation**: Easier to test layers in isolation
- **Single Responsibility**: Each mapper has a single, focused responsibility
- **Reusability**: Mappers can be reused across different parts of the application
- **Type Safety**: Compile-time checking of mapping operations

### Negative

- **Additional Complexity**: More components to understand and maintain
- **Boilerplate Code**: Repetitive mapping code for similar structures
- **Performance Overhead**: Additional object creation and transformation
- **Potential Inconsistency**: Risk of mapping logic becoming inconsistent

### Trade-offs

- **Flexibility vs. Simplicity**: Gains architectural flexibility at cost of simplicity
- **Maintainability vs. Performance**: Improves maintainability but adds performance overhead
- **Decoupling vs. Directness**: Achieves decoupling but loses direct data access

## Best Practices

1. **Single Purpose Mappers**: Each mapper should handle one specific transformation
2. **Error Handling**: Always validate data during mapping and provide clear errors
3. **Context Usage**: Pass context through mapping operations for cancellation/tracing
4. **Null Safety**: Handle nil inputs gracefully
5. **Batch Operations**: Provide efficient slice mapping methods
6. **Testing**: Thoroughly test mapping logic in both directions
7. **Documentation**: Document mapping rules and any special handling

## References

- [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Hexagonal Architecture](https://alistair.cockburn.us/hexagonal-architecture/)
- [Domain-Driven Design](https://martinfowler.com/bliki/DomainDrivenDesign.html)
- [Data Transfer Object Pattern](https://martinfowler.com/eaaCatalog/dataTransferObject.html)

