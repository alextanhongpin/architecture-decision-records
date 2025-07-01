# Independent Schema Design

## Status

`accepted`

## Context

Modern microservices and modular applications often require schema designs that minimize coupling between different domains and services. Independent schemas allow features to evolve separately, support different teams working in parallel, and enable better scaling and deployment strategies. However, most application features are inherently connected through relationships, making true independence challenging.

The goal is to design schemas that maximize independence while maintaining necessary relationships and data integrity across different domains.

## Decision

Implement independent schema design patterns that minimize coupling through strategic use of weak references, event-driven synchronization, and clear domain boundaries while maintaining data consistency and performance.

## Architecture

### Independence Strategies

1. **Weak References**: Use external IDs instead of foreign keys
2. **Domain Boundaries**: Clear separation of concerns
3. **Event-Driven Sync**: Asynchronous data synchronization
4. **Shared Nothing**: Independent data stores per domain
5. **Gateway Pattern**: Centralized access control
6. **Version Isolation**: Schema versioning for evolution

### Schema Design Patterns

```sql
-- Traditional Coupled Schema (Avoid)
CREATE SCHEMA traditional;

CREATE TABLE traditional.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE traditional.orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES traditional.users(id), -- Strong coupling
    amount DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Independent Schema Design (Preferred)
CREATE SCHEMA user_domain;
CREATE SCHEMA order_domain;
CREATE SCHEMA notification_domain;

-- User Domain - Standalone
CREATE TABLE user_domain.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id VARCHAR(255) NOT NULL UNIQUE, -- External reference
    email VARCHAR(255) NOT NULL UNIQUE,
    profile JSONB,
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    version INTEGER NOT NULL DEFAULT 1
);

-- Order Domain - References users weakly
CREATE TABLE order_domain.orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id VARCHAR(255) NOT NULL UNIQUE,
    user_external_id VARCHAR(255) NOT NULL, -- Weak reference
    user_email VARCHAR(255), -- Cached user data
    user_status VARCHAR(50), -- Cached user status
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    version INTEGER NOT NULL DEFAULT 1
);

-- Event store for cross-domain communication
CREATE TABLE order_domain.domain_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type VARCHAR(100) NOT NULL,
    event_version VARCHAR(10) NOT NULL DEFAULT 'v1',
    aggregate_id VARCHAR(255) NOT NULL,
    aggregate_type VARCHAR(100) NOT NULL,
    event_data JSONB NOT NULL,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ
);

-- Notification Domain - Independent
CREATE TABLE notification_domain.notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    external_id VARCHAR(255) NOT NULL UNIQUE,
    recipient_external_id VARCHAR(255) NOT NULL, -- Weak reference
    recipient_email VARCHAR(255), -- Cached data
    message TEXT NOT NULL,
    type VARCHAR(50) NOT NULL,
    channel VARCHAR(50) NOT NULL DEFAULT 'email',
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    scheduled_at TIMESTAMPTZ,
    sent_at TIMESTAMPTZ,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### Cross-Domain Reference Management

```sql
-- Reference integrity without foreign keys
CREATE TABLE order_domain.user_references (
    user_external_id VARCHAR(255) PRIMARY KEY,
    user_email VARCHAR(255) NOT NULL,
    user_status VARCHAR(50) NOT NULL,
    last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_valid BOOLEAN NOT NULL DEFAULT TRUE
);

-- Event handlers for maintaining references
CREATE TABLE order_domain.event_handlers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    handler_name VARCHAR(100) NOT NULL UNIQUE,
    event_type VARCHAR(100) NOT NULL,
    last_processed_event_id UUID,
    last_processed_at TIMESTAMPTZ,
    error_count INTEGER NOT NULL DEFAULT 0,
    status VARCHAR(50) NOT NULL DEFAULT 'active'
);

-- Saga coordination for complex workflows
CREATE TABLE order_domain.sagas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    saga_type VARCHAR(100) NOT NULL,
    aggregate_id VARCHAR(255) NOT NULL,
    current_step VARCHAR(100) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'started',
    compensation_data JSONB,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    timeout_at TIMESTAMPTZ
);

