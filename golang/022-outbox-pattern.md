# ADR 022: Outbox Pattern Implementation

## Status

**Accepted**

## Context

The Outbox pattern ensures reliable publishing of domain events as part of database transactions. It solves the dual-write problem where we need to update business data and publish events atomically, guaranteeing that events are published if and only if the business transaction succeeds.

### Problem Statement

In microservices architectures, we often need to:

- **Update business data** and **publish events** atomically
- **Guarantee event delivery** without data inconsistency
- **Handle message broker failures** gracefully
- **Maintain event ordering** for domain events
- **Avoid dual-write problems** between database and message broker

### Use Cases

- Publishing domain events after entity state changes
- Triggering downstream processes reliably
- Maintaining event sourcing consistency
- Cross-service communication with guaranteed delivery

## Decision

We will implement the Outbox pattern using:

1. **Transactional outbox table** for atomic event storage
2. **Background publisher** for reliable event delivery
3. **At-least-once delivery** with idempotency handling
4. **Event ordering** preservation per aggregate
5. **Dead letter handling** for failed events

## Implementation

### Core Outbox Framework

```go
package outbox

import (
    "context"
    "database/sql"
    "encoding/json"
    "errors"
    "fmt"
    "log/slog"
    "time"
)

// EventStatus represents the status of an outbox event
type EventStatus string

const (
    EventStatusPending   EventStatus = "pending"
    EventStatusPublished EventStatus = "published"
    EventStatusFailed    EventStatus = "failed"
    EventStatusDeadLetter EventStatus = "dead_letter"
)

// OutboxEvent represents an event stored in the outbox
type OutboxEvent struct {
    ID            string                 `json:"id" db:"id"`
    AggregateID   string                 `json:"aggregate_id" db:"aggregate_id"`
    AggregateType string                 `json:"aggregate_type" db:"aggregate_type"`
    EventType     string                 `json:"event_type" db:"event_type"`
    EventData     json.RawMessage        `json:"event_data" db:"event_data"`
    Metadata      map[string]interface{} `json:"metadata" db:"metadata"`
    Status        EventStatus            `json:"status" db:"status"`
    Version       int64                  `json:"version" db:"version"`
    CreatedAt     time.Time              `json:"created_at" db:"created_at"`
    PublishedAt   *time.Time             `json:"published_at" db:"published_at"`
    FailedAt      *time.Time             `json:"failed_at" db:"failed_at"`
    RetryCount    int                    `json:"retry_count" db:"retry_count"`
    MaxRetries    int                    `json:"max_retries" db:"max_retries"`
    LastError     *string                `json:"last_error" db:"last_error"`
    NextRetryAt   *time.Time             `json:"next_retry_at" db:"next_retry_at"`
}

// DomainEvent defines the interface for domain events
type DomainEvent interface {
    AggregateID() string
    AggregateType() string
    EventType() string
    EventData() interface{}
    Metadata() map[string]interface{}
}

// EventPublisher defines the interface for publishing events
type EventPublisher interface {
    Publish(ctx context.Context, event *OutboxEvent) error
}

// OutboxStore defines the storage interface for outbox events
type OutboxStore interface {
    Save(ctx context.Context, tx *sql.Tx, event *OutboxEvent) error
    SaveBatch(ctx context.Context, tx *sql.Tx, events []*OutboxEvent) error
    GetPendingEvents(ctx context.Context, limit int) ([]*OutboxEvent, error)
    MarkPublished(ctx context.Context, eventID string) error
    MarkFailed(ctx context.Context, eventID string, err error) error
    MarkDeadLetter(ctx context.Context, eventID string) error
    GetEventsByAggregate(ctx context.Context, aggregateType, aggregateID string) ([]*OutboxEvent, error)
}

// Outbox manages domain event publishing
type Outbox struct {
    store     OutboxStore
    publisher EventPublisher
    logger    *slog.Logger
    config    OutboxConfig
}

// OutboxConfig configures the outbox behavior
type OutboxConfig struct {
    MaxRetries      int
    RetryDelay      time.Duration
    BatchSize       int
    PollInterval    time.Duration
    PublishTimeout  time.Duration
}

// NewOutbox creates a new outbox instance
func NewOutbox(
    store OutboxStore,
    publisher EventPublisher,
    logger *slog.Logger,
    config OutboxConfig,
) *Outbox {
    return &Outbox{
        store:     store,
        publisher: publisher,
        logger:    logger,
        config:    config,
    }
}

// SaveEvent saves a domain event to the outbox within a transaction
func (o *Outbox) SaveEvent(ctx context.Context, tx *sql.Tx, event DomainEvent) error {
    return o.SaveEvents(ctx, tx, []DomainEvent{event})
}

// SaveEvents saves multiple domain events to the outbox within a transaction
func (o *Outbox) SaveEvents(ctx context.Context, tx *sql.Tx, events []DomainEvent) error {
    outboxEvents := make([]*OutboxEvent, len(events))
    
    for i, event := range events {
        eventData, err := json.Marshal(event.EventData())
        if err != nil {
            return fmt.Errorf("marshaling event data: %w", err)
        }
        
        outboxEvent := &OutboxEvent{
            ID:            generateEventID(),
            AggregateID:   event.AggregateID(),
            AggregateType: event.AggregateType(),
            EventType:     event.EventType(),
            EventData:     eventData,
            Metadata:      event.Metadata(),
            Status:        EventStatusPending,
            Version:       1,
            CreatedAt:     time.Now(),
            MaxRetries:    o.config.MaxRetries,
        }
        
        outboxEvents[i] = outboxEvent
    }
    
    if err := o.store.SaveBatch(ctx, tx, outboxEvents); err != nil {
        return fmt.Errorf("saving events to outbox: %w", err)
    }
    
    o.logger.InfoContext(ctx, "events saved to outbox", 
        "count", len(events),
        "aggregate_type", events[0].AggregateType(),
        "aggregate_id", events[0].AggregateID())
    
    return nil
}

// PublishPendingEvents publishes pending events from the outbox
func (o *Outbox) PublishPendingEvents(ctx context.Context) error {
    events, err := o.store.GetPendingEvents(ctx, o.config.BatchSize)
    if err != nil {
        return fmt.Errorf("getting pending events: %w", err)
    }
    
    if len(events) == 0 {
        return nil
    }
    
    o.logger.InfoContext(ctx, "publishing outbox events", "count", len(events))
    
    for _, event := range events {
        if err := o.publishEvent(ctx, event); err != nil {
            o.logger.ErrorContext(ctx, "failed to publish event",
                "event_id", event.ID,
                "event_type", event.EventType,
                "error", err)
            continue
        }
    }
    
    return nil
}

// publishEvent publishes a single event
func (o *Outbox) publishEvent(ctx context.Context, event *OutboxEvent) error {
    // Check if event should be retried
    if event.NextRetryAt != nil && time.Now().Before(*event.NextRetryAt) {
        return nil // Not time to retry yet
    }
    
    // Create timeout context for publishing
    publishCtx, cancel := context.WithTimeout(ctx, o.config.PublishTimeout)
    defer cancel()
    
    // Attempt to publish the event
    if err := o.publisher.Publish(publishCtx, event); err != nil {
        return o.handlePublishError(ctx, event, err)
    }
    
    // Mark as published
    if err := o.store.MarkPublished(ctx, event.ID); err != nil {
        o.logger.ErrorContext(ctx, "failed to mark event as published",
            "event_id", event.ID,
            "error", err)
        return err
    }
    
    o.logger.InfoContext(ctx, "event published successfully",
        "event_id", event.ID,
        "event_type", event.EventType,
        "aggregate_id", event.AggregateID)
    
    return nil
}

// handlePublishError handles publishing errors with retry logic
func (o *Outbox) handlePublishError(ctx context.Context, event *OutboxEvent, err error) error {
    event.RetryCount++
    
    if event.RetryCount >= event.MaxRetries {
        // Max retries reached, move to dead letter
        if dlErr := o.store.MarkDeadLetter(ctx, event.ID); dlErr != nil {
            o.logger.ErrorContext(ctx, "failed to mark event as dead letter",
                "event_id", event.ID,
                "error", dlErr)
            return dlErr
        }
        
        o.logger.WarnContext(ctx, "event moved to dead letter queue",
            "event_id", event.ID,
            "retry_count", event.RetryCount,
            "max_retries", event.MaxRetries,
            "error", err)
        
        return nil
    }
    
    // Mark as failed and schedule retry
    if failErr := o.store.MarkFailed(ctx, event.ID, err); failErr != nil {
        o.logger.ErrorContext(ctx, "failed to mark event as failed",
            "event_id", event.ID,
            "error", failErr)
        return failErr
    }
    
    return err
}

// StartPublisher starts the background event publisher
func (o *Outbox) StartPublisher(ctx context.Context) error {
    ticker := time.NewTicker(o.config.PollInterval)
    defer ticker.Stop()
    
    o.logger.InfoContext(ctx, "outbox publisher started", 
        "poll_interval", o.config.PollInterval)
    
    for {
        select {
        case <-ctx.Done():
            o.logger.InfoContext(ctx, "outbox publisher stopped")
            return ctx.Err()
            
        case <-ticker.C:
            if err := o.PublishPendingEvents(ctx); err != nil {
                o.logger.ErrorContext(ctx, "failed to publish pending events",
                    "error", err)
            }
        }
    }
}
```

