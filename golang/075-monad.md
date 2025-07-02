# Functional Monadic Patterns in Go

## Status

**Accepted** - Use functional monadic patterns for error handling, data transformation pipelines, and optional value management in Go applications.

## Context

Functional programming concepts like monads provide powerful abstractions for handling computations with context (errors, nullability, asynchronous operations). While Go is not a functional language, we can leverage monadic patterns to:

- **Chain Operations**: Create fluent, composable operation pipelines
- **Error Handling**: Manage errors consistently across operation chains
- **Null Safety**: Handle optional values without explicit null checks
- **Data Transformation**: Build reusable transformation pipelines
- **Computation Context**: Maintain context throughout operation sequences

Traditional Go error handling can become verbose and repetitive, especially in data processing pipelines. Monadic patterns provide a way to reduce boilerplate while maintaining clarity and type safety.

## Decision

We will implement and use monadic patterns for:

1. **Error Handling Chains**: Operations that may fail at any step
2. **Data Transformation Pipelines**: Multi-step data processing
3. **Optional Value Management**: Handling nullable or missing data
4. **Async Operation Composition**: Chaining asynchronous operations
5. **Validation Pipelines**: Multi-step validation processes

### Implementation Guidelines

#### 1. Core Monad Interface

```go
package monad

import (
	"context"
	"fmt"
)

// Monad represents a monadic computation with error handling
type Monad[T any] struct {
	value T
	err   error
}

// New creates a new monad with a value
func New[T any](value T) *Monad[T] {
	return &Monad[T]{value: value}
}

// NewWithError creates a new monad with an error
func NewWithError[T any](err error) *Monad[T] {
	var zero T
	return &Monad[T]{value: zero, err: err}
}

// Map applies a function to the wrapped value if no error exists
func (m *Monad[T]) Map(fn func(T) (T, error)) *Monad[T] {
	if m.err != nil {
		return m
	}
	
	newValue, err := fn(m.value)
	if err != nil {
		return NewWithError[T](err)
	}
	
	return New(newValue)
}

// FlatMap applies a function that returns a monad
func (m *Monad[T]) FlatMap(fn func(T) *Monad[T]) *Monad[T] {
	if m.err != nil {
		return m
	}
	
	return fn(m.value)
}

// Filter applies a predicate and returns an error if it fails
func (m *Monad[T]) Filter(predicate func(T) bool, errMsg string) *Monad[T] {
	if m.err != nil {
		return m
	}
	
	if !predicate(m.value) {
		return NewWithError[T](fmt.Errorf(errMsg))
	}
	
	return m
}

// Unwrap returns the value and error
func (m *Monad[T]) Unwrap() (T, error) {
	return m.value, m.err
}

// IsError returns true if the monad contains an error
func (m *Monad[T]) IsError() bool {
	return m.err != nil
}

// GetValue returns the value if no error exists
func (m *Monad[T]) GetValue() T {
	return m.value
}

// GetError returns the error
func (m *Monad[T]) GetError() error {
	return m.err
}

// OrElse returns the value or a default if error exists
func (m *Monad[T]) OrElse(defaultValue T) T {
	if m.err != nil {
		return defaultValue
	}
	return m.value
}
```

#### 2. Result Monad for Error Handling

