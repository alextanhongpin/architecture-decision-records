# Type-Safe Validation Framework

## Status

`accepted`

## Context

Validation is a critical aspect of any application, but most validation libraries in Go rely heavily on reflection, making them slow and lacking compile-time type safety. We need a validation framework that provides:

- Compile-time type safety without reflection
- Chainable validation rules
- Support for complex data types including slices and maps
- Extensible with custom validators
- Clear, customizable error messages
- High performance with minimal allocations

## Decision

We will implement a generic, type-safe validation framework using Go generics that provides compile-time safety, extensibility, and high performance without reflection.

## Implementation

### 1. Core Validation Framework

```go
package validator

import (
    "fmt"
    "reflect"
    "strconv"
    "strings"
    "unicode"
)

// ValidationError represents a validation error
type ValidationError struct {
    Field   string `json:"field"`
    Value   string `json:"value"`
    Tag     string `json:"tag"`
    Message string `json:"message"`
}

func (e ValidationError) Error() string {
    return fmt.Sprintf("validation failed for field '%s': %s", e.Field, e.Message)
}

// ValidationErrors represents a collection of validation errors
type ValidationErrors []ValidationError

func (e ValidationErrors) Error() string {
    if len(e) == 0 {
        return ""
    }
    
    var messages []string
    for _, err := range e {
        messages = append(messages, err.Error())
    }
    return strings.Join(messages, "; ")
}

// ValidatorFunc represents a generic validation function
type ValidatorFunc[T any] func(value T) error

// ValidatorRule represents a validation rule with metadata
type ValidatorRule[T any] struct {
    Name      string
    Validator ValidatorFunc[T]
    Message   string
}

// Validator provides chainable validation for any type
type Validator[T any] struct {
    rules    []ValidatorRule[T]
    field    string
    optional bool
    value    T
}

// New creates a new validator for the given value
func New[T any](value T) *Validator[T] {
    return &Validator[T]{
        value: value,
        rules: make([]ValidatorRule[T], 0),
    }
}

// Field sets the field name for error reporting
func (v *Validator[T]) Field(name string) *Validator[T] {
    v.field = name
    return v
}

// Optional marks the validation as optional (skip if zero value)
func (v *Validator[T]) Optional() *Validator[T] {
    v.optional = true
    return v
}

// Rule adds a custom validation rule
func (v *Validator[T]) Rule(name string, validator ValidatorFunc[T], message string) *Validator[T] {
    v.rules = append(v.rules, ValidatorRule[T]{
        Name:      name,
        Validator: validator,
        Message:   message,
    })
    return v
}

// Validate executes all validation rules
func (v *Validator[T]) Validate() error {
    // Check if optional and zero value
    if v.optional && isZeroValue(v.value) {
        return nil
    }
    
    var errors ValidationErrors
    
    for _, rule := range v.rules {
        if err := rule.Validator(v.value); err != nil {
            errors = append(errors, ValidationError{
                Field:   v.field,
                Value:   fmt.Sprintf("%v", v.value),
                Tag:     rule.Name,
                Message: rule.Message,
            })
        }
    }
    
    if len(errors) > 0 {
        return errors
    }
    
    return nil
}

// isZeroValue checks if a value is the zero value for its type
func isZeroValue[T any](value T) bool {
    var zero T
    return fmt.Sprintf("%v", value) == fmt.Sprintf("%v", zero)
}
```

### 2. String Validators