### PostgreSQL Storage Implementation

```go
package postgres

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/lib/pq"
)

const createOutboxTable = `
CREATE TABLE IF NOT EXISTS outbox_events (
    id UUID PRIMARY KEY,
    aggregate_id VARCHAR(255) NOT NULL,
    aggregate_type VARCHAR(255) NOT NULL,
    event_type VARCHAR(255) NOT NULL,
    event_data JSONB NOT NULL,
    metadata JSONB,
    status VARCHAR(50) NOT NULL,
    version BIGINT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL,
    published_at TIMESTAMP WITH TIME ZONE,
    failed_at TIMESTAMP WITH TIME ZONE,
    retry_count INTEGER NOT NULL DEFAULT 0,
    max_retries INTEGER NOT NULL DEFAULT 3,
    last_error TEXT,
    next_retry_at TIMESTAMP WITH TIME ZONE
);

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_outbox_events_status ON outbox_events(status);
CREATE INDEX IF NOT EXISTS idx_outbox_events_created_at ON outbox_events(created_at);
CREATE INDEX IF NOT EXISTS idx_outbox_events_aggregate ON outbox_events(aggregate_type, aggregate_id);
CREATE INDEX IF NOT EXISTS idx_outbox_events_pending ON outbox_events(status, next_retry_at) 
    WHERE status IN ('pending', 'failed');