```go
package result

import "fmt"

// Result represents a computation that may succeed or fail
type Result[T any] struct {
	value T
	err   error
}

// Ok creates a successful result
func Ok[T any](value T) *Result[T] {
	return &Result[T]{value: value}
}

// Err creates a failed result
func Err[T any](err error) *Result[T] {
	var zero T
	return &Result[T]{value: zero, err: err}
}

// Map transforms the value if the result is successful
func (r *Result[T]) Map(fn func(T) (T, error)) *Result[T] {
	if r.err != nil {
		return r
	}
	
	newValue, err := fn(r.value)
	if err != nil {
		return Err[T](err)
	}
	
	return Ok(newValue)
}

// MapTo transforms to a different type
func MapTo[T, U any](r *Result[T], fn func(T) (U, error)) *Result[U] {
	if r.err != nil {
		return Err[U](r.err)
	}
	
	newValue, err := fn(r.value)
	if err != nil {
		return Err[U](err)
	}
	
	return Ok(newValue)
}

// AndThen chains another operation
func (r *Result[T]) AndThen(fn func(T) *Result[T]) *Result[T] {
	if r.err != nil {
		return r
	}
	
	return fn(r.value)
}

// Bind allows chaining with different types
func Bind[T, U any](r *Result[T], fn func(T) *Result[U]) *Result[U] {
	if r.err != nil {
		return Err[U](r.err)
	}
	
	return fn(r.value)
}

// Validate applies validation rules
func (r *Result[T]) Validate(rules ...func(T) error) *Result[T] {
	if r.err != nil {
		return r
	}
	
	for _, rule := range rules {
		if err := rule(r.value); err != nil {
			return Err[T](err)
		}
	}
	
	return r
}

// Match provides pattern matching for results
func (r *Result[T]) Match(onSuccess func(T), onError func(error)) {
	if r.err != nil {
		onError(r.err)
	} else {
		onSuccess(r.value)
	}
}

// IsOk returns true if result is successful
func (r *Result[T]) IsOk() bool {
	return r.err == nil
}

// IsErr returns true if result has an error
func (r *Result[T]) IsErr() bool {
	return r.err != nil
}

// Unwrap returns value and error
func (r *Result[T]) Unwrap() (T, error) {
	return r.value, r.err
}

// UnwrapOr returns value or default
func (r *Result[T]) UnwrapOr(defaultValue T) T {
	if r.err != nil {
		return defaultValue
	}
	return r.value
}

// Example: User validation pipeline
type User struct {
	ID    string
	Name  string
	Email string
	Age   int
}

func CreateUser(id, name, email string, age int) *Result[*User] {
	user := &User{ID: id, Name: name, Email: email, Age: age}
	
	return Ok(user).
		Validate(validateID, validateName, validateEmail, validateAge)
}

func validateID(user *User) error {
	if user.ID == "" {
		return fmt.Errorf("user ID cannot be empty")
	}
	return nil
}

func validateName(user *User) error {
	if len(user.Name) < 2 {
		return fmt.Errorf("user name must be at least 2 characters")
	}
	return nil
}

func validateEmail(user *User) error {
	if !isValidEmail(user.Email) {
		return fmt.Errorf("invalid email format")
	}
	return nil
}

func validateAge(user *User) error {
	if user.Age < 0 || user.Age > 120 {
		return fmt.Errorf("invalid age: must be between 0 and 120")
	}
	return nil
}

func isValidEmail(email string) bool {
	// Simplified email validation
	return len(email) > 0 && contains(email, "@")
}

func contains(s, substr string) bool {
	// Simplified implementation
	return len(s) > len(substr)
}
```

#### 3. Option Monad for Nullable Values

