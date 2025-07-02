# Functional Options Pattern in Go

## Status

`production`

## Context

The functional options pattern provides a clean, extensible way to configure objects in Go. It's particularly useful when dealing with optional parameters, default values, and configuration that may grow over time.

This pattern is preferable to constructors with many parameters, configuration structs, or builder patterns in many scenarios.

## Decision

We will use the functional options pattern for configuring components that have optional parameters or when we want to provide sensible defaults while allowing customization.

### Core Pattern Implementation

```go
package client

import (
    "context"
    "net/http"
    "time"
)

// HTTPClient wraps an HTTP client with configuration
type HTTPClient struct {
    client      *http.Client
    baseURL     string
    userAgent   string
    timeout     time.Duration
    retries     int
    rateLimiter RateLimiter
    middleware  []Middleware
    logger      Logger
}

// Option defines a function that configures HTTPClient
type Option func(*HTTPClient)

// WithTimeout sets the request timeout
func WithTimeout(timeout time.Duration) Option {
    return func(c *HTTPClient) {
        c.timeout = timeout
        c.client.Timeout = timeout
    }
}

// WithRetries sets the number of retry attempts
func WithRetries(retries int) Option {
    return func(c *HTTPClient) {
        c.retries = retries
    }
}

// WithBaseURL sets the base URL for requests
func WithBaseURL(baseURL string) Option {
    return func(c *HTTPClient) {
        c.baseURL = strings.TrimSuffix(baseURL, "/")
    }
}

// WithUserAgent sets a custom user agent
func WithUserAgent(userAgent string) Option {
    return func(c *HTTPClient) {
        c.userAgent = userAgent
    }
}

// WithRateLimiter sets a rate limiter
func WithRateLimiter(limiter RateLimiter) Option {
    return func(c *HTTPClient) {
        c.rateLimiter = limiter
    }
}

// WithMiddleware adds middleware to the client
func WithMiddleware(middleware ...Middleware) Option {
    return func(c *HTTPClient) {
        c.middleware = append(c.middleware, middleware...)
    }
}

// WithLogger sets a custom logger
func WithLogger(logger Logger) Option {
    return func(c *HTTPClient) {
        c.logger = logger
    }
}

// WithTransport sets a custom HTTP transport
func WithTransport(transport *http.Transport) Option {
    return func(c *HTTPClient) {
        c.client.Transport = transport
    }
}

// WithTLS configures TLS settings
func WithTLS(config *tls.Config) Option {
    return func(c *HTTPClient) {
        if transport, ok := c.client.Transport.(*http.Transport); ok {
            transport.TLSClientConfig = config
        }
    }
}

// NewHTTPClient creates a new HTTP client with options
func NewHTTPClient(opts ...Option) *HTTPClient {
    // Create default transport
    transport := &http.Transport{
        MaxIdleConns:        100,
        MaxIdleConnsPerHost: 10,
        IdleConnTimeout:     90 * time.Second,
        DisableCompression:  false,
    }
    
    // Default client configuration
    client := &HTTPClient{
        client: &http.Client{
            Transport: transport,
            Timeout:   30 * time.Second,
        },
        timeout:   30 * time.Second,
        retries:   3,
        userAgent: "MyApp/1.0",
        logger:    &NoOpLogger{},
    }
    
    // Apply all options
    for _, opt := range opts {
        opt(client)
    }
    
    return client
}

// Usage examples:
func ExampleUsage() {
    // Basic client with defaults
    basicClient := NewHTTPClient()
    
    // Client with custom timeout and retries
    customClient := NewHTTPClient(
        WithTimeout(10*time.Second),
        WithRetries(5),
        WithBaseURL("https://api.example.com"),
    )
    
    // Client with advanced configuration
    advancedClient := NewHTTPClient(
        WithTimeout(30*time.Second),
        WithRetries(3),
        WithBaseURL("https://api.example.com"),
        WithUserAgent("MyApp/2.0"),
        WithRateLimiter(NewTokenBucketLimiter(100, time.Minute)),
        WithMiddleware(
            NewLoggingMiddleware(),
            NewRetryMiddleware(),
            NewMetricsMiddleware(),
        ),
        WithTLS(&tls.Config{
            MinVersion: tls.VersionTLS12,
        }),
    )
}
```

