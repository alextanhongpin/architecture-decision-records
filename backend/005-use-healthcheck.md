# Use Health Checks

## Status

`accepted`

## Context

Health checks are essential for monitoring application health and enabling automated operations in containerized and cloud environments. They provide visibility into service status, enable load balancer routing decisions, and support orchestration platforms like Kubernetes in making restart/scaling decisions.

Health checks serve multiple purposes:
- **Service Discovery**: Determine if a service is ready to receive traffic
- **Load Balancer Configuration**: Route traffic only to healthy instances
- **Monitoring and Alerting**: Detect service degradation or failures
- **Automated Recovery**: Enable automatic restart or replacement of unhealthy instances
- **Deployment Validation**: Verify successful deployments before routing traffic

## Decision

Implement comprehensive health check endpoints following industry standards and Kubernetes conventions. Health checks should be:
- **Fast and Lightweight**: Complete within 1-2 seconds
- **Comprehensive**: Check critical dependencies and internal state
- **Standardized**: Follow established endpoint conventions
- **Informative**: Provide actionable diagnostic information

## Implementation

### Health Check Endpoint Structure

Follow Kubernetes health check conventions with multiple endpoints:

```go
package health

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "net/http"
    "time"
    
    "github.com/go-redis/redis/v8"
)

// Health check endpoints
const (
    LivenessPath  = "/healthz"      // Kubernetes liveness probe
    ReadinessPath = "/readyz"       // Kubernetes readiness probe
    HealthPath    = "/health"       // General health endpoint
    DiagnosticPath = "/health/diagnostic" // Detailed diagnostic info
)

type HealthStatus string

const (
    StatusHealthy   HealthStatus = "healthy"
    StatusUnhealthy HealthStatus = "unhealthy"
    StatusDegraded  HealthStatus = "degraded"
)

type HealthResponse struct {
    Status      HealthStatus           `json:"status"`
    Timestamp   time.Time              `json:"timestamp"`
    Uptime      time.Duration          `json:"uptime"`
    Version     string                 `json:"version"`
    GitCommit   string                 `json:"gitCommit,omitempty"`
    BuildDate   string                 `json:"buildDate,omitempty"`
    Checks      map[string]CheckResult `json:"checks"`
    Message     string                 `json:"message,omitempty"`
}

type CheckResult struct {
    Status      HealthStatus  `json:"status"`
    Message     string        `json:"message,omitempty"`
    Duration    time.Duration `json:"duration"`
    LastChecked time.Time     `json:"lastChecked"`
    Error       string        `json:"error,omitempty"`
}

type HealthChecker struct {
    startTime   time.Time
    version     string
    gitCommit   string
    buildDate   string
    checks      map[string]Check
    db          *sql.DB
    redis       *redis.Client
}

type Check interface {
    Name() string
    Check(ctx context.Context) CheckResult
}
```

### Core Health Checker Implementation

