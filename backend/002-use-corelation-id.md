# Generate and Propagate Correlation ID

## Status

`accepted`

## Context

In distributed systems and microservices architectures, tracking requests across multiple services becomes challenging without proper request identification. We need a standardized way to correlate logs, metrics, and traces for a single user request as it flows through our system.

A correlation ID (also known as request ID or trace ID) is a unique identifier that follows a request throughout its entire lifecycle, making debugging, monitoring, and observability significantly easier.

## Decision

All services must generate and/or propagate correlation IDs for every request. The correlation ID should be:
- Extracted from HTTP headers (primarily `X-Request-ID`)
- Generated if not present in the incoming request
- Propagated to all downstream services
- Included in all log entries
- Returned to clients in error responses

## Implementation

### Header Standards

Use these headers in order of preference:
1. `X-Request-ID` - Primary standard
2. `X-Correlation-ID` - Alternative standard
3. `Request-ID` - Fallback

### Correlation ID Generation

```go
package correlation

import (
    "context"
    "net/http"
    
    "github.com/google/uuid"
)

type contextKey string

const (
    RequestIDKey contextKey = "request_id"
    HeaderRequestID = "X-Request-ID"
    HeaderCorrelationID = "X-Correlation-ID"
)

// GenerateID creates a new correlation ID
func GenerateID() string {
    return uuid.New().String()
}

// ExtractFromHeaders attempts to extract correlation ID from HTTP headers
func ExtractFromHeaders(headers http.Header) string {
    // Try multiple header names in order of preference
    headerNames := []string{
        HeaderRequestID,
        HeaderCorrelationID,
        "Request-ID",
        "Correlation-ID",
    }
    
    for _, name := range headerNames {
        if id := headers.Get(name); id != "" {
            return id
        }
    }
    
    return ""
}

// GetOrGenerate extracts correlation ID from headers or generates new one
func GetOrGenerate(headers http.Header) string {
    if id := ExtractFromHeaders(headers); id != "" {
        return id
    }
    return GenerateID()
}
```

### Context Integration

```go
// WithRequestID adds correlation ID to context
func WithRequestID(ctx context.Context, requestID string) context.Context {
    return context.WithValue(ctx, RequestIDKey, requestID)
}

// FromContext extracts correlation ID from context
func FromContext(ctx context.Context) (string, bool) {
    id, ok := ctx.Value(RequestIDKey).(string)
    return id, ok
}

// MustFromContext extracts correlation ID from context or panics
func MustFromContext(ctx context.Context) string {
    id, ok := FromContext(ctx)
    if !ok {
        panic("correlation: request ID not found in context")
    }
    return id
}
```

### HTTP Middleware

```go
package middleware

import (
    "net/http"
    
    "your-app/pkg/correlation"
    "your-app/pkg/logging"
)

// CorrelationID middleware extracts or generates correlation ID
func CorrelationID(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // Extract or generate correlation ID
        requestID := correlation.GetOrGenerate(r.Header)
        
        // Add to request context
        ctx := correlation.WithRequestID(r.Context(), requestID)
        r = r.WithContext(ctx)
        
        // Add to response headers for client reference
        w.Header().Set(correlation.HeaderRequestID, requestID)
        
        // Create logger with correlation ID
        logger := logging.FromContext(ctx).With().
            Str("request_id", requestID).
            Logger()
        
        // Add logger back to context
        ctx = logger.WithContext(ctx)
        r = r.WithContext(ctx)
        
        next.ServeHTTP(w, r)
    })
}

// LoggingMiddleware logs HTTP requests with correlation ID
func LoggingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        logger := logging.FromContext(r.Context())
        
        logger.Info().
            Str("method", r.Method).
            Str("path", r.URL.Path).
            Str("user_agent", r.UserAgent()).
            Str("remote_addr", r.RemoteAddr).
            Msg("incoming request")
        
        next.ServeHTTP(w, r)
    })
}
```

### Service Client with Correlation Propagation

```go
package client

import (
    "context"
    "net/http"
    
    "your-app/pkg/correlation"
)

type HTTPClient struct {
    client *http.Client
}

func NewHTTPClient() *HTTPClient {
    return &HTTPClient{
        client: &http.Client{
            Timeout: 30 * time.Second,
        },
    }
}

// Do executes HTTP request with correlation ID propagation
func (c *HTTPClient) Do(ctx context.Context, req *http.Request) (*http.Response, error) {
    // Propagate correlation ID to downstream service
    if requestID, ok := correlation.FromContext(ctx); ok {
        req.Header.Set(correlation.HeaderRequestID, requestID)
    }
    
    // Add request context
    req = req.WithContext(ctx)
    
    // Log outgoing request
    logger := logging.FromContext(ctx)
    logger.Info().
        Str("method", req.Method).
        Str("url", req.URL.String()).
        Msg("outgoing request")
    
    return c.client.Do(req)
}

// Example: Making a request to another service
func (c *HTTPClient) GetUser(ctx context.Context, userID string) (*User, error) {
    url := fmt.Sprintf("http://user-service/api/users/%s", userID)
    req, err := http.NewRequest("GET", url, nil)
    if err != nil {
        return nil, fmt.Errorf("failed to create request: %w", err)
    }
    
    resp, err := c.Do(ctx, req)
    if err != nil {
        return nil, fmt.Errorf("request failed: %w", err)
    }
    defer resp.Body.Close()
    
    if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("unexpected status: %d", resp.StatusCode)
    }
    
    var user User
    if err := json.NewDecoder(resp.Body).Decode(&user); err != nil {
        return nil, fmt.Errorf("failed to decode response: %w", err)
    }
    
    return &user, nil
}
```