```go
// StringValidator provides validation for string types
type StringValidator struct {
    *Validator[string]
}

// String creates a new string validator
func String(value string) *StringValidator {
    return &StringValidator{
        Validator: New[string](value),
    }
}

// Required validates that string is not empty
func (v *StringValidator) Required() *StringValidator {
    v.Rule("required", func(s string) error {
        if strings.TrimSpace(s) == "" {
            return fmt.Errorf("field is required")
        }
        return nil
    }, "field is required")
    return v
}

// MinLength validates minimum string length
func (v *StringValidator) MinLength(min int) *StringValidator {
    v.Rule("min_length", func(s string) error {
        if len(s) < min {
            return fmt.Errorf("minimum length is %d", min)
        }
        return nil
    }, fmt.Sprintf("minimum length is %d", min))
    return v
}

// MaxLength validates maximum string length
func (v *StringValidator) MaxLength(max int) *StringValidator {
    v.Rule("max_length", func(s string) error {
        if len(s) > max {
            return fmt.Errorf("maximum length is %d", max)
        }
        return nil
    }, fmt.Sprintf("maximum length is %d", max))
    return v
}

// Length validates exact string length
func (v *StringValidator) Length(length int) *StringValidator {
    v.Rule("length", func(s string) error {
        if len(s) != length {
            return fmt.Errorf("length must be exactly %d", length)
        }
        return nil
    }, fmt.Sprintf("length must be exactly %d", length))
    return v
}

// Pattern validates string against regex pattern
func (v *StringValidator) Pattern(pattern string) *StringValidator {
    v.Rule("pattern", func(s string) error {
        matched, err := regexp.MatchString(pattern, s)
        if err != nil {
            return fmt.Errorf("invalid pattern: %s", pattern)
        }
        if !matched {
            return fmt.Errorf("does not match pattern")
        }
        return nil
    }, "does not match required pattern")
    return v
}

// Email validates email format
func (v *StringValidator) Email() *StringValidator {
    emailPattern := `^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`
    return v.Pattern(emailPattern).Rule("email", func(s string) error {
        // Additional email validation logic
        if strings.Count(s, "@") != 1 {
            return fmt.Errorf("invalid email format")
        }
        return nil
    }, "invalid email format")
}

// URL validates URL format
func (v *StringValidator) URL() *StringValidator {
    v.Rule("url", func(s string) error {
        if !strings.HasPrefix(s, "http://") && !strings.HasPrefix(s, "https://") {
            return fmt.Errorf("must be a valid URL")
        }
        return nil
    }, "must be a valid URL")
    return v
}

// OneOf validates that string is one of the allowed values
func (v *StringValidator) OneOf(values ...string) *StringValidator {
    v.Rule("one_of", func(s string) error {
        for _, value := range values {
            if s == value {
                return nil
            }
        }
        return fmt.Errorf("must be one of: %s", strings.Join(values, ", "))
    }, fmt.Sprintf("must be one of: %s", strings.Join(values, ", ")))
    return v
}

// Alpha validates that string contains only alphabetic characters
func (v *StringValidator) Alpha() *StringValidator {
    v.Rule("alpha", func(s string) error {
        for _, r := range s {
            if !unicode.IsLetter(r) {
                return fmt.Errorf("must contain only letters")
            }
        }
        return nil
    }, "must contain only letters")
    return v
}

// AlphaNumeric validates that string contains only alphanumeric characters
func (v *StringValidator) AlphaNumeric() *StringValidator {
    v.Rule("alphanumeric", func(s string) error {
        for _, r := range s {
            if !unicode.IsLetter(r) && !unicode.IsNumber(r) {
                return fmt.Errorf("must contain only letters and numbers")
            }
        }
        return nil
    }, "must contain only letters and numbers")
    return v
}

// NoSpaces validates that string contains no spaces
func (v *StringValidator) NoSpaces() *StringValidator {
    v.Rule("no_spaces", func(s string) error {
        if strings.Contains(s, " ") {
            return fmt.Errorf("must not contain spaces")
        }
        return nil
    }, "must not contain spaces")
    return v
}
```

### 3. Numeric Validators

