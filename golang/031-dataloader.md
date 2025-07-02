# DataLoader Pattern for Efficient Batching and Caching

## Status 

`accepted`

## Context

DataLoader is a crucial pattern for solving the N+1 query problem in applications, particularly in GraphQL APIs where concurrent resolvers may request the same data multiple times. The pattern batches individual load requests into bulk operations and provides transparent caching to eliminate duplicate requests within a single request cycle.

Key challenges in DataLoader implementation:
- **N+1 Problem**: Multiple sequential queries instead of one bulk query
- **Cache coherence**: Ensuring cached results match the requested keys
- **Error handling**: Handling partial failures in batch operations
- **Memory management**: Preventing memory leaks from cached data
- **Concurrency**: Thread-safe operations across goroutines

## Decision

**Implement a robust DataLoader pattern with the following characteristics:**

### 1. Core DataLoader Implementation

```go
package dataloader

import (
    "context"
    "errors"
    "fmt"
    "sync"
    "time"
)

// BatchFunc loads data for the given keys. Must return values in the same order as keys.
// If a key has no value, return nil for that position.
type BatchFunc[K comparable, V any] func(ctx context.Context, keys []K) ([]V, []error)

// KeyFunc extracts the key from a value for cache mapping.
type KeyFunc[K comparable, V any] func(V) K

// Result represents a cached result that may contain a value or error.
type Result[V any] struct {
    Value V
    Error error
}

// DataLoader batches and caches data loading operations.
type DataLoader[K comparable, V any] struct {
    mu          sync.RWMutex
    batchFunc   BatchFunc[K, V]
    keyFunc     KeyFunc[K, V]
    cache       map[K]*Result[V]
    
    // Batching configuration
    maxBatchSize int
    batchTimeout time.Duration
    
    // Batching state
    batch       []K
    batchMu     sync.Mutex
    promises    map[K][]*promise[V]
    ticker      *time.Ticker
    done        chan struct{}
    started     bool
}

type promise[V any] struct {
    ch chan *Result[V]
}

func (p *promise[V]) await() (V, error) {
    result := <-p.ch
    return result.Value, result.Error
}

// Config for DataLoader initialization.
type Config struct {
    MaxBatchSize int
    BatchTimeout time.Duration
}

func New[K comparable, V any](
    batchFunc BatchFunc[K, V],
    keyFunc KeyFunc[K, V],
    config Config,
) *DataLoader[K, V] {
    if config.MaxBatchSize <= 0 {
        config.MaxBatchSize = 100
    }
    if config.BatchTimeout <= 0 {
        config.BatchTimeout = 10 * time.Millisecond
    }
    
    return &DataLoader[K, V]{
        batchFunc:    batchFunc,
        keyFunc:      keyFunc,
        cache:        make(map[K]*Result[V]),
        maxBatchSize: config.MaxBatchSize,
        batchTimeout: config.BatchTimeout,
        promises:     make(map[K][]*promise[V]),
        done:         make(chan struct{}),
    }
}

// Load fetches a value for the given key, batching with other concurrent loads.
func (dl *DataLoader[K, V]) Load(ctx context.Context, key K) (V, error) {
    // Check cache first
    dl.mu.RLock()
    if result, exists := dl.cache[key]; exists {
        dl.mu.RUnlock()
        return result.Value, result.Error
    }
    dl.mu.RUnlock()
    
    // Start batch worker if not already started
    dl.startWorker()
    
    // Create promise for this request
    p := &promise[V]{ch: make(chan *Result[V], 1)}
    
    dl.batchMu.Lock()
    dl.batch = append(dl.batch, key)
    dl.promises[key] = append(dl.promises[key], p)
    
    // Trigger immediate execution if batch is full
    if len(dl.batch) >= dl.maxBatchSize {
        dl.executeBatch(ctx)
    }
    dl.batchMu.Unlock()
    
    return p.await()
}

// LoadMany fetches values for multiple keys efficiently.
func (dl *DataLoader[K, V]) LoadMany(ctx context.Context, keys []K) ([]V, []error) {
    results := make([]V, len(keys))
    errors := make([]error, len(keys))
    
    // Use WaitGroup for concurrent loading
    var wg sync.WaitGroup
    for i, key := range keys {
        wg.Add(1)
        go func(idx int, k K) {
            defer wg.Done()
            value, err := dl.Load(ctx, k)
            results[idx] = value
            errors[idx] = err
        }(i, key)
    }
    
    wg.Wait()
    return results, errors
}

// Prime manually adds a value to the cache.
func (dl *DataLoader[K, V]) Prime(key K, value V, err error) {
    dl.mu.Lock()
    defer dl.mu.Unlock()
    
    dl.cache[key] = &Result[V]{
        Value: value,
        Error: err,
    }
}

// Clear removes all cached values.
func (dl *DataLoader[K, V]) Clear() {
    dl.mu.Lock()
    defer dl.mu.Unlock()
    
    dl.cache = make(map[K]*Result[V])
}

// ClearKey removes a specific key from cache.
func (dl *DataLoader[K, V]) ClearKey(key K) {
    dl.mu.Lock()
    defer dl.mu.Unlock()
    
    delete(dl.cache, key)
}

// Flush immediately executes any pending batch.
func (dl *DataLoader[K, V]) Flush(ctx context.Context) {
    dl.batchMu.Lock()
    if len(dl.batch) > 0 {
        dl.executeBatch(ctx)
    }
    dl.batchMu.Unlock()
}

// Close stops the DataLoader and cleans up resources.
func (dl *DataLoader[K, V]) Close() {
    dl.batchMu.Lock()
    if dl.started {
        close(dl.done)
        dl.ticker.Stop()
        dl.started = false
    }
    dl.batchMu.Unlock()
}

func (dl *DataLoader[K, V]) startWorker() {
    dl.batchMu.Lock()
    defer dl.batchMu.Unlock()
    
    if dl.started {
        return
    }
    
    dl.started = true
    dl.ticker = time.NewTicker(dl.batchTimeout)
    
    go func() {
        defer dl.ticker.Stop()
        
        for {
            select {
            case <-dl.ticker.C:
                dl.batchMu.Lock()
                if len(dl.batch) > 0 {
                    dl.executeBatch(context.Background())
                }
                dl.batchMu.Unlock()
                
            case <-dl.done:
                return
            }
        }
    }()
}

func (dl *DataLoader[K, V]) executeBatch(ctx context.Context) {
    if len(dl.batch) == 0 {
        return
    }
    
    // Get unique keys to avoid duplicate database queries
    keySet := make(map[K]struct{})
    var uniqueKeys []K
    for _, key := range dl.batch {
        if _, exists := keySet[key]; !exists {
            keySet[key] = struct{}{}
            uniqueKeys = append(uniqueKeys, key)
        }
    }
    
    currentBatch := dl.batch
    currentPromises := dl.promises
    
    // Reset batch state
    dl.batch = nil
    dl.promises = make(map[K][]*promise[V])
    
    // Execute batch function
    values, errors := dl.batchFunc(ctx, uniqueKeys)
    
    // Create results map
    results := make(map[K]*Result[V])
    
    if len(values) != len(uniqueKeys) || len(errors) != len(uniqueKeys) {
        // Handle length mismatch - create error for all keys
        err := errors.New("batch function returned mismatched lengths")
        for _, key := range uniqueKeys {
            results[key] = &Result[V]{Error: err}
        }
    } else {
        // Map results using key function
        for i, key := range uniqueKeys {
            result := &Result[V]{
                Value: values[i],
                Error: errors[i],
            }
            results[key] = result
        }
    }
    
    // Cache and deliver results
    dl.mu.Lock()
    for key, result := range results {
        // Cache the result
        dl.cache[key] = result
        
        // Deliver to all waiting promises
        if promises, exists := currentPromises[key]; exists {
            for _, promise := range promises {
                promise.ch <- result
            }
        }
    }
    dl.mu.Unlock()
}
```

