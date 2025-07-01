# Redis Convention

## Status

`accepted`

## Context

Redis serves as a critical component for caching, session storage, rate limiting, and real-time features. Without proper conventions, Redis usage becomes fragmented, difficult to maintain, and prone to key collisions, memory leaks, and performance issues.

### Common Redis Anti-patterns

- **Scattered Key Management**: Keys defined across multiple files without coordination
- **Inconsistent Naming**: Mixed naming conventions leading to confusion
- **Memory Leaks**: Keys without TTL causing unbounded memory growth
- **Key Collisions**: Different features using the same key patterns
- **Poor Serialization**: Inefficient data encoding strategies
- **Missing Monitoring**: No visibility into Redis usage patterns

### Redis Use Cases in Our System

| Use Case | Pattern | TTL Strategy | Example Keys |
|----------|---------|--------------|--------------|
| **User Sessions** | `session:` | 24 hours | `session:user:123` |
| **API Caching** | `cache:api:` | 5-15 minutes | `cache:api:products:list:page:1` |
| **Rate Limiting** | `ratelimit:` | Window duration | `ratelimit:user:123:api:2023-01-01-14` |
| **Temporary Tokens** | `token:` | Token lifetime | `token:reset:abc123` |
| **Real-time Features** | `realtime:` | Event-based | `realtime:notifications:user:123` |
| **Distributed Locks** | `lock:` | Operation timeout | `lock:payment:order:456` |

## Decision

Implement a **centralized Redis management system** with the following architecture:

### Core Principles

1. **Namespace Isolation**: Hierarchical key naming with environment prefixes
2. **Repository Pattern**: Grouped Redis operations by domain
3. **Automatic TTL Management**: Default TTL policies for all key types
4. **Type Safety**: Structured serialization and deserialization
5. **Monitoring Integration**: Built-in metrics and observability
6. **Connection Management**: Optimized connection pooling and failover

## Implementation

### Redis Client Configuration

```go
package redis

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/redis/go-redis/v9"
    "github.com/prometheus/client_golang/prometheus"
)

// Config holds Redis configuration
type Config struct {
    Host            string        `env:"REDIS_HOST" default:"localhost"`
    Port            int           `env:"REDIS_PORT" default:"6379"`
    Password        string        `env:"REDIS_PASSWORD"`
    DB              int           `env:"REDIS_DB" default:"0"`
    MaxRetries      int           `env:"REDIS_MAX_RETRIES" default:"3"`
    DialTimeout     time.Duration `env:"REDIS_DIAL_TIMEOUT" default:"5s"`
    ReadTimeout     time.Duration `env:"REDIS_READ_TIMEOUT" default:"3s"`
    WriteTimeout    time.Duration `env:"REDIS_WRITE_TIMEOUT" default:"3s"`
    PoolSize        int           `env:"REDIS_POOL_SIZE" default:"10"`
    MinIdleConns    int           `env:"REDIS_MIN_IDLE_CONNS" default:"2"`
    Environment     string        `env:"ENVIRONMENT" default:"development"`
    KeyPrefix       string        `env:"REDIS_KEY_PREFIX"`
}

// Client wraps redis.Client with additional functionality
type Client struct {
    client    *redis.Client
    config    *Config
    keyPrefix string
    metrics   *Metrics
}

type Metrics struct {
    commandDuration *prometheus.HistogramVec
    commandTotal    *prometheus.CounterVec
    keyspaceSize    *prometheus.GaugeVec
}

func NewClient(config *Config) (*Client, error) {
    rdb := redis.NewClient(&redis.Options{
        Addr:         fmt.Sprintf("%s:%d", config.Host, config.Port),
        Password:     config.Password,
        DB:           config.DB,
        MaxRetries:   config.MaxRetries,
        DialTimeout:  config.DialTimeout,
        ReadTimeout:  config.ReadTimeout,
        WriteTimeout: config.WriteTimeout,
        PoolSize:     config.PoolSize,
        MinIdleConns: config.MinIdleConns,
    })
    
    // Test connection
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    
    if err := rdb.Ping(ctx).Err(); err != nil {
        return nil, fmt.Errorf("redis connection failed: %w", err)
    }
    
    keyPrefix := config.KeyPrefix
    if keyPrefix == "" {
        keyPrefix = config.Environment
    }
    
    client := &Client{
        client:    rdb,
        config:    config,
        keyPrefix: keyPrefix,
        metrics:   newMetrics(),
    }
    
    return client, nil
}

// Key generates a namespaced key
func (c *Client) Key(parts ...string) string {
    allParts := append([]string{c.keyPrefix}, parts...)
    return fmt.Sprintf("%s", strings.Join(allParts, ":"))
}

// instrumentedCmd wraps Redis commands with metrics
func (c *Client) instrumentedCmd(ctx context.Context, cmd string, fn func() error) error {
    start := time.Now()
    err := fn()
    duration := time.Since(start).Seconds()
    
    status := "success"
    if err != nil {
        status = "error"
    }
    
    c.metrics.commandDuration.WithLabelValues(cmd, status).Observe(duration)
    c.metrics.commandTotal.WithLabelValues(cmd, status).Inc()
    
    return err
}
```

