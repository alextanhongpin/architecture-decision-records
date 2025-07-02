# Events Library for Instrumentation and Observability

## Status

`accepted`

## Context

Modern applications require comprehensive observability through logging, metrics, and tracing. When building libraries and packages, it's crucial to provide instrumentation that allows consumers to extract relevant telemetry data without being tied to specific observability backends.

Key challenges in library instrumentation:
- **Backend agnostic**: Support multiple logging/metrics/tracing backends
- **Performance**: Minimal overhead when instrumentation is disabled
- **Flexibility**: Allow selective filtering of events and metrics
- **Extensibility**: Easy to add new event types and handlers
- **Standards compliance**: Follow OpenTelemetry and structured logging standards

## Decision

**Use a flexible event-driven instrumentation framework that separates frontend (event emission) from backend (event handling):**

### 1. Core Event System

```go
package events

import (
    "context"
    "fmt"
    "sync"
    "time"
)

// EventLevel represents the severity level of an event.
type EventLevel int

const (
    LevelDebug EventLevel = iota
    LevelInfo
    LevelWarn
    LevelError
)

func (l EventLevel) String() string {
    switch l {
    case LevelDebug:
        return "DEBUG"
    case LevelInfo:
        return "INFO"
    case LevelWarn:
        return "WARN"
    case LevelError:
        return "ERROR"
    default:
        return "UNKNOWN"
    }
}

// Event represents a structured event with metadata.
type Event struct {
    ID        string                 `json:"id"`
    Timestamp time.Time             `json:"timestamp"`
    Level     EventLevel            `json:"level"`
    Source    string                `json:"source"`
    Message   string                `json:"message"`
    Fields    map[string]interface{} `json:"fields,omitempty"`
    Error     error                 `json:"error,omitempty"`
    
    // Tracing information
    TraceID string `json:"trace_id,omitempty"`
    SpanID  string `json:"span_id,omitempty"`
    
    // Metrics information
    Duration *time.Duration `json:"duration,omitempty"`
    Count    *int64        `json:"count,omitempty"`
}

// Handler processes events emitted by the instrumentation system.
type Handler interface {
    Handle(ctx context.Context, event Event) error
    Close() error
}

// Filter determines whether an event should be processed.
type Filter func(event Event) bool

// Emitter is the main interface for event emission.
type Emitter interface {
    Emit(ctx context.Context, event Event)
    EmitLog(ctx context.Context, level EventLevel, message string, fields map[string]interface{})
    EmitMetric(ctx context.Context, name string, value interface{}, fields map[string]interface{})
    EmitTrace(ctx context.Context, operation string, duration time.Duration, fields map[string]interface{})
    
    // Configuration
    SetLevel(level EventLevel)
    AddHandler(handler Handler) error
    AddFilter(filter Filter)
    Close() error
}

// EventEmitter implements the Emitter interface.
type EventEmitter struct {
    source   string
    level    EventLevel
    handlers []Handler
    filters  []Filter
    mu       sync.RWMutex
}

func NewEmitter(source string) *EventEmitter {
    return &EventEmitter{
        source:   source,
        level:    LevelInfo,
        handlers: make([]Handler, 0),
        filters:  make([]Filter, 0),
    }
}

func (e *EventEmitter) Emit(ctx context.Context, event Event) {
    e.mu.RLock()
    defer e.mu.RUnlock()
    
    // Check level
    if event.Level < e.level {
        return
    }
    
    // Apply filters
    for _, filter := range e.filters {
        if !filter(event) {
            return
        }
    }
    
    // Set default fields
    if event.ID == "" {
        event.ID = generateEventID()
    }
    if event.Timestamp.IsZero() {
        event.Timestamp = time.Now()
    }
    if event.Source == "" {
        event.Source = e.source
    }
    
    // Add tracing context if available
    if traceID := getTraceID(ctx); traceID != "" {
        event.TraceID = traceID
    }
    if spanID := getSpanID(ctx); spanID != "" {
        event.SpanID = spanID
    }
    
    // Send to all handlers
    for _, handler := range e.handlers {
        go func(h Handler) {
            _ = h.Handle(ctx, event)
        }(handler)
    }
}

func (e *EventEmitter) EmitLog(ctx context.Context, level EventLevel, message string, fields map[string]interface{}) {
    event := Event{
        Level:   level,
        Message: message,
        Fields:  fields,
    }
    e.Emit(ctx, event)
}

func (e *EventEmitter) EmitMetric(ctx context.Context, name string, value interface{}, fields map[string]interface{}) {
    if fields == nil {
        fields = make(map[string]interface{})
    }
    fields["metric_name"] = name
    fields["metric_value"] = value
    
    event := Event{
        Level:   LevelInfo,
        Message: fmt.Sprintf("metric: %s", name),
        Fields:  fields,
    }
    e.Emit(ctx, event)
}

func (e *EventEmitter) EmitTrace(ctx context.Context, operation string, duration time.Duration, fields map[string]interface{}) {
    if fields == nil {
        fields = make(map[string]interface{})
    }
    fields["operation"] = operation
    
    event := Event{
        Level:    LevelInfo,
        Message:  fmt.Sprintf("trace: %s", operation),
        Fields:   fields,
        Duration: &duration,
    }
    e.Emit(ctx, event)
}

func (e *EventEmitter) SetLevel(level EventLevel) {
    e.mu.Lock()
    defer e.mu.Unlock()
    e.level = level
}

func (e *EventEmitter) AddHandler(handler Handler) error {
    e.mu.Lock()
    defer e.mu.Unlock()
    e.handlers = append(e.handlers, handler)
    return nil
}

func (e *EventEmitter) AddFilter(filter Filter) {
    e.mu.Lock()
    defer e.mu.Unlock()
    e.filters = append(e.filters, filter)
}

func (e *EventEmitter) Close() error {
    e.mu.Lock()
    defer e.mu.Unlock()
    
    for _, handler := range e.handlers {
        _ = handler.Close()
    }
    e.handlers = nil
    return nil
}

// Helper functions for trace context (implement based on your tracing system)
func getTraceID(ctx context.Context) string {
    // Implementation depends on tracing system (OpenTelemetry, etc.)
    return ""
}

func getSpanID(ctx context.Context) string {
    // Implementation depends on tracing system
    return ""
}

func generateEventID() string {
    return fmt.Sprintf("%d", time.Now().UnixNano())
}
```

