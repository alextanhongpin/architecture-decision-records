# Structured Logging Strategy

## Status

`accepted`

## Context

Effective logging is crucial for system observability, debugging, and monitoring. Poor logging practices lead to difficult troubleshooting, performance issues, and operational blind spots. Modern distributed systems require structured, searchable, and contextual logging.

### Current Challenges

Traditional logging approaches face several issues:
- **Unstructured logs**: Text-based logs are difficult to search and analyze
- **Performance impact**: Synchronous logging can slow down applications
- **Missing context**: Logs lack correlation IDs and request context
- **Inconsistent format**: Different services use different log formats
- **Volume management**: High-traffic systems generate overwhelming log volumes
- **Security concerns**: Sensitive data accidentally logged

### Requirements

Our logging strategy must provide:
- **Performance**: Minimal impact on application performance
- **Structure**: Machine-readable format for analysis
- **Context**: Request tracing and correlation
- **Security**: Automatic sensitive data scrubbing
- **Scalability**: Handle high-volume logging efficiently
- **Standards**: Consistent format across all services

## Decision

We will implement structured JSON logging with correlation tracking, performance optimization, and automatic data classification.

### Logging Architecture

#### 1. Structured JSON Format

```go
package logger

import (
    "context"
    "encoding/json"
    "fmt"
    "log/slog"
    "os"
    "runtime"
    "time"
)

type LogEntry struct {
    Timestamp     time.Time              `json:"timestamp"`
    Level         string                 `json:"level"`
    Message       string                 `json:"message"`
    Service       string                 `json:"service"`
    Version       string                 `json:"version"`
    Environment   string                 `json:"environment"`
    CorrelationID string                 `json:"correlation_id,omitempty"`
    UserID        string                 `json:"user_id,omitempty"`
    RequestID     string                 `json:"request_id,omitempty"`
    TraceID       string                 `json:"trace_id,omitempty"`
    SpanID        string                 `json:"span_id,omitempty"`
    Tags          []string               `json:"tags,omitempty"`
    Fields        map[string]interface{} `json:"fields,omitempty"`
    Error         *ErrorDetails          `json:"error,omitempty"`
    Performance   *PerformanceMetrics    `json:"performance,omitempty"`
    Source        *SourceLocation        `json:"source,omitempty"`
}

type ErrorDetails struct {
    Type       string `json:"type"`
    Message    string `json:"message"`
    StackTrace string `json:"stack_trace,omitempty"`
    Code       string `json:"code,omitempty"`
}

type PerformanceMetrics struct {
    Duration   int64  `json:"duration_ms"`
    MemoryUsed int64  `json:"memory_used_bytes,omitempty"`
    CPUUsed    int64  `json:"cpu_used_ns,omitempty"`
}

type SourceLocation struct {
    File     string `json:"file"`
    Line     int    `json:"line"`
    Function string `json:"function"`
}
```

#### 2. High-Performance Logger Implementation