### Server Configuration Pattern

```go
package server

import (
    "context"
    "crypto/tls"
    "net"
    "net/http"
    "time"
)

// Server represents an HTTP server with configuration options
type Server struct {
    *http.Server
    logger         Logger
    shutdownHooks  []func(context.Context) error
    middleware     []Middleware
    errorHandler   ErrorHandler
    metrics        MetricsCollector
    rateLimiter    RateLimiter
    cors           CORSConfig
}

// ServerOption configures the server
type ServerOption func(*Server)

// WithAddr sets the server address
func WithAddr(addr string) ServerOption {
    return func(s *Server) {
        s.Addr = addr
    }
}

// WithReadTimeout sets the read timeout
func WithReadTimeout(timeout time.Duration) ServerOption {
    return func(s *Server) {
        s.ReadTimeout = timeout
    }
}

// WithWriteTimeout sets the write timeout
func WithWriteTimeout(timeout time.Duration) ServerOption {
    return func(s *Server) {
        s.WriteTimeout = timeout
    }
}

// WithIdleTimeout sets the idle timeout
func WithIdleTimeout(timeout time.Duration) ServerOption {
    return func(s *Server) {
        s.IdleTimeout = timeout
    }
}

// WithTLSConfig sets TLS configuration
func WithTLSConfig(config *tls.Config) ServerOption {
    return func(s *Server) {
        s.TLSConfig = config
    }
}

// WithLogger sets a custom logger
func WithLogger(logger Logger) ServerOption {
    return func(s *Server) {
        s.logger = logger
    }
}

// WithMiddleware adds middleware to the server
func WithMiddleware(middleware ...Middleware) ServerOption {
    return func(s *Server) {
        s.middleware = append(s.middleware, middleware...)
    }
}

// WithErrorHandler sets a custom error handler
func WithErrorHandler(handler ErrorHandler) ServerOption {
    return func(s *Server) {
        s.errorHandler = handler
    }
}

// WithMetrics sets a metrics collector
func WithMetrics(metrics MetricsCollector) ServerOption {
    return func(s *Server) {
        s.metrics = metrics
    }
}

// WithRateLimiter sets a rate limiter
func WithRateLimiter(limiter RateLimiter) ServerOption {
    return func(s *Server) {
        s.rateLimiter = limiter
    }
}

// WithCORS sets CORS configuration
func WithCORS(cors CORSConfig) ServerOption {
    return func(s *Server) {
        s.cors = cors
    }
}

// WithShutdownHook adds a shutdown hook
func WithShutdownHook(hook func(context.Context) error) ServerOption {
    return func(s *Server) {
        s.shutdownHooks = append(s.shutdownHooks, hook)
    }
}

// WithMaxHeaderBytes sets the maximum header size
func WithMaxHeaderBytes(size int) ServerOption {
    return func(s *Server) {
        s.MaxHeaderBytes = size
    }
}

// NewServer creates a new server with options
func NewServer(handler http.Handler, opts ...ServerOption) *Server {
    server := &Server{
        Server: &http.Server{
            Handler:           handler,
            Addr:              ":8080",
            ReadTimeout:       15 * time.Second,
            WriteTimeout:      15 * time.Second,
            IdleTimeout:       60 * time.Second,
            ReadHeaderTimeout: 5 * time.Second,
            MaxHeaderBytes:    1 << 20, // 1 MB
        },
        logger:        &DefaultLogger{},
        shutdownHooks: make([]func(context.Context) error, 0),
        middleware:    make([]Middleware, 0),
        errorHandler:  &DefaultErrorHandler{},
        metrics:       &NoOpMetrics{},
    }
    
    // Apply all options
    for _, opt := range opts {
        opt(server)
    }
    
    // Wrap handler with middleware
    server.Handler = server.wrapHandler(handler)
    
    return server
}

func (s *Server) wrapHandler(handler http.Handler) http.Handler {
    // Apply middleware in reverse order
    for i := len(s.middleware) - 1; i >= 0; i-- {
        handler = s.middleware[i].Wrap(handler)
    }
    
    // Add built-in middleware
    if s.rateLimiter != nil {
        handler = NewRateLimitMiddleware(s.rateLimiter).Wrap(handler)
    }
    
    if s.metrics != nil {
        handler = NewMetricsMiddleware(s.metrics).Wrap(handler)
    }
    
    if s.cors.Enabled {
        handler = NewCORSMiddleware(s.cors).Wrap(handler)
    }
    
    handler = NewErrorMiddleware(s.errorHandler).Wrap(handler)
    handler = NewLoggingMiddleware(s.logger).Wrap(handler)
    
    return handler
}

// Start starts the server
func (s *Server) Start() error {
    s.logger.Info("server starting", "addr", s.Addr)
    return s.ListenAndServe()
}

// StartTLS starts the server with TLS
func (s *Server) StartTLS(certFile, keyFile string) error {
    s.logger.Info("server starting with TLS", "addr", s.Addr)
    return s.ListenAndServeTLS(certFile, keyFile)
}

// Shutdown gracefully shuts down the server
func (s *Server) Shutdown(ctx context.Context) error {
    s.logger.Info("server shutting down")
    
    // Execute shutdown hooks
    for _, hook := range s.shutdownHooks {
        if err := hook(ctx); err != nil {
            s.logger.Error("shutdown hook failed", "error", err)
        }
    }
    
    return s.Server.Shutdown(ctx)
}
```