### Base Redis Repository

```go
package redis

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
)

// Repository provides base Redis operations with type safety
type Repository struct {
    client    *Client
    namespace string
    defaultTTL time.Duration
}

func NewRepository(client *Client, namespace string, defaultTTL time.Duration) *Repository {
    return &Repository{
        client:     client,
        namespace:  namespace,
        defaultTTL: defaultTTL,
    }
}

// Key generates a namespaced key for this repository
func (r *Repository) Key(parts ...string) string {
    allParts := append([]string{r.namespace}, parts...)
    return r.client.Key(allParts...)
}

// Set stores a value with automatic JSON serialization and TTL
func (r *Repository) Set(ctx context.Context, key string, value interface{}, ttl ...time.Duration) error {
    return r.client.instrumentedCmd(ctx, "SET", func() error {
        data, err := json.Marshal(value)
        if err != nil {
            return fmt.Errorf("json marshal failed: %w", err)
        }
        
        actualTTL := r.defaultTTL
        if len(ttl) > 0 {
            actualTTL = ttl[0]
        }
        
        return r.client.client.Set(ctx, r.Key(key), data, actualTTL).Err()
    })
}

// Get retrieves and unmarshals a value
func (r *Repository) Get(ctx context.Context, key string, dest interface{}) error {
    return r.client.instrumentedCmd(ctx, "GET", func() error {
        data, err := r.client.client.Get(ctx, r.Key(key)).Result()
        if err != nil {
            return err
        }
        
        return json.Unmarshal([]byte(data), dest)
    })
}

// Delete removes a key
func (r *Repository) Delete(ctx context.Context, keys ...string) error {
    return r.client.instrumentedCmd(ctx, "DEL", func() error {
        fullKeys := make([]string, len(keys))
        for i, key := range keys {
            fullKeys[i] = r.Key(key)
        }
        return r.client.client.Del(ctx, fullKeys...).Err()
    })
}

// Exists checks if key exists
func (r *Repository) Exists(ctx context.Context, key string) (bool, error) {
    var result bool
    err := r.client.instrumentedCmd(ctx, "EXISTS", func() error {
        count, err := r.client.client.Exists(ctx, r.Key(key)).Result()
        result = count > 0
        return err
    })
    return result, err
}

// SetHash stores a hash field
func (r *Repository) SetHash(ctx context.Context, key, field string, value interface{}) error {
    return r.client.instrumentedCmd(ctx, "HSET", func() error {
        data, err := json.Marshal(value)
        if err != nil {
            return err
        }
        return r.client.client.HSet(ctx, r.Key(key), field, data).Err()
    })
}

// GetHash retrieves a hash field
func (r *Repository) GetHash(ctx context.Context, key, field string, dest interface{}) error {
    return r.client.instrumentedCmd(ctx, "HGET", func() error {
        data, err := r.client.client.HGet(ctx, r.Key(key), field).Result()
        if err != nil {
            return err
        }
        return json.Unmarshal([]byte(data), dest)
    })
}

// Increment atomically increments a counter
func (r *Repository) Increment(ctx context.Context, key string, delta ...int64) (int64, error) {
    var result int64
    err := r.client.instrumentedCmd(ctx, "INCR", func() error {
        actualDelta := int64(1)
        if len(delta) > 0 {
            actualDelta = delta[0]
        }
        
        var err error
        if actualDelta == 1 {
            result, err = r.client.client.Incr(ctx, r.Key(key)).Result()
        } else {
            result, err = r.client.client.IncrBy(ctx, r.Key(key), actualDelta).Result()
        }
        return err
    })
    return result, err
}

// SetWithLock implements distributed locking
func (r *Repository) SetWithLock(ctx context.Context, lockKey, dataKey string, 
    value interface{}, lockTTL time.Duration) error {
    
    lockFullKey := r.Key("lock", lockKey)
    
    // Acquire lock
    acquired, err := r.client.client.SetNX(ctx, lockFullKey, "locked", lockTTL).Result()
    if err != nil {
        return fmt.Errorf("lock acquisition failed: %w", err)
    }
    
    if !acquired {
        return fmt.Errorf("could not acquire lock for key: %s", lockKey)
    }
    
    defer func() {
        // Release lock
        r.client.client.Del(ctx, lockFullKey)
    }()
    
    // Set data while holding lock
    return r.Set(ctx, dataKey, value)
}
```