```go
type AsyncLogger struct {
    logChan    chan LogEntry
    bufferSize int
    batchSize  int
    flushTimer *time.Timer
    buffer     []LogEntry
    output     io.Writer
    
    // Configuration
    service     string
    version     string
    environment string
    
    // Performance monitoring
    stats *LoggerStats
}

type LoggerStats struct {
    TotalLogs     int64
    DroppedLogs   int64
    AverageLatency time.Duration
    BufferUsage   int64
}

func NewAsyncLogger(config LoggerConfig) *AsyncLogger {
    logger := &AsyncLogger{
        logChan:     make(chan LogEntry, config.BufferSize),
        bufferSize:  config.BufferSize,
        batchSize:   config.BatchSize,
        buffer:      make([]LogEntry, 0, config.BatchSize),
        output:      config.Output,
        service:     config.Service,
        version:     config.Version,
        environment: config.Environment,
        stats:       &LoggerStats{},
    }
    
    // Start background goroutine for log processing
    go logger.processLogs()
    
    return logger
}

func (l *AsyncLogger) processLogs() {
    ticker := time.NewTicker(100 * time.Millisecond) // Flush every 100ms
    defer ticker.Stop()
    
    for {
        select {
        case entry := <-l.logChan:
            l.buffer = append(l.buffer, entry)
            
            // Flush when buffer is full
            if len(l.buffer) >= l.batchSize {
                l.flushBuffer()
            }
            
        case <-ticker.C:
            // Periodic flush to ensure timely log delivery
            if len(l.buffer) > 0 {
                l.flushBuffer()
            }
        }
    }
}

func (l *AsyncLogger) flushBuffer() {
    if len(l.buffer) == 0 {
        return
    }
    
    start := time.Now()
    
    // Batch write to output
    for _, entry := range l.buffer {
        jsonData, err := json.Marshal(entry)
        if err != nil {
            // Handle serialization error
            l.stats.DroppedLogs++
            continue
        }
        
        l.output.Write(jsonData)
        l.output.Write([]byte("\n"))
    }
    
    // Update statistics
    l.stats.TotalLogs += int64(len(l.buffer))
    l.stats.AverageLatency = time.Since(start) / time.Duration(len(l.buffer))
    
    // Clear buffer
    l.buffer = l.buffer[:0]
}

func (l *AsyncLogger) Log(ctx context.Context, level slog.Level, message string, fields map[string]interface{}) {
    entry := LogEntry{
        Timestamp:   time.Now().UTC(),
        Level:       level.String(),
        Message:     message,
        Service:     l.service,
        Version:     l.version,
        Environment: l.environment,
        Fields:      l.sanitizeFields(fields),
    }
    
    // Extract context information
    if correlationID := GetCorrelationID(ctx); correlationID != "" {
        entry.CorrelationID = correlationID
    }
    
    if userID := GetUserID(ctx); userID != "" {
        entry.UserID = userID
    }
    
    if requestID := GetRequestID(ctx); requestID != "" {
        entry.RequestID = requestID
    }
    
    // Add source location for errors and warnings
    if level >= slog.LevelWarn {
        entry.Source = l.getSourceLocation()
    }
    
    // Non-blocking send to channel
    select {
    case l.logChan <- entry:
        // Successfully queued
    default:
        // Channel full, increment dropped logs counter
        l.stats.DroppedLogs++
    }
}
```

#### 3. Context-Aware Logging

```go
type contextKey string

const (
    CorrelationIDKey contextKey = "correlation_id"
    UserIDKey        contextKey = "user_id"
    RequestIDKey     contextKey = "request_id"
    TraceIDKey       contextKey = "trace_id"
    SpanIDKey        contextKey = "span_id"
)

// Context helpers
func WithCorrelationID(ctx context.Context, id string) context.Context {
    return context.WithValue(ctx, CorrelationIDKey, id)
}

func GetCorrelationID(ctx context.Context) string {
    if id, ok := ctx.Value(CorrelationIDKey).(string); ok {
        return id
    }
    return ""
}

func WithUserID(ctx context.Context, userID string) context.Context {
    return context.WithValue(ctx, UserIDKey, userID)
}

func GetUserID(ctx context.Context) string {
    if id, ok := ctx.Value(UserIDKey).(string); ok {
        return id
    }
    return ""
}

// HTTP middleware for request context
func LoggingMiddleware(logger *AsyncLogger) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            start := time.Now()
            
            // Generate request ID
            requestID := generateRequestID()
            
            // Extract or generate correlation ID
            correlationID := r.Header.Get("X-Correlation-ID")
            if correlationID == "" {
                correlationID = generateCorrelationID()
            }
            
            // Add to context
            ctx := WithCorrelationID(r.Context(), correlationID)
            ctx = WithRequestID(ctx, requestID)
            
            // Wrap response writer to capture status code
            wrapper := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
            
            // Log request start
            logger.Log(ctx, slog.LevelInfo, "Request started", map[string]interface{}{
                "method":     r.Method,
                "path":       r.URL.Path,
                "user_agent": r.UserAgent(),
                "remote_ip":  getClientIP(r),
            })
            
            // Process request
            next.ServeHTTP(wrapper, r.WithContext(ctx))
            
            // Log request completion
            duration := time.Since(start)
            logger.Log(ctx, slog.LevelInfo, "Request completed", map[string]interface{}{
                "method":      r.Method,
                "path":        r.URL.Path,
                "status_code": wrapper.statusCode,
                "duration_ms": duration.Milliseconds(),
                "bytes_sent":  wrapper.bytesWritten,
            })
        })
    }
}

type responseWriter struct {
    http.ResponseWriter
    statusCode   int
    bytesWritten int64
}

func (rw *responseWriter) WriteHeader(statusCode int) {
    rw.statusCode = statusCode
    rw.ResponseWriter.WriteHeader(statusCode)
}

func (rw *responseWriter) Write(data []byte) (int, error) {
    n, err := rw.ResponseWriter.Write(data)
    rw.bytesWritten += int64(n)
    return n, err
}
```

#### 4. Sensitive Data Protection

