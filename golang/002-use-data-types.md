# ADR 002: Use Data Types and Package Organization

## Status

**Accepted**

## Context

Go applications often require custom data types and utility functions that extend beyond the standard library. Without clear organization principles, teams commonly create packages named `utils`, `common`, `helper`, or `constant`, which become dumping grounds for unrelated functionality. This leads to:

- Poor code organization and discoverability
- Circular dependencies
- Unclear package responsibilities
- Reduced code maintainability
- Violation of Go's package naming conventions

Go's philosophy emphasizes clear, descriptive package names that indicate their purpose. Package names should be short, clear, and evocative of their functionality.

## Decision

We will adopt a structured approach to organizing data types and utility packages following Go best practices:

### 1. Package Organization Structure

```
internal/
  types/
    set/          # Custom data structures
    queue/
    stack/
    stringcase/   # String manipulation utilities  
    mathext/      # Extended math functions
    timeutil/     # Time and date utilities
    sliceutil/    # Slice manipulation helpers
  adapters/       # External service adapters
  domain/         # Business logic types
```

### 2. Package Naming Conventions

#### Preferred Patterns:
- **Descriptive names**: `stringcase`, `timeutil`, `httptest`
- **Domain-specific**: `payment`, `user`, `order`
- **Functional grouping**: `cache`, `queue`, `monitor`
- **Standard suffixes**: `util`, `test` for utilities and testing

#### Forbidden Patterns:
- Generic names: `common`, `helper`, `utils`, `constant`
- Versioned names: `strings2`, `v2utils`
- Go prefixes: `gostrings`, `goutil`
- Underscores: `string_util`, `http_helper`
- Compound words: `userservice`, `ordermanager`
- Standard library conflicts: `errors`, `http`, `time`

### 3. Implementation Guidelines

#### Custom Data Types
```go
// internal/types/set/set.go
package set

type Set[T comparable] struct {
    items map[T]struct{}
}

func New[T comparable]() *Set[T] {
    return &Set[T]{
        items: make(map[T]struct{}),
    }
}

func (s *Set[T]) Add(item T) {
    s.items[item] = struct{}{}
}

func (s *Set[T]) Contains(item T) bool {
    _, exists := s.items[item]
    return exists
}

func (s *Set[T]) ToSlice() []T {
    result := make([]T, 0, len(s.items))
    for item := range s.items {
        result = append(result, item)
    }
    return result
}
```

#### String Utilities
```go
// internal/types/stringcase/stringcase.go
package stringcase

import (
    "regexp"
    "strings"
    "unicode"
)

var (
    camelCaseRegex = regexp.MustCompile(`([a-z])([A-Z])`)
    snakeCaseRegex = regexp.MustCompile(`[^a-zA-Z0-9]+`)
)

// ToCamelCase converts string to camelCase
func ToCamelCase(s string) string {
    words := strings.FieldsFunc(s, func(r rune) bool {
        return !unicode.IsLetter(r) && !unicode.IsNumber(r)
    })
    
    if len(words) == 0 {
        return ""
    }
    
    result := strings.ToLower(words[0])
    for _, word := range words[1:] {
        if len(word) > 0 {
            result += strings.ToUpper(word[:1]) + strings.ToLower(word[1:])
        }
    }
    return result
}

// ToPascalCase converts string to PascalCase
func ToPascalCase(s string) string {
    camel := ToCamelCase(s)
    if len(camel) > 0 {
        return strings.ToUpper(camel[:1]) + camel[1:]
    }
    return camel
}

// ToSnakeCase converts string to snake_case
func ToSnakeCase(s string) string {
    s = camelCaseRegex.ReplaceAllString(s, `${1}_${2}`)
    s = snakeCaseRegex.ReplaceAllString(s, "_")
    return strings.ToLower(strings.Trim(s, "_"))
}

// ToKebabCase converts string to kebab-case
func ToKebabCase(s string) string {
    return strings.ReplaceAll(ToSnakeCase(s), "_", "-")
}
```

#### Time Utilities
```go
// internal/types/timeutil/timeutil.go
package timeutil

import (
    "time"
)

// Today returns the start of today in the given timezone
func Today(tz *time.Location) time.Time {
    now := time.Now().In(tz)
    return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, tz)
}

// Tomorrow returns the start of tomorrow in the given timezone
func Tomorrow(tz *time.Location) time.Time {
    return Today(tz).AddDate(0, 0, 1)
}

// Yesterday returns the start of yesterday in the given timezone
func Yesterday(tz *time.Location) time.Time {
    return Today(tz).AddDate(0, 0, -1)
}

// StartOfMonth returns the first day of the current month
func StartOfMonth(t time.Time) time.Time {
    return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, t.Location())
}

// EndOfMonth returns the last moment of the current month
func EndOfMonth(t time.Time) time.Time {
    return StartOfMonth(t).AddDate(0, 1, 0).Add(-time.Nanosecond)
}

// DateRange represents a range between two dates
type DateRange struct {
    Start time.Time
    End   time.Time
}

// NewDateRange creates a new date range
func NewDateRange(start, end time.Time) DateRange {
    return DateRange{Start: start, End: end}
}

// Contains checks if a time falls within the range
func (dr DateRange) Contains(t time.Time) bool {
    return (t.Equal(dr.Start) || t.After(dr.Start)) && 
           (t.Equal(dr.End) || t.Before(dr.End))
}

// Duration returns the duration of the range
func (dr DateRange) Duration() time.Duration {
    return dr.End.Sub(dr.Start)
}
```