### Domain-Specific Redis Repositories

```go
package cache

import (
    "context"
    "fmt"
    "time"
    
    "github.com/your-org/app/internal/redis"
)

// UserCache handles user-related caching
type UserCache struct {
    *redis.Repository
}

func NewUserCache(client *redis.Client) *UserCache {
    return &UserCache{
        Repository: redis.NewRepository(client, "user", 30*time.Minute),
    }
}

// CacheUser stores user data
func (uc *UserCache) CacheUser(ctx context.Context, userID int64, user *User) error {
    return uc.Set(ctx, fmt.Sprintf("profile:%d", userID), user)
}

// GetUser retrieves cached user data
func (uc *UserCache) GetUser(ctx context.Context, userID int64) (*User, error) {
    var user User
    err := uc.Get(ctx, fmt.Sprintf("profile:%d", userID), &user)
    if err != nil {
        return nil, err
    }
    return &user, nil
}

// CacheUserSessions stores active sessions for a user
func (uc *UserCache) CacheUserSessions(ctx context.Context, userID int64, sessions []Session) error {
    return uc.Set(ctx, fmt.Sprintf("sessions:%d", userID), sessions, 24*time.Hour)
}

// InvalidateUser removes user from cache
func (uc *UserCache) InvalidateUser(ctx context.Context, userID int64) error {
    return uc.Delete(ctx, 
        fmt.Sprintf("profile:%d", userID),
        fmt.Sprintf("sessions:%d", userID),
        fmt.Sprintf("preferences:%d", userID),
    )
}

// SetUserPreference stores a user preference
func (uc *UserCache) SetUserPreference(ctx context.Context, userID int64, 
    key string, value interface{}) error {
    
    return uc.SetHash(ctx, fmt.Sprintf("preferences:%d", userID), key, value)
}

// GetUserPreference retrieves a user preference
func (uc *UserCache) GetUserPreference(ctx context.Context, userID int64, 
    key string, dest interface{}) error {
    
    return uc.GetHash(ctx, fmt.Sprintf("preferences:%d", userID), key, dest)
}
```