CREATE INDEX IF NOT EXISTS idx_outbox_events_retry ON outbox_events(next_retry_at) 
    WHERE status = 'failed' AND next_retry_at IS NOT NULL;
`

// PostgresOutboxStore implements OutboxStore using PostgreSQL
type PostgresOutboxStore struct {
    db *sql.DB
}

// NewPostgresOutboxStore creates a new PostgreSQL outbox store
func NewPostgresOutboxStore(db *sql.DB) (*PostgresOutboxStore, error) {
    if _, err := db.Exec(createOutboxTable); err != nil {
        return nil, fmt.Errorf("creating outbox table: %w", err)
    }
    
    return &PostgresOutboxStore{db: db}, nil
}

// Save saves a single event to the outbox within a transaction
func (s *PostgresOutboxStore) Save(ctx context.Context, tx *sql.Tx, event *OutboxEvent) error {
    return s.SaveBatch(ctx, tx, []*OutboxEvent{event})
}

// SaveBatch saves multiple events to the outbox within a transaction
func (s *PostgresOutboxStore) SaveBatch(ctx context.Context, tx *sql.Tx, events []*OutboxEvent) error {
    if len(events) == 0 {
        return nil
    }
    
    // Prepare batch insert
    query := `
        INSERT INTO outbox_events (
            id, aggregate_id, aggregate_type, event_type, event_data, 
            metadata, status, version, created_at, max_retries
        ) VALUES `
    
    // Build values placeholder
    values := make([]interface{}, 0, len(events)*10)
    placeholders := make([]string, 0, len(events))
    
    for i, event := range events {
        metadataJSON, err := json.Marshal(event.Metadata)
        if err != nil {
            return fmt.Errorf("marshaling metadata for event %d: %w", i, err)
        }
        
        baseIndex := i * 10
        placeholders = append(placeholders, fmt.Sprintf(
            "($%d, $%d, $%d, $%d, $%d, $%d, $%d, $%d, $%d, $%d)",
            baseIndex+1, baseIndex+2, baseIndex+3, baseIndex+4, baseIndex+5,
            baseIndex+6, baseIndex+7, baseIndex+8, baseIndex+9, baseIndex+10,
        ))
        
        values = append(values,
            event.ID, event.AggregateID, event.AggregateType, event.EventType,
            event.EventData, metadataJSON, event.Status, event.Version,
            event.CreatedAt, event.MaxRetries,
        )
    }
    
    query += fmt.Sprintf("%s", fmt.Sprintf("%v", placeholders)[1:len(fmt.Sprintf("%v", placeholders))-1])
    query = query[:len(query)-1] + strings.Join(placeholders, ", ")
    
    _, err := tx.ExecContext(ctx, query, values...)
    if err != nil {
        return fmt.Errorf("inserting outbox events: %w", err)
    }
    
    return nil
}

// GetPendingEvents retrieves pending events for publishing
func (s *PostgresOutboxStore) GetPendingEvents(ctx context.Context, limit int) ([]*OutboxEvent, error) {
    query := `
        SELECT id, aggregate_id, aggregate_type, event_type, event_data, 
               metadata, status, version, created_at, published_at, failed_at,
               retry_count, max_retries, last_error, next_retry_at
        FROM outbox_events 
        WHERE status IN ('pending', 'failed') 
        AND (next_retry_at IS NULL OR next_retry_at <= NOW())
        ORDER BY created_at ASC
        LIMIT $1
        FOR UPDATE SKIP LOCKED
    `
    
    rows, err := s.db.QueryContext(ctx, query, limit)
    if err != nil {
        return nil, fmt.Errorf("querying pending events: %w", err)
    }
    defer rows.Close()
    
    var events []*OutboxEvent
    
    for rows.Next() {
        event, err := s.scanEvent(rows)
        if err != nil {
            return nil, fmt.Errorf("scanning event: %w", err)
        }
        events = append(events, event)
    }
    
    return events, nil
}

// MarkPublished marks an event as published
func (s *PostgresOutboxStore) MarkPublished(ctx context.Context, eventID string) error {
    query := `
        UPDATE outbox_events 
        SET status = 'published', published_at = NOW(), version = version + 1
        WHERE id = $1
    `
    
    result, err := s.db.ExecContext(ctx, query, eventID)
    if err != nil {
        return fmt.Errorf("marking event as published: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return fmt.Errorf("checking rows affected: %w", err)
    }
    
    if rowsAffected == 0 {
        return fmt.Errorf("event not found: %s", eventID)
    }
    
    return nil
}

// MarkFailed marks an event as failed and schedules retry
func (s *PostgresOutboxStore) MarkFailed(ctx context.Context, eventID string, err error) error {
    // Calculate next retry time using exponential backoff
    nextRetryAt := time.Now().Add(calculateRetryDelay(1)) // This would need the current retry count
    
    query := `
        UPDATE outbox_events 
        SET status = 'failed', 
            failed_at = NOW(), 
            retry_count = retry_count + 1,
            last_error = $2,
            next_retry_at = $3,
            version = version + 1
        WHERE id = $1
    `
    
    _, execErr := s.db.ExecContext(ctx, query, eventID, err.Error(), nextRetryAt)
    if execErr != nil {
        return fmt.Errorf("marking event as failed: %w", execErr)
    }
    
    return nil
}

// MarkDeadLetter marks an event as dead letter
func (s *PostgresOutboxStore) MarkDeadLetter(ctx context.Context, eventID string) error {
    query := `
        UPDATE outbox_events 
        SET status = 'dead_letter', version = version + 1
        WHERE id = $1
    `
    
    _, err := s.db.ExecContext(ctx, query, eventID)
    if err != nil {
        return fmt.Errorf("marking event as dead letter: %w", err)
    }
    
    return nil
}

// GetEventsByAggregate retrieves events for a specific aggregate
func (s *PostgresOutboxStore) GetEventsByAggregate(
    ctx context.Context, 
    aggregateType, aggregateID string,
) ([]*OutboxEvent, error) {
    query := `
        SELECT id, aggregate_id, aggregate_type, event_type, event_data, 
               metadata, status, version, created_at, published_at, failed_at,
               retry_count, max_retries, last_error, next_retry_at
        FROM outbox_events 
        WHERE aggregate_type = $1 AND aggregate_id = $2
        ORDER BY created_at ASC
    `
    
    rows, err := s.db.QueryContext(ctx, query, aggregateType, aggregateID)
    if err != nil {
        return nil, fmt.Errorf("querying events by aggregate: %w", err)
    }
    defer rows.Close()
    
    var events []*OutboxEvent
    
    for rows.Next() {
        event, err := s.scanEvent(rows)
        if err != nil {
            return nil, fmt.Errorf("scanning event: %w", err)
        }
        events = append(events, event)
    }
    
    return events, nil
}

// scanEvent scans a database row into an OutboxEvent
func (s *PostgresOutboxStore) scanEvent(scanner interface{ Scan(...interface{}) error }) (*OutboxEvent, error) {
    var event OutboxEvent
    var metadataJSON []byte
    var publishedAt, failedAt, nextRetryAt sql.NullTime
    var lastError sql.NullString
    
    err := scanner.Scan(
        &event.ID, &event.AggregateID, &event.AggregateType, &event.EventType,
        &event.EventData, &metadataJSON, &event.Status, &event.Version,
        &event.CreatedAt, &publishedAt, &failedAt, &event.RetryCount,
        &event.MaxRetries, &lastError, &nextRetryAt,
    )
    if err != nil {
        return nil, err
    }
    
    if len(metadataJSON) > 0 {
        if err := json.Unmarshal(metadataJSON, &event.Metadata); err != nil {
            return nil, fmt.Errorf("unmarshaling metadata: %w", err)
        }
    }
    
    if publishedAt.Valid {
        event.PublishedAt = &publishedAt.Time
    }
    if failedAt.Valid {
        event.FailedAt = &failedAt.Time
    }
    if nextRetryAt.Valid {
        event.NextRetryAt = &nextRetryAt.Time
    }
    if lastError.Valid {
        event.LastError = &lastError.String
    }
    
    return &event, nil
}

// calculateRetryDelay calculates the delay for the next retry
func calculateRetryDelay(retryCount int) time.Duration {
    baseDelay := time.Minute
    multiplier := 1 << uint(retryCount-1) // Exponential backoff: 1, 2, 4, 8, ...
    return baseDelay * time.Duration(multiplier)
}
```