CREATE TABLE order_domain.saga_steps (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    saga_id UUID NOT NULL REFERENCES order_domain.sagas(id),
    step_name VARCHAR(100) NOT NULL,
    step_order INTEGER NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    input_data JSONB,
    output_data JSONB,
    error_data JSONB,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    
    UNIQUE(saga_id, step_order)
);
```

## Implementation

### Go Domain Service

```go
package domain

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/google/uuid"
)

type DomainService struct {
    db     *sql.DB
    schema string
    events EventPublisher
}

type EventPublisher interface {
    Publish(ctx context.Context, event DomainEvent) error
}

type DomainEvent struct {
    ID            uuid.UUID              `json:"id"`
    Type          string                 `json:"type"`
    Version       string                 `json:"version"`
    AggregateID   string                 `json:"aggregate_id"`
    AggregateType string                 `json:"aggregate_type"`
    Data          map[string]interface{} `json:"data"`
    Metadata      map[string]interface{} `json:"metadata"`
    CreatedAt     time.Time              `json:"created_at"`
}

func NewDomainService(db *sql.DB, schema string, events EventPublisher) *DomainService {
    return &DomainService{
        db:     db,
        schema: schema,
        events: events,
    }
}

// User Domain Service
type UserService struct {
    *DomainService
}

type User struct {
    ID         uuid.UUID              `json:"id"`
    ExternalID string                 `json:"external_id"`
    Email      string                 `json:"email"`
    Profile    map[string]interface{} `json:"profile"`
    Status     string                 `json:"status"`
    CreatedAt  time.Time              `json:"created_at"`
    UpdatedAt  time.Time              `json:"updated_at"`
    Version    int                    `json:"version"`
}

func NewUserService(db *sql.DB, events EventPublisher) *UserService {
    return &UserService{
        DomainService: NewDomainService(db, "user_domain", events),
    }
}

func (s *UserService) CreateUser(ctx context.Context, email string, 
    profile map[string]interface{}) (*User, error) {
    
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    user := &User{
        ID:         uuid.New(),
        ExternalID: generateExternalID("user"),
        Email:      email,
        Profile:    profile,
        Status:     "active",
        CreatedAt:  time.Now(),
        UpdatedAt:  time.Now(),
        Version:    1,
    }
    
    profileJSON, _ := json.Marshal(user.Profile)
    
    query := `
        INSERT INTO user_domain.users 
        (id, external_id, email, profile, status, created_at, updated_at, version)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`
    
    _, err = tx.ExecContext(ctx, query, user.ID, user.ExternalID, user.Email,
        profileJSON, user.Status, user.CreatedAt, user.UpdatedAt, user.Version)
    
    if err != nil {
        return nil, fmt.Errorf("insert user: %w", err)
    }
    
    // Publish domain event
    event := DomainEvent{
        ID:            uuid.New(),
        Type:          "user.created",
        Version:       "v1",
        AggregateID:   user.ExternalID,
        AggregateType: "user",
        Data: map[string]interface{}{
            "user_id":    user.ExternalID,
            "email":      user.Email,
            "status":     user.Status,
            "profile":    user.Profile,
        },
        Metadata: map[string]interface{}{
            "created_by": "user_service",
            "timestamp":  user.CreatedAt,
        },
        CreatedAt: time.Now(),
    }
    
    if err := s.publishEvent(ctx, tx, event); err != nil {
        return nil, fmt.Errorf("publish event: %w", err)
    }
    
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("commit transaction: %w", err)
    }
    
    // Async event publishing
    go s.events.Publish(context.Background(), event)
    
    return user, nil
}