```go
package cache

import (
    "context"
    "crypto/sha256"
    "fmt"
    "time"
)

// APICache handles API response caching
type APICache struct {
    *redis.Repository
}

func NewAPICache(client *redis.Client) *APICache {
    return &APICache{
        Repository: redis.NewRepository(client, "api", 10*time.Minute),
    }
}

// CacheResponse stores API response with automatic key generation
func (ac *APICache) CacheResponse(ctx context.Context, endpoint string, 
    params map[string]string, response interface{}, ttl ...time.Duration) error {
    
    key := ac.generateCacheKey(endpoint, params)
    return ac.Set(ctx, key, response, ttl...)
}

// GetResponse retrieves cached API response
func (ac *APICache) GetResponse(ctx context.Context, endpoint string, 
    params map[string]string, dest interface{}) error {
    
    key := ac.generateCacheKey(endpoint, params)
    return ac.Get(ctx, key, dest)
}

// generateCacheKey creates a deterministic cache key from endpoint and parameters
func (ac *APICache) generateCacheKey(endpoint string, params map[string]string) string {
    hash := sha256.New()
    hash.Write([]byte(endpoint))
    
    // Sort parameters for consistent key generation
    keys := make([]string, 0, len(params))
    for k := range params {
        keys = append(keys, k)
    }
    sort.Strings(keys)
    
    for _, k := range keys {
        hash.Write([]byte(k + "=" + params[k]))
    }
    
    return fmt.Sprintf("response:%x", hash.Sum(nil)[:8])
}

// InvalidateEndpoint removes all cached responses for an endpoint
func (ac *APICache) InvalidateEndpoint(ctx context.Context, endpoint string) error {
    pattern := ac.Key("response:*")
    
    keys, err := ac.client.client.Keys(ctx, pattern).Result()
    if err != nil {
        return err
    }
    
    if len(keys) > 0 {
        return ac.client.client.Del(ctx, keys...).Err()
    }
    
    return nil
}
```

```go
package ratelimit

import (
    "context"
    "fmt"
    "time"
    
    "github.com/your-org/app/internal/redis"
)

// RateLimiter implements sliding window rate limiting
type RateLimiter struct {
    *redis.Repository
}

func NewRateLimiter(client *redis.Client) *RateLimiter {
    return &RateLimiter{
        Repository: redis.NewRepository(client, "ratelimit", time.Hour),
    }
}

// CheckLimit verifies if operation is within rate limit
func (rl *RateLimiter) CheckLimit(ctx context.Context, identifier string, 
    limit int64, window time.Duration) (bool, int64, error) {
    
    now := time.Now()
    windowStart := now.Add(-window)
    
    key := rl.generateRateLimitKey(identifier, window)
    
    // Remove old entries and add current request
    pipe := rl.client.client.Pipeline()
    
    // Remove entries outside the window
    pipe.ZRemRangeByScore(ctx, key, "0", fmt.Sprintf("%d", windowStart.UnixNano()))
    
    // Add current request
    pipe.ZAdd(ctx, key, redis.Z{
        Score:  float64(now.UnixNano()),
        Member: now.UnixNano(),
    })
    
    // Count current requests in window
    countCmd := pipe.ZCard(ctx, key)
    
    // Set expiry
    pipe.Expire(ctx, key, window*2)
    
    _, err := pipe.Exec(ctx)
    if err != nil {
        return false, 0, err
    }
    
    currentCount := countCmd.Val()
    
    return currentCount <= limit, currentCount, nil
}

func (rl *RateLimiter) generateRateLimitKey(identifier string, window time.Duration) string {
    return fmt.Sprintf("sliding:%s:%s", identifier, window.String())
}

// TokenBucket implements token bucket rate limiting
func (rl *RateLimiter) TokenBucket(ctx context.Context, bucketKey string, 
    capacity, refillRate int64, refillInterval time.Duration) (bool, error) {
    
    key := rl.Key("bucket", bucketKey)
    
    now := time.Now()
    
    // Lua script for atomic token bucket operation
    script := `
        local key = KEYS[1]
        local capacity = tonumber(ARGV[1])
        local refill_rate = tonumber(ARGV[2])
        local refill_interval_ms = tonumber(ARGV[3])
        local now = tonumber(ARGV[4])
        
        local bucket = redis.call('HMGET', key, 'tokens', 'last_refill')
        local tokens = tonumber(bucket[1]) or capacity
        local last_refill = tonumber(bucket[2]) or now
        
        -- Calculate tokens to add based on time elapsed
        local time_elapsed = now - last_refill
        local intervals_passed = math.floor(time_elapsed / refill_interval_ms)
        local tokens_to_add = intervals_passed * refill_rate
        
        tokens = math.min(capacity, tokens + tokens_to_add)
        
        if tokens >= 1 then
            tokens = tokens - 1
            redis.call('HMSET', key, 'tokens', tokens, 'last_refill', now)
            redis.call('EXPIRE', key, 3600)
            return 1
        else
            redis.call('HMSET', key, 'tokens', tokens, 'last_refill', now)
            redis.call('EXPIRE', key, 3600)
            return 0
        end
    `
    
    result, err := rl.client.client.Eval(ctx, script, []string{key}, 
        capacity, refillRate, refillInterval.Milliseconds(), now.UnixMilli()).Result()
    
    if err != nil {
        return false, err
    }
    
    return result.(int64) == 1, nil
}
```

