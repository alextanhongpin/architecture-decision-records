# ADR 007: Timeout Patterns in Go

## Status

**Accepted**

## Context

Go's default HTTP server and client implementations do not enforce timeouts, which can lead to resource exhaustion, degraded performance, and potential security vulnerabilities. Without proper timeouts:

- **Server resource leaks**: Connections may hang indefinitely, consuming memory and file descriptors
- **Client hangs**: External API calls can block indefinitely, affecting user experience
- **Cascading failures**: Slow downstream services can bring down entire systems
- **Security vulnerabilities**: Slow loris attacks can exploit timeout-less servers

We need comprehensive timeout strategies for HTTP servers, clients, database connections, and general operations.

## Decision

We will implement layered timeout patterns across all network operations and long-running tasks, using Go's context package for cancellation and deadline management.

### 1. HTTP Server Timeouts

```go
package server

import (
    "context"
    "fmt"
    "net/http"
    "time"
)

type HTTPServerConfig struct {
    ReadTimeout       time.Duration // Time to read request headers and body
    WriteTimeout      time.Duration // Time to write response
    IdleTimeout       time.Duration // Keep-alive timeout
    ReadHeaderTimeout time.Duration // Time to read request headers only
    HandlerTimeout    time.Duration // Per-handler timeout
}

// NewTimeoutServer creates an HTTP server with comprehensive timeouts
func NewTimeoutServer(addr string, handler http.Handler, config HTTPServerConfig) *http.Server {
    if config.ReadTimeout == 0 {
        config.ReadTimeout = 30 * time.Second
    }
    if config.WriteTimeout == 0 {
        config.WriteTimeout = 30 * time.Second
    }
    if config.IdleTimeout == 0 {
        config.IdleTimeout = 120 * time.Second
    }
    if config.ReadHeaderTimeout == 0 {
        config.ReadHeaderTimeout = 10 * time.Second
    }
    if config.HandlerTimeout == 0 {
        config.HandlerTimeout = 30 * time.Second
    }
    
    // Wrap handler with timeout middleware
    timeoutHandler := NewTimeoutMiddleware(config.HandlerTimeout)(handler)
    
    return &http.Server{
        Addr:              addr,
        Handler:           timeoutHandler,
        ReadTimeout:       config.ReadTimeout,
        WriteTimeout:      config.WriteTimeout,
        IdleTimeout:       config.IdleTimeout,
        ReadHeaderTimeout: config.ReadHeaderTimeout,
        MaxHeaderBytes:    1 << 20, // 1 MB
    }
}

// TimeoutMiddleware adds per-request timeout handling
func NewTimeoutMiddleware(timeout time.Duration) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            ctx, cancel := context.WithTimeout(r.Context(), timeout)
            defer cancel()
            
            // Channel to signal completion
            done := make(chan bool, 1)
            
            go func() {
                defer func() {
                    if r := recover(); r != nil {
                        fmt.Printf("Handler panic: %v\n", r)
                        http.Error(w, "Internal Server Error", http.StatusInternalServerError)
                    }
                    done <- true
                }()
                
                next.ServeHTTP(w, r.WithContext(ctx))
            }()
            
            select {
            case <-done:
                // Handler completed normally
                return
            case <-ctx.Done():
                // Timeout occurred
                if ctx.Err() == context.DeadlineExceeded {
                    http.Error(w, "Request Timeout", http.StatusRequestTimeout)
                } else {
                    http.Error(w, "Request Cancelled", http.StatusRequestTimeout)
                }
                return
            }
        })
    }
}

// Example usage
func CreateProductionServer() *http.Server {
    mux := http.NewServeMux()
    
    // Add routes
    mux.HandleFunc("/api/health", healthHandler)
    mux.HandleFunc("/api/users", usersHandler)
    
    config := HTTPServerConfig{
        ReadTimeout:       15 * time.Second,
        WriteTimeout:      15 * time.Second,
        IdleTimeout:       60 * time.Second,
        ReadHeaderTimeout: 5 * time.Second,
        HandlerTimeout:    10 * time.Second,
    }
    
    return NewTimeoutServer(":8080", mux, config)
}
```

### 2. HTTP Client Timeouts