### Database Integration

```go
package database

import (
    "context"
    "database/sql"
    
    "your-app/pkg/correlation"
    "your-app/pkg/logging"
)

type DB struct {
    *sql.DB
}

// ExecContext executes query with correlation ID logging
func (db *DB) ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error) {
    logger := logging.FromContext(ctx)
    
    logger.Debug().
        Str("query", query).
        Interface("args", args).
        Msg("executing database query")
    
    start := time.Now()
    result, err := db.DB.ExecContext(ctx, query, args...)
    duration := time.Since(start)
    
    if err != nil {
        logger.Error().
            Err(err).
            Str("query", query).
            Duration("duration", duration).
            Msg("database query failed")
        return nil, err
    }
    
    logger.Debug().
        Str("query", query).
        Duration("duration", duration).
        Msg("database query completed")
    
    return result, nil
}

// QueryRowContext queries single row with correlation ID logging
func (db *DB) QueryRowContext(ctx context.Context, query string, args ...interface{}) *sql.Row {
    logger := logging.FromContext(ctx)
    
    logger.Debug().
        Str("query", query).
        Interface("args", args).
        Msg("executing database query")
    
    return db.DB.QueryRowContext(ctx, query, args...)
}
```

### Error Response with Correlation ID

```go
package handlers

import (
    "encoding/json"
    "net/http"
    
    "your-app/pkg/correlation"
    "your-app/pkg/logging"
)

type ErrorResponse struct {
    Success   bool   `json:"success"`
    Error     Error  `json:"error"`
    RequestID string `json:"requestId"`
}

type Error struct {
    Code    string `json:"code"`
    Message string `json:"message"`
}

func WriteErrorResponse(w http.ResponseWriter, r *http.Request, statusCode int, code, message string) {
    requestID, _ := correlation.FromContext(r.Context())
    
    response := ErrorResponse{
        Success: false,
        Error: Error{
            Code:    code,
            Message: message,
        },
        RequestID: requestID,
    }
    
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(statusCode)
    
    if err := json.NewEncoder(w).Encode(response); err != nil {
        logger := logging.FromContext(r.Context())
        logger.Error().Err(err).Msg("failed to encode error response")
    }
}

// Example handler with error handling
func (h *UserHandler) GetUser(w http.ResponseWriter, r *http.Request) {
    userID := mux.Vars(r)["id"]
    
    user, err := h.userService.GetUser(r.Context(), userID)
    if err != nil {
        if errors.Is(err, ErrUserNotFound) {
            WriteErrorResponse(w, r, http.StatusNotFound, "USER_NOT_FOUND", "User not found")
            return
        }
        
        logger := logging.FromContext(r.Context())
        logger.Error().Err(err).Str("user_id", userID).Msg("failed to get user")
        
        WriteErrorResponse(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "Internal server error")
        return
    }
    
    response := map[string]interface{}{
        "success": true,
        "data":    user,
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(response)
}
```

### Logging Integration

```go
package logging

import (
    "context"
    
    "github.com/rs/zerolog"
    "github.com/rs/zerolog/log"
    
    "your-app/pkg/correlation"
)

// FromContext returns logger with correlation ID from context
func FromContext(ctx context.Context) zerolog.Logger {
    if requestID, ok := correlation.FromContext(ctx); ok {
        return log.With().Str("request_id", requestID).Logger()
    }
    return log.Logger
}

// WithContext adds logger to context
func WithContext(ctx context.Context, logger zerolog.Logger) context.Context {
    return logger.WithContext(ctx)
}
```

### Complete Example

