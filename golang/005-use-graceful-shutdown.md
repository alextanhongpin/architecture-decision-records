# Graceful Shutdown in Go

## Status

`production`

## Context

Graceful shutdown ensures that applications terminate cleanly, completing in-flight operations and releasing resources properly. Without graceful shutdown, applications may lose data, leave transactions uncommitted, or cause client timeouts.

This is critical for production systems that need to handle deployments, scaling events, and maintenance operations without service degradation.

## Decision

We will implement a comprehensive graceful shutdown pattern that handles HTTP servers, background workers, database connections, and other resources systematically.

### Core Shutdown Framework

```go
package shutdown

import (
    "context"
    "fmt"
    "os"
    "os/signal"
    "sync"
    "syscall"
    "time"
    
    "log/slog"
)

// Shutdowner manages graceful shutdown of application components
type Shutdowner struct {
    logger      *slog.Logger
    hooks       []Hook
    timeout     time.Duration
    mu          sync.Mutex
    shutdownCh  chan struct{}
    doneCh      chan struct{}
    once        sync.Once
}

// Hook represents a function that should be called during shutdown
type Hook struct {
    Name     string
    Priority int           // Lower numbers execute first
    Timeout  time.Duration // Individual timeout for this hook
    Fn       func(ctx context.Context) error
}

// New creates a new Shutdowner
func New(logger *slog.Logger, timeout time.Duration) *Shutdowner {
    return &Shutdowner{
        logger:     logger,
        hooks:      make([]Hook, 0),
        timeout:    timeout,
        shutdownCh: make(chan struct{}),
        doneCh:     make(chan struct{}),
    }
}

// AddHook registers a shutdown hook
func (s *Shutdowner) AddHook(name string, priority int, timeout time.Duration, fn func(ctx context.Context) error) {
    s.mu.Lock()
    defer s.mu.Unlock()
    
    hook := Hook{
        Name:     name,
        Priority: priority,
        Timeout:  timeout,
        Fn:       fn,
    }
    
    s.hooks = append(s.hooks, hook)
    s.sortHooks()
    
    s.logger.Debug("shutdown hook registered", "name", name, "priority", priority)
}

// ListenForSignals starts listening for shutdown signals
func (s *Shutdowner) ListenForSignals() {
    sigCh := make(chan os.Signal, 1)
    signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM, syscall.SIGQUIT)
    
    go func() {
        sig := <-sigCh
        s.logger.Info("shutdown signal received", "signal", sig.String())
        s.Shutdown()
    }()
}

// Shutdown initiates the graceful shutdown process
func (s *Shutdowner) Shutdown() {
    s.once.Do(func() {
        close(s.shutdownCh)
        
        s.logger.Info("graceful shutdown initiated", "timeout", s.timeout)
        
        ctx, cancel := context.WithTimeout(context.Background(), s.timeout)
        defer cancel()
        
        var wg sync.WaitGroup
        errors := make(chan error, len(s.hooks))
        
        // Execute hooks in priority order
        for _, hook := range s.hooks {
            wg.Add(1)
            go s.executeHook(ctx, hook, &wg, errors)
        }
        
        // Wait for all hooks to complete or timeout
        go func() {
            wg.Wait()
            close(errors)
            close(s.doneCh)
        }()
        
        // Collect any errors
        var shutdownErrors []error
        for err := range errors {
            if err != nil {
                shutdownErrors = append(shutdownErrors, err)
            }
        }
        
        if len(shutdownErrors) > 0 {
            s.logger.Error("shutdown completed with errors", "errors", shutdownErrors)
        } else {
            s.logger.Info("graceful shutdown completed successfully")
        }
    })
}

// Wait blocks until shutdown is complete
func (s *Shutdowner) Wait() {
    <-s.doneCh
}

// Done returns a channel that's closed when shutdown is initiated
func (s *Shutdowner) Done() <-chan struct{} {
    return s.shutdownCh
}

func (s *Shutdowner) executeHook(ctx context.Context, hook Hook, wg *sync.WaitGroup, errors chan<- error) {
    defer wg.Done()
    
    hookCtx, cancel := context.WithTimeout(ctx, hook.Timeout)
    defer cancel()
    
    s.logger.Debug("executing shutdown hook", "name", hook.Name)
    
    start := time.Now()
    err := hook.Fn(hookCtx)
    duration := time.Since(start)
    
    if err != nil {
        s.logger.Error("shutdown hook failed", 
            "name", hook.Name, 
            "error", err, 
            "duration", duration)
        errors <- fmt.Errorf("hook %s failed: %w", hook.Name, err)
    } else {
        s.logger.Debug("shutdown hook completed", 
            "name", hook.Name, 
            "duration", duration)
        errors <- nil
    }
}

func (s *Shutdowner) sortHooks() {
    sort.Slice(s.hooks, func(i, j int) bool {
        return s.hooks[i].Priority < s.hooks[j].Priority
    })
}
```

