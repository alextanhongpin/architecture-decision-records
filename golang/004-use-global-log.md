# ADR 004: Logging Architecture and Global Logger Patterns

## Status

**Accepted**

## Context

Logging is fundamental to observability in distributed systems, but different approaches to logger management present distinct trade-offs. The main approaches are:

1. **Global logger**: Single instance accessible throughout the application
2. **Dependency injection**: Logger passed through constructors and method parameters  
3. **Context-scoped logging**: Logger attached to request contexts

Each approach affects:
- **Testability**: Ability to mock, capture, and verify log output
- **Request correlation**: Tracking logs across request boundaries
- **Configuration flexibility**: Runtime log level and format changes
- **Performance**: Overhead of logger creation and passing
- **Code maintainability**: Boilerplate and coupling concerns

## Decision

We will use **dependency injection for structured logging** with context-aware loggers, avoiding global state while enabling request-scoped logging and comprehensive testing.

### 1. Core Logging Interface

```go
package logging

import (
    "context"
    "fmt"
    "time"
)

// Logger defines the structured logging interface
type Logger interface {
    // Structured logging methods
    Debug(msg string, fields ...Field)
    Info(msg string, fields ...Field)
    Warn(msg string, fields ...Field)
    Error(msg string, fields ...Field)
    
    // Context-aware logging
    DebugContext(ctx context.Context, msg string, fields ...Field)
    InfoContext(ctx context.Context, msg string, fields ...Field)
    WarnContext(ctx context.Context, msg string, fields ...Field)
    ErrorContext(ctx context.Context, msg string, fields ...Field)
    
    // Logger configuration
    WithFields(fields ...Field) Logger
    WithContext(ctx context.Context) Logger
    SetLevel(level Level)
    
    // Testing support
    Flush() error
}

// Field represents a structured log field
type Field struct {
    Key   string
    Value interface{}
}

// Convenience functions for creating fields
func String(key, value string) Field        { return Field{key, value} }
func Int(key string, value int) Field       { return Field{key, value} }
func Int64(key string, value int64) Field   { return Field{key, value} }
func Float64(key string, value float64) Field { return Field{key, value} }
func Bool(key string, value bool) Field     { return Field{key, value} }
func Duration(key string, value time.Duration) Field { return Field{key, value} }
func Error(err error) Field                  { return Field{"error", err} }
func Any(key string, value interface{}) Field { return Field{key, value} }

// Level represents log levels
type Level int

const (
    DebugLevel Level = iota
    InfoLevel
    WarnLevel
    ErrorLevel
)

func (l Level) String() string {
    switch l {
    case DebugLevel:
        return "DEBUG"
    case InfoLevel:
        return "INFO"
    case WarnLevel:
        return "WARN"
    case ErrorLevel:
        return "ERROR"
    default:
        return "UNKNOWN"
    }
}
```

### 2. Production Logger Implementation

