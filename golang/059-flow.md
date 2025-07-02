# Application Flow Visualization and Metrics

## Status

`accepted`

## Context

Modern applications benefit from runtime introspection capabilities that expose application flow, metrics, and operational insights through HTTP endpoints. This enables better observability, debugging, and monitoring without requiring external tools or complex setup.

Similar to how Prometheus metrics and `expvar` provide runtime insights, application flow visualization helps developers and operators understand:
- Request paths and dependencies
- Performance bottlenecks
- Error patterns
- Resource utilization
- Business logic execution

## Decision

**Implement a comprehensive flow visualization system that exposes application metadata, metrics, and execution patterns through HTTP endpoints:**

### 1. Core Flow Tracker

```go
package flow

import (
    "context"
    "encoding/json"
    "fmt"
    "net/http"
    "runtime"
    "sort"
    "sync"
    "time"
)

// FlowTracker captures application execution flow and metrics
type FlowTracker struct {
    mu           sync.RWMutex
    operations   map[string]*OperationStats
    flows        map[string]*FlowExecution
    dependencies map[string][]string
    
    // Configuration
    maxFlowHistory int
    enabled        bool
}

// OperationStats tracks statistics for a specific operation
type OperationStats struct {
    Name            string            `json:"name"`
    TotalCalls      int64             `json:"total_calls"`
    TotalDuration   time.Duration     `json:"total_duration"`
    AverageDuration time.Duration     `json:"average_duration"`
    MinDuration     time.Duration     `json:"min_duration"`
    MaxDuration     time.Duration     `json:"max_duration"`
    ErrorCount      int64             `json:"error_count"`
    ErrorRate       float64           `json:"error_rate"`
    LastCalled      time.Time         `json:"last_called"`
    Dependencies    []string          `json:"dependencies"`
    Metadata        map[string]string `json:"metadata,omitempty"`
}

// FlowExecution represents a complete request flow
type FlowExecution struct {
    ID           string                `json:"id"`
    StartTime    time.Time             `json:"start_time"`
    EndTime      time.Time             `json:"end_time"`
    Duration     time.Duration         `json:"duration"`
    Operations   []*OperationExecution `json:"operations"`
    Error        string                `json:"error,omitempty"`
    TraceID      string                `json:"trace_id,omitempty"`
    UserID       string                `json:"user_id,omitempty"`
    RequestPath  string                `json:"request_path,omitempty"`
    StatusCode   int                   `json:"status_code,omitempty"`
}

// OperationExecution tracks a single operation within a flow
type OperationExecution struct {
    Name       string            `json:"name"`
    StartTime  time.Time         `json:"start_time"`
    EndTime    time.Time         `json:"end_time"`
    Duration   time.Duration     `json:"duration"`
    Error      string            `json:"error,omitempty"`
    Metadata   map[string]string `json:"metadata,omitempty"`
    Children   []*OperationExecution `json:"children,omitempty"`
    parent     *OperationExecution
}

var (
    globalTracker *FlowTracker
    once          sync.Once
)

// GetGlobalTracker returns the singleton flow tracker
func GetGlobalTracker() *FlowTracker {
    once.Do(func() {
        globalTracker = NewFlowTracker(Config{
            MaxFlowHistory: 1000,
            Enabled:        true,
        })
    })
    return globalTracker
}

type Config struct {
    MaxFlowHistory int
    Enabled        bool
}

func NewFlowTracker(config Config) *FlowTracker {
    return &FlowTracker{
        operations:     make(map[string]*OperationStats),
        flows:          make(map[string]*FlowExecution),
        dependencies:   make(map[string][]string),
        maxFlowHistory: config.MaxFlowHistory,
        enabled:        config.Enabled,
    }
}

// StartFlow begins tracking a new flow execution
func (ft *FlowTracker) StartFlow(ctx context.Context, id string) context.Context {
    if !ft.enabled {
        return ctx
    }
    
    flow := &FlowExecution{
        ID:        id,
        StartTime: time.Now(),
        Operations: make([]*OperationExecution, 0),
    }
    
    // Extract trace information if available
    if traceID := getTraceID(ctx); traceID != "" {
        flow.TraceID = traceID
    }
    
    if userID := getUserID(ctx); userID != "" {
        flow.UserID = userID
    }
    
    if requestPath := getRequestPath(ctx); requestPath != "" {
        flow.RequestPath = requestPath
    }
    
    ft.mu.Lock()
    ft.flows[id] = flow
    
    // Cleanup old flows if needed
    if len(ft.flows) > ft.maxFlowHistory {
        ft.cleanupOldFlows()
    }
    ft.mu.Unlock()
    
    return context.WithValue(ctx, "flow_id", id)
}

// StartOperation begins tracking an operation within the current flow
func (ft *FlowTracker) StartOperation(ctx context.Context, name string) context.Context {
    if !ft.enabled {
        return ctx
    }
    
    flowID, ok := ctx.Value("flow_id").(string)
    if !ok {
        return ctx
    }
    
    operation := &OperationExecution{
        Name:      name,
        StartTime: time.Now(),
        Metadata:  make(map[string]string),
        Children:  make([]*OperationExecution, 0),
    }
    
    ft.mu.Lock()
    defer ft.mu.Unlock()
    
    if flow, exists := ft.flows[flowID]; exists {
        // Check for parent operation
        if parentOp := getParentOperation(ctx); parentOp != nil {
            operation.parent = parentOp
            parentOp.Children = append(parentOp.Children, operation)
        } else {
            flow.Operations = append(flow.Operations, operation)
        }
    }
    
    return context.WithValue(ctx, "current_operation", operation)
}

// EndOperation completes tracking of an operation
func (ft *FlowTracker) EndOperation(ctx context.Context, err error) {
    if !ft.enabled {
        return
    }
    
    operation, ok := ctx.Value("current_operation").(*OperationExecution)
    if !ok {
        return
    }
    
    operation.EndTime = time.Now()
    operation.Duration = operation.EndTime.Sub(operation.StartTime)
    
    if err != nil {
        operation.Error = err.Error()
    }
    
    // Update operation statistics
    ft.updateOperationStats(operation.Name, operation.Duration, err != nil)
}

// EndFlow completes tracking of a flow execution
func (ft *FlowTracker) EndFlow(ctx context.Context, statusCode int, err error) {
    if !ft.enabled {
        return
    }
    
    flowID, ok := ctx.Value("flow_id").(string)
    if !ok {
        return
    }
    
    ft.mu.Lock()
    defer ft.mu.Unlock()
    
    if flow, exists := ft.flows[flowID]; exists {
        flow.EndTime = time.Now()
        flow.Duration = flow.EndTime.Sub(flow.StartTime)
        flow.StatusCode = statusCode
        
        if err != nil {
            flow.Error = err.Error()
        }
    }
}

func (ft *FlowTracker) updateOperationStats(name string, duration time.Duration, hasError bool) {
    ft.mu.Lock()
    defer ft.mu.Unlock()
    
    stats, exists := ft.operations[name]
    if !exists {
        stats = &OperationStats{
            Name:         name,
            MinDuration:  duration,
            MaxDuration:  duration,
            Dependencies: make([]string, 0),
            Metadata:     make(map[string]string),
        }
        ft.operations[name] = stats
    }
    
    stats.TotalCalls++
    stats.TotalDuration += duration
    stats.AverageDuration = time.Duration(int64(stats.TotalDuration) / stats.TotalCalls)
    stats.LastCalled = time.Now()
    
    if duration < stats.MinDuration {
        stats.MinDuration = duration
    }
    if duration > stats.MaxDuration {
        stats.MaxDuration = duration
    }
    
    if hasError {
        stats.ErrorCount++
    }
    
    stats.ErrorRate = float64(stats.ErrorCount) / float64(stats.TotalCalls)
}

func (ft *FlowTracker) cleanupOldFlows() {
    // Keep only the most recent flows
    type flowTime struct {
        id   string
        time time.Time
    }
    
    flows := make([]flowTime, 0, len(ft.flows))
    for id, flow := range ft.flows {
        flows = append(flows, flowTime{id: id, time: flow.StartTime})
    }
    
    sort.Slice(flows, func(i, j int) bool {
        return flows[i].time.After(flows[j].time)
    })
    
    // Remove oldest flows
    toRemove := len(flows) - ft.maxFlowHistory
    for i := ft.maxFlowHistory; i < len(flows); i++ {
        delete(ft.flows, flows[i].id)
    }
}

// Helper functions for context extraction
func getTraceID(ctx context.Context) string {
    if traceID := ctx.Value("trace_id"); traceID != nil {
        return traceID.(string)
    }
    return ""
}

func getUserID(ctx context.Context) string {
    if userID := ctx.Value("user_id"); userID != nil {
        return userID.(string)
    }
    return ""
}

func getRequestPath(ctx context.Context) string {
    if path := ctx.Value("request_path"); path != nil {
        return path.(string)
    }
    return ""
}

func getParentOperation(ctx context.Context) *OperationExecution {
    if op := ctx.Value("current_operation"); op != nil {
        return op.(*OperationExecution)
    }
    return nil
}
```