### 2. Practical Usage Examples

#### User DataLoader for GraphQL

```go
// Domain model
type User struct {
    ID       string    `json:"id"`
    Name     string    `json:"name"`
    Email    string    `json:"email"`
    Created  time.Time `json:"created"`
}

// Repository interface
type UserRepository interface {
    GetUsersByIDs(ctx context.Context, ids []string) ([]*User, error)
}

// Create DataLoader for users
func NewUserDataLoader(repo UserRepository) *dataloader.DataLoader[string, *User] {
    batchFunc := func(ctx context.Context, ids []string) ([]*User, []error) {
        users, err := repo.GetUsersByIDs(ctx, ids)
        if err != nil {
            // Return error for all keys
            errors := make([]error, len(ids))
            for i := range errors {
                errors[i] = err
            }
            return make([]*User, len(ids)), errors
        }
        
        // Create map for O(1) lookup
        userMap := make(map[string]*User)
        for _, user := range users {
            userMap[user.ID] = user
        }
        
        // Return results in same order as keys
        results := make([]*User, len(ids))
        errors := make([]error, len(ids))
        
        for i, id := range ids {
            if user, exists := userMap[id]; exists {
                results[i] = user
            } else {
                errors[i] = fmt.Errorf("user not found: %s", id)
            }
        }
        
        return results, errors
    }
    
    keyFunc := func(user *User) string {
        return user.ID
    }
    
    return dataloader.New(batchFunc, keyFunc, dataloader.Config{
        MaxBatchSize: 100,
        BatchTimeout: 10 * time.Millisecond,
    })
}

// GraphQL resolver example
type Resolver struct {
    userLoader *dataloader.DataLoader[string, *User]
}

func (r *Resolver) Posts(ctx context.Context) ([]*Post, error) {
    posts, err := r.postRepo.GetPosts(ctx)
    if err != nil {
        return nil, err
    }
    
    // This would normally cause N+1 queries
    for _, post := range posts {
        // Load user for each post - DataLoader will batch these
        user, err := r.userLoader.Load(ctx, post.AuthorID)
        if err != nil {
            return nil, err
        }
        post.Author = user
    }
    
    return posts, nil
}
```