```go
package logging

import (
    "context"
    "encoding/json"
    "fmt"
    "io"
    "os"
    "runtime"
    "sync"
    "time"
)

// ProductionLogger implements structured JSON logging
type ProductionLogger struct {
    mu       sync.RWMutex
    output   io.Writer
    level    Level
    fields   []Field
    encoder  Encoder
}

type Encoder interface {
    Encode(entry LogEntry) error
}

type LogEntry struct {
    Timestamp time.Time              `json:"timestamp"`
    Level     string                 `json:"level"`
    Message   string                 `json:"message"`
    Fields    map[string]interface{} `json:"fields,omitempty"`
    Caller    *CallerInfo            `json:"caller,omitempty"`
    TraceID   string                 `json:"trace_id,omitempty"`
    SpanID    string                 `json:"span_id,omitempty"`
}

type CallerInfo struct {
    File     string `json:"file"`
    Line     int    `json:"line"`
    Function string `json:"function"`
}

// NewProductionLogger creates a production-ready logger
func NewProductionLogger(output io.Writer, level Level) *ProductionLogger {
    if output == nil {
        output = os.Stdout
    }
    
    return &ProductionLogger{
        output:  output,
        level:   level,
        fields:  make([]Field, 0),
        encoder: NewJSONEncoder(output),
    }
}

func (pl *ProductionLogger) log(ctx context.Context, level Level, msg string, fields ...Field) {
    pl.mu.RLock()
    currentLevel := pl.level
    pl.mu.RUnlock()
    
    if level < currentLevel {
        return
    }
    
    // Combine instance fields with call-specific fields
    allFields := make(map[string]interface{})
    
    // Add instance fields
    for _, field := range pl.fields {
        allFields[field.Key] = field.Value
    }
    
    // Add call-specific fields
    for _, field := range fields {
        allFields[field.Key] = field.Value
    }
    
    // Extract tracing information from context
    traceID, spanID := ExtractTraceInfo(ctx)
    
    // Get caller information
    caller := getCaller(3) // Skip log wrapper methods
    
    entry := LogEntry{
        Timestamp: time.Now().UTC(),
        Level:     level.String(),
        Message:   msg,
        Fields:    allFields,
        Caller:    caller,
        TraceID:   traceID,
        SpanID:    spanID,
    }
    
    pl.encoder.Encode(entry)
}

func (pl *ProductionLogger) Debug(msg string, fields ...Field) {
    pl.log(context.Background(), DebugLevel, msg, fields...)
}

func (pl *ProductionLogger) Info(msg string, fields ...Field) {
    pl.log(context.Background(), InfoLevel, msg, fields...)
}

func (pl *ProductionLogger) Warn(msg string, fields ...Field) {
    pl.log(context.Background(), WarnLevel, msg, fields...)
}

func (pl *ProductionLogger) Error(msg string, fields ...Field) {
    pl.log(context.Background(), ErrorLevel, msg, fields...)
}

func (pl *ProductionLogger) DebugContext(ctx context.Context, msg string, fields ...Field) {
    pl.log(ctx, DebugLevel, msg, fields...)
}

func (pl *ProductionLogger) InfoContext(ctx context.Context, msg string, fields ...Field) {
    pl.log(ctx, InfoLevel, msg, fields...)
}

func (pl *ProductionLogger) WarnContext(ctx context.Context, msg string, fields ...Field) {
    pl.log(ctx, WarnLevel, msg, fields...)
}

func (pl *ProductionLogger) ErrorContext(ctx context.Context, msg string, fields ...Field) {
    pl.log(ctx, ErrorLevel, msg, fields...)
}

func (pl *ProductionLogger) WithFields(fields ...Field) Logger {
    pl.mu.RLock()
    existingFields := make([]Field, len(pl.fields))
    copy(existingFields, pl.fields)
    pl.mu.RUnlock()
    
    newFields := append(existingFields, fields...)
    
    return &ProductionLogger{
        output:  pl.output,
        level:   pl.level,
        fields:  newFields,
        encoder: pl.encoder,
    }
}

func (pl *ProductionLogger) WithContext(ctx context.Context) Logger {
    // Extract relevant context information and add as fields
    fields := []Field{}
    
    if traceID, spanID := ExtractTraceInfo(ctx); traceID != "" {
        fields = append(fields, String("trace_id", traceID))
        if spanID != "" {
            fields = append(fields, String("span_id", spanID))
        }
    }
    
    if userID := ExtractUserID(ctx); userID != "" {
        fields = append(fields, String("user_id", userID))
    }
    
    if requestID := ExtractRequestID(ctx); requestID != "" {
        fields = append(fields, String("request_id", requestID))
    }
    
    return pl.WithFields(fields...)
}

func (pl *ProductionLogger) SetLevel(level Level) {
    pl.mu.Lock()
    pl.level = level
    pl.mu.Unlock()
}

func (pl *ProductionLogger) Flush() error {
    if flusher, ok := pl.output.(interface{ Flush() error }); ok {
        return flusher.Flush()
    }
    return nil
}

// JSON Encoder implementation
type JSONEncoder struct {
    writer io.Writer
    mu     sync.Mutex
}

func NewJSONEncoder(writer io.Writer) *JSONEncoder {
    return &JSONEncoder{writer: writer}
}

func (je *JSONEncoder) Encode(entry LogEntry) error {
    je.mu.Lock()
    defer je.mu.Unlock()
    
    data, err := json.Marshal(entry)
    if err != nil {
        return fmt.Errorf("failed to marshal log entry: %w", err)
    }
    
    data = append(data, '\n')
    _, err = je.writer.Write(data)
    return err
}

// Helper functions
func getCaller(skip int) *CallerInfo {
    pc, file, line, ok := runtime.Caller(skip)
    if !ok {
        return nil
    }
    
    fn := runtime.FuncForPC(pc)
    if fn == nil {
        return nil
    }
    
    return &CallerInfo{
        File:     file,
        Line:     line,
        Function: fn.Name(),
    }
}

// Context extraction functions (implement based on your tracing setup)
func ExtractTraceInfo(ctx context.Context) (traceID, spanID string) {
    // Implement based on your tracing library (OpenTelemetry, Jaeger, etc.)
    return "", ""
}

func ExtractUserID(ctx context.Context) string {
    if userID, ok := ctx.Value("user_id").(string); ok {
        return userID
    }
    return ""
}

func ExtractRequestID(ctx context.Context) string {
    if requestID, ok := ctx.Value("request_id").(string); ok {
        return requestID
    }
    return ""
}
```