#### Slice Utilities
```go
// internal/types/sliceutil/sliceutil.go
package sliceutil

// Contains checks if a slice contains a specific element
func Contains[T comparable](slice []T, item T) bool {
    for _, v := range slice {
        if v == item {
            return true
        }
    }
    return false
}

// Filter returns a new slice containing only elements that satisfy the predicate
func Filter[T any](slice []T, predicate func(T) bool) []T {
    var result []T
    for _, item := range slice {
        if predicate(item) {
            result = append(result, item)
        }
    }
    return result
}

// Map transforms each element in the slice using the provided function
func Map[T, R any](slice []T, transform func(T) R) []R {
    result := make([]R, len(slice))
    for i, item := range slice {
        result[i] = transform(item)
    }
    return result
}

// Reduce reduces the slice to a single value using the provided function
func Reduce[T, R any](slice []T, initial R, reducer func(R, T) R) R {
    result := initial
    for _, item := range slice {
        result = reducer(result, item)
    }
    return result
}

// Chunk splits a slice into smaller slices of specified size
func Chunk[T any](slice []T, size int) [][]T {
    if size <= 0 {
        return nil
    }
    
    var chunks [][]T
    for i := 0; i < len(slice); i += size {
        end := i + size
        if end > len(slice) {
            end = len(slice)
        }
        chunks = append(chunks, slice[i:end])
    }
    return chunks
}
```

### 4. Testing Strategy

```go
// internal/types/stringcase/stringcase_test.go
package stringcase_test

import (
    "testing"
    "internal/types/stringcase"
)

func TestToCamelCase(t *testing.T) {
    tests := []struct {
        input    string
        expected string
    }{
        {"hello_world", "helloWorld"},
        {"user-name", "userName"},
        {"API_KEY", "apiKey"},
        {"", ""},
        {"single", "single"},
    }
    
    for _, tt := range tests {
        t.Run(tt.input, func(t *testing.T) {
            result := stringcase.ToCamelCase(tt.input)
            if result != tt.expected {
                t.Errorf("ToCamelCase(%q) = %q, want %q", tt.input, result, tt.expected)
            }
        })
    }
}
```

### 5. Package Documentation

```go
// Package stringcase provides utilities for converting strings between different cases.
//
// Supported conversions:
//   - camelCase
//   - PascalCase  
//   - snake_case
//   - kebab-case
//
// Example usage:
//
//     package main
//     
//     import "internal/types/stringcase"
//     
//     func main() {
//         input := "hello_world"
//         camel := stringcase.ToCamelCase(input)    // "helloWorld"
//         pascal := stringcase.ToPascalCase(input)  // "HelloWorld"
//         kebab := stringcase.ToKebabCase(input)    // "hello-world"
//     }
package stringcase
```

## Consequences

### Positive
- **Clear organization**: Types and utilities are logically grouped
- **Improved discoverability**: Package names indicate functionality
- **Better maintainability**: Related code is co-located
- **Reduced coupling**: Specific packages have focused responsibilities
- **Enhanced testing**: Each package can be tested independently
- **Go idioms**: Follows Go community conventions

### Negative
- **Initial migration**: Existing code may need refactoring
- **Package proliferation**: More packages to manage
- **Import path length**: Slightly longer import paths

### Migration Strategy

1. **Phase 1**: Create new package structure
2. **Phase 2**: Move existing utilities to appropriate packages
3. **Phase 3**: Update imports across codebase
4. **Phase 4**: Remove deprecated packages

## Best Practices

1. **One responsibility per package**: Each package should have a single, well-defined purpose
2. **Minimal dependencies**: Packages should have few external dependencies
3. **Generic programming**: Use Go generics for type-safe utilities
4. **Comprehensive testing**: Achieve high test coverage for utility packages
5. **Clear documentation**: Include examples and usage patterns
6. **Consistent API design**: Follow Go idioms for function signatures

## Anti-patterns to Avoid

```go
// ❌ Bad: Generic utility package
package utils
func StringToCamel(s string) string { ... }
func FormatDate(t time.Time) string { ... }
func ValidateEmail(email string) bool { ... }

// ✅ Good: Specific packages
package stringcase
func ToCamelCase(s string) string { ... }

package timeutil  
func FormatDate(t time.Time) string { ... }

package validator
func Email(email string) bool { ... }
```

## References

- [Effective Go - Package Names](https://golang.org/doc/effective_go.html#package-names)
- [Go Code Review Comments - Package Names](https://github.com/golang/go/wiki/CodeReviewComments#package-names)
- [Standard Library Package Organization](https://golang.org/pkg/)
- [Go Blog - Package Names](https://blog.golang.org/package-names)