```go
package client

import (
    "context"
    "fmt"
    "net"
    "net/http"
    "time"
)

type HTTPClientConfig struct {
    ConnectTimeout   time.Duration // TCP connection timeout
    TLSTimeout       time.Duration // TLS handshake timeout
    RequestTimeout   time.Duration // Total request timeout
    ResponseTimeout  time.Duration // Response header timeout
    IdleConnTimeout  time.Duration // Keep-alive timeout
    MaxIdleConns     int           // Connection pool size
    MaxConnsPerHost  int           // Connections per host
}

// NewTimeoutClient creates an HTTP client with comprehensive timeouts
func NewTimeoutClient(config HTTPClientConfig) *http.Client {
    if config.ConnectTimeout == 0 {
        config.ConnectTimeout = 10 * time.Second
    }
    if config.TLSTimeout == 0 {
        config.TLSTimeout = 10 * time.Second
    }
    if config.RequestTimeout == 0 {
        config.RequestTimeout = 30 * time.Second
    }
    if config.ResponseTimeout == 0 {
        config.ResponseTimeout = 30 * time.Second
    }
    if config.IdleConnTimeout == 0 {
        config.IdleConnTimeout = 90 * time.Second
    }
    if config.MaxIdleConns == 0 {
        config.MaxIdleConns = 100
    }
    if config.MaxConnsPerHost == 0 {
        config.MaxConnsPerHost = 10
    }
    
    transport := &http.Transport{
        DialContext: (&net.Dialer{
            Timeout:   config.ConnectTimeout,
            KeepAlive: 30 * time.Second,
        }).DialContext,
        TLSHandshakeTimeout:   config.TLSTimeout,
        ResponseHeaderTimeout: config.ResponseTimeout,
        IdleConnTimeout:       config.IdleConnTimeout,
        MaxIdleConns:          config.MaxIdleConns,
        MaxConnsPerHost:       config.MaxConnsPerHost,
        DisableKeepAlives:     false,
    }
    
    return &http.Client{
        Transport: transport,
        Timeout:   config.RequestTimeout,
    }
}

// RetryableClient adds retry logic with exponential backoff
type RetryableClient struct {
    client      *http.Client
    maxRetries  int
    baseDelay   time.Duration
    maxDelay    time.Duration
}

func NewRetryableClient(config HTTPClientConfig, maxRetries int) *RetryableClient {
    return &RetryableClient{
        client:     NewTimeoutClient(config),
        maxRetries: maxRetries,
        baseDelay:  100 * time.Millisecond,
        maxDelay:   5 * time.Second,
    }
}

func (rc *RetryableClient) Do(req *http.Request) (*http.Response, error) {
    var lastErr error
    
    for attempt := 0; attempt <= rc.maxRetries; attempt++ {
        // Create a copy of the request for retry
        reqCopy := req.Clone(req.Context())
        
        resp, err := rc.client.Do(reqCopy)
        if err == nil && resp.StatusCode < 500 {
            return resp, nil
        }
        
        lastErr = err
        
        // Don't retry on last attempt
        if attempt == rc.maxRetries {
            break
        }
        
        // Calculate delay with exponential backoff
        delay := rc.baseDelay * time.Duration(1<<uint(attempt))
        if delay > rc.maxDelay {
            delay = rc.maxDelay
        }
        
        select {
        case <-time.After(delay):
            // Continue with retry
        case <-req.Context().Done():
            return nil, req.Context().Err()
        }
    }
    
    return nil, fmt.Errorf("request failed after %d attempts: %w", rc.maxRetries+1, lastErr)
}

// Example usage
func CreateAPIClient() *RetryableClient {
    config := HTTPClientConfig{
        ConnectTimeout:  5 * time.Second,
        TLSTimeout:      5 * time.Second,
        RequestTimeout:  30 * time.Second,
        ResponseTimeout: 30 * time.Second,
        IdleConnTimeout: 60 * time.Second,
        MaxIdleConns:    50,
        MaxConnsPerHost: 5,
    }
    
    return NewRetryableClient(config, 3)
}
```

### 3. Database Connection Timeouts