### 3. Testing Logger Implementation

```go
package logging

import (
    "bytes"
    "context"
    "encoding/json"
    "sync"
)

// TestLogger captures log entries for testing
type TestLogger struct {
    mu      sync.RWMutex
    entries []LogEntry
    level   Level
    fields  []Field
}

func NewTestLogger(level Level) *TestLogger {
    return &TestLogger{
        entries: make([]LogEntry, 0),
        level:   level,
        fields:  make([]Field, 0),
    }
}

func (tl *TestLogger) log(ctx context.Context, level Level, msg string, fields ...Field) {
    tl.mu.Lock()
    defer tl.mu.Unlock()
    
    if level < tl.level {
        return
    }
    
    allFields := make(map[string]interface{})
    for _, field := range tl.fields {
        allFields[field.Key] = field.Value
    }
    for _, field := range fields {
        allFields[field.Key] = field.Value
    }
    
    traceID, spanID := ExtractTraceInfo(ctx)
    
    entry := LogEntry{
        Level:   level.String(),
        Message: msg,
        Fields:  allFields,
        TraceID: traceID,
        SpanID:  spanID,
    }
    
    tl.entries = append(tl.entries, entry)
}

// Implement Logger interface methods...
func (tl *TestLogger) Debug(msg string, fields ...Field) {
    tl.log(context.Background(), DebugLevel, msg, fields...)
}

func (tl *TestLogger) Info(msg string, fields ...Field) {
    tl.log(context.Background(), InfoLevel, msg, fields...)
}

func (tl *TestLogger) Warn(msg string, fields ...Field) {
    tl.log(context.Background(), WarnLevel, msg, fields...)
}

func (tl *TestLogger) Error(msg string, fields ...Field) {
    tl.log(context.Background(), ErrorLevel, msg, fields...)
}

func (tl *TestLogger) DebugContext(ctx context.Context, msg string, fields ...Field) {
    tl.log(ctx, DebugLevel, msg, fields...)
}

func (tl *TestLogger) InfoContext(ctx context.Context, msg string, fields ...Field) {
    tl.log(ctx, InfoLevel, msg, fields...)
}

func (tl *TestLogger) WarnContext(ctx context.Context, msg string, fields ...Field) {
    tl.log(ctx, WarnLevel, msg, fields...)
}

func (tl *TestLogger) ErrorContext(ctx context.Context, msg string, fields ...Field) {
    tl.log(ctx, ErrorLevel, msg, fields...)
}

func (tl *TestLogger) WithFields(fields ...Field) Logger {
    tl.mu.RLock()
    existingFields := make([]Field, len(tl.fields))
    copy(existingFields, tl.fields)
    tl.mu.RUnlock()
    
    newFields := append(existingFields, fields...)
    
    return &TestLogger{
        entries: tl.entries, // Share entries for verification
        level:   tl.level,
        fields:  newFields,
    }
}

func (tl *TestLogger) WithContext(ctx context.Context) Logger {
    return tl // For simplicity in tests
}

func (tl *TestLogger) SetLevel(level Level) {
    tl.mu.Lock()
    tl.level = level
    tl.mu.Unlock()
}

func (tl *TestLogger) Flush() error {
    return nil
}

// Testing helper methods
func (tl *TestLogger) Entries() []LogEntry {
    tl.mu.RLock()
    defer tl.mu.RUnlock()
    
    entries := make([]LogEntry, len(tl.entries))
    copy(entries, tl.entries)
    return entries
}

func (tl *TestLogger) Clear() {
    tl.mu.Lock()
    tl.entries = tl.entries[:0]
    tl.mu.Unlock()
}

func (tl *TestLogger) HasEntry(level Level, message string) bool {
    tl.mu.RLock()
    defer tl.mu.RUnlock()
    
    levelStr := level.String()
    for _, entry := range tl.entries {
        if entry.Level == levelStr && entry.Message == message {
            return true
        }
    }
    return false
}

func (tl *TestLogger) CountEntries(level Level) int {
    tl.mu.RLock()
    defer tl.mu.RUnlock()
    
    levelStr := level.String()
    count := 0
    for _, entry := range tl.entries {
        if entry.Level == levelStr {
            count++
        }
    }
    return count
}
```

