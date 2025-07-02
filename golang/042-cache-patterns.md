# Cache Patterns and Anti-Patterns

## Status

`accepted`

## Context

Caching is crucial for application performance but introduces complexity around consistency, invalidation, and resource management. Effective caching strategies must handle cache penetration, thundering herd problems, and provide clear interfaces for different caching scenarios.

Common caching challenges:
- **Cache penetration**: Malicious requests for non-existent keys
- **Cache stampede**: Multiple requests fetching the same missing data
- **Cache avalanche**: Mass cache expiration causing database overload
- **Memory management**: Unbounded cache growth
- **Consistency**: Stale data and invalidation strategies

## Decision

**Implement a comprehensive caching framework with multiple patterns:**

### 1. Core Cache Interface

```go
package cache

import (
    "context"
    "errors"
    "time"
)

var (
    ErrCacheNotFound = errors.New("cache: key not found")
    ErrCacheMiss     = errors.New("cache: miss")
)

// Cache defines the core caching interface.
type Cache interface {
    Get(ctx context.Context, key string) ([]byte, error)
    Set(ctx context.Context, key string, value []byte, ttl time.Duration) error
    Delete(ctx context.Context, key string) error
    Exists(ctx context.Context, key string) (bool, error)
    Clear(ctx context.Context) error
}

// TypedCache provides type-safe caching operations.
type TypedCache[T any] interface {
    Get(ctx context.Context, key string) (T, error)
    Set(ctx context.Context, key string, value T, ttl time.Duration) error
    GetOrSet(ctx context.Context, key string, fn func() (T, error), ttl time.Duration) (T, error)
    Delete(ctx context.Context, key string) error
    Clear(ctx context.Context) error
}

// BatchCache supports bulk operations for better performance.
type BatchCache interface {
    MGet(ctx context.Context, keys []string) (map[string][]byte, error)
    MSet(ctx context.Context, items map[string][]byte, ttl time.Duration) error
    MDelete(ctx context.Context, keys []string) error
}
```

### 2. Redis Implementation with Patterns

```go
package cache

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/go-redis/redis/v8"
    "golang.org/x/sync/singleflight"
)

// RedisCache implements Cache interface with Redis backend.
type RedisCache struct {
    client      redis.Cmdable
    prefix      string
    serializer  Serializer
    singleflight *singleflight.Group
}

type Serializer interface {
    Marshal(v interface{}) ([]byte, error)
    Unmarshal(data []byte, v interface{}) error
}

type JSONSerializer struct{}

func (s *JSONSerializer) Marshal(v interface{}) ([]byte, error) {
    return json.Marshal(v)
}

func (s *JSONSerializer) Unmarshal(data []byte, v interface{}) error {
    return json.Unmarshal(data, v)
}

func NewRedisCache(client redis.Cmdable, prefix string) *RedisCache {
    return &RedisCache{
        client:       client,
        prefix:       prefix,
        serializer:   &JSONSerializer{},
        singleflight: &singleflight.Group{},
    }
}

func (c *RedisCache) key(k string) string {
    if c.prefix == "" {
        return k
    }
    return c.prefix + ":" + k
}

func (c *RedisCache) Get(ctx context.Context, key string) ([]byte, error) {
    result, err := c.client.Get(ctx, c.key(key)).Result()
    if err != nil {
        if errors.Is(err, redis.Nil) {
            return nil, ErrCacheNotFound
        }
        return nil, fmt.Errorf("cache get: %w", err)
    }
    return []byte(result), nil
}

func (c *RedisCache) Set(ctx context.Context, key string, value []byte, ttl time.Duration) error {
    err := c.client.Set(ctx, c.key(key), value, ttl).Err()
    if err != nil {
        return fmt.Errorf("cache set: %w", err)
    }
    return nil
}

func (c *RedisCache) Delete(ctx context.Context, key string) error {
    err := c.client.Del(ctx, c.key(key)).Err()
    if err != nil {
        return fmt.Errorf("cache delete: %w", err)
    }
    return nil
}

func (c *RedisCache) Exists(ctx context.Context, key string) (bool, error) {
    count, err := c.client.Exists(ctx, c.key(key)).Result()
    if err != nil {
        return false, fmt.Errorf("cache exists: %w", err)
    }
    return count > 0, nil
}

func (c *RedisCache) Clear(ctx context.Context) error {
    pattern := c.key("*")
    keys, err := c.client.Keys(ctx, pattern).Result()
    if err != nil {
        return fmt.Errorf("cache clear keys: %w", err)
    }
    
    if len(keys) > 0 {
        err = c.client.Del(ctx, keys...).Err()
        if err != nil {
            return fmt.Errorf("cache clear delete: %w", err)
        }
    }
    
    return nil
}

// MGet implements BatchCache interface
func (c *RedisCache) MGet(ctx context.Context, keys []string) (map[string][]byte, error) {
    if len(keys) == 0 {
        return make(map[string][]byte), nil
    }
    
    redisKeys := make([]string, len(keys))
    for i, key := range keys {
        redisKeys[i] = c.key(key)
    }
    
    values, err := c.client.MGet(ctx, redisKeys...).Result()
    if err != nil {
        return nil, fmt.Errorf("cache mget: %w", err)
    }
    
    result := make(map[string][]byte)
    for i, value := range values {
        if value != nil {
            if str, ok := value.(string); ok {
                result[keys[i]] = []byte(str)
            }
        }
    }
    
    return result, nil
}

// MSet implements BatchCache interface
func (c *RedisCache) MSet(ctx context.Context, items map[string][]byte, ttl time.Duration) error {
    if len(items) == 0 {
        return nil
    }
    
    pipe := c.client.Pipeline()
    for key, value := range items {
        pipe.Set(ctx, c.key(key), value, ttl)
    }
    
    _, err := pipe.Exec(ctx)
    if err != nil {
        return fmt.Errorf("cache mset: %w", err)
    }
    
    return nil
}
```