### Session Management

```go
package session

import (
    "context"
    "crypto/rand"
    "encoding/hex"
    "fmt"
    "time"
    
    "github.com/your-org/app/internal/redis"
)

// SessionManager handles user sessions
type SessionManager struct {
    *redis.Repository
}

type Session struct {
    ID        string    `json:"id"`
    UserID    int64     `json:"user_id"`
    CreatedAt time.Time `json:"created_at"`
    ExpiresAt time.Time `json:"expires_at"`
    IPAddress string    `json:"ip_address"`
    UserAgent string    `json:"user_agent"`
    Data      map[string]interface{} `json:"data"`
}

func NewSessionManager(client *redis.Client) *SessionManager {
    return &SessionManager{
        Repository: redis.NewRepository(client, "session", 24*time.Hour),
    }
}

// CreateSession creates a new user session
func (sm *SessionManager) CreateSession(ctx context.Context, userID int64, 
    ipAddress, userAgent string, ttl time.Duration) (*Session, error) {
    
    sessionID, err := generateSessionID()
    if err != nil {
        return nil, err
    }
    
    now := time.Now()
    session := &Session{
        ID:        sessionID,
        UserID:    userID,
        CreatedAt: now,
        ExpiresAt: now.Add(ttl),
        IPAddress: ipAddress,
        UserAgent: userAgent,
        Data:      make(map[string]interface{}),
    }
    
    // Store session
    if err := sm.Set(ctx, sessionID, session, ttl); err != nil {
        return nil, err
    }
    
    // Add to user's active sessions
    if err := sm.addToUserSessions(ctx, userID, sessionID); err != nil {
        return nil, err
    }
    
    return session, nil
}

// GetSession retrieves a session by ID
func (sm *SessionManager) GetSession(ctx context.Context, sessionID string) (*Session, error) {
    var session Session
    err := sm.Get(ctx, sessionID, &session)
    if err != nil {
        return nil, err
    }
    
    // Check if session is expired
    if time.Now().After(session.ExpiresAt) {
        sm.DeleteSession(ctx, sessionID)
        return nil, fmt.Errorf("session expired")
    }
    
    return &session, nil
}

// UpdateSessionData updates session data
func (sm *SessionManager) UpdateSessionData(ctx context.Context, sessionID string, 
    data map[string]interface{}) error {
    
    session, err := sm.GetSession(ctx, sessionID)
    if err != nil {
        return err
    }
    
    for k, v := range data {
        session.Data[k] = v
    }
    
    return sm.Set(ctx, sessionID, session)
}

// DeleteSession removes a session
func (sm *SessionManager) DeleteSession(ctx context.Context, sessionID string) error {
    // Get session to find user ID
    session, err := sm.GetSession(ctx, sessionID)
    if err != nil {
        return err
    }
    
    // Remove from user's active sessions
    sm.removeFromUserSessions(ctx, session.UserID, sessionID)
    
    // Delete session
    return sm.Delete(ctx, sessionID)
}

// GetUserSessions retrieves all active sessions for a user
func (sm *SessionManager) GetUserSessions(ctx context.Context, userID int64) ([]Session, error) {
    userSessionsKey := fmt.Sprintf("user:%d", userID)
    
    sessionIDs, err := sm.client.client.SMembers(ctx, sm.Key(userSessionsKey)).Result()
    if err != nil {
        return nil, err
    }
    
    sessions := make([]Session, 0, len(sessionIDs))
    for _, sessionID := range sessionIDs {
        session, err := sm.GetSession(ctx, sessionID)
        if err != nil {
            // Remove invalid session from set
            sm.client.client.SRem(ctx, sm.Key(userSessionsKey), sessionID)
            continue
        }
        sessions = append(sessions, *session)
    }
    
    return sessions, nil
}

// InvalidateAllUserSessions removes all sessions for a user
func (sm *SessionManager) InvalidateAllUserSessions(ctx context.Context, userID int64) error {
    sessions, err := sm.GetUserSessions(ctx, userID)
    if err != nil {
        return err
    }
    
    sessionIDs := make([]string, len(sessions))
    for i, session := range sessions {
        sessionIDs[i] = session.ID
    }
    
    if len(sessionIDs) > 0 {
        if err := sm.Delete(ctx, sessionIDs...); err != nil {
            return err
        }
    }
    
    // Clear user sessions set
    userSessionsKey := fmt.Sprintf("user:%d", userID)
    return sm.client.client.Del(ctx, sm.Key(userSessionsKey)).Err()
}

func (sm *SessionManager) addToUserSessions(ctx context.Context, userID int64, sessionID string) error {
    userSessionsKey := fmt.Sprintf("user:%d", userID)
    return sm.client.client.SAdd(ctx, sm.Key(userSessionsKey), sessionID).Err()
}

func (sm *SessionManager) removeFromUserSessions(ctx context.Context, userID int64, sessionID string) error {
    userSessionsKey := fmt.Sprintf("user:%d", userID)
    return sm.client.client.SRem(ctx, sm.Key(userSessionsKey), sessionID).Err()
}

func generateSessionID() (string, error) {
    bytes := make([]byte, 32)
    if _, err := rand.Read(bytes); err != nil {
        return "", err
    }
    return hex.EncodeToString(bytes), nil
}
```