### 2. HTTP Endpoints for Flow Visualization

```go
package flow

import (
    "encoding/json"
    "fmt"
    "net/http"
    "runtime"
    "strconv"
    "time"
)

// RegisterHandlers adds flow visualization endpoints to a mux
func RegisterHandlers(mux *http.ServeMux) {
    tracker := GetGlobalTracker()
    
    mux.HandleFunc("/debug/flow/stats", tracker.handleStats)
    mux.HandleFunc("/debug/flow/operations", tracker.handleOperations)
    mux.HandleFunc("/debug/flow/flows", tracker.handleFlows)
    mux.HandleFunc("/debug/flow/dependencies", tracker.handleDependencies)
    mux.HandleFunc("/debug/flow/health", tracker.handleHealth)
    mux.HandleFunc("/debug/flow/metrics", tracker.handleMetrics)
    mux.HandleFunc("/debug/flow", tracker.handleIndex)
}

func (ft *FlowTracker) handleStats(w http.ResponseWriter, r *http.Request) {
    ft.mu.RLock()
    defer ft.mu.RUnlock()
    
    stats := map[string]interface{}{
        "enabled":            ft.enabled,
        "total_operations":   len(ft.operations),
        "total_flows":        len(ft.flows),
        "max_flow_history":   ft.maxFlowHistory,
        "runtime_stats":      getRuntimeStats(),
        "collected_at":       time.Now(),
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(stats)
}

func (ft *FlowTracker) handleOperations(w http.ResponseWriter, r *http.Request) {
    ft.mu.RLock()
    operations := make([]*OperationStats, 0, len(ft.operations))
    for _, op := range ft.operations {
        operations = append(operations, op)
    }
    ft.mu.RUnlock()
    
    // Sort by total calls descending
    sort.Slice(operations, func(i, j int) bool {
        return operations[i].TotalCalls > operations[j].TotalCalls
    })
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]interface{}{
        "operations": operations,
        "count":      len(operations),
    })
}

func (ft *FlowTracker) handleFlows(w http.ResponseWriter, r *http.Request) {
    limit := 50 // Default limit
    if l := r.URL.Query().Get("limit"); l != "" {
        if parsed, err := strconv.Atoi(l); err == nil && parsed > 0 {
            limit = parsed
        }
    }
    
    ft.mu.RLock()
    flows := make([]*FlowExecution, 0)
    for _, flow := range ft.flows {
        flows = append(flows, flow)
    }
    ft.mu.RUnlock()
    
    // Sort by start time descending (most recent first)
    sort.Slice(flows, func(i, j int) bool {
        return flows[i].StartTime.After(flows[j].StartTime)
    })
    
    // Limit results
    if len(flows) > limit {
        flows = flows[:limit]
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]interface{}{
        "flows": flows,
        "count": len(flows),
        "limit": limit,
    })
}

func (ft *FlowTracker) handleDependencies(w http.ResponseWriter, r *http.Request) {
    ft.mu.RLock()
    dependencies := make(map[string][]string)
    for k, v := range ft.dependencies {
        dependencies[k] = v
    }
    ft.mu.RUnlock()
    
    // Build dependency graph
    graph := buildDependencyGraph(dependencies)
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(map[string]interface{}{
        "dependencies": dependencies,
        "graph":        graph,
    })
}

func (ft *FlowTracker) handleHealth(w http.ResponseWriter, r *http.Request) {
    ft.mu.RLock()
    defer ft.mu.RUnlock()
    
    health := map[string]interface{}{
        "status":      "healthy",
        "tracker":     "enabled",
        "operations":  len(ft.operations),
        "flows":       len(ft.flows),
        "memory":      getRuntimeStats()["memory_stats"],
        "goroutines":  runtime.NumGoroutine(),
        "timestamp":   time.Now(),
    }
    
    // Check for any concerning metrics
    var issues []string
    if len(ft.flows) >= ft.maxFlowHistory {
        issues = append(issues, "flow history at maximum capacity")
    }
    
    if runtime.NumGoroutine() > 1000 {
        issues = append(issues, "high goroutine count")
    }
    
    if len(issues) > 0 {
        health["status"] = "warning"
        health["issues"] = issues
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(health)
}

func (ft *FlowTracker) handleMetrics(w http.ResponseWriter, r *http.Request) {
    ft.mu.RLock()
    defer ft.mu.RUnlock()
    
    // Prometheus-style metrics
    w.Header().Set("Content-Type", "text/plain")
    
    fmt.Fprintf(w, "# HELP flow_operations_total Total number of operation calls\n")
    fmt.Fprintf(w, "# TYPE flow_operations_total counter\n")
    
    for _, op := range ft.operations {
        fmt.Fprintf(w, "flow_operations_total{operation=\"%s\"} %d\n", op.Name, op.TotalCalls)
    }
    
    fmt.Fprintf(w, "\n# HELP flow_operation_duration_seconds Operation duration in seconds\n")
    fmt.Fprintf(w, "# TYPE flow_operation_duration_seconds histogram\n")
    
    for _, op := range ft.operations {
        fmt.Fprintf(w, "flow_operation_duration_seconds{operation=\"%s\",quantile=\"avg\"} %.6f\n", 
            op.Name, op.AverageDuration.Seconds())
        fmt.Fprintf(w, "flow_operation_duration_seconds{operation=\"%s\",quantile=\"min\"} %.6f\n", 
            op.Name, op.MinDuration.Seconds())
        fmt.Fprintf(w, "flow_operation_duration_seconds{operation=\"%s\",quantile=\"max\"} %.6f\n", 
            op.Name, op.MaxDuration.Seconds())
    }
    
    fmt.Fprintf(w, "\n# HELP flow_operation_errors_total Total number of operation errors\n")
    fmt.Fprintf(w, "# TYPE flow_operation_errors_total counter\n")
    
    for _, op := range ft.operations {
        fmt.Fprintf(w, "flow_operation_errors_total{operation=\"%s\"} %d\n", op.Name, op.ErrorCount)
    }
}

func (ft *FlowTracker) handleIndex(w http.ResponseWriter, r *http.Request) {
    html := `<!DOCTYPE html>