```go
func NewHealthChecker(version, gitCommit, buildDate string) *HealthChecker {
    return &HealthChecker{
        startTime: time.Now(),
        version:   version,
        gitCommit: gitCommit,
        buildDate: buildDate,
        checks:    make(map[string]Check),
    }
}

func (h *HealthChecker) AddCheck(check Check) {
    h.checks[check.Name()] = check
}

func (h *HealthChecker) SetDatabase(db *sql.DB) {
    h.db = db
    h.AddCheck(&DatabaseCheck{db: db})
}

func (h *HealthChecker) SetRedis(client *redis.Client) {
    h.redis = client
    h.AddCheck(&RedisCheck{client: client})
}

// Liveness probe - should only fail if the application is deadlocked or corrupted
func (h *HealthChecker) LivenessHandler(w http.ResponseWriter, r *http.Request) {
    ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
    defer cancel()
    
    // Basic liveness check - minimal dependencies
    response := &HealthResponse{
        Status:    StatusHealthy,
        Timestamp: time.Now(),
        Uptime:    time.Since(h.startTime),
        Version:   h.version,
        GitCommit: h.gitCommit,
        BuildDate: h.buildDate,
        Checks:    make(map[string]CheckResult),
    }
    
    // Only include critical internal checks for liveness
    for name, check := range h.checks {
        if isCriticalCheck(name) {
            result := check.Check(ctx)
            response.Checks[name] = result
            
            if result.Status == StatusUnhealthy {
                response.Status = StatusUnhealthy
                response.Message = fmt.Sprintf("Critical check failed: %s", name)
                break
            }
        }
    }
    
    statusCode := http.StatusOK
    if response.Status == StatusUnhealthy {
        statusCode = http.StatusServiceUnavailable
    }
    
    writeHealthResponse(w, response, statusCode)
}

// Readiness probe - checks if service is ready to receive traffic
func (h *HealthChecker) ReadinessHandler(w http.ResponseWriter, r *http.Request) {
    ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
    defer cancel()
    
    response := &HealthResponse{
        Status:    StatusHealthy,
        Timestamp: time.Now(),
        Uptime:    time.Since(h.startTime),
        Version:   h.version,
        Checks:    make(map[string]CheckResult),
    }
    
    // Check all dependencies for readiness
    var unhealthyCount int
    for name, check := range h.checks {
        result := check.Check(ctx)
        response.Checks[name] = result
        
        switch result.Status {
        case StatusUnhealthy:
            unhealthyCount++
            if isReadinessBlocker(name) {
                response.Status = StatusUnhealthy
                response.Message = fmt.Sprintf("Readiness blocker failed: %s", name)
            }
        case StatusDegraded:
            if response.Status == StatusHealthy {
                response.Status = StatusDegraded
            }
        }
    }
    
    // Service is unhealthy if too many dependencies are down
    if unhealthyCount > len(h.checks)/2 {
        response.Status = StatusUnhealthy
        response.Message = "Too many dependencies are unhealthy"
    }
    
    statusCode := http.StatusOK
    if response.Status == StatusUnhealthy {
        statusCode = http.StatusServiceUnavailable
    }
    
    writeHealthResponse(w, response, statusCode)
}

// Detailed health endpoint with full diagnostic information
func (h *HealthChecker) HealthHandler(w http.ResponseWriter, r *http.Request) {
    ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
    defer cancel()
    
    response := &HealthResponse{
        Status:    StatusHealthy,
        Timestamp: time.Now(),
        Uptime:    time.Since(h.startTime),
        Version:   h.version,
        GitCommit: h.gitCommit,
        BuildDate: h.buildDate,
        Checks:    make(map[string]CheckResult),
    }
    
    // Run all health checks
    for name, check := range h.checks {
        result := check.Check(ctx)
        response.Checks[name] = result
        
        if result.Status == StatusUnhealthy {
            response.Status = StatusUnhealthy
        } else if result.Status == StatusDegraded && response.Status == StatusHealthy {
            response.Status = StatusDegraded
        }
    }
    
    statusCode := http.StatusOK
    if response.Status == StatusUnhealthy {
        statusCode = http.StatusServiceUnavailable
    }
    
    writeHealthResponse(w, response, statusCode)
}

func writeHealthResponse(w http.ResponseWriter, response *HealthResponse, statusCode int) {
    w.Header().Set("Content-Type", "application/json")
    w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
    w.WriteHeader(statusCode)
    
    json.NewEncoder(w).Encode(response)
}

func isCriticalCheck(name string) bool {
    // Only memory, CPU, or internal state checks are critical for liveness
    criticalChecks := []string{"memory", "cpu", "goroutines", "internal"}
    for _, critical := range criticalChecks {
        if name == critical {
            return true
        }
    }
    return false
}

func isReadinessBlocker(name string) bool {
    // Database and cache are typically readiness blockers
    blockers := []string{"database", "redis", "primary_cache"}
    for _, blocker := range blockers {
        if name == blocker {
            return true
        }
    }
    return false
}
```

### Database Health Check