### HTTP Server Shutdown

```go
package server

import (
    "context"
    "errors"
    "fmt"
    "net"
    "net/http"
    "time"
    
    "log/slog"
)

const (
    MaxBytesSize         = 1 << 20       // 1 MB
    ReadTimeout          = 5 * time.Second
    WriteTimeout         = 10 * time.Second
    IdleTimeout          = 60 * time.Second
    HandlerTimeout       = 30 * time.Second
    DefaultShutdownTimeout = 30 * time.Second
)

// Server wraps http.Server with graceful shutdown capabilities
type Server struct {
    *http.Server
    logger     *slog.Logger
    shutdowner *shutdown.Shutdowner
    listener   net.Listener
}

// New creates a new server with graceful shutdown
func New(handler http.Handler, port int, logger *slog.Logger, shutdowner *shutdown.Shutdowner) *Server {
    // Apply timeouts and size limits
    handler = http.TimeoutHandler(handler, HandlerTimeout, `{"error": "Request timeout"}`)
    handler = http.MaxBytesHandler(handler, MaxBytesSize)
    
    srv := &http.Server{
        Addr:              fmt.Sprintf(":%d", port),
        Handler:           handler,
        ReadTimeout:       ReadTimeout,
        WriteTimeout:      WriteTimeout,
        IdleTimeout:       IdleTimeout,
        ReadHeaderTimeout: ReadTimeout,
        MaxHeaderBytes:    1 << 20, // 1 MB
    }
    
    server := &Server{
        Server:     srv,
        logger:     logger,
        shutdowner: shutdowner,
    }
    
    // Register shutdown hook for HTTP server
    shutdowner.AddHook("http-server", 10, DefaultShutdownTimeout, server.shutdown)
    
    return server
}

// Start starts the HTTP server
func (s *Server) Start() error {
    listener, err := net.Listen("tcp", s.Addr)
    if err != nil {
        return fmt.Errorf("failed to create listener: %w", err)
    }
    
    s.listener = listener
    
    s.logger.Info("http server starting", 
        "addr", s.Addr, 
        "read_timeout", ReadTimeout,
        "write_timeout", WriteTimeout)
    
    if err := s.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
        return fmt.Errorf("http server error: %w", err)
    }
    
    return nil
}

// shutdown handles graceful shutdown of the HTTP server
func (s *Server) shutdown(ctx context.Context) error {
    s.logger.Info("shutting down http server")
    
    // Stop accepting new connections
    if err := s.Server.Shutdown(ctx); err != nil {
        s.logger.Error("http server shutdown error", "error", err)
        
        // Force close if graceful shutdown fails
        if closeErr := s.Server.Close(); closeErr != nil {
            return fmt.Errorf("failed to force close server: %w", closeErr)
        }
        
        return fmt.Errorf("http server shutdown timeout: %w", err)
    }
    
    s.logger.Info("http server shutdown completed")
    return nil
}

// ListenAndServeWithShutdown starts the server and handles shutdown
func (s *Server) ListenAndServeWithShutdown() error {
    // Start shutdown signal listener
    s.shutdowner.ListenForSignals()
    
    // Start server in goroutine
    serverErr := make(chan error, 1)
    go func() {
        serverErr <- s.Start()
    }()
    
    // Wait for shutdown signal or server error
    select {
    case err := <-serverErr:
        if err != nil {
            s.logger.Error("server startup failed", "error", err)
            return err
        }
    case <-s.shutdowner.Done():
        s.logger.Info("shutdown signal received")
    }
    
    // Wait for graceful shutdown to complete
    s.shutdowner.Wait()
    
    return nil
}
```