```go
package option

// Option represents a value that may or may not exist
type Option[T any] struct {
	value   T
	hasValue bool
}

// Some creates an option with a value
func Some[T any](value T) *Option[T] {
	return &Option[T]{value: value, hasValue: true}
}

// None creates an empty option
func None[T any]() *Option[T] {
	var zero T
	return &Option[T]{value: zero, hasValue: false}
}

// FromPointer creates an option from a pointer
func FromPointer[T any](ptr *T) *Option[T] {
	if ptr == nil {
		return None[T]()
	}
	return Some(*ptr)
}

// Map applies a function if value exists
func (o *Option[T]) Map(fn func(T) T) *Option[T] {
	if !o.hasValue {
		return o
	}
	
	return Some(fn(o.value))
}

// MapTo transforms to a different type
func MapTo[T, U any](o *Option[T], fn func(T) U) *Option[U] {
	if !o.hasValue {
		return None[U]()
	}
	
	return Some(fn(o.value))
}

// FlatMap chains options
func (o *Option[T]) FlatMap(fn func(T) *Option[T]) *Option[T] {
	if !o.hasValue {
		return o
	}
	
	return fn(o.value)
}

// Filter applies a predicate
func (o *Option[T]) Filter(predicate func(T) bool) *Option[T] {
	if !o.hasValue || !predicate(o.value) {
		return None[T]()
	}
	
	return o
}

// OrElse returns this option or another if empty
func (o *Option[T]) OrElse(other *Option[T]) *Option[T] {
	if o.hasValue {
		return o
	}
	return other
}

// GetOrElse returns value or default
func (o *Option[T]) GetOrElse(defaultValue T) T {
	if o.hasValue {
		return o.value
	}
	return defaultValue
}

// IsSome returns true if option has a value
func (o *Option[T]) IsSome() bool {
	return o.hasValue
}

// IsNone returns true if option is empty
func (o *Option[T]) IsNone() bool {
	return !o.hasValue
}

// Get returns the value (panics if none)
func (o *Option[T]) Get() T {
	if !o.hasValue {
		panic("called Get() on None option")
	}
	return o.value
}

// ToPointer returns a pointer to the value or nil
func (o *Option[T]) ToPointer() *T {
	if !o.hasValue {
		return nil
	}
	return &o.value
}

// Example: Safe configuration retrieval
type Config struct {
	DBHost     string
	DBPort     int
	CacheURL   string
	Debug      bool
}

func GetConfig() *Config {
	return &Config{
		DBHost:   getEnvOption("DB_HOST").GetOrElse("localhost"),
		DBPort:   getEnvIntOption("DB_PORT").GetOrElse(5432),
		CacheURL: getEnvOption("CACHE_URL").GetOrElse("redis://localhost:6379"),
		Debug:    getEnvBoolOption("DEBUG").GetOrElse(false),
	}
}

func getEnvOption(key string) *Option[string] {
	// Simplified env lookup
	if value := lookupEnv(key); value != "" {
		return Some(value)
	}
	return None[string]()
}

func getEnvIntOption(key string) *Option[int] {
	return getEnvOption(key).
		Filter(func(s string) bool { return s != "" }).
		FlatMap(func(s string) *Option[int] {
			if val, err := parseInt(s); err == nil {
				return Some(val)
			}
			return None[int]()
		})
}

func getEnvBoolOption(key string) *Option[bool] {
	return getEnvOption(key).
		FlatMap(func(s string) *Option[bool] {
			if val, err := parseBool(s); err == nil {
				return Some(val)
			}
			return None[bool]()
		})
}

// Simplified implementations
func lookupEnv(key string) string { return "" }
func parseInt(s string) (int, error) { return 0, nil }
func parseBool(s string) (bool, error) { return false, nil }
```

#### 4. Data Processing Pipeline