### 3. Typed Cache with Generics

```go
// TypedRedisCache provides type-safe caching with automatic serialization.
type TypedRedisCache[T any] struct {
    cache      Cache
    serializer Serializer
    singleflight *singleflight.Group
}

func NewTypedRedisCache[T any](cache Cache) *TypedRedisCache[T] {
    return &TypedRedisCache[T]{
        cache:        cache,
        serializer:   &JSONSerializer{},
        singleflight: &singleflight.Group{},
    }
}

func (c *TypedRedisCache[T]) Get(ctx context.Context, key string) (T, error) {
    var zero T
    
    data, err := c.cache.Get(ctx, key)
    if err != nil {
        return zero, err
    }
    
    var value T
    if err := c.serializer.Unmarshal(data, &value); err != nil {
        return zero, fmt.Errorf("cache unmarshal: %w", err)
    }
    
    return value, nil
}

func (c *TypedRedisCache[T]) Set(ctx context.Context, key string, value T, ttl time.Duration) error {
    data, err := c.serializer.Marshal(value)
    if err != nil {
        return fmt.Errorf("cache marshal: %w", err)
    }
    
    return c.cache.Set(ctx, key, data, ttl)
}

// GetOrSet implements read-through cache pattern with singleflight protection.
func (c *TypedRedisCache[T]) GetOrSet(ctx context.Context, key string, fn func() (T, error), ttl time.Duration) (T, error) {
    // Try cache first
    value, err := c.Get(ctx, key)
    if err == nil {
        return value, nil
    }
    if !errors.Is(err, ErrCacheNotFound) {
        // Cache error, fallback to function
        return fn()
    }
    
    // Use singleflight to prevent thundering herd
    result, err, _ := c.singleflight.Do(key, func() (interface{}, error) {
        // Double-check cache in case another goroutine populated it
        if value, err := c.Get(ctx, key); err == nil {
            return value, nil
        }
        
        // Execute function to get value
        value, err := fn()
        if err != nil {
            return value, err
        }
        
        // Set in cache (fire and forget for better latency)
        go func() {
            ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
            defer cancel()
            _ = c.Set(ctx, key, value, ttl)
        }()
        
        return value, nil
    })
    
    if err != nil {
        var zero T
        return zero, err
    }
    
    return result.(T), nil
}

func (c *TypedRedisCache[T]) Delete(ctx context.Context, key string) error {
    return c.cache.Delete(ctx, key)
}

func (c *TypedRedisCache[T]) Clear(ctx context.Context) error {
    return c.cache.Clear(ctx)
}
```