### 2. Multiple Handler Implementations

```go
// ConsoleHandler writes events to stdout/stderr.
type ConsoleHandler struct {
    level EventLevel
}

func NewConsoleHandler(level EventLevel) *ConsoleHandler {
    return &ConsoleHandler{level: level}
}

func (h *ConsoleHandler) Handle(ctx context.Context, event Event) error {
    if event.Level < h.level {
        return nil
    }
    
    timestamp := event.Timestamp.Format("2006-01-02T15:04:05.000Z")
    
    // Basic structured output
    fmt.Printf("[%s] %s %s: %s", 
        timestamp, 
        event.Level.String(), 
        event.Source, 
        event.Message)
    
    if event.Error != nil {
        fmt.Printf(" error=%s", event.Error.Error())
    }
    
    if event.Duration != nil {
        fmt.Printf(" duration=%s", event.Duration.String())
    }
    
    for key, value := range event.Fields {
        fmt.Printf(" %s=%v", key, value)
    }
    
    fmt.Println()
    return nil
}

func (h *ConsoleHandler) Close() error {
    return nil
}

// JSONHandler writes events as JSON to any writer.
type JSONHandler struct {
    writer io.Writer
    level  EventLevel
    mu     sync.Mutex
}

func NewJSONHandler(writer io.Writer, level EventLevel) *JSONHandler {
    return &JSONHandler{
        writer: writer,
        level:  level,
    }
}

func (h *JSONHandler) Handle(ctx context.Context, event Event) error {
    if event.Level < h.level {
        return nil
    }
    
    h.mu.Lock()
    defer h.mu.Unlock()
    
    encoder := json.NewEncoder(h.writer)
    return encoder.Encode(event)
}

func (h *JSONHandler) Close() error {
    return nil
}

// MetricsHandler aggregates metrics for Prometheus/StatsD export.
type MetricsHandler struct {
    registry map[string]*MetricEntry
    mu       sync.RWMutex
}

type MetricEntry struct {
    Name      string
    Type      string
    Value     float64
    Count     int64
    LastSeen  time.Time
    Labels    map[string]string
}

func NewMetricsHandler() *MetricsHandler {
    return &MetricsHandler{
        registry: make(map[string]*MetricEntry),
    }
}

func (h *MetricsHandler) Handle(ctx context.Context, event Event) error {
    // Only process metric events
    metricName, ok := event.Fields["metric_name"].(string)
    if !ok {
        return nil
    }
    
    h.mu.Lock()
    defer h.mu.Unlock()
    
    key := h.buildMetricKey(metricName, event.Fields)
    entry, exists := h.registry[key]
    
    if !exists {
        entry = &MetricEntry{
            Name:     metricName,
            Type:     "counter", // Default type
            Labels:   h.extractLabels(event.Fields),
            LastSeen: event.Timestamp,
        }
        h.registry[key] = entry
    }
    
    // Update metric value
    if value, ok := event.Fields["metric_value"].(float64); ok {
        entry.Value = value
        entry.Count++
        entry.LastSeen = event.Timestamp
    }
    
    return nil
}

func (h *MetricsHandler) buildMetricKey(name string, fields map[string]interface{}) string {
    // Build unique key from metric name and labels
    key := name
    for k, v := range fields {
        if k != "metric_name" && k != "metric_value" {
            key += fmt.Sprintf("_%s_%v", k, v)
        }
    }
    return key
}

func (h *MetricsHandler) extractLabels(fields map[string]interface{}) map[string]string {
    labels := make(map[string]string)
    for k, v := range fields {
        if k != "metric_name" && k != "metric_value" {
            labels[k] = fmt.Sprintf("%v", v)
        }
    }
    return labels
}

func (h *MetricsHandler) GetMetrics() map[string]*MetricEntry {
    h.mu.RLock()
    defer h.mu.RUnlock()
    
    result := make(map[string]*MetricEntry)
    for k, v := range h.registry {
        result[k] = v
    }
    return result
}

func (h *MetricsHandler) Close() error {
    h.mu.Lock()
    defer h.mu.Unlock()
    h.registry = make(map[string]*MetricEntry)
    return nil
}

// AsyncHandler wraps another handler with buffering and async processing.
type AsyncHandler struct {
    handler Handler
    buffer  chan Event
    done    chan struct{}
    wg      sync.WaitGroup
}

func NewAsyncHandler(handler Handler, bufferSize int) *AsyncHandler {
    ah := &AsyncHandler{
        handler: handler,
        buffer:  make(chan Event, bufferSize),
        done:    make(chan struct{}),
    }
    
    ah.wg.Add(1)
    go ah.worker()
    
    return ah
}

func (h *AsyncHandler) Handle(ctx context.Context, event Event) error {
    select {
    case h.buffer <- event:
        return nil
    default:
        // Buffer full, drop event or handle differently
        return fmt.Errorf("event buffer full")
    }
}

func (h *AsyncHandler) worker() {
    defer h.wg.Done()
    
    for {
        select {
        case event := <-h.buffer:
            _ = h.handler.Handle(context.Background(), event)
        case <-h.done:
            // Drain remaining events
            for {
                select {
                case event := <-h.buffer:
                    _ = h.handler.Handle(context.Background(), event)
                default:
                    return
                }
            }
        }
    }
}

func (h *AsyncHandler) Close() error {
    close(h.done)
    h.wg.Wait()
    return h.handler.Close()
}
```