### 4. HTTP Middleware for Request Logging

```go
package middleware

import (
    "context"
    "net/http"
    "time"
    
    "github.com/google/uuid"
)

// LoggingMiddleware adds request logging and correlation IDs
func LoggingMiddleware(logger Logger) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            start := time.Now()
            
            // Generate request ID if not present
            requestID := r.Header.Get("X-Request-ID")
            if requestID == "" {
                requestID = uuid.New().String()
            }
            
            // Add request ID to context
            ctx := context.WithValue(r.Context(), "request_id", requestID)
            r = r.WithContext(ctx)
            
            // Create request-scoped logger
            requestLogger := logger.WithContext(ctx).WithFields(
                String("method", r.Method),
                String("path", r.URL.Path),
                String("user_agent", r.UserAgent()),
                String("remote_addr", r.RemoteAddr),
                String("request_id", requestID),
            )
            
            // Capture response details
            wrapped := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
            
            // Log request start
            requestLogger.Info("request started")
            
            // Process request
            next.ServeHTTP(wrapped, r)
            
            // Log request completion
            duration := time.Since(start)
            requestLogger.Info("request completed",
                Int("status_code", wrapped.statusCode),
                Int64("response_size", wrapped.bytesWritten),
                Duration("duration", duration),
            )
        })
    }
}

type responseWriter struct {
    http.ResponseWriter
    statusCode    int
    bytesWritten  int64
}

func (rw *responseWriter) WriteHeader(code int) {
    rw.statusCode = code
    rw.ResponseWriter.WriteHeader(code)
}

func (rw *responseWriter) Write(b []byte) (int, error) {
    n, err := rw.ResponseWriter.Write(b)
    rw.bytesWritten += int64(n)
    return n, err
}
```

### 5. Service Layer Integration

```go
package service

import (
    "context"
    "fmt"
)

// UserService demonstrates dependency injection of logger
type UserService struct {
    logger Logger
    repo   UserRepository
}

func NewUserService(logger Logger, repo UserRepository) *UserService {
    return &UserService{
        logger: logger.WithFields(String("component", "user_service")),
        repo:   repo,
    }
}

func (us *UserService) CreateUser(ctx context.Context, user *User) error {
    logger := us.logger.WithContext(ctx)
    
    logger.Info("creating user",
        String("email", user.Email),
        String("role", user.Role),
    )
    
    if err := us.validateUser(user); err != nil {
        logger.Error("user validation failed",
            Error(err),
            String("email", user.Email),
        )
        return fmt.Errorf("validation failed: %w", err)
    }
    
    if err := us.repo.Save(ctx, user); err != nil {
        logger.Error("failed to save user",
            Error(err),
            String("user_id", user.ID),
        )
        return fmt.Errorf("save failed: %w", err)
    }
    
    logger.Info("user created successfully",
        String("user_id", user.ID),
        String("email", user.Email),
    )
    
    return nil
}

func (us *UserService) validateUser(user *User) error {
    // Validation logic
    return nil
}

// UserRepository interface for dependency injection
type UserRepository interface {
    Save(ctx context.Context, user *User) error
    FindByID(ctx context.Context, id string) (*User, error)
}

type User struct {
    ID    string
    Email string
    Role  string
}
```