```go
package pipeline

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	
	"yourapp/result"
)

// DataPipeline represents a processing pipeline
type DataPipeline[T any] struct {
	steps []func(T) *result.Result[T]
}

// NewPipeline creates a new data pipeline
func NewPipeline[T any]() *DataPipeline[T] {
	return &DataPipeline[T]{
		steps: make([]func(T) *result.Result[T], 0),
	}
}

// AddStep adds a processing step
func (p *DataPipeline[T]) AddStep(step func(T) *result.Result[T]) *DataPipeline[T] {
	p.steps = append(p.steps, step)
	return p
}

// Execute runs the pipeline
func (p *DataPipeline[T]) Execute(input T) *result.Result[T] {
	current := result.Ok(input)
	
	for _, step := range p.steps {
		current = current.AndThen(step)
		if current.IsErr() {
			break
		}
	}
	
	return current
}

// Example: User data processing pipeline
type UserData struct {
	Name     string            `json:"name"`
	Email    string            `json:"email"`
	Age      int               `json:"age"`
	Metadata map[string]string `json:"metadata"`
}

func ProcessUserData(rawData string) *result.Result[*UserData] {
	pipeline := NewPipeline[string]().
		AddStep(parseJSON).
		AddStep(validateUserData).
		AddStep(normalizeUserData).
		AddStep(enrichUserData)
	
	return result.Bind(
		pipeline.Execute(rawData),
		func(processedJSON string) *result.Result[*UserData] {
			var user UserData
			if err := json.Unmarshal([]byte(processedJSON), &user); err != nil {
				return result.Err[*UserData](err)
			}
			return result.Ok(&user)
		},
	)
}

func parseJSON(data string) *result.Result[string] {
	// Validate JSON format
	var temp interface{}
	if err := json.Unmarshal([]byte(data), &temp); err != nil {
		return result.Err[string](fmt.Errorf("invalid JSON: %w", err))
	}
	return result.Ok(data)
}

func validateUserData(jsonData string) *result.Result[string] {
	var user UserData
	if err := json.Unmarshal([]byte(jsonData), &user); err != nil {
		return result.Err[string](err)
	}
	
	if user.Name == "" {
		return result.Err[string](fmt.Errorf("name is required"))
	}
	
	if user.Email == "" {
		return result.Err[string](fmt.Errorf("email is required"))
	}
	
	if user.Age < 0 {
		return result.Err[string](fmt.Errorf("age must be positive"))
	}
	
	return result.Ok(jsonData)
}

func normalizeUserData(jsonData string) *result.Result[string] {
	var user UserData
	if err := json.Unmarshal([]byte(jsonData), &user); err != nil {
		return result.Err[string](err)
	}
	
	// Normalize data
	user.Name = strings.TrimSpace(user.Name)
	user.Email = strings.ToLower(strings.TrimSpace(user.Email))
	
	normalizedData, err := json.Marshal(user)
	if err != nil {
		return result.Err[string](err)
	}
	
	return result.Ok(string(normalizedData))
}

func enrichUserData(jsonData string) *result.Result[string] {
	var user UserData
	if err := json.Unmarshal([]byte(jsonData), &user); err != nil {
		return result.Err[string](err)
	}
	
	// Add metadata
	if user.Metadata == nil {
		user.Metadata = make(map[string]string)
	}
	user.Metadata["processed_at"] = "2023-01-01T00:00:00Z"
	user.Metadata["version"] = "1.0"
	
	enrichedData, err := json.Marshal(user)
	if err != nil {
		return result.Err[string](err)
	}
	
	return result.Ok(string(enrichedData))
}
```

#### 5. Async Monad for Asynchronous Operations

```go
package async

import (
	"context"
	"time"
	
	"yourapp/result"
)

// Async represents an asynchronous computation
type Async[T any] struct {
	future chan *result.Result[T]
}

// NewAsync creates a new async computation
func NewAsync[T any](fn func(context.Context) (T, error)) *Async[T] {
	future := make(chan *result.Result[T], 1)
	
	go func() {
		defer close(future)
		
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		
		value, err := fn(ctx)
		if err != nil {
			future <- result.Err[T](err)
		} else {
			future <- result.Ok(value)
		}
	}()
	
	return &Async[T]{future: future}
}

// Map transforms the async value
func (a *Async[T]) Map(fn func(T) (T, error)) *Async[T] {
	return NewAsync(func(ctx context.Context) (T, error) {
		result := <-a.future
		if result.IsErr() {
			var zero T
			return zero, result.GetError()
		}
		
		return fn(result.GetValue())
	})
}

// FlatMap chains async operations
func (a *Async[T]) FlatMap(fn func(T) *Async[T]) *Async[T] {
	return NewAsync(func(ctx context.Context) (T, error) {
		result := <-a.future
		if result.IsErr() {
			var zero T
			return zero, result.GetError()
		}
		
		nextAsync := fn(result.GetValue())
		nextResult := <-nextAsync.future
		return nextResult.Unwrap()
	})
}

// Await blocks until completion
func (a *Async[T]) Await() *result.Result[T] {
	return <-a.future
}

// AwaitWithTimeout waits with timeout
func (a *Async[T]) AwaitWithTimeout(timeout time.Duration) *result.Result[T] {
	select {
	case result := <-a.future:
		return result
	case <-time.After(timeout):
		var zero T
		return result.Err[T](fmt.Errorf("timeout after %v", timeout))
	}
}
```

