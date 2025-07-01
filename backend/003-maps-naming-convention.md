# Maps Naming Convention

## Status

`accepted`

## Context

In software development, we frequently need to create mappings between different data types, often with multiple nested layers. The naming convention for these mappings significantly impacts code readability and maintainability. There are two common approaches: `valueByKey` and `keyToValue`, each with different readability characteristics.

## Decision

Use the `keyToValue` naming convention for maps and dictionaries as it provides clearer semantic meaning and better code comprehension.

## Rationale

The `keyToValue` convention reads more naturally and makes the data flow explicit:
- **Clarity**: Immediately understand what the key represents and what it maps to
- **Readability**: Follows natural language patterns (A to B, X to Y)
- **Scalability**: Works better with nested mappings and complex relationships
- **Consistency**: Aligns with functional programming concepts and transformation patterns

## Examples

### Simple Mappings

```go
// ✅ Preferred: Clear semantic meaning
userIDToName := map[int]string{
    1: "alice",
    2: "bob",
    3: "charlie",
}

roleIDToPermissions := map[string][]string{
    "admin": {"read", "write", "delete"},
    "user":  {"read"},
    "guest": {"read"},
}

// ❌ Avoid: Less clear, requires mental translation
namesByUserID := map[int]string{
    1: "alice",
    2: "bob",
}
```

### Nested Mappings

```go
// ✅ Multi-level mappings with clear hierarchy
roomIDToUserIDToName := map[string]map[int]string{
    "room1": {
        1: "alice",
        2: "bob",
    },
    "room2": {
        3: "charlie",
        4: "diana",
    },
}

// Usage is intuitive
userIDToName := roomIDToUserIDToName["room1"]
userName := userIDToName[1] // "alice"

// ✅ More complex example
organizationIDToTeamIDToMembers := map[string]map[string][]User{
    "org1": {
        "engineering": {
            {ID: 1, Name: "Alice"},
            {ID: 2, Name: "Bob"},
        },
        "marketing": {
            {ID: 3, Name: "Charlie"},
        },
    },
}
```

### Reverse Mappings

When you need bidirectional lookups, create separate maps:

```go
// Forward mapping
userIDToEmail := map[int]string{
    1: "alice@example.com",
    2: "bob@example.com",
}

// Reverse mapping
emailToUserID := map[string]int{
    "alice@example.com": 1,
    "bob@example.com":   2,
}

// Helper function to build reverse mapping
func buildEmailToUserID(userIDToEmail map[int]string) map[string]int {
    emailToUserID := make(map[string]int)
    for userID, email := range userIDToEmail {
        emailToUserID[email] = userID
    }
    return emailToUserID
}
```

### Time-based Mappings

```go
// Date-based aggregations
dateToOrderCount := map[string]int{
    "2023-12-01": 150,
    "2023-12-02": 175,
    "2023-12-03": 200,
}

// Time series data
timestampToMetrics := map[int64]Metrics{
    1701388800: {CPU: 45.5, Memory: 78.2, ActiveUsers: 1250},
    1701392400: {CPU: 52.1, Memory: 82.7, ActiveUsers: 1340},
}
```

### Grouped Data Patterns

```go
type Product struct {
    ID       int
    Name     string
    Category string
    Price    float64
}

// Group products by category
categoryToProducts := map[string][]Product{
    "electronics": {
        {ID: 1, Name: "Laptop", Category: "electronics", Price: 999.99},
        {ID: 2, Name: "Phone", Category: "electronics", Price: 599.99},
    },
    "books": {
        {ID: 3, Name: "Go Programming", Category: "books", Price: 49.99},
    },
}

// Price range groupings
priceRangeToProducts := map[string][]Product{
    "0-100":    {},
    "100-500":  {{ID: 3, Name: "Go Programming", Price: 49.99}},
    "500-1000": {{ID: 2, Name: "Phone", Price: 599.99}},
    "1000+":    {{ID: 1, Name: "Laptop", Price: 999.99}},
}
```

### Configuration Mappings

```go
// Environment-specific configurations
envToConfig := map[string]Config{
    "development": {
        DatabaseURL: "localhost:5432",
        Debug:       true,
        LogLevel:    "debug",
    },
    "staging": {
        DatabaseURL: "staging-db:5432",
        Debug:       false,
        LogLevel:    "info",
    },
    "production": {
        DatabaseURL: "prod-db:5432",
        Debug:       false,
        LogLevel:    "warn",
    },
}

// Feature flags per user segment
segmentToFeatures := map[string][]string{
    "beta_users":    {"new_dashboard", "advanced_analytics"},
    "premium_users": {"priority_support", "custom_themes"},
    "admin_users":   {"user_management", "system_metrics"},
}
```

### Caching Patterns