#### Redis Cache DataLoader

```go
// Cache DataLoader for expensive computations
func NewComputationDataLoader() *dataloader.DataLoader[string, *Result] {
    batchFunc := func(ctx context.Context, keys []string) ([]*Result, []error) {
        results := make([]*Result, len(keys))
        errors := make([]error, len(keys))
        
        for i, key := range keys {
            // Simulate expensive computation
            result, err := performExpensiveComputation(ctx, key)
            results[i] = result
            errors[i] = err
        }
        
        return results, errors
    }
    
    keyFunc := func(result *Result) string {
        return result.Key
    }
    
    return dataloader.New(batchFunc, keyFunc, dataloader.Config{
        MaxBatchSize: 50,
        BatchTimeout: 5 * time.Millisecond,
    })
}
```

### 3. Testing DataLoader

```go
func TestDataLoader(t *testing.T) {
    // Mock repository
    repo := &MockUserRepository{
        users: map[string]*User{
            "1": {ID: "1", Name: "Alice"},
            "2": {ID: "2", Name: "Bob"},
        },
    }
    
    loader := NewUserDataLoader(repo)
    defer loader.Close()
    
    t.Run("single load", func(t *testing.T) {
        user, err := loader.Load(context.Background(), "1")
        require.NoError(t, err)
        assert.Equal(t, "Alice", user.Name)
        
        // Verify repository was called
        assert.Equal(t, 1, repo.callCount)
    })
    
    t.Run("batch loading", func(t *testing.T) {
        repo.callCount = 0 // Reset
        
        // Concurrent loads should be batched
        var wg sync.WaitGroup
        results := make([]*User, 3)
        errors := make([]error, 3)
        
        for i, id := range []string{"1", "2", "1"} {
            wg.Add(1)
            go func(idx int, userID string) {
                defer wg.Done()
                user, err := loader.Load(context.Background(), userID)
                results[idx] = user
                errors[idx] = err
            }(i, id)
        }
        
        wg.Wait()
        
        // All should succeed
        for _, err := range errors {
            require.NoError(t, err)
        }
        
        // Results should be correct
        assert.Equal(t, "Alice", results[0].Name)
        assert.Equal(t, "Bob", results[1].Name)
        assert.Equal(t, "Alice", results[2].Name) // Cached
        
        // Repository should be called only once
        assert.Equal(t, 1, repo.callCount)
    })
    
    t.Run("cache behavior", func(t *testing.T) {
        // Prime cache
        loader.Prime("3", &User{ID: "3", Name: "Charlie"}, nil)
        
        user, err := loader.Load(context.Background(), "3")
        require.NoError(t, err)
        assert.Equal(t, "Charlie", user.Name)
        
        // Should not call repository
        assert.Equal(t, 1, repo.callCount) // From previous test
    })
}

type MockUserRepository struct {
    users     map[string]*User
    callCount int
}

func (m *MockUserRepository) GetUsersByIDs(ctx context.Context, ids []string) ([]*User, error) {
    m.callCount++
    
    var users []*User
    for _, id := range ids {
        if user, exists := m.users[id]; exists {
            users = append(users, user)
        }
    }
    
    return users, nil
}
```