### User Service Integration Example

```go
package user

import (
    "context"
    "database/sql"
    "fmt"
    "time"
)

// UserCreatedEvent represents a user creation domain event
type UserCreatedEvent struct {
    userID    string
    email     string
    name      string
    timestamp time.Time
    metadata  map[string]interface{}
}

func (e UserCreatedEvent) AggregateID() string {
    return e.userID
}

func (e UserCreatedEvent) AggregateType() string {
    return "user"
}

func (e UserCreatedEvent) EventType() string {
    return "user.created"
}

func (e UserCreatedEvent) EventData() interface{} {
    return map[string]interface{}{
        "user_id":   e.userID,
        "email":     e.email,
        "name":      e.name,
        "timestamp": e.timestamp,
    }
}

func (e UserCreatedEvent) Metadata() map[string]interface{} {
    return e.metadata
}

// UserUpdatedEvent represents a user update domain event
type UserUpdatedEvent struct {
    userID     string
    changes    map[string]interface{}
    timestamp  time.Time
    metadata   map[string]interface{}
}

func (e UserUpdatedEvent) AggregateID() string {
    return e.userID
}

func (e UserUpdatedEvent) AggregateType() string {
    return "user"
}

func (e UserUpdatedEvent) EventType() string {
    return "user.updated"
}

func (e UserUpdatedEvent) EventData() interface{} {
    return map[string]interface{}{
        "user_id":   e.userID,
        "changes":   e.changes,
        "timestamp": e.timestamp,
    }
}

func (e UserUpdatedEvent) Metadata() map[string]interface{} {
    return e.metadata
}

// UserService with outbox integration
type UserService struct {
    db     *sql.DB
    outbox *Outbox
    logger *slog.Logger
}

// CreateUser creates a new user and publishes domain event
func (s *UserService) CreateUser(ctx context.Context, req CreateUserRequest) (*User, error) {
    // Start transaction
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("starting transaction: %w", err)
    }
    defer tx.Rollback() // Will be ignored if committed
    
    // Create user entity
    user := &User{
        ID:        generateUserID(),
        Email:     req.Email,
        Name:      req.Name,
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
    }
    
    // Insert user into database
    if err := s.insertUser(ctx, tx, user); err != nil {
        return nil, fmt.Errorf("inserting user: %w", err)
    }
    
    // Create domain event
    event := UserCreatedEvent{
        userID:    user.ID,
        email:     user.Email,
        name:      user.Name,
        timestamp: user.CreatedAt,
        metadata: map[string]interface{}{
            "source":    "user-service",
            "version":   "1.0",
            "client_ip": getClientIP(ctx),
        },
    }
    
    // Save event to outbox (within the same transaction)
    if err := s.outbox.SaveEvent(ctx, tx, event); err != nil {
        return nil, fmt.Errorf("saving event to outbox: %w", err)
    }
    
    // Commit transaction (atomically saves user and event)
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("committing transaction: %w", err)
    }
    
    s.logger.InfoContext(ctx, "user created successfully",
        "user_id", user.ID,
        "email", user.Email)
    
    return user, nil
}

// UpdateUser updates an existing user and publishes domain event
func (s *UserService) UpdateUser(ctx context.Context, userID string, req UpdateUserRequest) (*User, error) {
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("starting transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Get existing user
    user, err := s.getUserByIDForUpdate(ctx, tx, userID)
    if err != nil {
        return nil, fmt.Errorf("getting user: %w", err)
    }
    
    // Track changes
    changes := make(map[string]interface{})
    
    // Apply updates
    if req.Email != "" && req.Email != user.Email {
        changes["email"] = map[string]string{
            "from": user.Email,
            "to":   req.Email,
        }
        user.Email = req.Email
    }
    
    if req.Name != "" && req.Name != user.Name {
        changes["name"] = map[string]string{
            "from": user.Name,
            "to":   req.Name,
        }
        user.Name = req.Name
    }
    
    if len(changes) == 0 {
        // No changes to apply
        return user, nil
    }
    
    // Update timestamp
    user.UpdatedAt = time.Now()
    
    // Update user in database
    if err := s.updateUser(ctx, tx, user); err != nil {
        return nil, fmt.Errorf("updating user: %w", err)
    }
    
    // Create domain event
    event := UserUpdatedEvent{
        userID:    user.ID,
        changes:   changes,
        timestamp: user.UpdatedAt,
        metadata: map[string]interface{}{
            "source":    "user-service",
            "version":   "1.0",
            "client_ip": getClientIP(ctx),
        },
    }
    
    // Save event to outbox
    if err := s.outbox.SaveEvent(ctx, tx, event); err != nil {
        return nil, fmt.Errorf("saving event to outbox: %w", err)
    }
    
    // Commit transaction
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("committing transaction: %w", err)
    }
    
    s.logger.InfoContext(ctx, "user updated successfully",
        "user_id", user.ID,
        "changes", changes)
    
    return user, nil
}

// Helper methods
func (s *UserService) insertUser(ctx context.Context, tx *sql.Tx, user *User) error {
    query := `
        INSERT INTO users (id, email, name, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5)
    `
    
    _, err := tx.ExecContext(ctx, query,
        user.ID, user.Email, user.Name, user.CreatedAt, user.UpdatedAt)
    
    return err
}

func (s *UserService) updateUser(ctx context.Context, tx *sql.Tx, user *User) error {
    query := `
        UPDATE users 
        SET email = $2, name = $3, updated_at = $4
        WHERE id = $1
    `
    
    _, err := tx.ExecContext(ctx, query,
        user.ID, user.Email, user.Name, user.UpdatedAt)
    
    return err
}

func (s *UserService) getUserByIDForUpdate(ctx context.Context, tx *sql.Tx, userID string) (*User, error) {
    query := `
        SELECT id, email, name, created_at, updated_at
        FROM users 
        WHERE id = $1
        FOR UPDATE
    `
    
    var user User
    err := tx.QueryRowContext(ctx, query, userID).Scan(
        &user.ID, &user.Email, &user.Name, &user.CreatedAt, &user.UpdatedAt,
    )
    
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, fmt.Errorf("user not found: %s", userID)
        }
        return nil, err
    }
    
    return &user, nil
}
```