### 4. Cache Penetration Protection with Bloom Filter

```go
package cache

import (
    "context"
    "crypto/sha256"
    "encoding/binary"
    "sync"
)

// BloomFilter provides probabilistic set membership testing.
type BloomFilter struct {
    bitSet []bool
    size   uint
    hashes uint
    mu     sync.RWMutex
}

func NewBloomFilter(size, hashes uint) *BloomFilter {
    return &BloomFilter{
        bitSet: make([]bool, size),
        size:   size,
        hashes: hashes,
    }
}

func (bf *BloomFilter) Add(key string) {
    bf.mu.Lock()
    defer bf.mu.Unlock()
    
    for i := uint(0); i < bf.hashes; i++ {
        hash := bf.hash(key, i)
        bf.bitSet[hash%bf.size] = true
    }
}

func (bf *BloomFilter) Contains(key string) bool {
    bf.mu.RLock()
    defer bf.mu.RUnlock()
    
    for i := uint(0); i < bf.hashes; i++ {
        hash := bf.hash(key, i)
        if !bf.bitSet[hash%bf.size] {
            return false
        }
    }
    return true
}

func (bf *BloomFilter) hash(key string, seed uint) uint {
    h := sha256.New()
    h.Write([]byte(key))
    h.Write([]byte{byte(seed)})
    hash := h.Sum(nil)
    return uint(binary.BigEndian.Uint64(hash[:8]))
}

// ProtectedCache wraps a cache with bloom filter protection.
type ProtectedCache[T any] struct {
    cache  TypedCache[T]
    bloom  *BloomFilter
    nullTTL time.Duration
}

func NewProtectedCache[T any](cache TypedCache[T], bloomSize, bloomHashes uint) *ProtectedCache[T] {
    return &ProtectedCache[T]{
        cache:   cache,
        bloom:   NewBloomFilter(bloomSize, bloomHashes),
        nullTTL: 5 * time.Minute, // Cache negative results
    }
}

func (c *ProtectedCache[T]) GetOrSet(ctx context.Context, key string, fn func() (T, error), ttl time.Duration) (T, error) {
    var zero T
    
    // Check bloom filter first
    if !c.bloom.Contains(key) {
        // Definitely not in cache, but might exist in data source
        value, err := fn()
        if err != nil {
            return zero, err
        }
        
        // Add to bloom filter and cache
        c.bloom.Add(key)
        _ = c.cache.Set(ctx, key, value, ttl)
        
        return value, nil
    }
    
    // Might be in cache, check cache
    value, err := c.cache.Get(ctx, key)
    if err == nil {
        return value, nil
    }
    
    if !errors.Is(err, ErrCacheNotFound) {
        return zero, err
    }
    
    // Not in cache, fetch from data source
    value, err = fn()
    if err != nil {
        // Cache negative result to prevent repeated queries
        go func() {
            ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
            defer cancel()
            _ = c.cache.Set(ctx, "null:"+key, zero, c.nullTTL)
        }()
        return zero, err
    }
    
    // Cache positive result
    go func() {
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        _ = c.cache.Set(ctx, key, value, ttl)
    }()
    
    return value, nil
}
```

### 5. Cache Warming and Preloading

```go
// CacheWarmer handles proactive cache population.
type CacheWarmer[K comparable, V any] struct {
    cache    TypedCache[V]
    loader   func(ctx context.Context, keys []K) (map[K]V, error)
    keyFunc  func(V) K
    batchSize int
}

func NewCacheWarmer[K comparable, V any](
    cache TypedCache[V],
    loader func(ctx context.Context, keys []K) (map[K]V, error),
    keyFunc func(V) K,
) *CacheWarmer[K, V] {
    return &CacheWarmer[K, V]{
        cache:     cache,
        loader:    loader,
        keyFunc:   keyFunc,
        batchSize: 100,
    }
}

// WarmKeys preloads specific keys into cache.
func (w *CacheWarmer[K, V]) WarmKeys(ctx context.Context, keys []K, ttl time.Duration) error {
    // Process in batches
    for i := 0; i < len(keys); i += w.batchSize {
        end := i + w.batchSize
        if end > len(keys) {
            end = len(keys)
        }
        
        batch := keys[i:end]
        data, err := w.loader(ctx, batch)
        if err != nil {
            return fmt.Errorf("warming batch %d: %w", i/w.batchSize, err)
        }
        
        // Set each item in cache
        for key, value := range data {
            keyStr := fmt.Sprintf("%v", key)
            if err := w.cache.Set(ctx, keyStr, value, ttl); err != nil {
                // Log error but continue with other items
                fmt.Printf("Warning: failed to cache key %v: %v\n", key, err)
            }
        }
    }
    
    return nil
}

// RefreshCache updates existing cache entries.
func (w *CacheWarmer[K, V]) RefreshCache(ctx context.Context, pattern string, ttl time.Duration) error {
    // Implementation depends on cache backend
    // For Redis, use SCAN to get keys matching pattern
    return nil
}
```