func (s *UserService) UpdateUser(ctx context.Context, externalID string, 
    updates map[string]interface{}) (*User, error) {
    
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Get current user with version for optimistic locking
    var user User
    var profileJSON []byte
    
    query := `
        SELECT id, external_id, email, profile, status, created_at, updated_at, version
        FROM user_domain.users 
        WHERE external_id = $1 
        FOR UPDATE`
    
    err = tx.QueryRowContext(ctx, query, externalID).Scan(
        &user.ID, &user.ExternalID, &user.Email, &profileJSON,
        &user.Status, &user.CreatedAt, &user.UpdatedAt, &user.Version)
    
    if err != nil {
        return nil, fmt.Errorf("get user: %w", err)
    }
    
    json.Unmarshal(profileJSON, &user.Profile)
    
    // Apply updates
    originalUser := user
    if email, ok := updates["email"]; ok {
        user.Email = email.(string)
    }
    if status, ok := updates["status"]; ok {
        user.Status = status.(string)
    }
    if profile, ok := updates["profile"]; ok {
        user.Profile = profile.(map[string]interface{})
    }
    
    user.UpdatedAt = time.Now()
    user.Version++
    
    updatedProfileJSON, _ := json.Marshal(user.Profile)
    
    updateQuery := `
        UPDATE user_domain.users 
        SET email = $1, profile = $2, status = $3, updated_at = $4, version = $5
        WHERE external_id = $6 AND version = $7`
    
    result, err := tx.ExecContext(ctx, updateQuery,
        user.Email, updatedProfileJSON, user.Status, user.UpdatedAt,
        user.Version, user.ExternalID, originalUser.Version)
    
    if err != nil {
        return nil, fmt.Errorf("update user: %w", err)
    }
    
    affected, _ := result.RowsAffected()
    if affected == 0 {
        return nil, fmt.Errorf("user was modified by another process")
    }
    
    // Publish update event
    event := DomainEvent{
        ID:            uuid.New(),
        Type:          "user.updated",
        Version:       "v1",
        AggregateID:   user.ExternalID,
        AggregateType: "user",
        Data: map[string]interface{}{
            "user_id":     user.ExternalID,
            "email":       user.Email,
            "status":      user.Status,
            "profile":     user.Profile,
            "old_email":   originalUser.Email,
            "old_status":  originalUser.Status,
            "old_profile": originalUser.Profile,
        },
        CreatedAt: time.Now(),
    }
    
    if err := s.publishEvent(ctx, tx, event); err != nil {
        return nil, fmt.Errorf("publish event: %w", err)
    }
    
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("commit transaction: %w", err)
    }
    
    go s.events.Publish(context.Background(), event)
    
    return &user, nil
}

func (s *DomainService) publishEvent(ctx context.Context, tx *sql.Tx, event DomainEvent) error {
    eventDataJSON, _ := json.Marshal(event.Data)
    metadataJSON, _ := json.Marshal(event.Metadata)
    
    query := fmt.Sprintf(`
        INSERT INTO %s.domain_events 
        (id, event_type, event_version, aggregate_id, aggregate_type, 
         event_data, metadata, created_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`, s.schema)
    
    _, err := tx.ExecContext(ctx, query,
        event.ID, event.Type, event.Version, event.AggregateID,
        event.AggregateType, eventDataJSON, metadataJSON, event.CreatedAt)
    
    return err
}

// Order Domain Service
type OrderService struct {
    *DomainService
    userRefs *UserReferenceManager
}

type Order struct {
    ID             uuid.UUID              `json:"id"`
    ExternalID     string                 `json:"external_id"`
    UserExternalID string                 `json:"user_external_id"`
    UserEmail      string                 `json:"user_email"`
    UserStatus     string                 `json:"user_status"`
    Amount         float64                `json:"amount"`
    Status         string                 `json:"status"`
    Metadata       map[string]interface{} `json:"metadata"`
    CreatedAt      time.Time              `json:"created_at"`
    UpdatedAt      time.Time              `json:"updated_at"`
    Version        int                    `json:"version"`
}

type UserReferenceManager struct {
    db     *sql.DB
    schema string
}

func NewOrderService(db *sql.DB, events EventPublisher) *OrderService {
    return &OrderService{
        DomainService: NewDomainService(db, "order_domain", events),
        userRefs:      &UserReferenceManager{db: db, schema: "order_domain"},
    }
}