### Message Broker Publisher

```go
package publisher

import (
    "context"
    "encoding/json"
    "fmt"
    
    "github.com/nats-io/nats.go"
)

// NATSEventPublisher implements EventPublisher using NATS
type NATSEventPublisher struct {
    conn   *nats.Conn
    logger *slog.Logger
}

// NewNATSEventPublisher creates a new NATS event publisher
func NewNATSEventPublisher(conn *nats.Conn, logger *slog.Logger) *NATSEventPublisher {
    return &NATSEventPublisher{
        conn:   conn,
        logger: logger,
    }
}

// Publish publishes an event to NATS
func (p *NATSEventPublisher) Publish(ctx context.Context, event *OutboxEvent) error {
    // Create message payload
    message := EventMessage{
        ID:            event.ID,
        AggregateID:   event.AggregateID,
        AggregateType: event.AggregateType,
        EventType:     event.EventType,
        EventData:     event.EventData,
        Metadata:      event.Metadata,
        Version:       event.Version,
        Timestamp:     event.CreatedAt,
    }
    
    // Marshal message
    messageData, err := json.Marshal(message)
    if err != nil {
        return fmt.Errorf("marshaling event message: %w", err)
    }
    
    // Determine subject based on event type
    subject := fmt.Sprintf("events.%s.%s", event.AggregateType, event.EventType)
    
    // Publish to NATS
    if err := p.conn.Publish(subject, messageData); err != nil {
        return fmt.Errorf("publishing to NATS: %w", err)
    }
    
    p.logger.InfoContext(ctx, "event published to NATS",
        "event_id", event.ID,
        "subject", subject,
        "event_type", event.EventType)
    
    return nil
}

// EventMessage represents the published event message format
type EventMessage struct {
    ID            string                 `json:"id"`
    AggregateID   string                 `json:"aggregate_id"`
    AggregateType string                 `json:"aggregate_type"`
    EventType     string                 `json:"event_type"`
    EventData     json.RawMessage        `json:"event_data"`
    Metadata      map[string]interface{} `json:"metadata"`
    Version       int64                  `json:"version"`
    Timestamp     time.Time              `json:"timestamp"`
}
```