<html>
<head>
    <title>Application Flow Dashboard</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .section { margin: 30px 0; }
        .metric { background: #f5f5f5; padding: 15px; margin: 10px 0; border-radius: 5px; }
        .error { color: red; }
        .success { color: green; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h1>Application Flow Dashboard</h1>
    
    <div class="section">
        <h2>Available Endpoints</h2>
        <ul>
            <li><a href="/debug/flow/stats">/debug/flow/stats</a> - General statistics</li>
            <li><a href="/debug/flow/operations">/debug/flow/operations</a> - Operation metrics</li>
            <li><a href="/debug/flow/flows">/debug/flow/flows</a> - Recent flow executions</li>
            <li><a href="/debug/flow/dependencies">/debug/flow/dependencies</a> - Dependency graph</li>
            <li><a href="/debug/flow/health">/debug/flow/health</a> - Health status</li>
            <li><a href="/debug/flow/metrics">/debug/flow/metrics</a> - Prometheus metrics</li>
        </ul>
    </div>
    
    <div class="section">
        <h2>Quick Stats</h2>
        <div id="stats">Loading...</div>
    </div>
    
    <script>
        fetch('/debug/flow/stats')
            .then(response => response.json())
            .then(data => {
                document.getElementById('stats').innerHTML = 
                    '<div class="metric">Operations: ' + data.total_operations + '</div>' +
                    '<div class="metric">Flows: ' + data.total_flows + '</div>' +
                    '<div class="metric">Enabled: ' + data.enabled + '</div>' +
                    '<div class="metric">Goroutines: ' + data.runtime_stats.goroutines + '</div>';
            })
            .catch(error => {
                document.getElementById('stats').innerHTML = '<div class="error">Error loading stats</div>';
            });
    </script>
</body>
</html>`
    
    w.Header().Set("Content-Type", "text/html")
    w.Write([]byte(html))
}

func getRuntimeStats() map[string]interface{} {
    var m runtime.MemStats
    runtime.ReadMemStats(&m)
    
    return map[string]interface{}{
        "goroutines": runtime.NumGoroutine(),
        "memory_stats": map[string]interface{}{
            "alloc_mb":      bToMb(m.Alloc),
            "total_alloc_mb": bToMb(m.TotalAlloc),
            "sys_mb":        bToMb(m.Sys),
            "num_gc":        m.NumGC,
        },
        "cpu_count": runtime.NumCPU(),
    }
}

func bToMb(b uint64) uint64 {
    return b / 1024 / 1024
}

func buildDependencyGraph(deps map[string][]string) map[string]interface{} {
    nodes := make(map[string]interface{})
    edges := make([]map[string]string, 0)
    
    for source, targets := range deps {
        nodes[source] = map[string]interface{}{"id": source}
        
        for _, target := range targets {
            nodes[target] = map[string]interface{}{"id": target}
            edges = append(edges, map[string]string{
                "source": source,
                "target": target,
            })
        }
    }
    
    return map[string]interface{}{
        "nodes": nodes,
        "edges": edges,
    }
}
```

### 3. Middleware Integration

```go
package flow

import (
    "context"
    "fmt"
    "net/http"
    "time"
)

// HTTPMiddleware wraps HTTP handlers with flow tracking
func HTTPMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        tracker := GetGlobalTracker()
        
        // Start flow tracking
        flowID := fmt.Sprintf("%s-%d", r.Method, time.Now().UnixNano())
        ctx := tracker.StartFlow(r.Context(), flowID)
        
        // Add request metadata to context
        ctx = context.WithValue(ctx, "request_path", r.URL.Path)
        ctx = context.WithValue(ctx, "request_method", r.Method)
        
        // Start HTTP operation
        ctx = tracker.StartOperation(ctx, fmt.Sprintf("%s %s", r.Method, r.URL.Path))
        
        // Create response wrapper to capture status code
        wrapper := &responseWrapper{ResponseWriter: w, statusCode: 200}
        
        // Execute request
        var err error
        func() {
            defer func() {
                if recovered := recover(); recovered != nil {
                    err = fmt.Errorf("panic: %v", recovered)
                    wrapper.statusCode = 500
                    panic(recovered) // Re-panic after recording
                }
            }()
            
            next.ServeHTTP(wrapper, r.WithContext(ctx))
        }()
        
        // End operation and flow tracking
        tracker.EndOperation(ctx, err)
        tracker.EndFlow(ctx, wrapper.statusCode, err)
    })
}

type responseWrapper struct {
    http.ResponseWriter
    statusCode int
}

func (rw *responseWrapper) WriteHeader(code int) {
    rw.statusCode = code
    rw.ResponseWriter.WriteHeader(code)
}

// OperationTracker provides operation-level tracking
type OperationTracker struct {
    ctx     context.Context
    tracker *FlowTracker
}

func StartOperation(ctx context.Context, name string) *OperationTracker {
    tracker := GetGlobalTracker()
    newCtx := tracker.StartOperation(ctx, name)
    
    return &OperationTracker{
        ctx:     newCtx,
        tracker: tracker,
    }
}

func (ot *OperationTracker) End(err error) {
    ot.tracker.EndOperation(ot.ctx, err)
}

func (ot *OperationTracker) SetMetadata(key, value string) {
    if op := getParentOperation(ot.ctx); op != nil {
        op.Metadata[key] = value
    }
}

func (ot *OperationTracker) Context() context.Context {
    return ot.ctx
}
```

### 4. Usage Examples

```go
package main

import (
    "context"
    "database/sql"
    "fmt"
    "log"
    "net/http"
    "time"
    
    "your-app/flow"
)

// Service with flow tracking
type UserService struct {
    db *sql.DB
}

func (s *UserService) GetUser(ctx context.Context, id string) (*User, error) {
    op := flow.StartOperation(ctx, "UserService.GetUser")
    defer op.End(nil)
    
    op.SetMetadata("user_id", id)
    
    // Simulate database operation
    dbOp := flow.StartOperation(op.Context(), "Database.QueryUser")
    user, err := s.queryUser(dbOp.Context(), id)
    dbOp.End(err)
    
    if err != nil {
        op.End(err)
        return nil, err
    }
    
    // Simulate cache operation
    cacheOp := flow.StartOperation(op.Context(), "Cache.SetUser")
    cacheErr := s.cacheUser(cacheOp.Context(), user)
    cacheOp.End(cacheErr)
    
    return user, nil
}

func (s *UserService) queryUser(ctx context.Context, id string) (*User, error) {
    // Simulate database query
    time.Sleep(50 * time.Millisecond)
    return &User{ID: id, Name: "John Doe"}, nil
}

func (s *UserService) cacheUser(ctx context.Context, user *User) error {
    // Simulate cache operation
    time.Sleep(5 * time.Millisecond)
    return nil
}

type User struct {
    ID   string `json:"id"`
    Name string `json:"name"`
}

func main() {
    service := &UserService{}
    
    // Setup HTTP server with flow tracking
    mux := http.NewServeMux()
    
    // Register flow endpoints
    flow.RegisterHandlers(mux)
    
    // Application endpoints
    mux.HandleFunc("/users/", func(w http.ResponseWriter, r *http.Request) {
        userID := r.URL.Path[len("/users/"):]
        
        user, err := service.GetUser(r.Context(), userID)
        if err != nil {
            http.Error(w, err.Error(), http.StatusInternalServerError)
            return
        }
        
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(user)
    })
    
    // Wrap with flow middleware
    handler := flow.HTTPMiddleware(mux)
    
    fmt.Println("Server starting on :8080")
    fmt.Println("Flow dashboard available at http://localhost:8080/debug/flow")
    
    log.Fatal(http.ListenAndServe(":8080", handler))
}
```

### 5. Integration with Popular Tools

```go
// Prometheus integration
import (
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

func RegisterPrometheusMetrics() {
    tracker := GetGlobalTracker()
    
    operationDuration := prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "flow_operation_duration_seconds",
            Help: "Duration of operations in seconds",
        },
        []string{"operation"},
    )
    
    operationCount := prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "flow_operations_total",
            Help: "Total number of operations",
        },
        []string{"operation", "status"},
    )
    
    prometheus.MustRegister(operationDuration, operationCount)
    
    // Update metrics from flow tracker periodically
    go func() {
        for range time.Tick(30 * time.Second) {
            tracker.mu.RLock()
            for _, op := range tracker.operations {
                operationDuration.WithLabelValues(op.Name).Observe(op.AverageDuration.Seconds())
                operationCount.WithLabelValues(op.Name, "success").Add(float64(op.TotalCalls - op.ErrorCount))
                operationCount.WithLabelValues(op.Name, "error").Add(float64(op.ErrorCount))
            }
            tracker.mu.RUnlock()
        }
    }()
}
```

## Consequences

**Benefits:**
- **Real-time visibility**: Live application flow and performance metrics
- **Debugging aid**: Trace request paths and identify bottlenecks
- **Operational insights**: Understand system behavior in production
- **Performance monitoring**: Track operation durations and error rates
- **Dependency mapping**: Visualize service dependencies and call patterns

**Trade-offs:**
- **Performance overhead**: Additional tracking and memory usage
- **Memory consumption**: Storing flow history and operation statistics
- **Security considerations**: Exposing internal application structure

**Best Practices:**
- Enable/disable tracking based on environment
- Implement sampling for high-traffic applications
- Secure debug endpoints in production
- Monitor memory usage of flow tracking
- Integrate with existing observability tools

## References

- [Go expvar Package](https://pkg.go.dev/expvar)
- [Prometheus Go Client](https://github.com/prometheus/client_golang)
- [OpenTelemetry Go](https://github.com/open-telemetry/opentelemetry-go)