func (s *OrderService) CreateOrder(ctx context.Context, userExternalID string, 
    amount float64, metadata map[string]interface{}) (*Order, error) {
    
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Get user reference data
    userRef, err := s.userRefs.GetUserReference(ctx, tx, userExternalID)
    if err != nil {
        return nil, fmt.Errorf("get user reference: %w", err)
    }
    
    if userRef.Status != "active" {
        return nil, fmt.Errorf("user is not active")
    }
    
    order := &Order{
        ID:             uuid.New(),
        ExternalID:     generateExternalID("order"),
        UserExternalID: userExternalID,
        UserEmail:      userRef.Email,
        UserStatus:     userRef.Status,
        Amount:         amount,
        Status:         "pending",
        Metadata:       metadata,
        CreatedAt:      time.Now(),
        UpdatedAt:      time.Now(),
        Version:        1,
    }
    
    metadataJSON, _ := json.Marshal(order.Metadata)
    
    query := `
        INSERT INTO order_domain.orders 
        (id, external_id, user_external_id, user_email, user_status,
         amount, status, metadata, created_at, updated_at, version)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`
    
    _, err = tx.ExecContext(ctx, query, order.ID, order.ExternalID,
        order.UserExternalID, order.UserEmail, order.UserStatus,
        order.Amount, order.Status, metadataJSON,
        order.CreatedAt, order.UpdatedAt, order.Version)
    
    if err != nil {
        return nil, fmt.Errorf("insert order: %w", err)
    }
    
    // Publish domain event
    event := DomainEvent{
        ID:            uuid.New(),
        Type:          "order.created",
        Version:       "v1",
        AggregateID:   order.ExternalID,
        AggregateType: "order",
        Data: map[string]interface{}{
            "order_id":         order.ExternalID,
            "user_external_id": order.UserExternalID,
            "amount":           order.Amount,
            "status":           order.Status,
            "metadata":         order.Metadata,
        },
        CreatedAt: time.Now(),
    }
    
    if err := s.publishEvent(ctx, tx, event); err != nil {
        return nil, fmt.Errorf("publish event: %w", err)
    }
    
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("commit transaction: %w", err)
    }
    
    go s.events.Publish(context.Background(), event)
    
    return order, nil
}

type UserReference struct {
    UserExternalID string    `json:"user_external_id"`
    Email          string    `json:"email"`
    Status         string    `json:"status"`
    LastUpdated    time.Time `json:"last_updated"`
    IsValid        bool      `json:"is_valid"`
}

func (m *UserReferenceManager) GetUserReference(ctx context.Context, tx *sql.Tx, 
    userExternalID string) (*UserReference, error) {
    
    var ref UserReference
    query := fmt.Sprintf(`
        SELECT user_external_id, user_email, user_status, last_updated, is_valid
        FROM %s.user_references 
        WHERE user_external_id = $1 AND is_valid = TRUE`, m.schema)
    
    err := tx.QueryRowContext(ctx, query, userExternalID).Scan(
        &ref.UserExternalID, &ref.Email, &ref.Status, &ref.LastUpdated, &ref.IsValid)
    
    if err == sql.ErrNoRows {
        return nil, fmt.Errorf("user reference not found: %s", userExternalID)
    }
    
    if err != nil {
        return nil, fmt.Errorf("query user reference: %w", err)
    }
    
    // Check if reference is stale (older than 1 hour)
    if time.Since(ref.LastUpdated) > time.Hour {
        return nil, fmt.Errorf("user reference is stale")
    }
    
    return &ref, nil
}

