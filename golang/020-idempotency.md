# ADR 020: Idempotency Implementation

## Status

**Accepted**

## Context

Idempotency ensures that repeated requests with the same parameters produce the same result without side effects. This is crucial for distributed systems to handle network failures, retries, and duplicate requests safely.

### Problem Statement

In distributed systems, we encounter:

- **Network failures**: Clients retrying failed requests
- **Duplicate processing**: Multiple instances processing the same request
- **Financial operations**: Preventing double charges or withdrawals
- **External API calls**: Avoiding duplicate expensive operations
- **Message queue processing**: Handling message redelivery

### Definition

An operation is idempotent if executing it multiple times with the same input produces the same output:

```
f(key, request) → response

Where:
- f: idempotent function
- key: idempotency key (unique identifier)
- request: input data
- response: deterministic output
```

## Decision

We will implement idempotency using:

1. **Idempotency keys** for operation identification
2. **Request fingerprinting** for validation
3. **Response caching** for consistency
4. **Database constraints** for enforcement
5. **TTL-based cleanup** for storage management

## Implementation

### Core Idempotency Pattern

```go
package idempotency

import (
    "context"
    "crypto/sha256"
    "encoding/hex"
    "encoding/json"
    "errors"
    "fmt"
    "time"
)

// IdempotencyKey represents an idempotency operation
type IdempotencyKey struct {
    Key           string                 `json:"key" db:"key"`
    RequestHash   string                 `json:"request_hash" db:"request_hash"`
    ResponseData  json.RawMessage        `json:"response_data" db:"response_data"`
    Status        IdempotencyStatus      `json:"status" db:"status"`
    CreatedAt     time.Time              `json:"created_at" db:"created_at"`
    CompletedAt   *time.Time             `json:"completed_at" db:"completed_at"`
    ExpiresAt     time.Time              `json:"expires_at" db:"expires_at"`
    ErrorMessage  *string                `json:"error_message" db:"error_message"`
    RetryCount    int                    `json:"retry_count" db:"retry_count"`
}

// IdempotencyStatus represents the status of an idempotent operation
type IdempotencyStatus string

const (
    StatusPending   IdempotencyStatus = "pending"
    StatusCompleted IdempotencyStatus = "completed"
    StatusFailed    IdempotencyStatus = "failed"
)

var (
    ErrKeyExists        = errors.New("idempotency key already exists")
    ErrRequestMismatch  = errors.New("request data does not match stored request")
    ErrOperationPending = errors.New("operation is still pending")
    ErrOperationFailed  = errors.New("operation failed")
)

// IdempotencyManager handles idempotent operations
type IdempotencyManager struct {
    store IdempotencyStore
    ttl   time.Duration
}

// IdempotencyStore defines the storage interface
type IdempotencyStore interface {
    Create(ctx context.Context, key *IdempotencyKey) error
    Get(ctx context.Context, keyStr string) (*IdempotencyKey, error)
    Update(ctx context.Context, key *IdempotencyKey) error
    Delete(ctx context.Context, keyStr string) error
    Cleanup(ctx context.Context, before time.Time) error
}

// NewIdempotencyManager creates a new idempotency manager
func NewIdempotencyManager(store IdempotencyStore, ttl time.Duration) *IdempotencyManager {
    return &IdempotencyManager{
        store: store,
        ttl:   ttl,
    }
}

// Execute performs an idempotent operation
func (im *IdempotencyManager) Execute(
    ctx context.Context,
    key string,
    request interface{},
    operation func(ctx context.Context) (interface{}, error),
) (interface{}, error) {
    // Generate request hash for validation
    requestHash, err := im.hashRequest(request)
    if err != nil {
        return nil, fmt.Errorf("hashing request: %w", err)
    }
    
    // Try to get existing operation
    existing, err := im.store.Get(ctx, key)
    if err != nil && !errors.Is(err, ErrNotFound) {
        return nil, fmt.Errorf("checking existing operation: %w", err)
    }
    
    // If operation exists, validate and return
    if existing != nil {
        return im.handleExisting(ctx, existing, requestHash)
    }
    
    // Create new idempotency record
    idempotencyKey := &IdempotencyKey{
        Key:         key,
        RequestHash: requestHash,
        Status:      StatusPending,
        CreatedAt:   time.Now(),
        ExpiresAt:   time.Now().Add(im.ttl),
    }
    
    if err := im.store.Create(ctx, idempotencyKey); err != nil {
        if errors.Is(err, ErrKeyExists) {
            // Race condition: another process created the key
            return im.Execute(ctx, key, request, operation)
        }
        return nil, fmt.Errorf("creating idempotency record: %w", err)
    }
    
    // Execute the operation
    result, err := operation(ctx)
    
    // Update the record with result
    now := time.Now()
    idempotencyKey.CompletedAt = &now
    
    if err != nil {
        idempotencyKey.Status = StatusFailed
        errMsg := err.Error()
        idempotencyKey.ErrorMessage = &errMsg
        idempotencyKey.RetryCount++
    } else {
        idempotencyKey.Status = StatusCompleted
        responseData, marshalErr := json.Marshal(result)
        if marshalErr != nil {
            return nil, fmt.Errorf("marshaling response: %w", marshalErr)
        }
        idempotencyKey.ResponseData = responseData
    }
    
    if updateErr := im.store.Update(ctx, idempotencyKey); updateErr != nil {
        // Log error but don't fail the operation if it succeeded
        fmt.Printf("Failed to update idempotency record: %v\n", updateErr)
    }
    
    return result, err
}

// handleExisting handles an existing idempotency operation
func (im *IdempotencyManager) handleExisting(
    ctx context.Context,
    existing *IdempotencyKey,
    requestHash string,
) (interface{}, error) {
    // Validate request hash
    if existing.RequestHash != requestHash {
        return nil, ErrRequestMismatch
    }
    
    switch existing.Status {
    case StatusPending:
        return nil, ErrOperationPending
        
    case StatusFailed:
        if existing.ErrorMessage != nil {
            return nil, fmt.Errorf("%w: %s", ErrOperationFailed, *existing.ErrorMessage)
        }
        return nil, ErrOperationFailed
        
    case StatusCompleted:
        var result interface{}
        if err := json.Unmarshal(existing.ResponseData, &result); err != nil {
            return nil, fmt.Errorf("unmarshaling cached response: %w", err)
        }
        return result, nil
        
    default:
        return nil, fmt.Errorf("unknown status: %s", existing.Status)
    }
}

// hashRequest creates a hash of the request for validation
func (im *IdempotencyManager) hashRequest(request interface{}) (string, error) {
    data, err := json.Marshal(request)
    if err != nil {
        return "", err
    }
    
    hash := sha256.Sum256(data)
    return hex.EncodeToString(hash[:]), nil
}
```