```go
type DatabaseCheck struct {
    db      *sql.DB
    timeout time.Duration
}

func NewDatabaseCheck(db *sql.DB) *DatabaseCheck {
    return &DatabaseCheck{
        db:      db,
        timeout: 5 * time.Second,
    }
}

func (d *DatabaseCheck) Name() string {
    return "database"
}

func (d *DatabaseCheck) Check(ctx context.Context) CheckResult {
    start := time.Now()
    defer func() {
        // Always record the duration
    }()
    
    ctx, cancel := context.WithTimeout(ctx, d.timeout)
    defer cancel()
    
    // Simple ping check
    if err := d.db.PingContext(ctx); err != nil {
        return CheckResult{
            Status:      StatusUnhealthy,
            Message:     "Database ping failed",
            Duration:    time.Since(start),
            LastChecked: time.Now(),
            Error:       err.Error(),
        }
    }
    
    // Check database connectivity with a simple query
    var result int
    query := "SELECT 1"
    if err := d.db.QueryRowContext(ctx, query).Scan(&result); err != nil {
        return CheckResult{
            Status:      StatusUnhealthy,
            Message:     "Database query failed",
            Duration:    time.Since(start),
            LastChecked: time.Now(),
            Error:       err.Error(),
        }
    }
    
    duration := time.Since(start)
    
    // Check if database is responding slowly
    if duration > 2*time.Second {
        return CheckResult{
            Status:      StatusDegraded,
            Message:     "Database responding slowly",
            Duration:    duration,
            LastChecked: time.Now(),
        }
    }
    
    return CheckResult{
        Status:      StatusHealthy,
        Message:     "Database connection healthy",
        Duration:    duration,
        LastChecked: time.Now(),
    }
}
```

### Redis Health Check

```go
type RedisCheck struct {
    client  *redis.Client
    timeout time.Duration
}

func NewRedisCheck(client *redis.Client) *RedisCheck {
    return &RedisCheck{
        client:  client,
        timeout: 3 * time.Second,
    }
}

func (r *RedisCheck) Name() string {
    return "redis"
}

func (r *RedisCheck) Check(ctx context.Context) CheckResult {
    start := time.Now()
    
    ctx, cancel := context.WithTimeout(ctx, r.timeout)
    defer cancel()
    
    // Ping Redis
    if err := r.client.Ping(ctx).Err(); err != nil {
        return CheckResult{
            Status:      StatusUnhealthy,
            Message:     "Redis ping failed",
            Duration:    time.Since(start),
            LastChecked: time.Now(),
            Error:       err.Error(),
        }
    }
    
    // Test basic operations
    testKey := fmt.Sprintf("health_check_%d", time.Now().UnixNano())
    if err := r.client.Set(ctx, testKey, "test", time.Minute).Err(); err != nil {
        return CheckResult{
            Status:      StatusUnhealthy,
            Message:     "Redis write failed",
            Duration:    time.Since(start),
            LastChecked: time.Now(),
            Error:       err.Error(),
        }
    }
    
    if _, err := r.client.Get(ctx, testKey).Result(); err != nil {
        return CheckResult{
            Status:      StatusUnhealthy,
            Message:     "Redis read failed",
            Duration:    time.Since(start),
            LastChecked: time.Now(),
            Error:       err.Error(),
        }
    }
    
    // Clean up test key
    r.client.Del(ctx, testKey)
    
    duration := time.Since(start)
    
    if duration > 1*time.Second {
        return CheckResult{
            Status:      StatusDegraded,
            Message:     "Redis responding slowly",
            Duration:    duration,
            LastChecked: time.Now(),
        }
    }
    
    return CheckResult{
        Status:      StatusHealthy,
        Message:     "Redis connection healthy",
        Duration:    duration,
        LastChecked: time.Now(),
    }
}
```

### External Service Health Check

```go
type ExternalServiceCheck struct {
    name        string
    url         string
    client      *http.Client
    timeout     time.Duration
    expectedCode int
}

func NewExternalServiceCheck(name, url string, timeout time.Duration) *ExternalServiceCheck {
    return &ExternalServiceCheck{
        name:         name,
        url:          url,
        timeout:      timeout,
        expectedCode: http.StatusOK,
        client: &http.Client{
            Timeout: timeout,
        },
    }
}

func (e *ExternalServiceCheck) Name() string {
    return e.name
}

func (e *ExternalServiceCheck) Check(ctx context.Context) CheckResult {
    start := time.Now()
    
    req, err := http.NewRequestWithContext(ctx, "GET", e.url, nil)
    if err != nil {
        return CheckResult{
            Status:      StatusUnhealthy,
            Message:     "Failed to create request",
            Duration:    time.Since(start),
            LastChecked: time.Now(),
            Error:       err.Error(),
        }
    }
    
    resp, err := e.client.Do(req)
    if err != nil {
        return CheckResult{
            Status:      StatusUnhealthy,
            Message:     "Request failed",
            Duration:    time.Since(start),
            LastChecked: time.Now(),
            Error:       err.Error(),
        }
    }
    defer resp.Body.Close()
    
    duration := time.Since(start)
    
    if resp.StatusCode != e.expectedCode {
        return CheckResult{
            Status:      StatusUnhealthy,
            Message:     fmt.Sprintf("Unexpected status code: %d", resp.StatusCode),
            Duration:    duration,
            LastChecked: time.Now(),
        }
    }
    
    if duration > 5*time.Second {
        return CheckResult{
            Status:      StatusDegraded,
            Message:     "Service responding slowly",
            Duration:    duration,
            LastChecked: time.Now(),
        }
    }
    
    return CheckResult{
        Status:      StatusHealthy,
        Message:     "External service healthy",
        Duration:    duration,
        LastChecked: time.Now(),
    }
}
```