### 3. Instrumented Library Example

```go
// Example: HTTP client with instrumentation
package httpclient

import (
    "context"
    "fmt"
    "net/http"
    "time"
    
    "your-package/events"
)

type Client struct {
    httpClient *http.Client
    emitter    events.Emitter
    name       string
}

func NewClient(name string, emitter events.Emitter) *Client {
    return &Client{
        httpClient: &http.Client{Timeout: 30 * time.Second},
        emitter:    emitter,
        name:       name,
    }
}

func (c *Client) Get(ctx context.Context, url string) (*http.Response, error) {
    start := time.Now()
    
    // Emit start event
    c.emitter.EmitLog(ctx, events.LevelInfo, "http_request_start", map[string]interface{}{
        "method": "GET",
        "url":    url,
        "client": c.name,
    })
    
    // Make request
    req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
    if err != nil {
        c.emitError(ctx, "http_request_error", err, map[string]interface{}{
            "method": "GET",
            "url":    url,
            "stage":  "request_creation",
        })
        return nil, err
    }
    
    resp, err := c.httpClient.Do(req)
    duration := time.Since(start)
    
    if err != nil {
        c.emitError(ctx, "http_request_error", err, map[string]interface{}{
            "method":   "GET",
            "url":      url,
            "duration": duration.String(),
            "stage":    "request_execution",
        })
        return nil, err
    }
    
    // Emit success metrics
    c.emitter.EmitTrace(ctx, "http_request", duration, map[string]interface{}{
        "method":      "GET",
        "url":         url,
        "status_code": resp.StatusCode,
        "client":      c.name,
    })
    
    c.emitter.EmitMetric(ctx, "http_requests_total", 1, map[string]interface{}{
        "method":      "GET",
        "status_code": fmt.Sprintf("%d", resp.StatusCode),
        "client":      c.name,
    })
    
    c.emitter.EmitMetric(ctx, "http_request_duration_seconds", duration.Seconds(), map[string]interface{}{
        "method": "GET",
        "client": c.name,
    })
    
    return resp, nil
}

func (c *Client) emitError(ctx context.Context, message string, err error, fields map[string]interface{}) {
    event := events.Event{
        Level:   events.LevelError,
        Message: message,
        Fields:  fields,
        Error:   err,
    }
    c.emitter.Emit(ctx, event)
}
```