### 6. Multi-Level Cache

```go
// MultiLevelCache implements L1 (in-memory) and L2 (Redis) caching.
type MultiLevelCache[T any] struct {
    l1Cache   TypedCache[T]
    l2Cache   TypedCache[T]
    l1TTL     time.Duration
    l2TTL     time.Duration
}

func NewMultiLevelCache[T any](l1, l2 TypedCache[T], l1TTL, l2TTL time.Duration) *MultiLevelCache[T] {
    return &MultiLevelCache[T]{
        l1Cache: l1,
        l2Cache: l2,
        l1TTL:   l1TTL,
        l2TTL:   l2TTL,
    }
}

func (c *MultiLevelCache[T]) Get(ctx context.Context, key string) (T, error) {
    // Try L1 cache first
    value, err := c.l1Cache.Get(ctx, key)
    if err == nil {
        return value, nil
    }
    
    // Try L2 cache
    value, err = c.l2Cache.Get(ctx, key)
    if err == nil {
        // Promote to L1 cache
        go func() {
            ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
            defer cancel()
            _ = c.l1Cache.Set(ctx, key, value, c.l1TTL)
        }()
        return value, nil
    }
    
    return value, err
}

func (c *MultiLevelCache[T]) Set(ctx context.Context, key string, value T, ttl time.Duration) error {
    // Set in both caches
    if err := c.l1Cache.Set(ctx, key, value, c.l1TTL); err != nil {
        return err
    }
    
    return c.l2Cache.Set(ctx, key, value, c.l2TTL)
}

func (c *MultiLevelCache[T]) GetOrSet(ctx context.Context, key string, fn func() (T, error), ttl time.Duration) (T, error) {
    // Try L1 first
    value, err := c.l1Cache.Get(ctx, key)
    if err == nil {
        return value, nil
    }
    
    // Try L2
    value, err = c.l2Cache.Get(ctx, key)
    if err == nil {
        // Promote to L1
        go func() {
            ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
            defer cancel()
            _ = c.l1Cache.Set(ctx, key, value, c.l1TTL)
        }()
        return value, nil
    }
    
    // Not in either cache, fetch and populate both
    value, err = fn()
    if err != nil {
        return value, err
    }
    
    // Set in both caches
    go func() {
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        _ = c.l1Cache.Set(ctx, key, value, c.l1TTL)
        _ = c.l2Cache.Set(ctx, key, value, c.l2TTL)
    }()
    
    return value, nil
}
```

### 7. Usage Examples