### Database Implementation

```go
package postgres

import (
    "context"
    "database/sql"
    "errors"
    "time"
    
    "github.com/lib/pq"
)

const createIdempotencyTable = `
CREATE TABLE IF NOT EXISTS idempotency_keys (
    key TEXT PRIMARY KEY,
    request_hash TEXT NOT NULL,
    response_data JSONB,
    status TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL,
    completed_at TIMESTAMP WITH TIME ZONE,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    error_message TEXT,
    retry_count INTEGER DEFAULT 0
);

-- Index for cleanup operations
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_expires_at 
ON idempotency_keys(expires_at);

-- Index for status queries
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_status 
ON idempotency_keys(status);
`

// PostgresIdempotencyStore implements IdempotencyStore using PostgreSQL
type PostgresIdempotencyStore struct {
    db *sql.DB
}

// NewPostgresIdempotencyStore creates a new PostgreSQL idempotency store
func NewPostgresIdempotencyStore(db *sql.DB) (*PostgresIdempotencyStore, error) {
    if _, err := db.Exec(createIdempotencyTable); err != nil {
        return nil, fmt.Errorf("creating idempotency table: %w", err)
    }
    
    return &PostgresIdempotencyStore{db: db}, nil
}

// Create creates a new idempotency key
func (s *PostgresIdempotencyStore) Create(
    ctx context.Context, 
    key *IdempotencyKey,
) error {
    query := `
        INSERT INTO idempotency_keys (
            key, request_hash, status, created_at, expires_at
        ) VALUES ($1, $2, $3, $4, $5)
    `
    
    _, err := s.db.ExecContext(ctx, query,
        key.Key,
        key.RequestHash,
        key.Status,
        key.CreatedAt,
        key.ExpiresAt,
    )
    
    if err != nil {
        if pqErr, ok := err.(*pq.Error); ok && pqErr.Code == "23505" {
            return ErrKeyExists
        }
        return err
    }
    
    return nil
}

// Get retrieves an idempotency key
func (s *PostgresIdempotencyStore) Get(
    ctx context.Context, 
    keyStr string,
) (*IdempotencyKey, error) {
    query := `
        SELECT key, request_hash, response_data, status, created_at, 
               completed_at, expires_at, error_message, retry_count
        FROM idempotency_keys 
        WHERE key = $1 AND expires_at > NOW()
    `
    
    var key IdempotencyKey
    var responseData sql.NullString
    var completedAt sql.NullTime
    var errorMessage sql.NullString
    
    err := s.db.QueryRowContext(ctx, query, keyStr).Scan(
        &key.Key,
        &key.RequestHash,
        &responseData,
        &key.Status,
        &key.CreatedAt,
        &completedAt,
        &key.ExpiresAt,
        &errorMessage,
        &key.RetryCount,
    )
    
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return nil, ErrNotFound
        }
        return nil, err
    }
    
    if responseData.Valid {
        key.ResponseData = json.RawMessage(responseData.String)
    }
    
    if completedAt.Valid {
        key.CompletedAt = &completedAt.Time
    }
    
    if errorMessage.Valid {
        key.ErrorMessage = &errorMessage.String
    }
    
    return &key, nil
}

// Update updates an idempotency key
func (s *PostgresIdempotencyStore) Update(
    ctx context.Context, 
    key *IdempotencyKey,
) error {
    query := `
        UPDATE idempotency_keys 
        SET response_data = $2, status = $3, completed_at = $4, 
            error_message = $5, retry_count = $6
        WHERE key = $1
    `
    
    var responseData interface{}
    if key.ResponseData != nil {
        responseData = string(key.ResponseData)
    }
    
    _, err := s.db.ExecContext(ctx, query,
        key.Key,
        responseData,
        key.Status,
        key.CompletedAt,
        key.ErrorMessage,
        key.RetryCount,
    )
    
    return err
}

// Cleanup removes expired idempotency keys
func (s *PostgresIdempotencyStore) Cleanup(
    ctx context.Context, 
    before time.Time,
) error {
    query := `DELETE FROM idempotency_keys WHERE expires_at < $1`
    _, err := s.db.ExecContext(ctx, query, before)
    return err
}
```