### Database Configuration Pattern

```go
package database

import (
    "context"
    "database/sql"
    "fmt"
    "time"
    
    _ "github.com/lib/pq"
)

// DB wraps sql.DB with configuration
type DB struct {
    *sql.DB
    config *Config
    logger Logger
    hooks  *Hooks
}

// Config holds database configuration
type Config struct {
    MaxOpenConns    int
    MaxIdleConns    int
    ConnMaxLifetime time.Duration
    ConnMaxIdleTime time.Duration
    QueryTimeout    time.Duration
    Logger          Logger
    Hooks           *Hooks
}

// Hooks contains database lifecycle hooks
type Hooks struct {
    BeforeConnect func(ctx context.Context, config *Config) error
    AfterConnect  func(ctx context.Context, db *sql.DB) error
    BeforeClose   func(ctx context.Context, db *sql.DB) error
}

// DBOption configures the database
type DBOption func(*Config)

// WithMaxOpenConns sets the maximum number of open connections
func WithMaxOpenConns(max int) DBOption {
    return func(c *Config) {
        c.MaxOpenConns = max
    }
}

// WithMaxIdleConns sets the maximum number of idle connections
func WithMaxIdleConns(max int) DBOption {
    return func(c *Config) {
        c.MaxIdleConns = max
    }
}

// WithConnMaxLifetime sets the maximum lifetime of connections
func WithConnMaxLifetime(lifetime time.Duration) DBOption {
    return func(c *Config) {
        c.ConnMaxLifetime = lifetime
    }
}

// WithConnMaxIdleTime sets the maximum idle time for connections
func WithConnMaxIdleTime(idleTime time.Duration) DBOption {
    return func(c *Config) {
        c.ConnMaxIdleTime = idleTime
    }
}

// WithQueryTimeout sets the default query timeout
func WithQueryTimeout(timeout time.Duration) DBOption {
    return func(c *Config) {
        c.QueryTimeout = timeout
    }
}

// WithDBLogger sets a database logger
func WithDBLogger(logger Logger) DBOption {
    return func(c *Config) {
        c.Logger = logger
    }
}

// WithHooks sets database lifecycle hooks
func WithHooks(hooks *Hooks) DBOption {
    return func(c *Config) {
        c.Hooks = hooks
    }
}

// WithBeforeConnect sets a before connect hook
func WithBeforeConnect(hook func(ctx context.Context, config *Config) error) DBOption {
    return func(c *Config) {
        if c.Hooks == nil {
            c.Hooks = &Hooks{}
        }
        c.Hooks.BeforeConnect = hook
    }
}

// WithAfterConnect sets an after connect hook
func WithAfterConnect(hook func(ctx context.Context, db *sql.DB) error) DBOption {
    return func(c *Config) {
        if c.Hooks == nil {
            c.Hooks = &Hooks{}
        }
        c.Hooks.AfterConnect = hook
    }
}

// NewDB creates a new database connection with options
func NewDB(databaseURL string, opts ...DBOption) (*DB, error) {
    config := &Config{
        MaxOpenConns:    25,
        MaxIdleConns:    5,
        ConnMaxLifetime: time.Hour,
        ConnMaxIdleTime: 30 * time.Minute,
        QueryTimeout:    30 * time.Second,
        Logger:          &DefaultLogger{},
    }
    
    // Apply options
    for _, opt := range opts {
        opt(config)
    }
    
    ctx := context.Background()
    
    // Execute before connect hook
    if config.Hooks != nil && config.Hooks.BeforeConnect != nil {
        if err := config.Hooks.BeforeConnect(ctx, config); err != nil {
            return nil, fmt.Errorf("before connect hook failed: %w", err)
        }
    }
    
    // Open database connection
    db, err := sql.Open("postgres", databaseURL)
    if err != nil {
        return nil, fmt.Errorf("failed to open database: %w", err)
    }
    
    // Configure connection pool
    db.SetMaxOpenConns(config.MaxOpenConns)
    db.SetMaxIdleConns(config.MaxIdleConns)
    db.SetConnMaxLifetime(config.ConnMaxLifetime)
    db.SetConnMaxIdleTime(config.ConnMaxIdleTime)
    
    // Test connection
    if err := db.Ping(); err != nil {
        db.Close()
        return nil, fmt.Errorf("failed to ping database: %w", err)
    }
    
    dbWrapper := &DB{
        DB:     db,
        config: config,
        logger: config.Logger,
        hooks:  config.Hooks,
    }
    
    // Execute after connect hook
    if config.Hooks != nil && config.Hooks.AfterConnect != nil {
        if err := config.Hooks.AfterConnect(ctx, db); err != nil {
            db.Close()
            return nil, fmt.Errorf("after connect hook failed: %w", err)
        }
    }
    
    config.Logger.Info("database connected", 
        "max_open_conns", config.MaxOpenConns,
        "max_idle_conns", config.MaxIdleConns)
    
    return dbWrapper, nil
}

// Close closes the database connection
func (db *DB) Close() error {
    ctx := context.Background()
    
    // Execute before close hook
    if db.hooks != nil && db.hooks.BeforeClose != nil {
        if err := db.hooks.BeforeClose(ctx, db.DB); err != nil {
            db.logger.Error("before close hook failed", "error", err)
        }
    }
    
    return db.DB.Close()
}

// QueryContext executes a query with the configured timeout
func (db *DB) QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error) {
    ctx, cancel := context.WithTimeout(ctx, db.config.QueryTimeout)
    defer cancel()
    
    return db.DB.QueryContext(ctx, query, args...)
}

// ExecContext executes a statement with the configured timeout
func (db *DB) ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error) {
    ctx, cancel := context.WithTimeout(ctx, db.config.QueryTimeout)
    defer cancel()
    
    return db.DB.ExecContext(ctx, query, args...)
}
```