```go
package database

import (
    "context"
    "database/sql"
    "fmt"
    "time"
    
    _ "github.com/lib/pq"
)

type DatabaseConfig struct {
    ConnectTimeout  time.Duration
    QueryTimeout    time.Duration
    TxTimeout       time.Duration
    MaxOpenConns    int
    MaxIdleConns    int
    ConnMaxLifetime time.Duration
    ConnMaxIdleTime time.Duration
}

// NewTimeoutDB creates a database connection with timeout configuration
func NewTimeoutDB(driverName, dataSourceName string, config DatabaseConfig) (*sql.DB, error) {
    if config.ConnectTimeout == 0 {
        config.ConnectTimeout = 10 * time.Second
    }
    if config.QueryTimeout == 0 {
        config.QueryTimeout = 30 * time.Second
    }
    if config.TxTimeout == 0 {
        config.TxTimeout = 30 * time.Second
    }
    if config.MaxOpenConns == 0 {
        config.MaxOpenConns = 25
    }
    if config.MaxIdleConns == 0 {
        config.MaxIdleConns = 5
    }
    if config.ConnMaxLifetime == 0 {
        config.ConnMaxLifetime = 5 * time.Minute
    }
    if config.ConnMaxIdleTime == 0 {
        config.ConnMaxIdleTime = 5 * time.Minute
    }
    
    ctx, cancel := context.WithTimeout(context.Background(), config.ConnectTimeout)
    defer cancel()
    
    db, err := sql.Open(driverName, dataSourceName)
    if err != nil {
        return nil, fmt.Errorf("failed to open database: %w", err)
    }
    
    // Test connection
    if err := db.PingContext(ctx); err != nil {
        db.Close()
        return nil, fmt.Errorf("failed to ping database: %w", err)
    }
    
    // Configure connection pool
    db.SetMaxOpenConns(config.MaxOpenConns)
    db.SetMaxIdleConns(config.MaxIdleConns)
    db.SetConnMaxLifetime(config.ConnMaxLifetime)
    db.SetConnMaxIdleTime(config.ConnMaxIdleTime)
    
    return db, nil
}

// TimeoutExecutor wraps database operations with timeouts
type TimeoutExecutor struct {
    db           *sql.DB
    queryTimeout time.Duration
    txTimeout    time.Duration
}

func NewTimeoutExecutor(db *sql.DB, config DatabaseConfig) *TimeoutExecutor {
    return &TimeoutExecutor{
        db:           db,
        queryTimeout: config.QueryTimeout,
        txTimeout:    config.TxTimeout,
    }
}

// QueryContext executes a query with timeout
func (te *TimeoutExecutor) QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error) {
    if _, hasDeadline := ctx.Deadline(); !hasDeadline {
        var cancel context.CancelFunc
        ctx, cancel = context.WithTimeout(ctx, te.queryTimeout)
        defer cancel()
    }
    
    return te.db.QueryContext(ctx, query, args...)
}

// ExecContext executes a statement with timeout
func (te *TimeoutExecutor) ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error) {
    if _, hasDeadline := ctx.Deadline(); !hasDeadline {
        var cancel context.CancelFunc
        ctx, cancel = context.WithTimeout(ctx, te.queryTimeout)
        defer cancel()
    }
    
    return te.db.ExecContext(ctx, query, args...)
}

// BeginTxContext starts a transaction with timeout
func (te *TimeoutExecutor) BeginTxContext(ctx context.Context, opts *sql.TxOptions) (*TimeoutTx, error) {
    if _, hasDeadline := ctx.Deadline(); !hasDeadline {
        var cancel context.CancelFunc
        ctx, cancel = context.WithTimeout(ctx, te.txTimeout)
        defer cancel()
    }
    
    tx, err := te.db.BeginTx(ctx, opts)
    if err != nil {
        return nil, err
    }
    
    return &TimeoutTx{
        tx:      tx,
        timeout: te.queryTimeout,
    }, nil
}

// TimeoutTx wraps sql.Tx with timeout support
type TimeoutTx struct {
    tx      *sql.Tx
    timeout time.Duration
}

func (ttx *TimeoutTx) QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error) {
    if _, hasDeadline := ctx.Deadline(); !hasDeadline {
        var cancel context.CancelFunc
        ctx, cancel = context.WithTimeout(ctx, ttx.timeout)
        defer cancel()
    }
    
    return ttx.tx.QueryContext(ctx, query, args...)
}

func (ttx *TimeoutTx) ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error) {
    if _, hasDeadline := ctx.Deadline(); !hasDeadline {
        var cancel context.CancelFunc
        ctx, cancel = context.WithTimeout(ctx, ttx.timeout)
        defer cancel()
    }
    
    return ttx.tx.ExecContext(ctx, query, args...)
}

func (ttx *TimeoutTx) Commit() error {
    return ttx.tx.Commit()
}

func (ttx *TimeoutTx) Rollback() error {
    return ttx.tx.Rollback()
}
```

### 4. Context-Based Timeout Patterns