### Payment Service Example

```go
package payment

import (
    "context"
    "fmt"
    "time"
)

// PaymentRequest represents a payment request
type PaymentRequest struct {
    Amount      int64  `json:"amount"`
    Currency    string `json:"currency"`
    CustomerID  string `json:"customer_id"`
    Description string `json:"description"`
}

// PaymentResponse represents a payment response
type PaymentResponse struct {
    PaymentID   string    `json:"payment_id"`
    Status      string    `json:"status"`
    Amount      int64     `json:"amount"`
    Currency    string    `json:"currency"`
    ProcessedAt time.Time `json:"processed_at"`
}

// PaymentService handles payment processing with idempotency
type PaymentService struct {
    idempotency *IdempotencyManager
    processor   PaymentProcessor
}

// PaymentProcessor defines the payment processing interface
type PaymentProcessor interface {
    ProcessPayment(ctx context.Context, req PaymentRequest) (*PaymentResponse, error)
}

// NewPaymentService creates a new payment service
func NewPaymentService(
    idempotency *IdempotencyManager,
    processor PaymentProcessor,
) *PaymentService {
    return &PaymentService{
        idempotency: idempotency,
        processor:   processor,
    }
}

// ProcessPayment processes a payment idempotently
func (ps *PaymentService) ProcessPayment(
    ctx context.Context,
    idempotencyKey string,
    req PaymentRequest,
) (*PaymentResponse, error) {
    // Validate idempotency key format
    if idempotencyKey == "" {
        return nil, errors.New("idempotency key is required")
    }
    
    // Execute idempotent operation
    result, err := ps.idempotency.Execute(
        ctx,
        fmt.Sprintf("payment:%s", idempotencyKey),
        req,
        func(ctx context.Context) (interface{}, error) {
            return ps.processor.ProcessPayment(ctx, req)
        },
    )
    
    if err != nil {
        return nil, err
    }
    
    // Type assertion (in production, use proper type-safe methods)
    response, ok := result.(*PaymentResponse)
    if !ok {
        return nil, errors.New("invalid response type")
    }
    
    return response, nil
}
```