### 4. Advanced Patterns

#### TTL Cache Integration

```go
type TTLDataLoader[K comparable, V any] struct {
    *DataLoader[K, V]
    ttl   time.Duration
    times map[K]time.Time
    mu    sync.RWMutex
}

func (dl *TTLDataLoader[K, V]) Load(ctx context.Context, key K) (V, error) {
    dl.mu.RLock()
    if expiry, exists := dl.times[key]; exists {
        if time.Now().After(expiry) {
            dl.mu.RUnlock()
            dl.ClearKey(key)
            dl.mu.Lock()
            delete(dl.times, key)
            dl.mu.Unlock()
        } else {
            dl.mu.RUnlock()
        }
    } else {
        dl.mu.RUnlock()
    }
    
    value, err := dl.DataLoader.Load(ctx, key)
    if err == nil {
        dl.mu.Lock()
        dl.times[key] = time.Now().Add(dl.ttl)
        dl.mu.Unlock()
    }
    
    return value, err
}
```

## Consequences

**Benefits:**
- **Performance**: Eliminates N+1 queries through intelligent batching
- **Simplicity**: Transparent caching without manual cache management
- **Concurrency**: Thread-safe operations across multiple goroutines
- **Memory efficiency**: Bounded cache size with TTL support
- **Debugging**: Clear visibility into batch operations and cache hits

**Trade-offs:**
- **Complexity**: Additional abstraction layer to understand and maintain
- **Memory usage**: Cached data consumes memory until cleared
- **Latency**: Small delay due to batching timeout
- **Debugging**: Harder to trace individual data requests

**Best Practices:**
- Use per-request DataLoader instances to prevent data leakage
- Implement proper key extraction functions for cache coherence  
- Set reasonable batch sizes and timeouts based on use case
- Monitor cache hit rates and batch effectiveness
- Clear cache appropriately to prevent memory leaks
- Use TTL for long-lived DataLoader instances

## References

- [Facebook DataLoader](https://github.com/graphql/dataloader)
- [GraphQL Best Practices](https://graphql.org/learn/best-practices/)
- [Go Concurrency Patterns](https://blog.golang.org/concurrency-patterns)

The user is responsible to handle the error.


### Lazy initiation

A background worker needs to be initialized in order to perform the batching.
A DataLoader is commonly created per request for a given resource. When we need to fetch multiple resource, we will have to create a number of separate DataLoader, each with their own goroutine.

However, there is still no guarantee that the dataloader will be executed. So the goroutine will remain until the requests ends.

To solve this, we initialize the dataloader lazily starting from when the first key is send.

### Referencing values

Once a value for a key is fetched, the value is stored in a cache.

Subsequent load for the same key will return the same value.

Care needs to be taken for values that are pointers, as they may share the same state.

The user can clone the object before using them if the states should not be shared.


### Idle timeout

Goroutines are cheap, but no resources are cheap. When idle, we can stop the goroutine. This is determined by the idle timeout.

When there are new tasks to be scheduled, we can then restart the goroutine.

Below, we demonstrate the application of idle timeout together with debounce mechanism.

Everytime we received a new message from the work channel, we will reset the idle timeout as well as the ticker timeout. This essentially means that we will not execute the job as long as we already have a minimum batch size, or when there are no further message from the channel after the tick period.

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"time"
)

func main() {
	idle := time.NewTicker(1 * time.Second)
	defer idle.Stop()

	ch := make(chan int)
	t := time.NewTicker(100 * time.Millisecond)
	defer t.Stop()

	n := 0
	threshold := 100

	for {
		select {
		case <-idle.C:
			fmt.Println("idle")
			return
		case <-t.C:
			// Periodic.
			fmt.Println("exec batch jobs")
		case <-ch:
			n++
			if n > threshold {
				n = 0
				fmt.Println("exec batch job")
			}
			// Reset the idle timeout and perform debounce.
			t.Reset(100 * time.Millisecond)
			idle.Reset(1 * time.Second)
		}
	}
}
```

## Plain cache

When the background job is cancelled, there wont be any batching.

As a fallback, the dataloader should behave like a regular cache and get/set should work too.

## Manual flush

Dataloader can triggered to fetch the keys manually by calling the `Flush` method, instead of waiting for the batch timeout.

This is usually at the end of a for loop, once we know there are no further keys to fetch.