```go
// NumericValidator provides validation for numeric types
type NumericValidator[T Numeric] struct {
    *Validator[T]
}

// Numeric constraint for numeric types
type Numeric interface {
    ~int | ~int8 | ~int16 | ~int32 | ~int64 |
    ~uint | ~uint8 | ~uint16 | ~uint32 | ~uint64 |
    ~float32 | ~float64
}

// Number creates a new numeric validator
func Number[T Numeric](value T) *NumericValidator[T] {
    return &NumericValidator[T]{
        Validator: New[T](value),
    }
}

// Min validates minimum value
func (v *NumericValidator[T]) Min(min T) *NumericValidator[T] {
    v.Rule("min", func(value T) error {
        if value < min {
            return fmt.Errorf("minimum value is %v", min)
        }
        return nil
    }, fmt.Sprintf("minimum value is %v", min))
    return v
}

// Max validates maximum value
func (v *NumericValidator[T]) Max(max T) *NumericValidator[T] {
    v.Rule("max", func(value T) error {
        if value > max {
            return fmt.Errorf("maximum value is %v", max)
        }
        return nil
    }, fmt.Sprintf("maximum value is %v", max))
    return v
}

// Range validates value is within range
func (v *NumericValidator[T]) Range(min, max T) *NumericValidator[T] {
    return v.Min(min).Max(max)
}

// Positive validates that number is positive
func (v *NumericValidator[T]) Positive() *NumericValidator[T] {
    v.Rule("positive", func(value T) error {
        if value <= 0 {
            return fmt.Errorf("must be positive")
        }
        return nil
    }, "must be positive")
    return v
}

// Negative validates that number is negative
func (v *NumericValidator[T]) Negative() *NumericValidator[T] {
    v.Rule("negative", func(value T) error {
        if value >= 0 {
            return fmt.Errorf("must be negative")
        }
        return nil
    }, "must be negative")
    return v
}

// NonZero validates that number is not zero
func (v *NumericValidator[T]) NonZero() *NumericValidator[T] {
    v.Rule("non_zero", func(value T) error {
        if value == 0 {
            return fmt.Errorf("must not be zero")
        }
        return nil
    }, "must not be zero")
    return v
}
```

### 4. Slice Validators

```go
// SliceValidator provides validation for slice types
type SliceValidator[T any] struct {
    *Validator[[]T]
    itemValidator func(T) error
}

// Slice creates a new slice validator
func Slice[T any](value []T) *SliceValidator[T] {
    return &SliceValidator[T]{
        Validator: New[[]T](value),
    }
}

// MinLen validates minimum slice length
func (v *SliceValidator[T]) MinLen(min int) *SliceValidator[T] {
    v.Rule("min_len", func(slice []T) error {
        if len(slice) < min {
            return fmt.Errorf("minimum length is %d", min)
        }
        return nil
    }, fmt.Sprintf("minimum length is %d", min))
    return v
}

// MaxLen validates maximum slice length
func (v *SliceValidator[T]) MaxLen(max int) *SliceValidator[T] {
    v.Rule("max_len", func(slice []T) error {
        if len(slice) > max {
            return fmt.Errorf("maximum length is %d", max)
        }
        return nil
    }, fmt.Sprintf("maximum length is %d", max))
    return v
}

// NotEmpty validates that slice is not empty
func (v *SliceValidator[T]) NotEmpty() *SliceValidator[T] {
    return v.MinLen(1)
}

// Each validates each item in the slice
func (v *SliceValidator[T]) Each(validator func(T) error) *SliceValidator[T] {
    v.itemValidator = validator
    v.Rule("each", func(slice []T) error {
        for i, item := range slice {
            if err := validator(item); err != nil {
                return fmt.Errorf("item at index %d: %w", i, err)
            }
        }
        return nil
    }, "one or more items failed validation")
    return v
}

// Unique validates that all items in slice are unique
func (v *SliceValidator[T]) Unique() *SliceValidator[T] {
    v.Rule("unique", func(slice []T) error {
        seen := make(map[string]bool)
        for i, item := range slice {
            key := fmt.Sprintf("%v", item)
            if seen[key] {
                return fmt.Errorf("duplicate item at index %d: %v", i, item)
            }
            seen[key] = true
        }
        return nil
    }, "all items must be unique")
    return v
}
```

### 5. Map Validators