### Monitoring and Health Checks

```go
package monitoring

import (
    "context"
    "fmt"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
)

// RedisHealthChecker monitors Redis health
type RedisHealthChecker struct {
    client  *redis.Client
    metrics *HealthMetrics
}

type HealthMetrics struct {
    connectionStatus prometheus.Gauge
    memoryUsage      prometheus.Gauge
    keyspaceKeys     *prometheus.GaugeVec
    commandLatency   *prometheus.HistogramVec
}

func NewRedisHealthChecker(client *redis.Client) *RedisHealthChecker {
    return &RedisHealthChecker{
        client:  client,
        metrics: newHealthMetrics(),
    }
}

// CheckHealth performs comprehensive Redis health check
func (rhc *RedisHealthChecker) CheckHealth(ctx context.Context) error {
    start := time.Now()
    
    // Test basic connectivity
    if err := rhc.client.client.Ping(ctx).Err(); err != nil {
        rhc.metrics.connectionStatus.Set(0)
        return fmt.Errorf("redis ping failed: %w", err)
    }
    
    rhc.metrics.connectionStatus.Set(1)
    
    // Get Redis info
    info, err := rhc.client.client.Info(ctx, "memory", "keyspace").Result()
    if err != nil {
        return fmt.Errorf("redis info failed: %w", err)
    }
    
    // Parse and update metrics
    rhc.updateMetricsFromInfo(info)
    
    // Record latency
    latency := time.Since(start).Seconds()
    rhc.metrics.commandLatency.WithLabelValues("health_check").Observe(latency)
    
    return nil
}

// CleanupExpiredKeys removes keys that should have expired
func (rhc *RedisHealthChecker) CleanupExpiredKeys(ctx context.Context, pattern string) error {
    keys, err := rhc.client.client.Keys(ctx, pattern).Result()
    if err != nil {
        return err
    }
    
    for _, key := range keys {
        ttl, err := rhc.client.client.TTL(ctx, key).Result()
        if err != nil {
            continue
        }
        
        // Remove keys that should have expired
        if ttl == -1 { // No expiry set
            rhc.client.client.Del(ctx, key)
        }
    }
    
    return nil
}

// GetKeyspaceStatistics returns statistics about key usage
func (rhc *RedisHealthChecker) GetKeyspaceStatistics(ctx context.Context) (map[string]int64, error) {
    stats := make(map[string]int64)
    
    // Get all keys by pattern
    patterns := []string{
        rhc.client.Key("user:*"),
        rhc.client.Key("session:*"),
        rhc.client.Key("cache:*"),
        rhc.client.Key("ratelimit:*"),
    }
    
    for _, pattern := range patterns {
        keys, err := rhc.client.client.Keys(ctx, pattern).Result()
        if err != nil {
            continue
        }
        
        namespace := pattern[:strings.LastIndex(pattern, ":")]
        stats[namespace] = int64(len(keys))
    }
    
    return stats, nil
}
```