### Database Connection Shutdown

```go
package database

import (
    "context"
    "database/sql"
    "fmt"
    "time"
    
    "log/slog"
)

// DB wraps sql.DB with graceful shutdown
type DB struct {
    *sql.DB
    logger     *slog.Logger
    shutdowner *shutdown.Shutdowner
}

// New creates a new database connection with shutdown handling
func New(databaseURL string, logger *slog.Logger, shutdowner *shutdown.Shutdowner) (*DB, error) {
    db, err := sql.Open("postgres", databaseURL)
    if err != nil {
        return nil, fmt.Errorf("failed to open database: %w", err)
    }
    
    // Configure connection pool
    db.SetMaxOpenConns(25)
    db.SetMaxIdleConns(5)
    db.SetConnMaxLifetime(time.Hour)
    db.SetConnMaxIdleTime(time.Minute * 30)
    
    // Test connection
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    
    if err := db.PingContext(ctx); err != nil {
        db.Close()
        return nil, fmt.Errorf("failed to ping database: %w", err)
    }
    
    dbWrapper := &DB{
        DB:         db,
        logger:     logger,
        shutdowner: shutdowner,
    }
    
    // Register shutdown hook
    shutdowner.AddHook("database", 20, 10*time.Second, dbWrapper.shutdown)
    
    logger.Info("database connection established")
    
    return dbWrapper, nil
}

func (d *DB) shutdown(ctx context.Context) error {
    d.logger.Info("closing database connections")
    
    // Close all connections
    if err := d.DB.Close(); err != nil {
        return fmt.Errorf("failed to close database: %w", err)
    }
    
    d.logger.Info("database connections closed")
    return nil
}
```

### Background Worker Shutdown