func (m *UserReferenceManager) UpdateUserReference(ctx context.Context, event DomainEvent) error {
    if event.Type != "user.created" && event.Type != "user.updated" {
        return nil
    }
    
    userExternalID := event.Data["user_id"].(string)
    email := event.Data["email"].(string)
    status := event.Data["status"].(string)
    
    query := fmt.Sprintf(`
        INSERT INTO %s.user_references 
        (user_external_id, user_email, user_status, last_updated, is_valid)
        VALUES ($1, $2, $3, NOW(), TRUE)
        ON CONFLICT (user_external_id)
        DO UPDATE SET
            user_email = $2,
            user_status = $3,
            last_updated = NOW(),
            is_valid = TRUE`, m.schema)
    
    _, err := m.db.ExecContext(ctx, query, userExternalID, email, status)
    return err
}
```

### Event Processing System

```go
package events

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "log"
    "time"
)

type EventProcessor struct {
    db       *sql.DB
    handlers map[string]EventHandler
}

type EventHandler interface {
    Handle(ctx context.Context, event DomainEvent) error
    EventType() string
}

func NewEventProcessor(db *sql.DB) *EventProcessor {
    return &EventProcessor{
        db:       db,
        handlers: make(map[string]EventHandler),
    }
}

func (p *EventProcessor) RegisterHandler(handler EventHandler) {
    p.handlers[handler.EventType()] = handler
}

func (p *EventProcessor) ProcessEvents(ctx context.Context, schema string) error {
    query := fmt.Sprintf(`
        SELECT id, event_type, event_version, aggregate_id, aggregate_type,
               event_data, metadata, created_at
        FROM %s.domain_events 
        WHERE processed_at IS NULL
        ORDER BY created_at ASC
        LIMIT 100`, schema)
    
    rows, err := p.db.QueryContext(ctx, query)
    if err != nil {
        return fmt.Errorf("query events: %w", err)
    }
    defer rows.Close()
    
    for rows.Next() {
        var event DomainEvent
        var eventDataJSON, metadataJSON []byte
        
        err := rows.Scan(&event.ID, &event.Type, &event.Version,
            &event.AggregateID, &event.AggregateType,
            &eventDataJSON, &metadataJSON, &event.CreatedAt)
        
        if err != nil {
            log.Printf("Error scanning event: %v", err)
            continue
        }
        
        json.Unmarshal(eventDataJSON, &event.Data)
        json.Unmarshal(metadataJSON, &event.Metadata)
        
        if err := p.processEvent(ctx, schema, event); err != nil {
            log.Printf("Error processing event %s: %v", event.ID, err)
            continue
        }
    }
    
    return nil
}

func (p *EventProcessor) processEvent(ctx context.Context, schema string, event DomainEvent) error {
    handler, exists := p.handlers[event.Type]
    if !exists {
        // Mark as processed even if no handler
        return p.markEventProcessed(ctx, schema, event.ID)
    }
    
    if err := handler.Handle(ctx, event); err != nil {
        return fmt.Errorf("handle event: %w", err)
    }
    
    return p.markEventProcessed(ctx, schema, event.ID)
}

func (p *EventProcessor) markEventProcessed(ctx context.Context, schema string, eventID uuid.UUID) error {
    query := fmt.Sprintf(`
        UPDATE %s.domain_events 
        SET processed_at = NOW() 
        WHERE id = $1`, schema)
    
    _, err := p.db.ExecContext(ctx, query, eventID)
    return err
}

// User Reference Update Handler
type UserReferenceHandler struct {
    userRefs *UserReferenceManager
}

func (h *UserReferenceHandler) EventType() string {
    return "user.*" // Wildcard for all user events
}

func (h *UserReferenceHandler) Handle(ctx context.Context, event DomainEvent) error {
    return h.userRefs.UpdateUserReference(ctx, event)
}
```

### Monitoring and Health Checks

```go
package monitoring

import (
    "context"
    "database/sql"
    "fmt"
    "time"
)

type SchemaMonitor struct {
    db *sql.DB
}

func NewSchemaMonitor(db *sql.DB) *SchemaMonitor {
    return &SchemaMonitor{db: db}
}