```go
type DataClassifier struct {
    sensitivePatterns []*regexp.Regexp
    hashSalt         string
}

func NewDataClassifier() *DataClassifier {
    patterns := []*regexp.Regexp{
        regexp.MustCompile(`(?i)(password|secret|token|key)`),           // Field names
        regexp.MustCompile(`\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b`), // Credit card numbers
        regexp.MustCompile(`\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b`), // Email addresses
        regexp.MustCompile(`\b\d{3}-\d{2}-\d{4}\b`),                   // SSN
    }
    
    return &DataClassifier{
        sensitivePatterns: patterns,
        hashSalt:         getHashSalt(),
    }
}

func (dc *DataClassifier) sanitizeFields(fields map[string]interface{}) map[string]interface{} {
    sanitized := make(map[string]interface{})
    
    for key, value := range fields {
        sanitized[key] = dc.sanitizeValue(key, value)
    }
    
    return sanitized
}

func (dc *DataClassifier) sanitizeValue(key string, value interface{}) interface{} {
    // Convert to string for pattern matching
    strValue := fmt.Sprintf("%v", value)
    
    // Check field name patterns
    for _, pattern := range dc.sensitivePatterns {
        if pattern.MatchString(key) {
            return "[REDACTED]"
        }
        
        // Check value patterns
        if pattern.MatchString(strValue) {
            return "[REDACTED]"
        }
    }
    
    return value
}

// Hash sensitive data for tracking while maintaining privacy
func (dc *DataClassifier) hashSensitiveData(data string) string {
    hasher := sha256.New()
    hasher.Write([]byte(data + dc.hashSalt))
    return fmt.Sprintf("hash:%x", hasher.Sum(nil)[:8]) // First 8 bytes for tracking
}
```

#### 5. Performance Monitoring and Metrics

```go
type PerformanceLogger struct {
    logger *AsyncLogger
}

func (pl *PerformanceLogger) LogOperationPerformance(ctx context.Context, operation string, duration time.Duration, success bool) {
    level := slog.LevelInfo
    if !success {
        level = slog.LevelWarn
    }
    
    fields := map[string]interface{}{
        "operation":    operation,
        "duration_ms":  duration.Milliseconds(),
        "success":      success,
    }
    
    // Add memory usage if available
    var m runtime.MemStats
    runtime.ReadMemStats(&m)
    fields["memory_alloc"] = m.Alloc
    
    pl.logger.Log(ctx, level, "Operation performance", fields)
}

func (pl *PerformanceLogger) LogDatabaseQuery(ctx context.Context, query string, duration time.Duration, rowsAffected int64, err error) {
    level := slog.LevelInfo
    if err != nil {
        level = slog.LevelError
    }
    
    fields := map[string]interface{}{
        "component":      "database",
        "query_type":     extractQueryType(query),
        "duration_ms":    duration.Milliseconds(),
        "rows_affected":  rowsAffected,
        "query_hash":     hashQuery(query), // Hash to avoid logging sensitive data
    }
    
    if err != nil {
        fields["error"] = err.Error()
    }
    
    pl.logger.Log(ctx, level, "Database query executed", fields)
}

func (pl *PerformanceLogger) LogExternalAPICall(ctx context.Context, service, endpoint string, duration time.Duration, statusCode int, err error) {
    level := slog.LevelInfo
    if err != nil || statusCode >= 400 {
        level = slog.LevelError
    }
    
    fields := map[string]interface{}{
        "component":    "external_api",
        "service":      service,
        "endpoint":     endpoint,
        "duration_ms":  duration.Milliseconds(),
        "status_code":  statusCode,
    }
    
    if err != nil {
        fields["error"] = err.Error()
    }
    
    pl.logger.Log(ctx, level, "External API call", fields)
}
```

### Configuration and Environment Setup