```go
package worker

import (
    "context"
    "fmt"
    "sync"
    "time"
    
    "log/slog"
)

// WorkerPool manages background workers with graceful shutdown
type WorkerPool struct {
    logger      *slog.Logger
    shutdowner  *shutdown.Shutdowner
    workers     []Worker
    workerCount int
    jobCh       chan Job
    wg          sync.WaitGroup
    mu          sync.RWMutex
    started     bool
}

// Job represents work to be done
type Job interface {
    Execute(ctx context.Context) error
    ID() string
}

// Worker processes jobs
type Worker struct {
    id     int
    pool   *WorkerPool
    logger *slog.Logger
}

// NewWorkerPool creates a new worker pool
func NewWorkerPool(workerCount int, bufferSize int, logger *slog.Logger, shutdowner *shutdown.Shutdowner) *WorkerPool {
    pool := &WorkerPool{
        logger:      logger,
        shutdowner:  shutdowner,
        workers:     make([]Worker, workerCount),
        workerCount: workerCount,
        jobCh:       make(chan Job, bufferSize),
    }
    
    // Initialize workers
    for i := 0; i < workerCount; i++ {
        pool.workers[i] = Worker{
            id:     i,
            pool:   pool,
            logger: logger.With("worker_id", i),
        }
    }
    
    // Register shutdown hook
    shutdowner.AddHook("worker-pool", 5, 30*time.Second, pool.shutdown)
    
    return pool
}

// Start starts all workers
func (p *WorkerPool) Start(ctx context.Context) {
    p.mu.Lock()
    defer p.mu.Unlock()
    
    if p.started {
        return
    }
    
    p.started = true
    
    for i := range p.workers {
        p.wg.Add(1)
        go p.workers[i].start(ctx)
    }
    
    p.logger.Info("worker pool started", "worker_count", p.workerCount)
}

// Submit adds a job to the queue
func (p *WorkerPool) Submit(job Job) error {
    p.mu.RLock()
    defer p.mu.RUnlock()
    
    if !p.started {
        return fmt.Errorf("worker pool not started")
    }
    
    select {
    case p.jobCh <- job:
        return nil
    default:
        return fmt.Errorf("job queue full")
    }
}

func (w *Worker) start(ctx context.Context) {
    defer w.pool.wg.Done()
    
    w.logger.Debug("worker started")
    
    for {
        select {
        case job := <-w.pool.jobCh:
            w.processJob(ctx, job)
        case <-ctx.Done():
            w.logger.Debug("worker stopping")
            return
        }
    }
}

func (w *Worker) processJob(ctx context.Context, job Job) {
    jobCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
    defer cancel()
    
    start := time.Now()
    err := job.Execute(jobCtx)
    duration := time.Since(start)
    
    if err != nil {
        w.logger.Error("job failed", 
            "job_id", job.ID(), 
            "error", err, 
            "duration", duration)
    } else {
        w.logger.Debug("job completed", 
            "job_id", job.ID(), 
            "duration", duration)
    }
}

func (p *WorkerPool) shutdown(ctx context.Context) error {
    p.logger.Info("shutting down worker pool")
    
    p.mu.Lock()
    if !p.started {
        p.mu.Unlock()
        return nil
    }
    
    // Close job channel to stop accepting new jobs
    close(p.jobCh)
    p.mu.Unlock()
    
    // Wait for workers to finish current jobs
    done := make(chan struct{})
    go func() {
        p.wg.Wait()
        close(done)
    }()
    
    select {
    case <-done:
        p.logger.Info("worker pool shutdown completed")
        return nil
    case <-ctx.Done():
        p.logger.Warn("worker pool shutdown timeout")
        return ctx.Err()
    }
}
```

### Application Bootstrap

```go
package main

import (
    "context"
    "log/slog"
    "os"
    "time"
)

func main() {
    // Initialize logger
    logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
        Level: slog.LevelInfo,
    }))
    
    // Create shutdowner
    shutdowner := shutdown.New(logger, 45*time.Second)
    
    // Initialize dependencies
    container := container.New()
    
    // Register cleanup hook for container
    shutdowner.AddHook("container", 100, 10*time.Second, func(ctx context.Context) error {
        return container.Cleanup()
    })
    
    // Initialize database
    db, err := database.New(container.Config().DatabaseURL, logger, shutdowner)
    if err != nil {
        logger.Error("failed to initialize database", "error", err)
        os.Exit(1)
    }
    
    // Initialize worker pool
    workerPool := worker.NewWorkerPool(5, 100, logger, shutdowner)
    workerPool.Start(context.Background())
    
    // Initialize HTTP server
    handler := setupRoutes(container, logger)
    server := server.New(handler, 8080, logger, shutdowner)
    
    // Register health check endpoint
    shutdowner.AddHook("health-check", 1, 5*time.Second, func(ctx context.Context) error {
        // Stop health checks immediately to fail load balancer checks
        logger.Info("health checks disabled for shutdown")
        return nil
    })
    
    // Start server with graceful shutdown
    if err := server.ListenAndServeWithShutdown(); err != nil {
        logger.Error("server error", "error", err)
        os.Exit(1)
    }
    
    logger.Info("application shutdown complete")
}

func setupRoutes(container *container.Container, logger *slog.Logger) http.Handler {
    mux := http.NewServeMux()
    
    // Health check endpoint
    mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("OK"))
    })
    
    // API routes
    userHandler := container.NewUserHandler()
    mux.HandleFunc("/api/users", userHandler.CreateUser)
    mux.HandleFunc("/api/users/", userHandler.GetUser)
    
    return mux
}
```