```go
// Service using multiple cache patterns
type UserService struct {
    repo       UserRepository
    cache      TypedCache[*User]
    batchCache *DataLoader[string, *User]
    warmer     *CacheWarmer[string, *User]
}

func NewUserService(repo UserRepository, cache TypedCache[*User]) *UserService {
    service := &UserService{
        repo:  repo,
        cache: cache,
    }
    
    // Set up DataLoader for batch operations
    service.batchCache = dataloader.New(
        service.batchLoadUsers,
        func(u *User) string { return u.ID },
        dataloader.Config{
            MaxBatchSize: 100,
            BatchTimeout: 10 * time.Millisecond,
        },
    )
    
    // Set up cache warmer
    service.warmer = NewCacheWarmer(
        cache,
        service.loadUsersBatch,
        func(u *User) string { return u.ID },
    )
    
    return service
}

func (s *UserService) GetUser(ctx context.Context, id string) (*User, error) {
    return s.cache.GetOrSet(ctx, "user:"+id, func() (*User, error) {
        return s.repo.GetByID(ctx, id)
    }, time.Hour)
}

func (s *UserService) GetUsers(ctx context.Context, ids []string) ([]*User, error) {
    return s.batchCache.LoadMany(ctx, ids)
}

func (s *UserService) WarmPopularUsers(ctx context.Context) error {
    popularIDs, err := s.repo.GetPopularUserIDs(ctx, 1000)
    if err != nil {
        return err
    }
    
    return s.warmer.WarmKeys(ctx, popularIDs, time.Hour)
}

func (s *UserService) batchLoadUsers(ctx context.Context, ids []string) ([]*User, []error) {
    users, err := s.repo.GetByIDs(ctx, ids)
    if err != nil {
        errors := make([]error, len(ids))
        for i := range errors {
            errors[i] = err
        }
        return make([]*User, len(ids)), errors
    }
    
    // Map users by ID for proper ordering
    userMap := make(map[string]*User)
    for _, user := range users {
        userMap[user.ID] = user
    }
    
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

func (s *UserService) loadUsersBatch(ctx context.Context, ids []string) (map[string]*User, error) {
    users, err := s.repo.GetByIDs(ctx, ids)
    if err != nil {
        return nil, err
    }
    
    result := make(map[string]*User)
    for _, user := range users {
        result[user.ID] = user
    }
    
    return result, nil
}
```

### 8. Testing Cache Patterns

```go
func TestCachePatterns(t *testing.T) {
    // Use miniredis for testing
    mr := miniredis.RunT(t)
    client := redis.NewClient(&redis.Options{Addr: mr.Addr()})
    
    cache := NewRedisCache(client, "test")
    typedCache := NewTypedRedisCache[*User](cache)
    
    t.Run("basic operations", func(t *testing.T) {
        user := &User{ID: "1", Name: "Alice"}
        
        err := typedCache.Set(context.Background(), "user:1", user, time.Hour)
        require.NoError(t, err)
        
        retrieved, err := typedCache.Get(context.Background(), "user:1")
        require.NoError(t, err)
        assert.Equal(t, user, retrieved)
    })
    
    t.Run("get or set with singleflight", func(t *testing.T) {
        callCount := 0
        fn := func() (*User, error) {
            callCount++
            return &User{ID: "2", Name: "Bob"}, nil
        }
        
        // Multiple concurrent calls should only execute fn once
        var wg sync.WaitGroup
        results := make([]*User, 5)
        
        for i := 0; i < 5; i++ {
            wg.Add(1)
            go func(idx int) {
                defer wg.Done()
                user, err := typedCache.GetOrSet(context.Background(), "user:2", fn, time.Hour)
                require.NoError(t, err)
                results[idx] = user
            }(i)
        }
        
        wg.Wait()
        
        // Function should only be called once due to singleflight
        assert.Equal(t, 1, callCount)
        
        // All results should be the same
        for _, result := range results {
            assert.Equal(t, "Bob", result.Name)
        }
    })
}
```

## Consequences

**Benefits:**
- **Performance**: Dramatic reduction in database load and response times
- **Scalability**: Better handling of traffic spikes and concurrent requests
- **Reliability**: Protection against cache penetration and stampede scenarios
- **Flexibility**: Multiple cache patterns for different use cases
- **Observability**: Built-in metrics and monitoring capabilities

**Trade-offs:**
- **Complexity**: Additional infrastructure and code complexity
- **Consistency**: Potential for stale data and cache coherence issues
- **Memory usage**: Cache storage requirements
- **Operational overhead**: Cache warming, invalidation, and monitoring

**Best Practices:**
- Use appropriate TTL values based on data characteristics
- Implement proper cache invalidation strategies
- Monitor cache hit rates and performance metrics
- Use singleflight for expensive operations
- Implement circuit breakers for cache dependencies
- Consider data consistency requirements when choosing cache patterns

## References

- [Cache-Aside Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/cache-aside)
- [Redis Best Practices](https://redis.io/topics/memory-optimization)
- [Singleflight Package](https://pkg.go.dev/golang.org/x/sync/singleflight)