### 4. Integration with Popular Backends

```go
// Zap handler integration
type ZapHandler struct {
    logger *zap.Logger
    level  EventLevel
}

func NewZapHandler(logger *zap.Logger, level EventLevel) *ZapHandler {
    return &ZapHandler{
        logger: logger,
        level:  level,
    }
}

func (h *ZapHandler) Handle(ctx context.Context, event Event) error {
    if event.Level < h.level {
        return nil
    }
    
    fields := make([]zap.Field, 0, len(event.Fields)+5)
    fields = append(fields,
        zap.String("event_id", event.ID),
        zap.String("source", event.Source),
        zap.Time("timestamp", event.Timestamp),
    )
    
    if event.Error != nil {
        fields = append(fields, zap.Error(event.Error))
    }
    
    if event.Duration != nil {
        fields = append(fields, zap.Duration("duration", *event.Duration))
    }
    
    for key, value := range event.Fields {
        fields = append(fields, zap.Any(key, value))
    }
    
    switch event.Level {
    case LevelDebug:
        h.logger.Debug(event.Message, fields...)
    case LevelInfo:
        h.logger.Info(event.Message, fields...)
    case LevelWarn:
        h.logger.Warn(event.Message, fields...)
    case LevelError:
        h.logger.Error(event.Message, fields...)
    }
    
    return nil
}

func (h *ZapHandler) Close() error {
    return h.logger.Sync()
}

// OpenTelemetry handler integration
type OTelHandler struct {
    tracer trace.Tracer
    meter  metric.Meter
    level  EventLevel
}

func NewOTelHandler(tracer trace.Tracer, meter metric.Meter, level EventLevel) *OTelHandler {
    return &OTelHandler{
        tracer: tracer,
        meter:  meter,
        level:  level,
    }
}

func (h *OTelHandler) Handle(ctx context.Context, event Event) error {
    if event.Level < h.level {
        return nil
    }
    
    // Create span for trace events
    if event.Duration != nil {
        _, span := h.tracer.Start(ctx, event.Message)
        defer span.End()
        
        span.SetAttributes(
            attribute.String("event.id", event.ID),
            attribute.String("event.source", event.Source),
        )
        
        for key, value := range event.Fields {
            span.SetAttributes(attribute.String(key, fmt.Sprintf("%v", value)))
        }
    }
    
    // Emit metrics
    if metricName, ok := event.Fields["metric_name"].(string); ok {
        if value, ok := event.Fields["metric_value"].(float64); ok {
            counter, _ := h.meter.Float64Counter(metricName)
            counter.Add(ctx, value)
        }
    }
    
    return nil
}

func (h *OTelHandler) Close() error {
    return nil
}
```

