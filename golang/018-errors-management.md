# Error Management in Go

## Status

`production`

## Context

Error handling is a critical aspect of Go applications that directly impacts reliability, debuggability, and user experience. Poor error management leads to unclear error messages, difficult debugging, and inconsistent error handling across the codebase.

This ADR establishes comprehensive patterns and practices for error management in Go applications, covering everything from error creation to propagation, logging, and user-facing error responses.

## Decision

We will implement a structured approach to error management that emphasizes clarity, consistency, and actionability.

### Core Error Framework

```go
package errors

import (
    "context"
    "encoding/json"
    "fmt"
    "net/http"
    "runtime"
    "strings"
    "time"
)

// ErrorCode represents a unique identifier for an error type
type ErrorCode string

const (
    // System errors
    ErrCodeInternal     ErrorCode = "INTERNAL_ERROR"
    ErrCodeTimeout      ErrorCode = "TIMEOUT"
    ErrCodeUnavailable  ErrorCode = "SERVICE_UNAVAILABLE"
    
    // Client errors
    ErrCodeValidation   ErrorCode = "VALIDATION_ERROR"
    ErrCodeNotFound     ErrorCode = "NOT_FOUND"
    ErrCodeUnauthorized ErrorCode = "UNAUTHORIZED"
    ErrCodeForbidden    ErrorCode = "FORBIDDEN"
    ErrCodeConflict     ErrorCode = "CONFLICT"
    ErrCodeRateLimit    ErrorCode = "RATE_LIMITED"
    
    // Business errors
    ErrCodeBusinessRule ErrorCode = "BUSINESS_RULE_VIOLATION"
    ErrCodeInsufficientFunds ErrorCode = "INSUFFICIENT_FUNDS"
    ErrCodeExpired      ErrorCode = "EXPIRED"
)

// Error represents a structured application error
type Error struct {
    Code        ErrorCode              `json:"code"`
    Message     string                 `json:"message"`
    Details     map[string]interface{} `json:"details,omitempty"`
    Cause       error                  `json:"-"`
    StackTrace  []Frame                `json:"stack_trace,omitempty"`
    Timestamp   time.Time              `json:"timestamp"`
    RequestID   string                 `json:"request_id,omitempty"`
    UserID      string                 `json:"user_id,omitempty"`
    Operation   string                 `json:"operation,omitempty"`
    Resource    string                 `json:"resource,omitempty"`
    Retryable   bool                   `json:"retryable"`
    HTTPStatus  int                    `json:"-"`
}

type Frame struct {
    Function string `json:"function"`
    File     string `json:"file"`
    Line     int    `json:"line"`
}

// Error implements the error interface
func (e *Error) Error() string {
    if e.Cause != nil {
        return fmt.Sprintf("%s: %v", e.Message, e.Cause)
    }
    return e.Message
}

// Unwrap implements error unwrapping
func (e *Error) Unwrap() error {
    return e.Cause
}

// Is implements error comparison
func (e *Error) Is(target error) bool {
    if other, ok := target.(*Error); ok {
        return e.Code == other.Code
    }
    return false
}

// WithDetail adds contextual details to the error
func (e *Error) WithDetail(key string, value interface{}) *Error {
    if e.Details == nil {
        e.Details = make(map[string]interface{})
    }
    e.Details[key] = value
    return e
}

// WithCause sets the underlying cause
func (e *Error) WithCause(cause error) *Error {
    e.Cause = cause
    return e
}

// WithContext adds context information
func (e *Error) WithContext(ctx context.Context) *Error {
    if requestID := getRequestID(ctx); requestID != "" {
        e.RequestID = requestID
    }
    if userID := getUserID(ctx); userID != "" {
        e.UserID = userID
    }
    return e
}

// New creates a new structured error
func New(code ErrorCode, message string) *Error {
    return &Error{
        Code:       code,
        Message:    message,
        Timestamp:  time.Now(),
        StackTrace: captureStackTrace(),
        HTTPStatus: getHTTPStatus(code),
        Retryable:  isRetryable(code),
    }
}

// Newf creates a new structured error with formatted message
func Newf(code ErrorCode, format string, args ...interface{}) *Error {
    return New(code, fmt.Sprintf(format, args...))
}

// Wrap wraps an existing error with additional context
func Wrap(err error, code ErrorCode, message string) *Error {
    if err == nil {
        return nil
    }
    
    // If it's already our Error type, preserve the original code
    if appErr, ok := err.(*Error); ok {
        return &Error{
            Code:       appErr.Code,
            Message:    message,
            Details:    appErr.Details,
            Cause:      appErr.Cause,
            StackTrace: appErr.StackTrace,
            Timestamp:  appErr.Timestamp,
            RequestID:  appErr.RequestID,
            UserID:     appErr.UserID,
            Operation:  appErr.Operation,
            Resource:   appErr.Resource,
            Retryable:  appErr.Retryable,
            HTTPStatus: appErr.HTTPStatus,
        }
    }
    
    return &Error{
        Code:       code,
        Message:    message,
        Cause:      err,
        Timestamp:  time.Now(),
        StackTrace: captureStackTrace(),
        HTTPStatus: getHTTPStatus(code),
        Retryable:  isRetryable(code),
    }
}

func captureStackTrace() []Frame {
    var frames []Frame
    pc := make([]uintptr, 10)
    n := runtime.Callers(3, pc) // Skip captureStackTrace, New, and caller
    
    for i := 0; i < n; i++ {
        fn := runtime.FuncForPC(pc[i])
        if fn == nil {
            continue
        }
        
        file, line := fn.FileLine(pc[i])
        frames = append(frames, Frame{
            Function: fn.Name(),
            File:     file,
            Line:     line,
        })
    }
    
    return frames
}

func getHTTPStatus(code ErrorCode) int {
    switch code {
    case ErrCodeValidation:
        return http.StatusBadRequest
    case ErrCodeUnauthorized:
        return http.StatusUnauthorized
    case ErrCodeForbidden:
        return http.StatusForbidden
    case ErrCodeNotFound:
        return http.StatusNotFound
    case ErrCodeConflict:
        return http.StatusConflict
    case ErrCodeRateLimit:
        return http.StatusTooManyRequests
    case ErrCodeTimeout:
        return http.StatusRequestTimeout
    case ErrCodeUnavailable:
        return http.StatusServiceUnavailable
    default:
        return http.StatusInternalServerError
    }
}

func isRetryable(code ErrorCode) bool {
    switch code {
    case ErrCodeTimeout, ErrCodeUnavailable, ErrCodeRateLimit:
        return true
    default:
        return false
    }
}
```