func (m *SchemaMonitor) CheckSchemaHealth(ctx context.Context, schema string) error {
    // Check event processing lag
    var unprocessedCount int
    query := fmt.Sprintf(`
        SELECT COUNT(*) 
        FROM %s.domain_events 
        WHERE processed_at IS NULL 
        AND created_at < NOW() - INTERVAL '1 hour'`, schema)
    
    err := m.db.QueryRowContext(ctx, query).Scan(&unprocessedCount)
    if err != nil {
        return fmt.Errorf("check unprocessed events: %w", err)
    }
    
    if unprocessedCount > 1000 {
        return fmt.Errorf("too many unprocessed events: %d", unprocessedCount)
    }
    
    // Check reference data freshness
    if schema == "order_domain" {
        var staleRefCount int
        staleQuery := fmt.Sprintf(`
            SELECT COUNT(*) 
            FROM %s.user_references 
            WHERE last_updated < NOW() - INTERVAL '6 hours'
            AND is_valid = TRUE`, schema)
        
        err := m.db.QueryRowContext(ctx, staleQuery).Scan(&staleRefCount)
        if err != nil {
            return fmt.Errorf("check stale references: %w", err)
        }
        
        if staleRefCount > 100 {
            return fmt.Errorf("too many stale references: %d", staleRefCount)
        }
    }
    
    return nil
}