#### 6. Testing Monadic Code

```go
package monad_test

import (
	"fmt"
	"testing"
	
	"yourapp/result"
	"yourapp/option"
)

func TestResultMonadSuccess(t *testing.T) {
	value := 10
	
	result := result.Ok(value).
		Map(func(v int) (int, error) { return v * 2, nil }).
		Map(func(v int) (int, error) { return v + 5, nil })
	
	if result.IsErr() {
		t.Errorf("Expected success, got error: %v", result.GetError())
	}
	
	if result.GetValue() != 25 {
		t.Errorf("Expected 25, got %d", result.GetValue())
	}
}

func TestResultMonadError(t *testing.T) {
	value := 10
	
	result := result.Ok(value).
		Map(func(v int) (int, error) { return v * 2, nil }).
		Map(func(v int) (int, error) { return 0, fmt.Errorf("error") }).
		Map(func(v int) (int, error) { return v + 5, nil })
	
	if !result.IsErr() {
		t.Error("Expected error, got success")
	}
}

func TestOptionMonadSome(t *testing.T) {
	opt := option.Some(10).
		Map(func(v int) int { return v * 2 }).
		Filter(func(v int) bool { return v > 15 })
	
	if opt.IsNone() {
		t.Error("Expected Some, got None")
	}
	
	if opt.Get() != 20 {
		t.Errorf("Expected 20, got %d", opt.Get())
	}
}

func TestOptionMonadNone(t *testing.T) {
	opt := option.Some(5).
		Map(func(v int) int { return v * 2 }).
		Filter(func(v int) bool { return v > 15 })
	
	if opt.IsSome() {
		t.Error("Expected None, got Some")
	}
}

func BenchmarkMonadChain(b *testing.B) {
	for i := 0; i < b.N; i++ {
		result.Ok(i).
			Map(func(v int) (int, error) { return v * 2, nil }).
			Map(func(v int) (int, error) { return v + 1, nil }).
			Map(func(v int) (int, error) { return v / 2, nil })
	}
}
```

## Consequences

### Positive

- **Composable Operations**: Chain operations fluently without nested error checks
- **Error Propagation**: Automatic error handling through operation chains
- **Type Safety**: Compile-time guarantees about value and error states
- **Readability**: More expressive code for complex data transformations
- **Reusability**: Modular operations that can be composed differently
- **Null Safety**: Explicit handling of optional values

### Negative

- **Learning Curve**: Requires understanding of functional programming concepts
- **Performance Overhead**: Additional allocations and indirection
- **Debugging Complexity**: Stack traces may be less clear in chains
- **Go Idiom Deviation**: May feel unnatural to Go developers

### Trade-offs

- **Expressiveness vs. Simplicity**: Gains expressiveness but adds abstraction
- **Safety vs. Performance**: Provides safety at the cost of some performance
- **Consistency vs. Flexibility**: Enforces patterns but may limit some flexibility

## Best Practices

1. **Use for Complex Pipelines**: Apply monads to multi-step operations with error handling
2. **Keep Chains Reasonable**: Avoid overly long operation chains
3. **Document Patterns**: Clearly document monadic patterns for team understanding
4. **Test Error Paths**: Ensure error propagation works correctly
5. **Mix with Idiomatic Go**: Use alongside traditional Go patterns where appropriate
6. **Performance Considerations**: Profile monadic code in performance-critical paths

## References

- [Functional Programming in Go](https://github.com/go-functional/core)
- [Monad Pattern](https://en.wikipedia.org/wiki/Monad_(functional_programming))
- [Railway Oriented Programming](https://fsharpforfunandprofit.com/rop/)
- [Option Type](https://en.wikipedia.org/wiki/Option_type)