```go
// Cache with TTL information
type CacheEntry struct {
    Value     interface{}
    ExpiresAt time.Time
}

keyToCache := map[string]CacheEntry{
    "user:123": {
        Value:     User{ID: 123, Name: "Alice"},
        ExpiresAt: time.Now().Add(time.Hour),
    },
}

// Query result caching
queryHashToResult := map[string]QueryResult{
    "SELECT_users_WHERE_active": {
        Data:      []User{{ID: 1, Name: "Alice"}},
        CachedAt:  time.Now(),
        ExpiresAt: time.Now().Add(5 * time.Minute),
    },
}
```

### Advanced Patterns

#### Index Mappings

```go
// Search indices
termToDocumentIDs := map[string][]int{
    "golang":      {1, 3, 7, 12},
    "programming": {1, 2, 5, 8, 12},
    "backend":     {3, 7, 9, 11},
}

// Inverted index for full-text search
func buildInvertedIndex(documents map[int]string) map[string][]int {
    termToDocIDs := make(map[string][]int)
    
    for docID, content := range documents {
        words := strings.Fields(strings.ToLower(content))
        for _, word := range words {
            termToDocIDs[word] = append(termToDocIDs[word], docID)
        }
    }
    
    return termToDocIDs
}
```

#### Graph Adjacency Lists

```go
// Graph representation using maps
nodeToNeighbors := map[string][]string{
    "A": {"B", "C"},
    "B": {"A", "D", "E"},
    "C": {"A", "F"},
    "D": {"B"},
    "E": {"B", "F"},
    "F": {"C", "E"},
}

// Weighted graph
nodeToWeightedEdges := map[string]map[string]int{
    "A": {"B": 5, "C": 3},
    "B": {"A": 5, "D": 7, "E": 2},
    "C": {"A": 3, "F": 4},
}
```

## Implementation Guidelines

### Type Safety

```go
// Use type aliases for complex key types
type UserID int
type RoomID string

type UserMap map[UserID]User
type RoomToUsers map[RoomID]UserMap

var roomToUsers RoomToUsers = make(RoomToUsers)
```

### Helper Functions

```go
// Generic helper for safe map access
func GetOrDefault[K comparable, V any](m map[K]V, key K, defaultValue V) V {
    if value, exists := m[key]; exists {
        return value
    }
    return defaultValue
}

// Safe nested map access
func GetNestedValue[K1, K2 comparable, V any](
    m map[K1]map[K2]V, 
    key1 K1, 
    key2 K2,
) (V, bool) {
    var zero V
    inner, exists := m[key1]
    if !exists {
        return zero, false
    }
    
    value, exists := inner[key2]
    return value, exists
}

// Usage
value, exists := GetNestedValue(roomIDToUserIDToName, "room1", 1)
```

### Builder Patterns

```go
type MapBuilder[K comparable, V any] struct {
    data map[K]V
}

func NewMapBuilder[K comparable, V any]() *MapBuilder[K, V] {
    return &MapBuilder[K, V]{
        data: make(map[K]V),
    }
}

func (b *MapBuilder[K, V]) Add(key K, value V) *MapBuilder[K, V] {
    b.data[key] = value
    return b
}

func (b *MapBuilder[K, V]) Build() map[K]V {
    return b.data
}

// Usage
userIDToName := NewMapBuilder[int, string]().
    Add(1, "alice").
    Add(2, "bob").
    Add(3, "charlie").
    Build()
```

## Testing Considerations

```go
func TestUserMapping(t *testing.T) {
    userIDToName := map[int]string{
        1: "alice",
        2: "bob",
    }
    
    tests := []struct {
        userID   int
        expected string
        exists   bool
    }{
        {1, "alice", true},
        {2, "bob", true},
        {3, "", false},
    }
    
    for _, test := range tests {
        name, exists := userIDToName[test.userID]
        assert.Equal(t, test.exists, exists)
        if exists {
            assert.Equal(t, test.expected, name)
        }
    }
}
```

## Anti-patterns to Avoid

```go
// ❌ Ambiguous naming - what are these?
data := map[string]string{
    "a": "b",
    "c": "d",
}

// ❌ Inconsistent conventions in same codebase
usersByID := map[int]User{}     // valueByKey
idToUser := map[int]User{}      // keyToValue

// ❌ Overly abbreviated names
utu := map[int]string{}  // user to ???

// ❌ Backwards naming that confuses the mapping direction
nameToUserID := map[string]int{
    "alice": 1,  // This actually maps name TO userID, so naming is correct
}
// But then using it incorrectly:
userIDToName := nameToUserID  // This is wrong - the data is backwards
```

## Benefits

- **Improved Readability**: Code becomes self-documenting
- **Reduced Cognitive Load**: Less mental translation required
- **Better Debugging**: Clear understanding of data relationships
- **Easier Maintenance**: New team members can understand code faster
- **Consistent Patterns**: Standardized approach across the codebase

## Migration Strategy

For existing codebases with `valueByKey` conventions:

1. **Gradual Refactoring**: Update maps during regular maintenance
2. **New Code**: Apply `keyToValue` convention for all new mappings
3. **Documentation**: Update variable naming guidelines
4. **Code Reviews**: Enforce convention in pull request reviews