### Kubernetes Integration

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: myapp
        image: myapp:latest
        ports:
        - containerPort: 8080
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: myapp-secrets
              key: database-url
        
        # Health checks
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          successThreshold: 1
          failureThreshold: 3
        
        # Graceful shutdown configuration
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sleep", "15"]
        
        # Resource limits
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      
      # Graceful termination
      terminationGracePeriodSeconds: 60
```

## Best Practices

### 1. Shutdown Hook Priorities

```go
// Priority order (lower numbers execute first):
// 1-10:   Immediate stop operations (health checks, load balancer removal)
// 11-20:  Application services (HTTP servers, gRPC servers)
// 21-30:  Background workers and processors
// 31-50:  External connections (databases, caches, message queues)
// 51-100: Cleanup operations (file handles, temporary resources)
```

### 2. Timeout Management

```go
// Use appropriate timeouts for different components
shutdowner.AddHook("http-server", 10, 30*time.Second, httpShutdown)
shutdowner.AddHook("database", 20, 10*time.Second, dbShutdown)
shutdowner.AddHook("cache-flush", 30, 5*time.Second, cacheShutdown)
```

### 3. Context Propagation

```go
// Always respect context cancellation in long-running operations
func processWithShutdown(ctx context.Context, items []Item) error {
    for _, item := range items {
        select {
        case <-ctx.Done():
            return ctx.Err() // Respect shutdown signal
        default:
            if err := processItem(item); err != nil {
                return err
            }
        }
    }
    return nil
}
```

### 4. Health Check Integration

```go
// Disable health checks early in shutdown process
func healthCheckShutdown(ctx context.Context) error {
    // This allows load balancers to stop routing traffic
    healthCheck.Disable()
    
    // Wait a bit for load balancer to react
    select {
    case <-time.After(5 * time.Second):
    case <-ctx.Done():
    }
    
    return nil
}
```

## Testing Graceful Shutdown

```go
func TestGracefulShutdown(t *testing.T) {
    logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
    shutdowner := shutdown.New(logger, 10*time.Second)
    
    var shutdownCalled bool
    shutdowner.AddHook("test", 10, 5*time.Second, func(ctx context.Context) error {
        shutdownCalled = true
        return nil
    })
    
    // Start shutdown
    go shutdowner.Shutdown()
    
    // Wait for completion
    shutdowner.Wait()
    
    assert.True(t, shutdownCalled)
}
```

## Implementation Checklist

- [ ] Implement shutdown framework
- [ ] Add HTTP server graceful shutdown
- [ ] Handle database connection cleanup
- [ ] Implement worker pool shutdown
- [ ] Set up signal handling
- [ ] Configure appropriate timeouts
- [ ] Test shutdown behavior
- [ ] Document shutdown sequence
- [ ] Configure Kubernetes termination settings
- [ ] Set up monitoring for shutdown events

## Consequences

**Benefits:**
- Zero-downtime deployments
- Data integrity during shutdowns
- Improved user experience
- Better resource cleanup
- Predictable shutdown behavior

**Challenges:**
- Increased complexity
- Need for careful timeout tuning
- Testing shutdown scenarios
- Coordination between components

**Trade-offs:**
- Shutdown speed vs. data safety
- Complexity vs. reliability
- Resource usage vs. graceful handling

```go
func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		select {
		case <-ctx.Done():
			fmt.Println("http graceful shutdown")
			w.WriteHeader(http.StatusOK)
		case <-time.After(2 * time.Second):
			fmt.Fprint(w, "hello world")
		}
	})
	server.New(mux, 8080)
}
```