### System Resource Checks

```go
type SystemResourceCheck struct {
    memoryThreshold float64 // Percentage
    goroutineThreshold int
}

func NewSystemResourceCheck(memoryThreshold float64, goroutineThreshold int) *SystemResourceCheck {
    return &SystemResourceCheck{
        memoryThreshold:    memoryThreshold,
        goroutineThreshold: goroutineThreshold,
    }
}

func (s *SystemResourceCheck) Name() string {
    return "system_resources"
}

func (s *SystemResourceCheck) Check(ctx context.Context) CheckResult {
    start := time.Now()
    
    var m runtime.MemStats
    runtime.ReadMemStats(&m)
    
    // Check memory usage
    memoryUsageMB := float64(m.Alloc) / 1024 / 1024
    memoryUsagePercent := float64(m.Alloc) / float64(m.Sys) * 100
    
    // Check goroutine count
    goroutineCount := runtime.NumGoroutine()
    
    var issues []string
    status := StatusHealthy
    
    if memoryUsagePercent > s.memoryThreshold {
        issues = append(issues, fmt.Sprintf("High memory usage: %.1f%%", memoryUsagePercent))
        status = StatusDegraded
        
        if memoryUsagePercent > 90 {
            status = StatusUnhealthy
        }
    }
    
    if goroutineCount > s.goroutineThreshold {
        issues = append(issues, fmt.Sprintf("High goroutine count: %d", goroutineCount))
        if status == StatusHealthy {
            status = StatusDegraded
        }
        
        if goroutineCount > s.goroutineThreshold*2 {
            status = StatusUnhealthy
        }
    }
    
    message := fmt.Sprintf("Memory: %.1fMB (%.1f%%), Goroutines: %d", 
        memoryUsageMB, memoryUsagePercent, goroutineCount)
    
    if len(issues) > 0 {
        message = strings.Join(issues, "; ")
    }
    
    return CheckResult{
        Status:      status,
        Message:     message,
        Duration:    time.Since(start),
        LastChecked: time.Now(),
    }
}
```

### HTTP Server Integration

```go
func SetupHealthEndpoints(mux *http.ServeMux, checker *HealthChecker) {
    // Kubernetes standard endpoints
    mux.HandleFunc(LivenessPath, checker.LivenessHandler)
    mux.HandleFunc(ReadinessPath, checker.ReadinessHandler)
    
    // General health endpoints
    mux.HandleFunc(HealthPath, checker.HealthHandler)
    mux.HandleFunc(DiagnosticPath, checker.HealthHandler) // Same as health for now
}

// Example server setup
func main() {
    // Build info (typically injected at build time)
    version := "1.0.0"
    gitCommit := "abc123"
    buildDate := "2024-01-01T00:00:00Z"
    
    // Initialize health checker
    healthChecker := NewHealthChecker(version, gitCommit, buildDate)
    
    // Add database
    db, err := sql.Open("postgres", "postgresql://...")
    if err != nil {
        log.Fatal(err)
    }
    healthChecker.SetDatabase(db)
    
    // Add Redis
    rdb := redis.NewClient(&redis.Options{
        Addr: "localhost:6379",
    })
    healthChecker.SetRedis(rdb)
    
    // Add external service checks
    healthChecker.AddCheck(NewExternalServiceCheck(
        "payment_gateway",
        "https://api.payment.com/health",
        5*time.Second,
    ))
    
    // Add system resource check
    healthChecker.AddCheck(NewSystemResourceCheck(80.0, 1000))
    
    // Setup HTTP server
    mux := http.NewServeMux()
    SetupHealthEndpoints(mux, healthChecker)
    
    // Add your other routes
    mux.HandleFunc("/api/users", usersHandler)
    
    server := &http.Server{
        Addr:    ":8080",
        Handler: mux,
    }
    
    log.Println("Server starting on :8080")
    log.Fatal(server.ListenAndServe())
}
```