### Domain-Specific Error Types

```go
// ValidationError represents field validation failures
type ValidationError struct {
    *Error
    Fields map[string][]string `json:"fields"`
}

func NewValidationError(message string) *ValidationError {
    return &ValidationError{
        Error:  New(ErrCodeValidation, message),
        Fields: make(map[string][]string),
    }
}

func (v *ValidationError) AddField(field, message string) *ValidationError {
    if v.Fields[field] == nil {
        v.Fields[field] = []string{}
    }
    v.Fields[field] = append(v.Fields[field], message)
    return v
}

func (v *ValidationError) HasErrors() bool {
    return len(v.Fields) > 0
}

// BusinessError represents domain business rule violations
type BusinessError struct {
    *Error
    Rule   string      `json:"rule"`
    Entity string      `json:"entity"`
    Value  interface{} `json:"value,omitempty"`
}

func NewBusinessError(rule, entity, message string) *BusinessError {
    return &BusinessError{
        Error:  New(ErrCodeBusinessRule, message),
        Rule:   rule,
        Entity: entity,
    }
}

// RetryableError represents errors that can be retried
type RetryableError struct {
    *Error
    RetryAfter time.Duration `json:"retry_after,omitempty"`
    MaxRetries int           `json:"max_retries,omitempty"`
    Attempt    int           `json:"attempt,omitempty"`
}

func NewRetryableError(code ErrorCode, message string, retryAfter time.Duration) *RetryableError {
    err := New(code, message)
    err.Retryable = true
    
    return &RetryableError{
        Error:      err,
        RetryAfter: retryAfter,
        MaxRetries: 3,
    }
}
```

### Error Groups and Multi-Errors