## Testing

```go
func TestOutbox_SaveAndPublishEvents(t *testing.T) {
    // Setup test dependencies
    db := setupTestDB(t)
    store, err := NewPostgresOutboxStore(db)
    require.NoError(t, err)
    
    publisher := &MockEventPublisher{}
    logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
    
    config := OutboxConfig{
        MaxRetries:     3,
        RetryDelay:     time.Second,
        BatchSize:      10,
        PollInterval:   time.Second,
        PublishTimeout: 30 * time.Second,
    }
    
    outbox := NewOutbox(store, publisher, logger, config)
    
    t.Run("save and publish event", func(t *testing.T) {
        ctx := context.Background()
        
        // Create test event
        event := &TestDomainEvent{
            aggregateID:   "user-123",
            aggregateType: "user",
            eventType:     "user.created",
            eventData: map[string]interface{}{
                "email": "test@example.com",
                "name":  "Test User",
            },
            metadata: map[string]interface{}{
                "source": "test",
            },
        }
        
        // Start transaction
        tx, err := db.BeginTx(ctx, nil)
        require.NoError(t, err)
        defer tx.Rollback()
        
        // Save event to outbox
        err = outbox.SaveEvent(ctx, tx, event)
        require.NoError(t, err)
        
        // Commit transaction
        err = tx.Commit()
        require.NoError(t, err)
        
        // Publish pending events
        err = outbox.PublishPendingEvents(ctx)
        require.NoError(t, err)
        
        // Verify event was published
        assert.Equal(t, 1, publisher.PublishCount)
        
        publishedEvent := publisher.LastEvent
        assert.Equal(t, event.AggregateID(), publishedEvent.AggregateID)
        assert.Equal(t, event.EventType(), publishedEvent.EventType)
    })
    
    t.Run("retry failed events", func(t *testing.T) {
        ctx := context.Background()
        
        // Configure publisher to fail
        publisher.ShouldFail = true
        publisher.Reset()
        
        event := &TestDomainEvent{
            aggregateID:   "user-456",
            aggregateType: "user",
            eventType:     "user.updated",
            eventData:     map[string]interface{}{"name": "Updated User"},
        }
        
        tx, err := db.BeginTx(ctx, nil)
        require.NoError(t, err)
        
        err = outbox.SaveEvent(ctx, tx, event)
        require.NoError(t, err)
        
        err = tx.Commit()
        require.NoError(t, err)
        
        // First attempt should fail
        err = outbox.PublishPendingEvents(ctx)
        require.NoError(t, err) // No error returned, but event should be marked as failed
        
        assert.Equal(t, 1, publisher.PublishCount)
        
        // Configure publisher to succeed
        publisher.ShouldFail = false
        
        // Retry should succeed
        err = outbox.PublishPendingEvents(ctx)
        require.NoError(t, err)
        
        assert.Equal(t, 2, publisher.PublishCount)
    })
}

// TestDomainEvent for testing
type TestDomainEvent struct {
    aggregateID   string
    aggregateType string
    eventType     string
    eventData     map[string]interface{}
    metadata      map[string]interface{}
}

func (e *TestDomainEvent) AggregateID() string   { return e.aggregateID }
func (e *TestDomainEvent) AggregateType() string { return e.aggregateType }
func (e *TestDomainEvent) EventType() string     { return e.eventType }
func (e *TestDomainEvent) EventData() interface{} { return e.eventData }
func (e *TestDomainEvent) Metadata() map[string]interface{} { return e.metadata }

// MockEventPublisher for testing
type MockEventPublisher struct {
    ShouldFail   bool
    PublishCount int
    LastEvent    *OutboxEvent
}

func (m *MockEventPublisher) Publish(ctx context.Context, event *OutboxEvent) error {
    m.PublishCount++
    m.LastEvent = event
    
    if m.ShouldFail {
        return errors.New("publisher failure")
    }
    
    return nil
}

func (m *MockEventPublisher) Reset() {
    m.PublishCount = 0
    m.LastEvent = nil
    m.ShouldFail = false
}
```