```go
// MapValidator provides validation for map types
type MapValidator[K comparable, V any] struct {
    *Validator[map[K]V]
}

// Map creates a new map validator
func Map[K comparable, V any](value map[K]V) *MapValidator[K, V] {
    return &MapValidator[K, V]{
        Validator: New[map[K]V](value),
    }
}

// MinSize validates minimum map size
func (v *MapValidator[K, V]) MinSize(min int) *MapValidator[K, V] {
    v.Rule("min_size", func(m map[K]V) error {
        if len(m) < min {
            return fmt.Errorf("minimum size is %d", min)
        }
        return nil
    }, fmt.Sprintf("minimum size is %d", min))
    return v
}

// MaxSize validates maximum map size
func (v *MapValidator[K, V]) MaxSize(max int) *MapValidator[K, V] {
    v.Rule("max_size", func(m map[K]V) error {
        if len(m) > max {
            return fmt.Errorf("maximum size is %d", max)
        }
        return nil
    }, fmt.Sprintf("maximum size is %d", max))
    return v
}

// HasKey validates that map contains a specific key
func (v *MapValidator[K, V]) HasKey(key K) *MapValidator[K, V] {
    v.Rule("has_key", func(m map[K]V) error {
        if _, exists := m[key]; !exists {
            return fmt.Errorf("must contain key: %v", key)
        }
        return nil
    }, fmt.Sprintf("must contain key: %v", key))
    return v
}

// EachKey validates each key in the map
func (v *MapValidator[K, V]) EachKey(validator func(K) error) *MapValidator[K, V] {
    v.Rule("each_key", func(m map[K]V) error {
        for key := range m {
            if err := validator(key); err != nil {
                return fmt.Errorf("key %v: %w", key, err)
            }
        }
        return nil
    }, "one or more keys failed validation")
    return v
}

// EachValue validates each value in the map
func (v *MapValidator[K, V]) EachValue(validator func(V) error) *MapValidator[K, V] {
    v.Rule("each_value", func(m map[K]V) error {
        for key, value := range m {
            if err := validator(value); err != nil {
                return fmt.Errorf("value for key %v: %w", key, err)
            }
        }
        return nil
    }, "one or more values failed validation")
    return v
}
```

### 6. Struct Validators

```go
// StructValidator provides validation for struct types
type StructValidator[T any] struct {
    *Validator[T]
    fieldValidators map[string]func(T) error
}

// Struct creates a new struct validator
func Struct[T any](value T) *StructValidator[T] {
    return &StructValidator[T]{
        Validator:       New[T](value),
        fieldValidators: make(map[string]func(T) error),
    }
}

// Field adds validation for a specific field
func (v *StructValidator[T]) Field(name string, validator func(T) error) *StructValidator[T] {
    v.fieldValidators[name] = validator
    return v
}

// ValidateStruct validates the struct using field validators
func (v *StructValidator[T]) ValidateStruct() error {
    var errors ValidationErrors
    
    // Run field validators
    for fieldName, validator := range v.fieldValidators {
        if err := validator(v.value); err != nil {
            if ve, ok := err.(ValidationErrors); ok {
                errors = append(errors, ve...)
            } else {
                errors = append(errors, ValidationError{
                    Field:   fieldName,
                    Message: err.Error(),
                })
            }
        }
    }
    
    // Run general validators
    if err := v.Validate(); err != nil {
        if ve, ok := err.(ValidationErrors); ok {
            errors = append(errors, ve...)
        }
    }
    
    if len(errors) > 0 {
        return errors
    }
    
    return nil
}
```

### 7. Conditional Validators

```go
// ConditionalValidator provides conditional validation
type ConditionalValidator[T any] struct {
    *Validator[T]
}

// When creates a conditional validator
func When[T any](condition bool, value T) *ConditionalValidator[T] {
    cv := &ConditionalValidator[T]{
        Validator: New[T](value),
    }
    
    if !condition {
        // If condition is false, create a no-op validator
        cv.Rule("conditional", func(T) error { return nil }, "")
    }
    
    return cv
}

// Then adds validation rules that apply when condition is true
func (v *ConditionalValidator[T]) Then(validators ...ValidatorFunc[T]) *ConditionalValidator[T] {
    for i, validator := range validators {
        v.Rule(fmt.Sprintf("then_%d", i), validator, "conditional validation failed")
    }
    return v
}
```