```go
// ErrorGroup collects multiple errors
type ErrorGroup struct {
    Errors []error `json:"errors"`
}

func (eg *ErrorGroup) Error() string {
    if len(eg.Errors) == 0 {
        return "no errors"
    }
    
    if len(eg.Errors) == 1 {
        return eg.Errors[0].Error()
    }
    
    var messages []string
    for _, err := range eg.Errors {
        messages = append(messages, err.Error())
    }
    
    return fmt.Sprintf("multiple errors: %s", strings.Join(messages, "; "))
}

func (eg *ErrorGroup) Add(err error) {
    if err != nil {
        eg.Errors = append(eg.Errors, err)
    }
}

func (eg *ErrorGroup) HasErrors() bool {
    return len(eg.Errors) > 0
}

func (eg *ErrorGroup) Unwrap() []error {
    return eg.Errors
}

// NewErrorGroup creates a new error group
func NewErrorGroup() *ErrorGroup {
    return &ErrorGroup{
        Errors: make([]error, 0),
    }
}
```

### Error Translation and Localization

```go
// ErrorTranslator handles error message translation
type ErrorTranslator interface {
    Translate(ctx context.Context, err error) *TranslatedError
}

type TranslatedError struct {
    Code         ErrorCode              `json:"code"`
    Message      string                 `json:"message"`
    UserMessage  string                 `json:"user_message"`
    Details      map[string]interface{} `json:"details,omitempty"`
    Language     string                 `json:"language"`
    Suggestions  []string               `json:"suggestions,omitempty"`
}

type DefaultTranslator struct {
    templates map[string]map[ErrorCode]string // language -> code -> template
}

func NewDefaultTranslator() *DefaultTranslator {
    return &DefaultTranslator{
        templates: map[string]map[ErrorCode]string{
            "en": {
                ErrCodeValidation:   "Please check your input and try again.",
                ErrCodeNotFound:     "The requested resource was not found.",
                ErrCodeUnauthorized: "Please log in to access this resource.",
                ErrCodeForbidden:    "You don't have permission to access this resource.",
                ErrCodeInternal:     "Something went wrong. Please try again later.",
                ErrCodeTimeout:      "The request timed out. Please try again.",
                ErrCodeRateLimit:    "Too many requests. Please wait before trying again.",
            },
            "es": {
                ErrCodeValidation:   "Por favor verifica tu entrada e inténtalo de nuevo.",
                ErrCodeNotFound:     "El recurso solicitado no fue encontrado.",
                ErrCodeUnauthorized: "Por favor inicia sesión para acceder a este recurso.",
                ErrCodeForbidden:    "No tienes permiso para acceder a este recurso.",
                ErrCodeInternal:     "Algo salió mal. Por favor inténtalo más tarde.",
                ErrCodeTimeout:      "La solicitud expiró. Por favor inténtalo de nuevo.",
                ErrCodeRateLimit:    "Demasiadas solicitudes. Por favor espera antes de intentar de nuevo.",
            },
        },
    }
}

func (dt *DefaultTranslator) Translate(ctx context.Context, err error) *TranslatedError {
    lang := getLanguage(ctx)
    
    var appErr *Error
    if !errors.As(err, &appErr) {
        appErr = Wrap(err, ErrCodeInternal, "Internal error")
    }
    
    template, exists := dt.templates[lang][appErr.Code]
    if !exists {
        template = dt.templates["en"][appErr.Code]
        if template == "" {
            template = "An error occurred."
        }
    }
    
    return &TranslatedError{
        Code:        appErr.Code,
        Message:     appErr.Message,
        UserMessage: template,
        Details:     appErr.Details,
        Language:    lang,
        Suggestions: dt.getSuggestions(appErr.Code),
    }
}

func (dt *DefaultTranslator) getSuggestions(code ErrorCode) []string {
    switch code {
    case ErrCodeValidation:
        return []string{
            "Check required fields are filled",
            "Verify data formats are correct",
            "Remove any special characters if not allowed",
        }
    case ErrCodeUnauthorized:
        return []string{
            "Log in with valid credentials",
            "Check if your session has expired",
            "Contact support if login issues persist",
        }
    case ErrCodeRateLimit:
        return []string{
            "Wait a few minutes before trying again",
            "Reduce the frequency of requests",
            "Contact support for rate limit increases",
        }
    default:
        return nil
    }
}
```

### Error Logging and Monitoring