## Best Practices

### Do

- ✅ Always save events within the same transaction as business data
- ✅ Design idempotent event handlers in downstream services
- ✅ Implement proper retry logic with exponential backoff
- ✅ Monitor dead letter queues for failed events
- ✅ Include relevant metadata in events for debugging
- ✅ Use ordered processing per aggregate
- ✅ Implement event schema versioning

### Don't

- ❌ Save events outside of business transactions
- ❌ Ignore failed events in dead letter queue
- ❌ Create events that are too large for message brokers
- ❌ Skip event ordering for related operations
- ❌ Expose internal domain details in event data

## Consequences

### Positive

- **Atomicity**: Guaranteed consistency between business data and events
- **Reliability**: At-least-once delivery with retry mechanisms
- **Decoupling**: Clean separation between business logic and event publishing
- **Observability**: Complete audit trail of domain events
- **Scalability**: Asynchronous event processing

### Negative

- **Complexity**: Additional infrastructure for outbox management
- **Storage**: Extra database table and storage requirements
- **Latency**: Slight delay in event delivery due to polling
- **Duplication**: Potential duplicate events requiring idempotent handling

## References

- [Outbox Pattern](https://microservices.io/patterns/data/transactional-outbox.html)
- [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)
- [Domain Events](https://martinfowler.com/eaaDev/DomainEvent.html)
- [Saga Pattern](https://microservices.io/patterns/data/saga.html)