### Cache Configuration Pattern

```go
package cache

import (
    "context"
    "encoding/json"
    "time"
    
    "github.com/redis/go-redis/v9"
)

// Cache wraps Redis client with configuration
type Cache struct {
    client     *redis.Client
    config     *CacheConfig
    serializer Serializer
    logger     Logger
}

// CacheConfig holds cache configuration
type CacheConfig struct {
    KeyPrefix       string
    DefaultTTL      time.Duration
    MaxRetries      int
    RetryDelay      time.Duration
    EnableMetrics   bool
    Logger          Logger
    Serializer      Serializer
    Hooks          *CacheHooks
}

// CacheHooks contains cache operation hooks
type CacheHooks struct {
    BeforeGet func(ctx context.Context, key string)
    AfterGet  func(ctx context.Context, key string, hit bool, err error)
    BeforeSet func(ctx context.Context, key string, value interface{})
    AfterSet  func(ctx context.Context, key string, err error)
}

// CacheOption configures the cache
type CacheOption func(*CacheConfig)

// WithKeyPrefix sets a key prefix for all cache operations
func WithKeyPrefix(prefix string) CacheOption {
    return func(c *CacheConfig) {
        c.KeyPrefix = prefix
    }
}

// WithDefaultTTL sets the default TTL for cache entries
func WithDefaultTTL(ttl time.Duration) CacheOption {
    return func(c *CacheConfig) {
        c.DefaultTTL = ttl
    }
}

// WithMaxRetries sets the maximum number of retries
func WithMaxRetries(retries int) CacheOption {
    return func(c *CacheConfig) {
        c.MaxRetries = retries
    }
}

// WithRetryDelay sets the delay between retries
func WithRetryDelay(delay time.Duration) CacheOption {
    return func(c *CacheConfig) {
        c.RetryDelay = delay
    }
}

// WithMetrics enables metrics collection
func WithMetrics(enabled bool) CacheOption {
    return func(c *CacheConfig) {
        c.EnableMetrics = enabled
    }
}

// WithCacheLogger sets a logger
func WithCacheLogger(logger Logger) CacheOption {
    return func(c *CacheConfig) {
        c.Logger = logger
    }
}

// WithSerializer sets a custom serializer
func WithSerializer(serializer Serializer) CacheOption {
    return func(c *CacheConfig) {
        c.Serializer = serializer
    }
}

// WithCacheHooks sets cache operation hooks
func WithCacheHooks(hooks *CacheHooks) CacheOption {
    return func(c *CacheConfig) {
        c.Hooks = hooks
    }
}

// NewCache creates a new cache with options
func NewCache(client *redis.Client, opts ...CacheOption) *Cache {
    config := &CacheConfig{
        KeyPrefix:     "",
        DefaultTTL:    time.Hour,
        MaxRetries:    3,
        RetryDelay:    time.Millisecond * 100,
        EnableMetrics: false,
        Logger:        &NoOpLogger{},
        Serializer:    &JSONSerializer{},
    }
    
    // Apply options
    for _, opt := range opts {
        opt(config)
    }
    
    return &Cache{
        client:     client,
        config:     config,
        serializer: config.Serializer,
        logger:     config.Logger,
    }
}

// Get retrieves a value from cache
func (c *Cache) Get(ctx context.Context, key string, dest interface{}) error {
    fullKey := c.buildKey(key)
    
    // Execute before hook
    if c.config.Hooks != nil && c.config.Hooks.BeforeGet != nil {
        c.config.Hooks.BeforeGet(ctx, key)
    }
    
    data, err := c.client.Get(ctx, fullKey).Result()
    hit := err == nil
    
    // Execute after hook
    if c.config.Hooks != nil && c.config.Hooks.AfterGet != nil {
        c.config.Hooks.AfterGet(ctx, key, hit, err)
    }
    
    if err != nil {
        if err == redis.Nil {
            return ErrCacheMiss
        }
        return err
    }
    
    return c.serializer.Unmarshal([]byte(data), dest)
}

// Set stores a value in cache
func (c *Cache) Set(ctx context.Context, key string, value interface{}, ttl ...time.Duration) error {
    fullKey := c.buildKey(key)
    
    // Use default TTL if not specified
    cacheTTL := c.config.DefaultTTL
    if len(ttl) > 0 {
        cacheTTL = ttl[0]
    }
    
    // Execute before hook
    if c.config.Hooks != nil && c.config.Hooks.BeforeSet != nil {
        c.config.Hooks.BeforeSet(ctx, key, value)
    }
    
    data, err := c.serializer.Marshal(value)
    if err != nil {
        return err
    }
    
    err = c.client.Set(ctx, fullKey, data, cacheTTL).Err()
    
    // Execute after hook
    if c.config.Hooks != nil && c.config.Hooks.AfterSet != nil {
        c.config.Hooks.AfterSet(ctx, key, err)
    }
    
    return err
}

func (c *Cache) buildKey(key string) string {
    if c.config.KeyPrefix == "" {
        return key
    }
    return c.config.KeyPrefix + ":" + key
}
```