func (m *SchemaMonitor) GetSchemaMetrics(ctx context.Context, schema string) (map[string]interface{}, error) {
    metrics := make(map[string]interface{})
    
    // Event metrics
    var eventCount, unprocessedCount int
    eventQuery := fmt.Sprintf(`
        SELECT 
            COUNT(*) as total,
            COUNT(*) FILTER (WHERE processed_at IS NULL) as unprocessed
        FROM %s.domain_events 
        WHERE created_at > NOW() - INTERVAL '24 hours'`, schema)
    
    err := m.db.QueryRowContext(ctx, eventQuery).Scan(&eventCount, &unprocessedCount)
    if err == nil {
        metrics["events_24h"] = eventCount
        metrics["unprocessed_events"] = unprocessedCount
    }
    
    // Schema-specific metrics
    switch schema {
    case "user_domain":
        var userCount, activeUserCount int
        userQuery := `SELECT COUNT(*), COUNT(*) FILTER (WHERE status = 'active') FROM user_domain.users`
        if m.db.QueryRowContext(ctx, userQuery).Scan(&userCount, &activeUserCount) == nil {
            metrics["total_users"] = userCount
            metrics["active_users"] = activeUserCount
        }
        
    case "order_domain":
        var orderCount, pendingOrderCount int
        orderQuery := `SELECT COUNT(*), COUNT(*) FILTER (WHERE status = 'pending') FROM order_domain.orders`
        if m.db.QueryRowContext(ctx, orderQuery).Scan(&orderCount, &pendingOrderCount) == nil {
            metrics["total_orders"] = orderCount
            metrics["pending_orders"] = pendingOrderCount
        }
        
        var refCount, staleRefCount int
        refQuery := `SELECT COUNT(*), COUNT(*) FILTER (WHERE last_updated < NOW() - INTERVAL '1 hour') FROM order_domain.user_references`
        if m.db.QueryRowContext(ctx, refQuery).Scan(&refCount, &staleRefCount) == nil {
            metrics["user_references"] = refCount
            metrics["stale_references"] = staleRefCount
        }
    }
    
    return metrics, nil
}
```

## Usage Examples

### Setting Up Independent Schemas

```go
func main() {
    db := setupDatabase()
    
    // Create event publisher
    eventBus := events.NewEventBus()
    
    // Create domain services
    userService := NewUserService(db, eventBus)
    orderService := NewOrderService(db, eventBus)
    
    // Setup event processing
    processor := events.NewEventProcessor(db)
    processor.RegisterHandler(&UserReferenceHandler{
        userRefs: orderService.userRefs,
    })
    
    // Start event processing
    go func() {
        ticker := time.NewTicker(5 * time.Second)
        defer ticker.Stop()
        
        for range ticker.C {
            processor.ProcessEvents(context.Background(), "order_domain")
        }
    }()
    
    // Setup monitoring
    monitor := monitoring.NewSchemaMonitor(db)
    go func() {
        ticker := time.NewTicker(1 * time.Minute)
        defer ticker.Stop()
        
        for range ticker.C {
            if err := monitor.CheckSchemaHealth(context.Background(), "user_domain"); err != nil {
                log.Printf("User domain health check failed: %v", err)
            }
            
            if err := monitor.CheckSchemaHealth(context.Background(), "order_domain"); err != nil {
                log.Printf("Order domain health check failed: %v", err)
            }
        }
    }()
}
```

### Creating Cross-Domain Operations

```go
func handleCreateOrder(userService *UserService, orderService *OrderService) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        var req struct {
            UserEmail string  `json:"user_email"`
            Amount    float64 `json:"amount"`
        }
        
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            http.Error(w, "Invalid request", http.StatusBadRequest)
            return
        }
        
        // This would typically come from authentication
        userExternalID := "user_12345"
        
        order, err := orderService.CreateOrder(r.Context(), userExternalID, req.Amount, nil)
        if err != nil {
            http.Error(w, err.Error(), http.StatusBadRequest)
            return
        }
        
        json.NewEncoder(w).Encode(order)
    }
}
```

### Health Check Endpoints

```go
func handleHealthCheck(monitor *monitoring.SchemaMonitor) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        schema := r.URL.Query().Get("schema")
        if schema == "" {
            http.Error(w, "schema parameter required", http.StatusBadRequest)
            return
        }
        
        if err := monitor.CheckSchemaHealth(r.Context(), schema); err != nil {
            http.Error(w, err.Error(), http.StatusServiceUnavailable)
            return
        }
        
        metrics, err := monitor.GetSchemaMetrics(r.Context(), schema)
        if err != nil {
            http.Error(w, err.Error(), http.StatusInternalServerError)
            return
        }
        
        json.NewEncoder(w).Encode(map[string]interface{}{
            "status":  "healthy",
            "schema":  schema,
            "metrics": metrics,
        })
    }
}
```

## Best Practices

### Schema Design

1. **Weak References**: Use external IDs instead of foreign keys
2. **Event-Driven**: Use events for cross-domain communication
3. **Data Caching**: Cache necessary data from other domains
4. **Version Control**: Include version fields for optimistic locking
5. **Clear Boundaries**: Define clear domain boundaries

### Event Management

1. **Event Ordering**: Ensure events are processed in order
2. **Idempotency**: Make event handlers idempotent
3. **Error Handling**: Implement proper error handling and retries
4. **Monitoring**: Monitor event processing lag
5. **Cleanup**: Regularly clean up old processed events

### Reference Management

1. **Freshness**: Keep reference data fresh with regular updates
2. **Validation**: Validate references before use
3. **Fallback**: Have fallback strategies for stale references
4. **Consistency**: Maintain eventual consistency across domains
5. **Monitoring**: Monitor reference data quality

### Performance Considerations

1. **Indexing**: Proper indexes on external ID columns
2. **Batching**: Process events in batches
3. **Connection Pooling**: Use separate pools per schema
4. **Caching**: Cache frequently accessed reference data
5. **Partitioning**: Consider partitioning large event tables

## Consequences

### Positive

- **Independence**: Domains can evolve independently
- **Scalability**: Each domain can scale separately
- **Team Autonomy**: Different teams can work on different domains
- **Deployment**: Independent deployment of domain services
- **Technology Diversity**: Different domains can use different technologies
- **Fault Isolation**: Failures in one domain don't affect others

### Negative

- **Complexity**: Increased system complexity
- **Eventual Consistency**: No immediate consistency across domains
- **Event Management**: Complex event processing and ordering
- **Reference Management**: Additional overhead for maintaining references
- **Debugging**: More complex debugging across domain boundaries
- **Data Duplication**: Some data duplication across domains

## Related Patterns

- **Microservices**: For service-level independence
- **Event Sourcing**: For complete event-driven architecture
- **CQRS**: For separating read/write operations
- **Saga Pattern**: For distributed transaction management
- **Database per Service**: For complete data independence
- **API Gateway**: For unified access to independent services