```go
package timeout

import (
    "context"
    "fmt"
    "sync"
    "time"
)

// WithDeadline creates a context with absolute deadline
func WithDeadline(parent context.Context, deadline time.Time) (context.Context, context.CancelFunc) {
    return context.WithDeadline(parent, deadline)
}

// WithTimeout creates a context with relative timeout
func WithTimeout(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
    return context.WithTimeout(parent, timeout)
}

// DoWithTimeout executes a function with timeout
func DoWithTimeout(ctx context.Context, timeout time.Duration, fn func(context.Context) error) error {
    ctx, cancel := context.WithTimeout(ctx, timeout)
    defer cancel()
    
    errCh := make(chan error, 1)
    
    go func() {
        errCh <- fn(ctx)
    }()
    
    select {
    case err := <-errCh:
        return err
    case <-ctx.Done():
        return ctx.Err()
    }
}

// ParallelWithTimeout executes multiple functions in parallel with global timeout
func ParallelWithTimeout(ctx context.Context, timeout time.Duration, fns ...func(context.Context) error) error {
    ctx, cancel := context.WithTimeout(ctx, timeout)
    defer cancel()
    
    var wg sync.WaitGroup
    errCh := make(chan error, len(fns))
    
    for _, fn := range fns {
        wg.Add(1)
        go func(f func(context.Context) error) {
            defer wg.Done()
            if err := f(ctx); err != nil {
                errCh <- err
            }
        }(fn)
    }
    
    done := make(chan bool, 1)
    go func() {
        wg.Wait()
        done <- true
    }()
    
    select {
    case <-done:
        close(errCh)
        // Return first error if any
        for err := range errCh {
            if err != nil {
                return err
            }
        }
        return nil
    case <-ctx.Done():
        return ctx.Err()
    case err := <-errCh:
        cancel() // Cancel other operations
        return err
    }
}

// RetryWithTimeout implements retry logic with timeout
func RetryWithTimeout(ctx context.Context, maxAttempts int, delay time.Duration, fn func() error) error {
    var lastErr error
    
    for attempt := 0; attempt < maxAttempts; attempt++ {
        select {
        case <-ctx.Done():
            return ctx.Err()
        default:
        }
        
        if err := fn(); err == nil {
            return nil
        } else {
            lastErr = err
        }
        
        if attempt < maxAttempts-1 {
            select {
            case <-time.After(delay):
                // Continue with next attempt
            case <-ctx.Done():
                return ctx.Err()
            }
        }
    }
    
    return fmt.Errorf("operation failed after %d attempts: %w", maxAttempts, lastErr)
}

// CascadingTimeout implements timeouts that decrease with each level
type CascadingTimeout struct {
    baseTimeout time.Duration
    factor      float64
    minTimeout  time.Duration
}

func NewCascadingTimeout(base time.Duration, factor float64, min time.Duration) *CascadingTimeout {
    return &CascadingTimeout{
        baseTimeout: base,
        factor:      factor,
        minTimeout:  min,
    }
}

func (ct *CascadingTimeout) Next() time.Duration {
    timeout := time.Duration(float64(ct.baseTimeout) * ct.factor)
    if timeout < ct.minTimeout {
        timeout = ct.minTimeout
    }
    ct.baseTimeout = timeout
    return timeout
}

// Example: API service with cascading timeouts
func CallServiceWithCascadingTimeout(ctx context.Context, service APIService) error {
    cascade := NewCascadingTimeout(30*time.Second, 0.7, 5*time.Second)
    
    return RetryWithTimeout(ctx, 3, 1*time.Second, func() error {
        timeout := cascade.Next()
        return DoWithTimeout(ctx, timeout, func(ctx context.Context) error {
            return service.Call(ctx)
        })
    })
}
```

### 5. Testing Timeout Behavior