## When to Use Functional Options

### ✅ Use When:

1. **Many optional parameters**: When you have more than 2-3 optional parameters
2. **Future extensibility**: When configuration might grow over time
3. **Sensible defaults**: When you can provide good default values
4. **Library APIs**: When creating libraries that others will use
5. **Complex configuration**: When configuration involves multiple related settings

### ❌ Avoid When:

1. **Simple constructors**: For types with only 1-2 required parameters
2. **Performance critical paths**: Where function call overhead matters
3. **Value setting**: When you just need to set a simple value (use struct fields)
4. **Internal APIs**: For simple internal components

## Best Practices

### 1. Naming Conventions

```go
// Use "With" prefix for options
func WithTimeout(timeout time.Duration) Option { ... }
func WithRetries(retries int) Option { ... }

// Use descriptive names
func WithTLSConfig(config *tls.Config) Option { ... }  // Good
func WithTLS(config *tls.Config) Option { ... }        // Less clear
```

### 2. Provide Good Defaults

```go
func NewClient(opts ...Option) *Client {
    // Always provide sensible defaults
    client := &Client{
        timeout: 30 * time.Second,
        retries: 3,
        logger:  &NoOpLogger{},
    }
    
    for _, opt := range opts {
        opt(client)
    }
    
    return client
}
```