### HTTP Handler Implementation

```go
package handler

import (
    "encoding/json"
    "net/http"
    
    "github.com/google/uuid"
)

// PaymentHandler handles payment HTTP requests
type PaymentHandler struct {
    paymentService *PaymentService
}

// CreatePayment handles payment creation with idempotency
func (h *PaymentHandler) CreatePayment(w http.ResponseWriter, r *http.Request) {
    // Extract idempotency key from header
    idempotencyKey := r.Header.Get("Idempotency-Key")
    if idempotencyKey == "" {
        // Generate a unique key if not provided (optional)
        idempotencyKey = uuid.New().String()
    }
    
    // Parse request
    var req PaymentRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "Invalid request body", http.StatusBadRequest)
        return
    }
    
    // Process payment
    response, err := h.paymentService.ProcessPayment(r.Context(), idempotencyKey, req)
    if err != nil {
        switch {
        case errors.Is(err, ErrRequestMismatch):
            http.Error(w, "Request data mismatch", http.StatusConflict)
        case errors.Is(err, ErrOperationPending):
            http.Error(w, "Operation in progress", http.StatusAccepted)
        case errors.Is(err, ErrOperationFailed):
            http.Error(w, "Operation failed", http.StatusUnprocessableEntity)
        default:
            http.Error(w, "Internal server error", http.StatusInternalServerError)
        }
        return
    }
    
    // Return successful response
    w.Header().Set("Content-Type", "application/json")
    w.Header().Set("Idempotency-Key", idempotencyKey)
    json.NewEncoder(w).Encode(response)
}
```

### Redis Implementation for High Performance