### Configuration Management

```go
package config

import (
    "context"
    "time"
    
    "github.com/your-org/app/internal/redis"
)

// RedisManager coordinates all Redis repositories
type RedisManager struct {
    client        *redis.Client
    UserCache     *cache.UserCache
    APICache      *cache.APICache
    RateLimiter   *ratelimit.RateLimiter
    SessionMgr    *session.SessionManager
    healthChecker *monitoring.RedisHealthChecker
}

func NewRedisManager(config *redis.Config) (*RedisManager, error) {
    client, err := redis.NewClient(config)
    if err != nil {
        return nil, err
    }
    
    manager := &RedisManager{
        client:        client,
        UserCache:     cache.NewUserCache(client),
        APICache:      cache.NewAPICache(client),
        RateLimiter:   ratelimit.NewRateLimiter(client),
        SessionMgr:    session.NewSessionManager(client),
        healthChecker: monitoring.NewRedisHealthChecker(client),
    }
    
    return manager, nil
}

// HealthCheck performs overall Redis health check
func (rm *RedisManager) HealthCheck(ctx context.Context) error {
    return rm.healthChecker.CheckHealth(ctx)
}

// Cleanup performs maintenance tasks
func (rm *RedisManager) Cleanup(ctx context.Context) error {
    // Clean up expired sessions
    if err := rm.healthChecker.CleanupExpiredKeys(ctx, rm.client.Key("session:*")); err != nil {
        return err
    }
    
    // Clean up expired rate limit entries
    if err := rm.healthChecker.CleanupExpiredKeys(ctx, rm.client.Key("ratelimit:*")); err != nil {
        return err
    }
    
    return nil
}

// Close closes all Redis connections
func (rm *RedisManager) Close() error {
    return rm.client.client.Close()
}
```

## Consequences

### Positive

- **Organized Structure**: Clear separation of Redis usage by domain
- **Type Safety**: Structured serialization prevents data corruption
- **Automatic TTL**: Prevents memory leaks with default expiration policies
- **Monitoring**: Built-in metrics and health checking
- **Testability**: Repository pattern enables easy mocking and testing
- **Performance**: Connection pooling and instrumented operations
- **Consistency**: Standardized key naming and operation patterns

### Negative

- **Complexity**: More sophisticated setup compared to direct Redis usage
- **Performance Overhead**: JSON serialization and instrumentation add latency
- **Memory Usage**: Additional abstraction layers consume more memory
- **Learning Curve**: Team must understand the repository patterns

### Mitigations

- **Documentation**: Comprehensive examples and usage patterns
- **Performance Monitoring**: Track operation latency and optimize bottlenecks
- **Gradual Migration**: Migrate existing Redis usage incrementally
- **Training**: Team education on Redis best practices and patterns

## Related Patterns

- **[Rate Limiting](018-rate-limit.md)**: Redis-based rate limiting implementation
- **[Docker Testing](004-dockertest.md)**: Testing Redis operations in isolation
- **[Logging](013-logging.md)**: Structured logging for Redis operations
- **[Independent Schema](022-independent-schema.md)**: Redis schema versioning strategies