### 3. Validation in Constructor

```go
func NewServer(handler http.Handler, opts ...ServerOption) (*Server, error) {
    server := &Server{
        handler: handler,
        port:    8080,
        timeout: 30 * time.Second,
    }
    
    for _, opt := range opts {
        opt(server)
    }
    
    // Validate configuration
    if server.port <= 0 || server.port > 65535 {
        return nil, fmt.Errorf("invalid port: %d", server.port)
    }
    
    if server.timeout <= 0 {
        return nil, fmt.Errorf("timeout must be positive")
    }
    
    return server, nil
}
```

### 4. Type-Safe Options

```go
// Use types to prevent misuse
type Port int
type Timeout time.Duration

func WithPort(port Port) Option {
    return func(s *Server) {
        s.port = int(port)
    }
}

// Usage
server := NewServer(handler, WithPort(Port(8080)))
```

## Testing Functional Options

```go
func TestServerOptions(t *testing.T) {
    tests := []struct {
        name     string
        options  []ServerOption
        expected *Server
    }{
        {
            name:    "default configuration",
            options: nil,
            expected: &Server{
                port:    8080,
                timeout: 30 * time.Second,
            },
        },
        {
            name: "custom port and timeout",
            options: []ServerOption{
                WithPort(9000),
                WithTimeout(60 * time.Second),
            },
            expected: &Server{
                port:    9000,
                timeout: 60 * time.Second,
            },
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            server := NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}), tt.options...)
            
            assert.Equal(t, tt.expected.port, server.port)
            assert.Equal(t, tt.expected.timeout, server.timeout)
        })
    }
}
```

## Implementation Checklist

- [ ] Identify components that benefit from functional options
- [ ] Define clear option interfaces
- [ ] Implement sensible defaults
- [ ] Add validation in constructors
- [ ] Write comprehensive tests
- [ ] Document option usage and examples
- [ ] Consider performance implications
- [ ] Plan for future extensibility

## Consequences

**Benefits:**
- Clean, readable configuration API
- Backward compatible extensibility
- Sensible defaults with customization
- Self-documenting configuration
- Type-safe option handling

**Challenges:**
- Slight performance overhead
- More complex than simple constructors
- Can be overused for simple cases
- Requires good documentation

**Trade-offs:**
- Flexibility vs. simplicity
- Type safety vs. ease of use
- Performance vs. ergonomics