```go
package redis

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/go-redis/redis/v8"
)

// RedisIdempotencyStore implements IdempotencyStore using Redis
type RedisIdempotencyStore struct {
    client *redis.Client
    prefix string
}

// NewRedisIdempotencyStore creates a new Redis idempotency store
func NewRedisIdempotencyStore(client *redis.Client, prefix string) *RedisIdempotencyStore {
    return &RedisIdempotencyStore{
        client: client,
        prefix: prefix,
    }
}

// Create creates a new idempotency key with NX (not exists) condition
func (s *RedisIdempotencyStore) Create(
    ctx context.Context, 
    key *IdempotencyKey,
) error {
    redisKey := s.getRedisKey(key.Key)
    
    data, err := json.Marshal(key)
    if err != nil {
        return fmt.Errorf("marshaling key: %w", err)
    }
    
    // Use SET with NX (only if not exists) and EX (expiration)
    ttl := time.Until(key.ExpiresAt)
    success, err := s.client.SetNX(ctx, redisKey, data, ttl).Result()
    if err != nil {
        return fmt.Errorf("setting key in Redis: %w", err)
    }
    
    if !success {
        return ErrKeyExists
    }
    
    return nil
}

// Get retrieves an idempotency key
func (s *RedisIdempotencyStore) Get(
    ctx context.Context, 
    keyStr string,
) (*IdempotencyKey, error) {
    redisKey := s.getRedisKey(keyStr)
    
    data, err := s.client.Get(ctx, redisKey).Result()
    if err != nil {
        if errors.Is(err, redis.Nil) {
            return nil, ErrNotFound
        }
        return nil, fmt.Errorf("getting key from Redis: %w", err)
    }
    
    var key IdempotencyKey
    if err := json.Unmarshal([]byte(data), &key); err != nil {
        return nil, fmt.Errorf("unmarshaling key: %w", err)
    }
    
    return &key, nil
}

// Update updates an idempotency key while preserving TTL
func (s *RedisIdempotencyStore) Update(
    ctx context.Context, 
    key *IdempotencyKey,
) error {
    redisKey := s.getRedisKey(key.Key)
    
    data, err := json.Marshal(key)
    if err != nil {
        return fmt.Errorf("marshaling key: %w", err)
    }
    
    // Get current TTL to preserve it
    ttl, err := s.client.TTL(ctx, redisKey).Result()
    if err != nil {
        return fmt.Errorf("getting TTL: %w", err)
    }
    
    // Update with preserved TTL
    err = s.client.Set(ctx, redisKey, data, ttl).Err()
    if err != nil {
        return fmt.Errorf("updating key in Redis: %w", err)
    }
    
    return nil
}

func (s *RedisIdempotencyStore) getRedisKey(key string) string {
    return fmt.Sprintf("%s:idempotency:%s", s.prefix, key)
}
```

## Testing

```go
func TestIdempotencyManager_Execute(t *testing.T) {
    store := &MockIdempotencyStore{}
    manager := NewIdempotencyManager(store, time.Hour)
    
    tests := []struct {
        name        string
        key         string
        request     interface{}
        setupMock   func(*MockIdempotencyStore)
        expectError bool
        expectCall  bool
    }{
        {
            name:    "first execution",
            key:     "test-key-1",
            request: map[string]string{"amount": "100"},
            setupMock: func(m *MockIdempotencyStore) {
                m.On("Get", mock.Anything, "test-key-1").Return(nil, ErrNotFound)
                m.On("Create", mock.Anything, mock.AnythingOfType("*IdempotencyKey")).Return(nil)
                m.On("Update", mock.Anything, mock.AnythingOfType("*IdempotencyKey")).Return(nil)
            },
            expectCall: true,
        },
        {
            name:    "duplicate execution - completed",
            key:     "test-key-2",
            request: map[string]string{"amount": "100"},
            setupMock: func(m *MockIdempotencyStore) {
                existing := &IdempotencyKey{
                    Key:          "test-key-2",
                    RequestHash:  "hash",
                    Status:       StatusCompleted,
                    ResponseData: json.RawMessage(`{"result": "success"}`),
                }
                m.On("Get", mock.Anything, "test-key-2").Return(existing, nil)
            },
            expectCall: false,
        },
        {
            name:    "request mismatch",
            key:     "test-key-3",
            request: map[string]string{"amount": "200"},
            setupMock: func(m *MockIdempotencyStore) {
                existing := &IdempotencyKey{
                    Key:         "test-key-3",
                    RequestHash: "different-hash",
                    Status:      StatusCompleted,
                }
                m.On("Get", mock.Anything, "test-key-3").Return(existing, nil)
            },
            expectError: true,
            expectCall:  false,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            store.Reset()
            tt.setupMock(store)
            
            callCount := 0
            operation := func(ctx context.Context) (interface{}, error) {
                callCount++
                return map[string]string{"result": "success"}, nil
            }
            
            result, err := manager.Execute(context.Background(), tt.key, tt.request, operation)
            
            if tt.expectError {
                assert.Error(t, err)
            } else {
                assert.NoError(t, err)
                assert.NotNil(t, result)
            }
            
            if tt.expectCall {
                assert.Equal(t, 1, callCount)
            } else {
                assert.Equal(t, 0, callCount)
            }
            
            store.AssertExpectations(t)
        })
    }
}
```