### 8. Usage Examples

```go
package main

import (
    "fmt"
    "log"
)

// User represents a user struct
type User struct {
    ID       string            `json:"id"`
    Username string            `json:"username"`
    Email    string            `json:"email"`
    Age      int               `json:"age"`
    Tags     []string          `json:"tags"`
    Metadata map[string]string `json:"metadata"`
}

func validateUser(user User) error {
    // Validate individual fields
    if err := String(user.Username).
        Field("username").
        Required().
        MinLength(3).
        MaxLength(20).
        AlphaNumeric().
        Validate(); err != nil {
        return err
    }
    
    if err := String(user.Email).
        Field("email").
        Required().
        Email().
        Validate(); err != nil {
        return err
    }
    
    if err := Number(user.Age).
        Field("age").
        Min(13).
        Max(120).
        Validate(); err != nil {
        return err
    }
    
    if err := Slice(user.Tags).
        Field("tags").
        MaxLen(10).
        Each(func(tag string) error {
            return String(tag).
                MinLength(1).
                MaxLength(20).
                Validate()
        }).
        Unique().
        Validate(); err != nil {
        return err
    }
    
    if err := Map(user.Metadata).
        Field("metadata").
        MaxSize(20).
        EachKey(func(key string) error {
            return String(key).
                MinLength(1).
                MaxLength(50).
                Validate()
        }).
        EachValue(func(value string) error {
            return String(value).
                MaxLength(200).
                Validate()
        }).
        Validate(); err != nil {
        return err
    }
    
    return nil
}

// Example with struct validator
func validateUserStruct(user User) error {
    return Struct(user).
        Field("username", func(u User) error {
            return String(u.Username).
                Required().
                MinLength(3).
                MaxLength(20).
                AlphaNumeric().
                Validate()
        }).
        Field("email", func(u User) error {
            return String(u.Email).
                Required().
                Email().
                Validate()
        }).
        Field("age", func(u User) error {
            return Number(u.Age).
                Min(13).
                Max(120).
                Validate()
        }).
        ValidateStruct()
}

// Example with conditional validation
func validateUserWithConditions(user User, isAdmin bool) error {
    // Basic validation
    if err := validateUser(user); err != nil {
        return err
    }
    
    // Admin-specific validation
    return When(isAdmin, user.Email).
        Then(func(email string) error {
            if !strings.HasSuffix(email, "@company.com") {
                return fmt.Errorf("admin email must be from company domain")
            }
            return nil
        }).
        Validate()
}

func main() {
    user := User{
        ID:       "123",
        Username: "john_doe",
        Email:    "john@example.com",
        Age:      25,
        Tags:     []string{"developer", "golang"},
        Metadata: map[string]string{
            "department": "engineering",
            "location":   "remote",
        },
    }
    
    // Validate user
    if err := validateUser(user); err != nil {
        log.Printf("Validation failed: %v", err)
        return
    }
    
    fmt.Println("User validation passed!")
    
    // Validate with struct validator
    if err := validateUserStruct(user); err != nil {
        log.Printf("Struct validation failed: %v", err)
        return
    }
    
    fmt.Println("Struct validation passed!")
    
    // Conditional validation
    if err := validateUserWithConditions(user, false); err != nil {
        log.Printf("Conditional validation failed: %v", err)
        return
    }
    
    fmt.Println("All validations passed!")
}
```

### 9. Advanced Features