### Kubernetes Configuration

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: my-app
        image: my-app:latest
        ports:
        - containerPort: 8080
        
        # Liveness probe - restarts container if unhealthy
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        
        # Readiness probe - removes from service if not ready
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
        
        # Startup probe - gives extra time during startup
        startupProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 10
```

### Load Balancer Health Checks

```yaml
# For AWS Application Load Balancer
apiVersion: v1
kind: Service
metadata:
  name: my-app-service
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: http
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/health"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-timeout: "5"
    service.beta.kubernetes.io/aws-load-balancer-healthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-unhealthy-threshold: "3"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: my-app
```

## Monitoring and Alerting

### Prometheus Metrics

```go
var (
    healthCheckDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "health_check_duration_seconds",
            Help: "Duration of health checks",
        },
        []string{"check_name", "status"},
    )
    
    healthCheckStatus = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "health_check_status",
            Help: "Status of health checks (1=healthy, 0=unhealthy)",
        },
        []string{"check_name"},
    )
)

func (c *CheckResult) RecordMetrics(checkName string) {
    status := "healthy"
    statusValue := 1.0
    
    if c.Status != StatusHealthy {
        status = string(c.Status)
        statusValue = 0.0
    }
    
    healthCheckDuration.WithLabelValues(checkName, status).Observe(c.Duration.Seconds())
    healthCheckStatus.WithLabelValues(checkName).Set(statusValue)
}
```

### Alert Rules

```yaml
# Prometheus alert rules
groups:
- name: health-checks
  rules:
  - alert: ServiceUnhealthy
    expr: health_check_status == 0
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "Service health check failing"
      description: "Health check {{ $labels.check_name }} has been failing for more than 1 minute"
  
  - alert: HealthCheckSlow
    expr: histogram_quantile(0.95, health_check_duration_seconds_bucket) > 5
    for: 2m
    labels:
      severity: warning
    annotations:
      summary: "Health checks are slow"
      description: "95th percentile of health check duration is above 5 seconds"
```

## Best Practices

### Design Principles

1. **Fail Fast**: Health checks should complete quickly (< 5 seconds)
2. **Dependency Aware**: Check critical dependencies but avoid cascading failures
3. **Graceful Degradation**: Distinguish between critical and non-critical failures
4. **Idempotent**: Health checks should not modify system state
5. **Informative**: Provide actionable information in responses

### Security Considerations

```go
// Add basic authentication or IP restrictions for diagnostic endpoints
func (h *HealthChecker) DiagnosticHandler(w http.ResponseWriter, r *http.Request) {
    // Check if request is from allowed sources
    if !h.isAuthorizedForDiagnostics(r) {
        http.Error(w, "Forbidden", http.StatusForbidden)
        return
    }
    
    h.HealthHandler(w, r)
}

func (h *HealthChecker) isAuthorizedForDiagnostics(r *http.Request) bool {
    // Only allow from internal networks or with proper authentication
    clientIP := getClientIP(r)
    return isInternalIP(clientIP) || hasValidAPIKey(r)
}
```

## Consequences

### Positive

- **Automated Operations**: Enables orchestration platforms to manage services automatically
- **Early Problem Detection**: Identifies issues before they impact users
- **Load Balancer Integration**: Ensures traffic only goes to healthy instances
- **Operational Visibility**: Provides insight into service and dependency health
- **Deployment Safety**: Validates service health during deployments

### Negative

- **Resource Overhead**: Health checks consume CPU, memory, and network resources
- **False Positives**: Overly sensitive checks may cause unnecessary restarts
- **Complexity**: Comprehensive health checks add implementation complexity
- **Dependency Coupling**: Health checks may create tight coupling with dependencies

### Anti-patterns

- **Too Many Dependencies**: Checking every possible dependency can make service brittle
- **Expensive Operations**: Health checks should not perform costly operations
- **State Modification**: Health checks should never modify application state
- **Ignoring Results**: Implementing health checks but not acting on failures
- **No Differentiation**: Using the same checks for liveness and readiness