```go
type LoggerConfig struct {
    Service      string        `json:"service"`
    Version      string        `json:"version"`
    Environment  string        `json:"environment"`
    Level        slog.Level    `json:"level"`
    Format       string        `json:"format"` // "json" or "text"
    Output       io.Writer     `json:"-"`
    BufferSize   int           `json:"buffer_size"`
    BatchSize    int           `json:"batch_size"`
    FlushTimeout time.Duration `json:"flush_timeout"`
}

func LoadLoggerConfig() LoggerConfig {
    return LoggerConfig{
        Service:      getEnv("SERVICE_NAME", "unknown"),
        Version:      getEnv("SERVICE_VERSION", "unknown"),
        Environment:  getEnv("ENVIRONMENT", "development"),
        Level:        parseLogLevel(getEnv("LOG_LEVEL", "info")),
        Format:       getEnv("LOG_FORMAT", "json"),
        Output:       os.Stdout,
        BufferSize:   parseInt(getEnv("LOG_BUFFER_SIZE", "1000")),
        BatchSize:    parseInt(getEnv("LOG_BATCH_SIZE", "100")),
        FlushTimeout: parseDuration(getEnv("LOG_FLUSH_TIMEOUT", "100ms")),
    }
}

// Environment-specific configurations
var EnvironmentConfigs = map[string]LoggerConfig{
    "development": {
        Level:      slog.LevelDebug,
        Format:     "text",
        BufferSize: 100,
        BatchSize:  10,
    },
    "staging": {
        Level:      slog.LevelInfo,
        Format:     "json",
        BufferSize: 500,
        BatchSize:  50,
    },
    "production": {
        Level:      slog.LevelInfo,
        Format:     "json",
        BufferSize: 2000,
        BatchSize:  200,
    },
}
```

### Log Analysis and Monitoring

#### Elasticsearch Index Template

```json
{
  "index_patterns": ["app-logs-*"],
  "template": {
    "mappings": {
      "properties": {
        "timestamp": { "type": "date" },
        "level": { "type": "keyword" },
        "message": { "type": "text" },
        "service": { "type": "keyword" },
        "version": { "type": "keyword" },
        "environment": { "type": "keyword" },
        "correlation_id": { "type": "keyword" },
        "user_id": { "type": "keyword" },
        "request_id": { "type": "keyword" },
        "trace_id": { "type": "keyword" },
        "tags": { "type": "keyword" },
        "fields": { "type": "object", "dynamic": true },
        "error.type": { "type": "keyword" },
        "error.message": { "type": "text" },
        "performance.duration_ms": { "type": "long" },
        "source.file": { "type": "keyword" },
        "source.function": { "type": "keyword" }
      }
    },
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1,
      "index.lifecycle.name": "app-logs-policy"
    }
  }
}
```

#### Common Log Queries

```json
// Find errors in the last hour
{
  "query": {
    "bool": {
      "must": [
        { "term": { "level": "ERROR" } },
        { "range": { "timestamp": { "gte": "now-1h" } } }
      ]
    }
  }
}

// Trace request flow by correlation ID
{
  "query": {
    "term": { "correlation_id": "12345-abcde-67890" }
  },
  "sort": [
    { "timestamp": "asc" }
  ]
}

// Performance analysis - slow operations
{
  "query": {
    "range": {
      "performance.duration_ms": { "gte": 1000 }
    }
  },
  "aggs": {
    "slow_operations": {
      "terms": { "field": "operation" }
    }
  }
}
```

## Consequences

### Positive
- **Structured format**: JSON logs are easily searchable and analyzable
- **High performance**: Async logging minimizes application impact
- **Rich context**: Correlation IDs enable request tracing
- **Security**: Automatic sensitive data protection
- **Monitoring**: Built-in performance metrics and error tracking
- **Scalability**: Efficient batch processing handles high volumes

### Negative
- **Complexity**: More complex than simple text logging
- **Memory usage**: Buffering requires additional memory
- **Potential data loss**: Async logging risks losing logs on crash
- **JSON overhead**: Structured format increases log size

### Mitigation Strategies
- **Graceful shutdown**: Flush logs before application termination
- **Health monitoring**: Track logger performance and dropped logs
- **Fallback mechanisms**: Switch to synchronous logging if buffer full
- **Log rotation**: Implement proper log file management
- **Compression**: Use log compression to reduce storage costs

## Best Practices

1. **Use correlation IDs**: Enable request tracing across services
2. **Log at appropriate levels**: Don't over-log or under-log
3. **Include context**: Add relevant business context to logs
4. **Sanitize sensitive data**: Never log passwords or personal information
5. **Monitor log performance**: Track logging overhead and dropped logs
6. **Use structured fields**: Make logs searchable and analyzable
7. **Implement log rotation**: Manage log file sizes and retention
8. **Test logging**: Include logging in your testing strategy

## References

- [Structured Logging Best Practices](https://engineering.grab.com/structured-logging)
- [The Twelve-Factor App: Logs](https://12factor.net/logs)
- [Go slog Package](https://pkg.go.dev/log/slog)
- [ELK Stack Documentation](https://www.elastic.co/what-is/elk-stack)
- [OpenTelemetry Logging](https://opentelemetry.io/docs/specs/otel/logs/)
- [Google Cloud Logging Best Practices](https://cloud.google.com/logging/docs/structured-logging)