### 6. Configuration and Factory

```go
package logging

import (
    "os"
    "strings"
)

type Config struct {
    Level      string `json:"level" yaml:"level"`
    Format     string `json:"format" yaml:"format"` // "json" or "console"
    Output     string `json:"output" yaml:"output"` // "stdout", "stderr", or file path
    AddCaller  bool   `json:"add_caller" yaml:"add_caller"`
    AddStacktrace bool `json:"add_stacktrace" yaml:"add_stacktrace"`
}

// NewLogger creates appropriate logger based on configuration
func NewLogger(config Config) (Logger, error) {
    level := parseLevel(config.Level)
    
    var output io.Writer
    switch config.Output {
    case "", "stdout":
        output = os.Stdout
    case "stderr":
        output = os.Stderr
    default:
        file, err := os.OpenFile(config.Output, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0666)
        if err != nil {
            return nil, fmt.Errorf("failed to open log file: %w", err)
        }
        output = file
    }
    
    switch config.Format {
    case "console":
        return NewConsoleLogger(output, level), nil
    case "json", "":
        return NewProductionLogger(output, level), nil
    default:
        return nil, fmt.Errorf("unsupported log format: %s", config.Format)
    }
}

func parseLevel(levelStr string) Level {
    switch strings.ToUpper(levelStr) {
    case "DEBUG":
        return DebugLevel
    case "INFO", "":
        return InfoLevel
    case "WARN", "WARNING":
        return WarnLevel
    case "ERROR":
        return ErrorLevel
    default:
        return InfoLevel
    }
}

// Factory for different environments
func NewProductionLogger() Logger {
    config := Config{
        Level:  "INFO",
        Format: "json",
        Output: "stdout",
    }
    
    logger, _ := NewLogger(config)
    return logger
}

func NewDevelopmentLogger() Logger {
    config := Config{
        Level:  "DEBUG",
        Format: "console",
        Output: "stdout",
    }
    
    logger, _ := NewLogger(config)
    return logger
}

func NewTestLogger() *TestLogger {
    return NewTestLogger(DebugLevel)
}
```

### 7. Testing Examples

```go
package service_test

import (
    "context"
    "testing"
    
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
    "github.com/stretchr/testify/require"
)

func TestUserService_CreateUser(t *testing.T) {
    testLogger := NewTestLogger(DebugLevel)
    mockRepo := NewMockUserRepository()
    
    service := NewUserService(testLogger, mockRepo)
    
    user := &User{
        ID:    "user-123",
        Email: "test@example.com",
        Role:  "user",
    }
    
    mockRepo.On("Save", mock.Anything, user).Return(nil)
    
    err := service.CreateUser(context.Background(), user)
    require.NoError(t, err)
    
    // Verify logging behavior
    entries := testLogger.Entries()
    assert.Len(t, entries, 2) // Start and completion logs
    
    assert.True(t, testLogger.HasEntry(InfoLevel, "creating user"))
    assert.True(t, testLogger.HasEntry(InfoLevel, "user created successfully"))
    
    // Verify log fields
    creationEntry := entries[0]
    assert.Equal(t, "test@example.com", creationEntry.Fields["email"])
    assert.Equal(t, "user", creationEntry.Fields["role"])
    
    mockRepo.AssertExpectations(t)
}

func TestUserService_CreateUser_ValidationError(t *testing.T) {
    testLogger := NewTestLogger(DebugLevel)
    mockRepo := NewMockUserRepository()
    
    service := NewUserService(testLogger, mockRepo)
    
    user := &User{
        ID:    "user-123",
        Email: "", // Invalid email
        Role:  "user",
    }
    
    err := service.CreateUser(context.Background(), user)
    assert.Error(t, err)
    
    // Verify error was logged
    assert.True(t, testLogger.HasEntry(ErrorLevel, "user validation failed"))
    assert.Equal(t, 1, testLogger.CountEntries(ErrorLevel))
    
    mockRepo.AssertNotCalled(t, "Save")
}

type MockUserRepository struct {
    mock.Mock
}

func NewMockUserRepository() *MockUserRepository {
    return &MockUserRepository{}
}

func (m *MockUserRepository) Save(ctx context.Context, user *User) error {
    args := m.Called(ctx, user)
    return args.Error(0)
}

func (m *MockUserRepository) FindByID(ctx context.Context, id string) (*User, error) {
    args := m.Called(ctx, id)
    return args.Get(0).(*User), args.Error(1)
}
```