```go
// ErrorLogger handles structured error logging
type ErrorLogger interface {
    LogError(ctx context.Context, err error, level LogLevel)
}

type LogLevel string

const (
    LogLevelError LogLevel = "error"
    LogLevelWarn  LogLevel = "warn"
    LogLevelInfo  LogLevel = "info"
    LogLevelDebug LogLevel = "debug"
)

type StructuredLogger struct {
    logger Logger // Your preferred logger (zerolog, logrus, etc.)
    tracer Tracer // Optional tracing integration
}

func (sl *StructuredLogger) LogError(ctx context.Context, err error, level LogLevel) {
    fields := map[string]interface{}{
        "timestamp": time.Now(),
        "level":     level,
    }
    
    // Extract structured error information
    if appErr, ok := err.(*Error); ok {
        fields["error_code"] = appErr.Code
        fields["error_message"] = appErr.Message
        fields["request_id"] = appErr.RequestID
        fields["user_id"] = appErr.UserID
        fields["operation"] = appErr.Operation
        fields["resource"] = appErr.Resource
        fields["retryable"] = appErr.Retryable
        fields["details"] = appErr.Details
        
        if appErr.StackTrace != nil && len(appErr.StackTrace) > 0 {
            fields["stack_trace"] = appErr.StackTrace
        }
        
        if appErr.Cause != nil {
            fields["cause"] = appErr.Cause.Error()
        }
    } else {
        fields["error_message"] = err.Error()
        fields["error_code"] = "UNKNOWN"
    }
    
    // Add context information
    if traceID := getTraceID(ctx); traceID != "" {
        fields["trace_id"] = traceID
    }
    
    if spanID := getSpanID(ctx); spanID != "" {
        fields["span_id"] = spanID
    }
    
    // Log with appropriate level
    switch level {
    case LogLevelError:
        sl.logger.Error(fields, "Application error occurred")
    case LogLevelWarn:
        sl.logger.Warn(fields, "Application warning")
    case LogLevelInfo:
        sl.logger.Info(fields, "Application info")
    case LogLevelDebug:
        sl.logger.Debug(fields, "Application debug")
    }
    
    // Send to error tracking service
    if level == LogLevelError {
        sl.reportError(ctx, err, fields)
    }
}

func (sl *StructuredLogger) reportError(ctx context.Context, err error, fields map[string]interface{}) {
    // Integration with error tracking services like Sentry, Rollbar, etc.
    // This would typically be done asynchronously
    go func() {
        errorEvent := ErrorEvent{
            Error:     err,
            Context:   fields,
            Timestamp: time.Now(),
        }
        
        // Send to error tracking service
        _ = sl.sendToErrorTracker(errorEvent)
    }()
}

type ErrorEvent struct {
    Error     error                  `json:"error"`
    Context   map[string]interface{} `json:"context"`
    Timestamp time.Time              `json:"timestamp"`
}
```

### HTTP Error Handling

```go
// HTTPErrorHandler converts application errors to HTTP responses
type HTTPErrorHandler struct {
    translator ErrorTranslator
    logger     ErrorLogger
}

func NewHTTPErrorHandler(translator ErrorTranslator, logger ErrorLogger) *HTTPErrorHandler {
    return &HTTPErrorHandler{
        translator: translator,
        logger:     logger,
    }
}

func (h *HTTPErrorHandler) HandleError(w http.ResponseWriter, r *http.Request, err error) {
    ctx := r.Context()
    
    // Log the error
    level := h.determineLogLevel(err)
    h.logger.LogError(ctx, err, level)
    
    // Translate for user consumption
    translatedErr := h.translator.Translate(ctx, err)
    
    // Determine HTTP status code
    var statusCode int
    if appErr, ok := err.(*Error); ok {
        statusCode = appErr.HTTPStatus
    } else {
        statusCode = http.StatusInternalServerError
    }
    
    // Create error response
    response := ErrorResponse{
        Error: *translatedErr,
        Metadata: ResponseMetadata{
            RequestID: getRequestID(ctx),
            Timestamp: time.Now(),
            Path:      r.URL.Path,
            Method:    r.Method,
        },
    }
    
    // Set headers
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(statusCode)
    
    // Encode response
    if err := json.NewEncoder(w).Encode(response); err != nil {
        h.logger.LogError(ctx, Wrap(err, ErrCodeInternal, "Failed to encode error response"), LogLevelError)
    }
}

func (h *HTTPErrorHandler) determineLogLevel(err error) LogLevel {
    if appErr, ok := err.(*Error); ok {
        switch appErr.Code {
        case ErrCodeValidation, ErrCodeNotFound, ErrCodeUnauthorized, ErrCodeForbidden:
            return LogLevelWarn
        case ErrCodeRateLimit:
            return LogLevelInfo
        default:
            return LogLevelError
        }
    }
    return LogLevelError
}

type ErrorResponse struct {
    Error    TranslatedError  `json:"error"`
    Metadata ResponseMetadata `json:"metadata"`
}

type ResponseMetadata struct {
    RequestID string    `json:"request_id"`
    Timestamp time.Time `json:"timestamp"`
    Path      string    `json:"path"`
    Method    string    `json:"method"`
}
```