### 5. Usage and Configuration

```go
// Library usage example
func main() {
    // Create emitter
    emitter := events.NewEmitter("my-service")
    
    // Add console handler for development
    consoleHandler := events.NewConsoleHandler(events.LevelInfo)
    emitter.AddHandler(consoleHandler)
    
    // Add JSON handler for production logs
    logFile, _ := os.OpenFile("app.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
    jsonHandler := events.NewJSONHandler(logFile, events.LevelInfo)
    asyncJSONHandler := events.NewAsyncHandler(jsonHandler, 1000)
    emitter.AddHandler(asyncJSONHandler)
    
    // Add metrics handler
    metricsHandler := events.NewMetricsHandler()
    emitter.AddHandler(metricsHandler)
    
    // Add filters
    emitter.AddFilter(func(event events.Event) bool {
        // Skip debug events in production
        return event.Level >= events.LevelInfo
    })
    
    emitter.AddFilter(func(event events.Event) bool {
        // Skip noisy metrics
        if metricName, ok := event.Fields["metric_name"].(string); ok {
            return !strings.HasPrefix(metricName, "debug_")
        }
        return true
    })
    
    // Use instrumented client
    client := httpclient.NewClient("api-client", emitter)
    
    ctx := context.Background()
    resp, err := client.Get(ctx, "https://api.example.com/users")
    if err != nil {
        log.Fatal(err)
    }
    defer resp.Body.Close()
    
    // Cleanup
    defer emitter.Close()
}

// Testing instrumentation
func TestInstrumentation(t *testing.T) {
    // Create test handler that captures events
    var capturedEvents []events.Event
    testHandler := &TestHandler{
        events: &capturedEvents,
    }
    
    emitter := events.NewEmitter("test")
    emitter.AddHandler(testHandler)
    
    // Test the instrumented component
    client := httpclient.NewClient("test-client", emitter)
    
    // Use httptest server for testing
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("OK"))
    }))
    defer server.Close()
    
    _, err := client.Get(context.Background(), server.URL)
    require.NoError(t, err)
    
    // Verify events were emitted
    assert.GreaterOrEqual(t, len(capturedEvents), 3) // start, trace, metric events
    
    // Verify event types
    var hasStartEvent, hasTraceEvent, hasMetricEvent bool
    for _, event := range capturedEvents {
        switch {
        case strings.Contains(event.Message, "start"):
            hasStartEvent = true
        case strings.Contains(event.Message, "trace"):
            hasTraceEvent = true
        case strings.Contains(event.Message, "metric"):
            hasMetricEvent = true
        }
    }
    
    assert.True(t, hasStartEvent)
    assert.True(t, hasTraceEvent)
    assert.True(t, hasMetricEvent)
}

type TestHandler struct {
    events *[]events.Event
}

func (h *TestHandler) Handle(ctx context.Context, event events.Event) error {
    *h.events = append(*h.events, event)
    return nil
}

func (h *TestHandler) Close() error {
    return nil
}
```

## Consequences

**Benefits:**
- **Backend agnostic**: Easy to switch between logging, metrics, and tracing systems
- **Performance**: Minimal overhead with async handlers and filtering
- **Flexibility**: Rich filtering and configuration options
- **Testability**: Easy to test instrumentation with mock handlers
- **Standards compliance**: Compatible with OpenTelemetry and structured logging

**Trade-offs:**
- **Complexity**: Additional abstraction layer for instrumentation
- **Memory usage**: Event buffering and async processing overhead
- **Learning curve**: Teams need to understand the instrumentation patterns

**Best Practices:**
- Use appropriate event levels and filtering to control noise
- Implement async handlers for high-throughput applications
- Add structured fields rather than embedding data in messages
- Use trace correlation IDs for distributed tracing
- Monitor instrumentation overhead and buffer utilization
- Provide clear documentation for available events and metrics

## References

- [OpenTelemetry Go SDK](https://github.com/open-telemetry/opentelemetry-go)
- [Structured Logging Best Practices](https://github.com/uber-go/zap/blob/master/FAQ.md)
- [Go Instrumentation Guidelines](https://github.com/golang/go/wiki/Instrumenting-Go-Code)