## Best Practices

### Do

- ✅ Use meaningful idempotency keys (UUIDs, request IDs)
- ✅ Include request hash validation
- ✅ Set appropriate TTL for cleanup
- ✅ Handle race conditions gracefully
- ✅ Use database constraints for enforcement
- ✅ Implement proper error handling
- ✅ Cache responses for completed operations

### Don't

- ❌ Use predictable or sequential keys
- ❌ Store large response payloads indefinitely
- ❌ Ignore request validation
- ❌ Make operations non-deterministic
- ❌ Skip TTL configuration

## Consequences

### Positive

- **Reliability**: Prevents duplicate processing
- **Consistency**: Deterministic operation results
- **Client Safety**: Safe retry mechanisms
- **Financial Safety**: Prevents double charges
- **Operational Safety**: Reduces support incidents

### Negative

- **Storage Overhead**: Additional table/cache storage
- **Latency**: Extra validation step
- **Complexity**: Additional error handling paths
- **Cleanup**: TTL management required

## References

- [Idempotent REST APIs](https://restfulapi.net/idempotent-rest-apis/)
- [Stripe Idempotency](https://stripe.com/docs/api/idempotent_requests)
- [AWS API Idempotency](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/Run_Instance_Idempotency.html)

If the idempotency key does not exists:

1. perform the idempotent operation
2. save the request and response

Ideally, each steps should be designed as idempotent to avoid complexity.

Idempotency is not the same as distributed locking. To achieve idempotency, we also need to implement locking to ensure that

1. the same operation is not conducted twice
2. access to the same resource is locked by a mutex
3. the request must match in order to return an already completed operation 

## Decision

### Using redis

Redis is a suitable option, since it is distributed and fast.

We use a distributed cache storage when the idempotent operation is an external call to a service that doesn't implement idempotency.

### Using postgres

For resource creation that resides in database, we can just set a unique constraint in the database.

### SLA

We will store the successful idempotency keys for 7-30 days, depending on the usecase. Note that for redis, if the swrvice restarts, all the data will be gone.

### Key name

The key name should be prefixed to avoid name collision.

The root prefix should be short, probably `i9y` for idempotency.

A second level prefix should indicate the idempotency operation name. This is to avoid mistakes with just using a resource id, which could span multiple operations.

Take for example, two operations that are related to orders, payment and refunds. If the operation prefix is not defined, and only the order id is used, there is a possibility of conflict when running the idempoteny operation.

Prefixing the operation makes it clear that they are two separate operation:

```
order-refund:order-123
order-payment:order-123
```

### Hashing the request

To save storage, we can hash the request payload. This also keeps the value secure since we do not keep sensitive values in the storage.

However, care need to be taken to handle the evolution of the value (adding or removing fields).

Hashing the request can be optional. The issue with hashing request is it is not easy to debug if there is a mismatch.

Conclusion:
- hash only if you have sensitive data
- hash only if you don't care about the values

### Idempotency value

The idempotency key is generated by concatenating a unique identified with the (hashed) request body.

The same idempotency keg will always return the same response. To retry the same request with the same identifier, just use a different body.

### Idempotency Goal

The goal in idempotency is to eliminate duplicate requests. However, they come in different categories. I have not found the best naming, but this is what i have seen so far

- identity based
- operation based
- sequential state

Identity based and operation based is probably the most common category we encounter day to day.

Identity operation usually involves an idempotency key that is based on the id of a resource, or could be hash of a payload. This could normally be handled in the database by setting a unique constraint in the column.

Operation based is an extension to identity based idempotency. For a given identity, we want to perform an operation only once. For example, we want to send an email once a day for a user with an email, so the idempotency key is `send-email:john.doe@mail.com:20230822`. For operation based idempotency, we also check the request to ensure it matches.


Sequential state is more complicated, but can happen for scenarios where an idempotency key cannot be based on a unique identifier, because the resource is not created yet. For example, when creating withdrawal for a user, we need to provide an idempotency key. However, every new withdrawal will actually generate a new idempotency key. This can be problematic, as we do not want users to be making many concurrent withdrawal requests, where the order of withdrawal may affect the balance. To ensure the withdrawal is done sequentially, we can introduce sequential state, where we used the last successful or failed withdrawal as the key for a given user, e.g. `payout:user:1:last_withdrawal_id`. This ensures that every withdrawal is successful or failed before the next one could be requested. This could also be a unique constraint within the database.

### Error handling

What happens if there is an error? Do we still store the request/response? Yes. The client will have to make a new request that is different from the previous one.

## Behaviour

Single operation, bounded by time
- request 1 enter
- request is cached
- request 2 enter
- error request in flight
- request 1 completed
- request 3 enter
- got cached response


  ### Metrics


  How do we measure the success of the idempotency operations?

Again, we can measure the idempotency hit and miss to understand how racy is the operation.
The ratio of hit should be high, to indicate that the data is always retrieved from the cache. If the count is low, it means it is just being saved once and not used much.

How do we test the success of this operation?

We can generate n requests for the same key, which contains duplicate and different parameters. We can then trigger a save to the database. By right, if it is idempotent, only one operation will save to the database. We can set a unique constraints in the sqlitedb to panic if an error occurs. We can simulate error saving to db.

We can do chaos testing with redis to simulate errors, to see the impact of failing redis to the save operations too.


### Articles

https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/

https://stripe.com/docs/api/idempotent_requests

https://developer.mastercard.com/mastercard-send-person-to-person/documentation/api-basics/

## Implementation 


Ideally the idempotency package should be storage (postgres, redis) independent.

The idea is to have a factory that takes a normal handler, and convert it into idempotent handler.


```
factory = redis_factory()
idempotent_handler = factory.make(handler, opts)
idempotent_handler.do(ctx, key, req)
```

### Redis

Implementation idempotency in redis is tricky, considering there is no built-in locking mechanism like postgres (e.g. advisory lock).

The `redlock` algo might work, but with additional complexity. We opt for a single node solution instead in order to customize the behavior.


We start with the data structure. We just use a simple string to store both the pending and completed state.

To acquire the lock, as well as returning the existing payload, we do:
```
# set or get
$ set <key> <token> nx get px <lock ttl ms>
nil: the value is set/does not exist
val: the existing value
```

This ensures both the set and get operation is atomic. Otherwise, there will be a dilemma between whether to get or set first in separate operations.

It value exists, we just need to check if it is a token uuid or a json body.

If it is a token uuid, it means another process is processing it. Otherwise, we check the json request to ensure it matches the existing request.

After acquiring the lock, we still need to extend it, in case the process takes longer than the lock timeout:

```
@every 7/10 of lock_ttl
extend(key, token, lock_ttl)
```

If an error occurs, we need to unlock, or wait for the timeout to expire:

```
unlock(key, token)
```

Otherwise, we process the function and replace the token uuid with the payload. We also update the ttl and specify how long to keep it 


```
replace(key, token, payload, keep_ttl)
```

At this point, the extend or unlock will fail because the token already changes.


The pseudo code
```
def idempotent(key, req) -> res:
  data = get(key)
  if data is not none:
    if is_token(data):
       return ErrRequestInFlight
    if hash(req) != data.req:
       return ErrRequestMismatch
    return data.res
  token = new_token()
  ok = setnx(key, token, lock_ttl)
  if not ok:
    return ErrRequestInFlight
  defer unlock(key, token)
  set_interval(extend(key, token, lock_ttl), 7/10*lock_ttl)
  res = work()
  replace(key, token, data(req=hash(req), res=res))
  return res
```



## Consequences