```go
package main

import (
    "context"
    "log"
    "net/http"
    "time"
    
    "github.com/gorilla/mux"
    "github.com/rs/zerolog"
    
    "your-app/pkg/correlation"
    "your-app/pkg/logging"
    "your-app/pkg/middleware"
)

func main() {
    // Configure structured logging
    zerolog.TimeFieldFormat = zerolog.TimeFormatUnix
    
    r := mux.NewRouter()
    
    // Apply correlation ID middleware
    r.Use(middleware.CorrelationID)
    r.Use(middleware.LoggingMiddleware)
    
    // API routes
    r.HandleFunc("/api/users/{id}", getUserHandler).Methods("GET")
    r.HandleFunc("/api/users", createUserHandler).Methods("POST")
    
    log.Println("Server starting on :8080")
    log.Fatal(http.ListenAndServe(":8080", r))
}

func getUserHandler(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    logger := logging.FromContext(ctx)
    
    userID := mux.Vars(r)["id"]
    
    logger.Info().Str("user_id", userID).Msg("getting user")
    
    // Simulate service call
    user, err := getUserFromService(ctx, userID)
    if err != nil {
        logger.Error().Err(err).Msg("failed to get user")
        http.Error(w, "Internal server error", http.StatusInternalServerError)
        return
    }
    
    logger.Info().Str("user_id", userID).Msg("user retrieved successfully")
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]interface{}{
        "success": true,
        "data":    user,
    })
}

func getUserFromService(ctx context.Context, userID string) (*User, error) {
    logger := logging.FromContext(ctx)
    
    logger.Debug().Str("user_id", userID).Msg("fetching user from database")
    
    // Simulate database call
    time.Sleep(10 * time.Millisecond)
    
    if userID == "404" {
        return nil, errors.New("user not found")
    }
    
    return &User{
        ID:   userID,
        Name: "John Doe",
    }, nil
}

type User struct {
    ID   string `json:"id"`
    Name string `json:"name"`
}
```

### Log Output Example

```json
{"level":"info","request_id":"550e8400-e29b-41d4-a716-446655440000","method":"GET","path":"/api/users/123","user_agent":"curl/7.68.0","remote_addr":"127.0.0.1:52376","time":1641024000,"message":"incoming request"}
{"level":"info","request_id":"550e8400-e29b-41d4-a716-446655440000","user_id":"123","time":1641024000,"message":"getting user"}
{"level":"debug","request_id":"550e8400-e29b-41d4-a716-446655440000","user_id":"123","time":1641024000,"message":"fetching user from database"}
{"level":"info","request_id":"550e8400-e29b-41d4-a716-446655440000","user_id":"123","time":1641024000,"message":"user retrieved successfully"}
```

## Benefits

- **Distributed Tracing**: Track requests across multiple services
- **Debugging**: Easily correlate logs for a specific request
- **Monitoring**: Measure request latency and error rates
- **Client Support**: Clients can reference request ID when reporting issues
- **Audit Trail**: Complete request lifecycle visibility

## Best Practices

1. **Always Generate**: Generate correlation ID if not provided by client
2. **Consistent Propagation**: Pass correlation ID to all downstream services
3. **Log Everything**: Include correlation ID in all log entries
4. **Error Responses**: Always return correlation ID in error responses
5. **Short-lived**: Correlation IDs should be unique per request, not reused
6. **Format**: Use UUID format for better uniqueness and readability
7. **Header Standards**: Stick to standard header names for compatibility

## Anti-patterns

- **Reusing IDs**: Don't reuse correlation IDs across different requests
- **Missing Context**: Don't make service calls without propagating correlation ID
- **Logging Without ID**: Don't write logs without including correlation ID
- **Client Generation**: Don't rely solely on clients to provide correlation IDs
- **Sensitive Data**: Don't include sensitive information in correlation IDs

The example below demonstrates passing the context containing the correlation id to services that handles the request, as well as logging the request id on error/info:

```go
package main

import (
	"context"
	"errors"
	"fmt"

	"net/http"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
	"github.com/segmentio/ksuid"
)

var RequestID contextkey[string] = "request_id"

type contextkey[T any] string

func (key contextkey[T]) WithValue(ctx context.Context, val T) context.Context {
	return context.WithValue(ctx, key, val)
}

func (key contextkey[T]) Value(ctx context.Context) (t T, found bool) {
	t, found = ctx.Value(key).(T)

	return
}

func (key contextkey[T]) MustValue(ctx context.Context) T {
	requestID, found := key.Value(ctx)
	if !found {
		panic("context: requestID not found")
	}

	return requestID
}

func main() {
	headers := make(http.Header)
	headers.Set("X-Request-ID", ksuid.New().String())

	requestID := headers.Get("X-Request-ID")
	fmt.Println("requestID:", requestID)

	ctx := context.Background()
	ctx = RequestID.WithValue(ctx, requestID)
	log := newLogger(ctx)
	if err := createUser(ctx, ""); err != nil {
		log.Error().Err(err).Msg("failed to create user")
	}

	if err := createUser(ctx, "john"); err != nil {
		log.Error().Err(err).Msg("failed to create user")
	}
}

func createUser(ctx context.Context, name string) error {
	if name == "" {
		return errors.New("name is required")
	}

	log := newLogger(ctx)
	log.Info().Str("name", name).Msg("creating user")

	return nil
}

func newLogger(ctx context.Context) zerolog.Logger {
	return log.With().Str("request_id", RequestID.MustValue(ctx)).Logger()
}
```


Output:

```go
requestID: ZJkWuUrRVAHjLtxQPl1jlBz8FXd
{"level":"error","request_id":"ZJkWuUrRVAHjLtxQPl1jlBz8FXd","error":"name is required","time":"2009-11-10T23:00:00Z","message":"failed to create user"}
{"level":"info","request_id":"ZJkWuUrRVAHjLtxQPl1jlBz8FXd","name":"john","time":"2009-11-10T23:00:00Z","message":"creating user"}
```