## Best Practices

### 1. Error Creation and Propagation

**Keep errors close to their cause:**
```go
func (r *UserRepository) GetUser(ctx context.Context, id string) (*User, error) {
    user := &User{}
    err := r.db.QueryRowContext(ctx, "SELECT * FROM users WHERE id = $1", id).Scan(...)
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, New(ErrCodeNotFound, "User not found").
                WithDetail("user_id", id).
                WithContext(ctx)
        }
        return nil, Wrap(err, ErrCodeInternal, "Failed to query user").
            WithDetail("user_id", id).
            WithContext(ctx)
    }
    return user, nil
}
```

**Layer translation:**
```go
func (s *UserService) UpdateUser(ctx context.Context, id string, updates UserUpdates) error {
    user, err := s.repo.GetUser(ctx, id)
    if err != nil {
        return err // Propagate repository errors
    }
    
    if err := s.validateUpdates(updates); err != nil {
        return err // Return validation errors
    }
    
    if err := s.repo.UpdateUser(ctx, user); err != nil {
        return Wrap(err, ErrCodeInternal, "Failed to update user").
            WithDetail("user_id", id).
            WithContext(ctx)
    }
    
    return nil
}
```

### 2. Error Testing

```go
func TestUserService_GetUser(t *testing.T) {
    tests := []struct {
        name          string
        userID        string
        mockError     error
        expectedError *Error
    }{
        {
            name:   "user not found",
            userID: "nonexistent",
            mockError: New(ErrCodeNotFound, "User not found"),
            expectedError: &Error{Code: ErrCodeNotFound},
        },
        {
            name:   "database error",
            userID: "test-id",
            mockError: errors.New("database connection failed"),
            expectedError: &Error{Code: ErrCodeInternal},
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Setup mock
            mockRepo := &MockUserRepository{}
            mockRepo.On("GetUser", mock.Anything, tt.userID).Return(nil, tt.mockError)
            
            service := NewUserService(mockRepo)
            
            // Execute
            _, err := service.GetUser(context.Background(), tt.userID)
            
            // Assert
            require.Error(t, err)
            
            var appErr *Error
            require.True(t, errors.As(err, &appErr))
            assert.Equal(t, tt.expectedError.Code, appErr.Code)
        })
    }
}
```

### 3. Sentinel Errors

```go
// Define package-level sentinel errors
var (
    ErrUserNotFound     = New(ErrCodeNotFound, "User not found")
    ErrInvalidPassword  = New(ErrCodeValidation, "Invalid password")
    ErrAccountSuspended = New(ErrCodeForbidden, "Account suspended")
)

// Usage
func (s *AuthService) Authenticate(email, password string) error {
    user, err := s.userRepo.GetByEmail(email)
    if err != nil {
        if errors.Is(err, ErrUserNotFound) {
            return ErrUserNotFound
        }
        return err
    }
    
    if !s.verifyPassword(user.PasswordHash, password) {
        return ErrInvalidPassword
    }
    
    if user.Status == "suspended" {
        return ErrAccountSuspended.WithDetail("reason", user.SuspensionReason)
    }
    
    return nil
}
```

## Implementation Checklist

- [ ] Implement core error types and framework
- [ ] Set up structured logging integration
- [ ] Create HTTP error handling middleware
- [ ] Implement error translation system
- [ ] Set up error monitoring and alerting
- [ ] Create validation error helpers
- [ ] Document error codes and responses
- [ ] Write comprehensive tests
- [ ] Train team on error handling patterns

## Consequences

**Benefits:**
- Consistent error handling across the application
- Better debugging with structured error information
- Improved user experience with translated messages
- Enhanced monitoring and observability
- Reduced debugging time with stack traces and context

**Challenges:**
- Initial setup complexity
- Need for team training on new patterns
- Potential performance impact with stack trace capture
- Requires discipline to maintain consistency

**Trade-offs:**
- More verbose error creation vs. better error information
- Performance overhead vs. debugging capabilities
- Complexity vs. maintainability