```go
// ValidationBuilder provides a fluent interface for complex validation
type ValidationBuilder struct {
    validators []func() error
}

// NewValidationBuilder creates a new validation builder
func NewValidationBuilder() *ValidationBuilder {
    return &ValidationBuilder{
        validators: make([]func() error, 0),
    }
}

// Add adds a validation function
func (vb *ValidationBuilder) Add(validator func() error) *ValidationBuilder {
    vb.validators = append(vb.validators, validator)
    return vb
}

// Validate executes all validators
func (vb *ValidationBuilder) Validate() error {
    var errors ValidationErrors
    
    for _, validator := range vb.validators {
        if err := validator(); err != nil {
            if ve, ok := err.(ValidationErrors); ok {
                errors = append(errors, ve...)
            } else {
                errors = append(errors, ValidationError{
                    Message: err.Error(),
                })
            }
        }
    }
    
    if len(errors) > 0 {
        return errors
    }
    
    return nil
}

// Custom validator with context
type ContextValidator[T any] struct {
    *Validator[T]
    context map[string]interface{}
}

// WithContext creates a validator with context
func WithContext[T any](value T, ctx map[string]interface{}) *ContextValidator[T] {
    return &ContextValidator[T]{
        Validator: New[T](value),
        context:   ctx,
    }
}

// RuleWithContext adds a validation rule that can access context
func (v *ContextValidator[T]) RuleWithContext(name string, validator func(T, map[string]interface{}) error, message string) *ContextValidator[T] {
    v.Rule(name, func(value T) error {
        return validator(value, v.context)
    }, message)
    return v
}

// Example usage with context
func validateWithContext() error {
    user := User{Username: "admin"}
    context := map[string]interface{}{
        "existing_usernames": []string{"admin", "root", "system"},
    }
    
    return WithContext(user.Username, context).
        RuleWithContext("unique_username", func(username string, ctx map[string]interface{}) error {
            existing := ctx["existing_usernames"].([]string)
            for _, existing := range existing {
                if username == existing {
                    return fmt.Errorf("username already exists")
                }
            }
            return nil
        }, "username must be unique").
        Validate()
}
```

## Benefits

1. **Compile-Time Safety**: No reflection, full type safety with generics
2. **Performance**: Minimal allocations, no runtime type checking
3. **Extensibility**: Easy to add custom validators and rules
4. **Chainable API**: Fluent interface for readable validation code
5. **Comprehensive**: Supports all major data types and complex validations
6. **Clear Errors**: Detailed error messages with field context

## Consequences

### Positive

- **Type Safety**: Compile-time error detection for validation rules
- **Performance**: High performance without reflection overhead
- **Maintainability**: Clear, readable validation code
- **Extensibility**: Easy to add custom validation logic
- **Consistency**: Uniform validation patterns across the application

### Negative

- **Go Version**: Requires Go 1.18+ for generics support
- **Learning Curve**: Team needs to learn the validation framework
- **Compilation Time**: Generics may increase compilation time
- **Code Generation**: May require code generation for complex scenarios

## Implementation Checklist

- [ ] Implement core validation framework with generics
- [ ] Create validators for common types (string, numeric, slice, map)
- [ ] Add struct validation support
- [ ] Implement conditional validation
- [ ] Create validation builder for complex scenarios
- [ ] Add context-aware validation
- [ ] Implement custom error message support
- [ ] Add comprehensive test coverage
- [ ] Create documentation and examples
- [ ] Set up benchmarking for performance validation
- [ ] Integrate with HTTP request validation middleware
- [ ] Create code generation tools if needed

## Best Practices

1. **Type-Specific Validators**: Use appropriate validators for each type
2. **Early Validation**: Validate at request boundaries
3. **Custom Validators**: Create reusable custom validators for business rules
4. **Error Handling**: Provide clear, actionable error messages
5. **Performance**: Benchmark validation performance for critical paths
6. **Testing**: Thoroughly test all validation rules and edge cases
7. **Documentation**: Document custom validators and their usage
8. **Consistency**: Use consistent validation patterns across the application

## References

- [Go Generics](https://go.dev/doc/tutorial/generics)
- [Validation Libraries Comparison](https://github.com/go-playground/validator)
- [Type Safety in Go](https://golang.org/doc/effective_go.html#type_switch)
- [Performance Considerations](https://dave.cheney.net/2014/06/07/five-things-that-make-go-fast)