```go
package timeout_test

import (
    "context"
    "testing"
    "time"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestHTTPServerTimeout(t *testing.T) {
    tests := []struct {
        name           string
        handlerDelay   time.Duration
        requestTimeout time.Duration
        expectTimeout  bool
    }{
        {
            name:           "request completes before timeout",
            handlerDelay:   100 * time.Millisecond,
            requestTimeout: 1 * time.Second,
            expectTimeout:  false,
        },
        {
            name:           "request times out",
            handlerDelay:   2 * time.Second,
            requestTimeout: 500 * time.Millisecond,
            expectTimeout:  true,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Create test handler that sleeps
            handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                time.Sleep(tt.handlerDelay)
                w.WriteHeader(http.StatusOK)
            })
            
            // Create server with timeout
            config := HTTPServerConfig{
                HandlerTimeout: tt.requestTimeout,
            }
            server := NewTimeoutServer(":0", handler, config)
            
            // Test the timeout behavior
            // Implementation depends on your specific testing setup
        })
    }
}

func TestDoWithTimeout(t *testing.T) {
    t.Run("function completes before timeout", func(t *testing.T) {
        ctx := context.Background()
        
        err := DoWithTimeout(ctx, 1*time.Second, func(ctx context.Context) error {
            time.Sleep(100 * time.Millisecond)
            return nil
        })
        
        assert.NoError(t, err)
    })
    
    t.Run("function times out", func(t *testing.T) {
        ctx := context.Background()
        
        err := DoWithTimeout(ctx, 100*time.Millisecond, func(ctx context.Context) error {
            time.Sleep(1 * time.Second)
            return nil
        })
        
        assert.ErrorIs(t, err, context.DeadlineExceeded)
    })
    
    t.Run("context respects cancellation", func(t *testing.T) {
        ctx := context.Background()
        
        err := DoWithTimeout(ctx, 1*time.Second, func(ctx context.Context) error {
            select {
            case <-time.After(2 * time.Second):
                return nil
            case <-ctx.Done():
                return ctx.Err()
            }
        })
        
        assert.ErrorIs(t, err, context.DeadlineExceeded)
    })
}

func TestRetryWithTimeout(t *testing.T) {
    t.Run("succeeds after retry", func(t *testing.T) {
        ctx := context.Background()
        attempts := 0
        
        err := RetryWithTimeout(ctx, 3, 10*time.Millisecond, func() error {
            attempts++
            if attempts < 2 {
                return fmt.Errorf("not ready yet")
            }
            return nil
        })
        
        assert.NoError(t, err)
        assert.Equal(t, 2, attempts)
    })
    
    t.Run("fails after max attempts", func(t *testing.T) {
        ctx := context.Background()
        attempts := 0
        
        err := RetryWithTimeout(ctx, 3, 1*time.Millisecond, func() error {
            attempts++
            return fmt.Errorf("always fails")
        })
        
        assert.Error(t, err)
        assert.Equal(t, 3, attempts)
    })
}

func BenchmarkTimeoutOverhead(b *testing.B) {
    ctx := context.Background()
    
    b.Run("with timeout", func(b *testing.B) {
        for i := 0; i < b.N; i++ {
            DoWithTimeout(ctx, 1*time.Second, func(ctx context.Context) error {
                return nil
            })
        }
    })
    
    b.Run("without timeout", func(b *testing.B) {
        for i := 0; i < b.N; i++ {
            func() error {
                return nil
            }()
        }
    })
}
```

## Implementation Guidelines

### Timeout Values

1. **HTTP Server Timeouts**:
   - Read timeout: 15-30 seconds
   - Write timeout: 15-30 seconds
   - Handler timeout: 5-30 seconds
   - Idle timeout: 60-120 seconds

2. **HTTP Client Timeouts**:
   - Connect timeout: 5-10 seconds
   - Request timeout: 30-60 seconds
   - Response timeout: 30-60 seconds

3. **Database Timeouts**:
   - Connect timeout: 5-10 seconds
   - Query timeout: 30-60 seconds
   - Transaction timeout: 30-60 seconds

### Best Practices

1. **Always set timeouts**: Never leave network operations without timeouts
2. **Use context**: Propagate context with deadlines through call stacks
3. **Layer timeouts**: Set timeouts at multiple levels (network, application, handler)
4. **Monitor timeout rates**: Track how often timeouts occur
5. **Graceful degradation**: Handle timeouts gracefully with fallbacks

## Consequences

### Positive
- **Resource protection**: Prevents resource exhaustion
- **Predictable performance**: Bounded execution times
- **Better user experience**: Faster failure detection
- **System stability**: Prevents cascading failures

### Negative
- **Complexity**: Additional configuration and error handling
- **Tuning required**: Timeout values need careful calibration
- **Potential data loss**: Operations may be interrupted
- **Testing challenges**: Timeout scenarios are harder to test

## Anti-patterns to Avoid

```go
// ❌ Bad: No timeout
client := &http.Client{}
resp, err := client.Get("http://example.com")

// ❌ Bad: Timeout too long
client := &http.Client{Timeout: 10 * time.Minute}

// ❌ Bad: Ignoring context cancellation
func longOperation(ctx context.Context) error {
    time.Sleep(5 * time.Minute) // Ignores context
    return nil
}

// ✅ Good: Proper timeout and context usage
client := &http.Client{Timeout: 30 * time.Second}
ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()

req, _ := http.NewRequestWithContext(ctx, "GET", "http://example.com", nil)
resp, err := client.Do(req)
```

## References

- [The Complete Guide to Go net/http Timeouts](https://blog.cloudflare.com/the-complete-guide-to-golang-net-http-timeouts/)
- [Go Context Package](https://golang.org/pkg/context/)
- [So You Want to Expose Go on the Internet](https://blog.cloudflare.com/exposing-go-on-the-internet/)
- [HTTP Client Timeout](https://medium.com/@nate510/don-t-use-go-s-default-http-client-4804cb19f779)