## Implementation Guidelines

### Best Practices

1. **Always inject loggers**: Pass loggers through constructors, not as global variables
2. **Use structured logging**: Prefer key-value pairs over string formatting
3. **Context-aware logging**: Extract request/trace information from context
4. **Appropriate log levels**: Debug for development, Info for operations, Error for failures
5. **Include correlation IDs**: Use request IDs and trace IDs for request tracking

### Dependency Injection Pattern

```go
// ✅ Good: Explicit dependency injection
type Service struct {
    logger Logger
    db     Database
}

func NewService(logger Logger, db Database) *Service {
    return &Service{
        logger: logger.WithFields(String("component", "service")),
        db:     db,
    }
}

// ❌ Bad: Global logger usage
var globalLogger Logger

func (s *Service) DoWork() {
    globalLogger.Info("doing work") // Hard to test, no context
}
```

## Consequences

### Positive
- **Testability**: Easy to mock and verify logging behavior
- **Request correlation**: Context-aware logging with trace IDs
- **Flexibility**: Runtime configuration and level changes
- **Structured data**: JSON output for log aggregation systems
- **Performance**: Efficient field handling and level checking

### Negative
- **Boilerplate**: Logger must be passed through constructors
- **Interface complexity**: More methods than simple global logger
- **Memory overhead**: Logger instances and field allocation

## Comparison with Global Logger

| Aspect | Dependency Injection | Global Logger |
|--------|---------------------|---------------|
| Testability | Easy mocking/verification | Difficult to test |
| Request correlation | Context-aware logging | Manual correlation |
| Configuration | Per-instance config | Single global config |
| Code complexity | Higher (DI boilerplate) | Lower (direct access) |
| Performance | Good (scoped loggers) | Excellent (minimal overhead) |
| Maintainability | Good (explicit deps) | Poor (hidden dependencies) |

## Anti-patterns to Avoid

```go
// ❌ Bad: Global logger
var log = logrus.New()

func ProcessUser(user *User) {
    log.Info("processing user") // No context, hard to test
}

// ❌ Bad: Logger in every method signature
func (s *Service) ProcessUser(logger Logger, user *User) {
    // Too much boilerplate
}

// ❌ Bad: Creating loggers everywhere
func (s *Service) ProcessUser(user *User) {
    logger := logrus.New() // Inefficient, no configuration
    logger.Info("processing user")
}

// ✅ Good: Injected logger with context
type Service struct {
    logger Logger
}

func (s *Service) ProcessUser(ctx context.Context, user *User) {
    logger := s.logger.WithContext(ctx)
    logger.Info("processing user", String("user_id", user.ID))
}
```

## References

- [Go Logging Best Practices](https://dave.cheney.net/2015/11/05/lets-talk-about-logging)
- [Structured Logging](https://www.honeycomb.io/blog/structured-logging-and-your-team/)
- [The Twelve-Factor App: Logs](https://12factor.net/logs)
- [OpenTelemetry Go SDK](https://github.com/open-telemetry/opentelemetry-go)
