# Redis Naming

## Status
Accepted

## Context
Redis key naming conventions are crucial for maintaining organized, scalable, and conflict-free data structures. Without proper naming standards, Redis instances can become difficult to manage, debug, and scale as applications grow.

## Decision
We will use a hierarchical naming convention based on `entity:id:attribute` pattern with data type prefixes and environment namespacing to ensure clear organization, prevent key conflicts, and enable efficient operations.

## Rationale

### Benefits
- **Organization**: Clear hierarchical structure for easy navigation
- **Conflict Prevention**: Avoid key collisions across different data types
- **Debugging**: Easily identify key purpose and data type
- **Scaling**: Support multiple environments and applications
- **Maintenance**: Simplified key management and cleanup operations

### Key Structure
```
[environment]:[application]:[datatype]:[entity]:[id]:[attribute]
```

## Implementation

### Base Naming Convention

```go
package redis

import (
	"fmt"
	"strings"
	"time"
)

// KeyBuilder provides methods for consistent Redis key construction
type KeyBuilder struct {
	environment string
	application string
	separator   string
}

func NewKeyBuilder(environment, application string) *KeyBuilder {
	return &KeyBuilder{
		environment: environment,
		application: application,
		separator:   ":",
	}
}

// String builds a string key
func (kb *KeyBuilder) String(entity, id, attribute string) string {
	return kb.buildKey("str", entity, id, attribute)
}

// Hash builds a hash key
func (kb *KeyBuilder) Hash(entity, id string) string {
	return kb.buildKey("hash", entity, id, "")
}

// List builds a list key
func (kb *KeyBuilder) List(entity, id, attribute string) string {
	return kb.buildKey("list", entity, id, attribute)
}

// Set builds a set key
func (kb *KeyBuilder) Set(entity, id, attribute string) string {
	return kb.buildKey("set", entity, id, attribute)
}

// ZSet builds a sorted set key
func (kb *KeyBuilder) ZSet(entity, id, attribute string) string {
	return kb.buildKey("zset", entity, id, attribute)
}

// Stream builds a stream key
func (kb *KeyBuilder) Stream(entity, id, attribute string) string {
	return kb.buildKey("stream", entity, id, attribute)
}

// HyperLogLog builds a HyperLogLog key
func (kb *KeyBuilder) HyperLogLog(entity, id, attribute string) string {
	return kb.buildKey("hll", entity, id, attribute)
}

// Bitmap builds a bitmap key
func (kb *KeyBuilder) Bitmap(entity, id, attribute string) string {
	return kb.buildKey("bitmap", entity, id, attribute)
}

// buildKey constructs the complete key
func (kb *KeyBuilder) buildKey(dataType, entity, id, attribute string) string {
	parts := []string{kb.environment, kb.application, dataType, entity}
	
	if id != "" {
		parts = append(parts, id)
	}
	
	if attribute != "" {
		parts = append(parts, attribute)
	}
	
	return strings.Join(parts, kb.separator)
}

// Temporary key with TTL suffix
func (kb *KeyBuilder) Temporary(dataType, entity, id, attribute string, ttl time.Duration) string {
	baseKey := kb.buildKey(dataType, entity, id, attribute)
	return fmt.Sprintf("%s:tmp:%d", baseKey, ttl.Seconds())
}

// Session key
func (kb *KeyBuilder) Session(sessionID string) string {
	return kb.buildKey("hash", "session", sessionID, "")
}

// Cache key
func (kb *KeyBuilder) Cache(entity, id string) string {
	return kb.buildKey("str", "cache", entity, id)
}

// Lock key
func (kb *KeyBuilder) Lock(resource string) string {
	return kb.buildKey("str", "lock", resource, "")
}

// Counter key
func (kb *KeyBuilder) Counter(entity, id, metric string) string {
	return kb.buildKey("str", "counter", entity, fmt.Sprintf("%s:%s", id, metric))
}

// Queue key
func (kb *KeyBuilder) Queue(queueName string) string {
	return kb.buildKey("list", "queue", queueName, "")
}

// PubSub channel key
func (kb *KeyBuilder) Channel(entity, event string) string {
	return kb.buildKey("channel", entity, event, "")
}
```

### Specific Use Case Implementations

```go
package models

import (
	"encoding/json"
	"fmt"
	"strconv"
	"time"
	"your-app/redis"
)

// UserCache handles user-related Redis operations
type UserCache struct {
	client     redis.Client
	keyBuilder *redis.KeyBuilder
}

func NewUserCache(client redis.Client, keyBuilder *redis.KeyBuilder) *UserCache {
	return &UserCache{
		client:     client,
		keyBuilder: keyBuilder,
	}
}

// User data operations
func (uc *UserCache) SetUser(userID string, user *User) error {
	key := uc.keyBuilder.Hash("user", userID)
	
	userData := map[string]interface{}{
		"id":         user.ID,
		"email":      user.Email,
		"name":       user.Name,
		"created_at": user.CreatedAt.Unix(),
		"updated_at": user.UpdatedAt.Unix(),
	}
	
	return uc.client.HMSet(key, userData).Err()
}

func (uc *UserCache) GetUser(userID string) (*User, error) {
	key := uc.keyBuilder.Hash("user", userID)
	
	result := uc.client.HGetAll(key)
	if result.Err() != nil {
		return nil, result.Err()
	}
	
	data := result.Val()
	if len(data) == 0 {
		return nil, fmt.Errorf("user not found")
	}
	
	user := &User{
		ID:    data["id"],
		Email: data["email"],
		Name:  data["name"],
	}
	
	if createdAt, err := strconv.ParseInt(data["created_at"], 10, 64); err == nil {
		user.CreatedAt = time.Unix(createdAt, 0)
	}
	
	if updatedAt, err := strconv.ParseInt(data["updated_at"], 10, 64); err == nil {
		user.UpdatedAt = time.Unix(updatedAt, 0)
	}
	
	return user, nil
}

// User session operations
func (uc *UserCache) SetUserSession(userID, sessionID string, sessionData *SessionData) error {
	key := uc.keyBuilder.Hash("user", userID, "sessions")
	
	data, err := json.Marshal(sessionData)
	if err != nil {
		return err
	}
	
	return uc.client.HSet(key, sessionID, string(data)).Err()
}

func (uc *UserCache) GetUserSessions(userID string) (map[string]*SessionData, error) {
	key := uc.keyBuilder.Hash("user", userID, "sessions")
	
	result := uc.client.HGetAll(key)
	if result.Err() != nil {
		return nil, result.Err()
	}
	
	sessions := make(map[string]*SessionData)
	for sessionID, data := range result.Val() {
		var sessionData SessionData
		if err := json.Unmarshal([]byte(data), &sessionData); err == nil {
			sessions[sessionID] = &sessionData
		}
	}
	
	return sessions, nil
}

// User preferences
func (uc *UserCache) SetUserPreference(userID, key, value string) error {
	redisKey := uc.keyBuilder.Hash("user", userID, "preferences")
	return uc.client.HSet(redisKey, key, value).Err()
}

func (uc *UserCache) GetUserPreferences(userID string) (map[string]string, error) {
	key := uc.keyBuilder.Hash("user", userID, "preferences")
	return uc.client.HGetAll(key).Result()
}

// User activity tracking
func (uc *UserCache) TrackUserActivity(userID, activity string) error {
	key := uc.keyBuilder.ZSet("user", userID, "activity")
	score := float64(time.Now().Unix())
	return uc.client.ZAdd(key, redis.Z{Score: score, Member: activity}).Err()
}

func (uc *UserCache) GetRecentActivity(userID string, limit int64) ([]string, error) {
	key := uc.keyBuilder.ZSet("user", userID, "activity")
	return uc.client.ZRevRange(key, 0, limit-1).Result()
}

// User counters
func (uc *UserCache) IncrementUserMetric(userID, metric string) error {
	key := uc.keyBuilder.Counter("user", userID, metric)
	return uc.client.Incr(key).Err()
}

func (uc *UserCache) GetUserMetric(userID, metric string) (int64, error) {
	key := uc.keyBuilder.Counter("user", userID, metric)
	return uc.client.Get(key).Int64()
}

// User models
type User struct {
	ID        string    `json:"id"`
	Email     string    `json:"email"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type SessionData struct {
	DeviceID  string    `json:"device_id"`
	IP        string    `json:"ip"`
	UserAgent string    `json:"user_agent"`
	CreatedAt time.Time `json:"created_at"`
	LastUsed  time.Time `json:"last_used"`
}
```

### Cache and Session Management

```go
package cache

import (
	"encoding/json"
	"time"
	"your-app/redis"
)

// CacheManager handles general caching operations
type CacheManager struct {
	client     redis.Client
	keyBuilder *redis.KeyBuilder
	defaultTTL time.Duration
}

func NewCacheManager(client redis.Client, keyBuilder *redis.KeyBuilder) *CacheManager {
	return &CacheManager{
		client:     client,
		keyBuilder: keyBuilder,
		defaultTTL: 1 * time.Hour,
	}
}

// Generic cache operations
func (cm *CacheManager) Set(entity, id string, data interface{}, ttl time.Duration) error {
	key := cm.keyBuilder.Cache(entity, id)
	
	jsonData, err := json.Marshal(data)
	if err != nil {
		return err
	}
	
	if ttl == 0 {
		ttl = cm.defaultTTL
	}
	
	return cm.client.Set(key, jsonData, ttl).Err()
}

func (cm *CacheManager) Get(entity, id string, dest interface{}) error {
	key := cm.keyBuilder.Cache(entity, id)
	
	result := cm.client.Get(key)
	if result.Err() != nil {
		return result.Err()
	}
	
	return json.Unmarshal([]byte(result.Val()), dest)
}

func (cm *CacheManager) Delete(entity, id string) error {
	key := cm.keyBuilder.Cache(entity, id)
	return cm.client.Del(key).Err()
}

// Pattern-based operations
func (cm *CacheManager) DeletePattern(pattern string) error {
	fullPattern := fmt.Sprintf("%s:%s:*", cm.keyBuilder.environment, pattern)
	
	keys := cm.client.Keys(fullPattern)
	if keys.Err() != nil {
		return keys.Err()
	}
	
	if len(keys.Val()) > 0 {
		return cm.client.Del(keys.Val()...).Err()
	}
	
	return nil
}

// Session operations
func (cm *CacheManager) SetSession(sessionID string, data interface{}, ttl time.Duration) error {
	key := cm.keyBuilder.Session(sessionID)
	
	jsonData, err := json.Marshal(data)
	if err != nil {
		return err
	}
	
	return cm.client.Set(key, jsonData, ttl).Err()
}

func (cm *CacheManager) GetSession(sessionID string, dest interface{}) error {
	key := cm.keyBuilder.Session(sessionID)
	
	result := cm.client.Get(key)
	if result.Err() != nil {
		return result.Err()
	}
	
	return json.Unmarshal([]byte(result.Val()), dest)
}

func (cm *CacheManager) DeleteSession(sessionID string) error {
	key := cm.keyBuilder.Session(sessionID)
	return cm.client.Del(key).Err()
}
```

### Advanced Patterns

```go
package patterns

import (
	"fmt"
	"time"
	"your-app/redis"
)

// DistributedLock implements distributed locking
type DistributedLock struct {
	client     redis.Client
	keyBuilder *redis.KeyBuilder
}

func NewDistributedLock(client redis.Client, keyBuilder *redis.KeyBuilder) *DistributedLock {
	return &DistributedLock{
		client:     client,
		keyBuilder: keyBuilder,
	}
}

func (dl *DistributedLock) Acquire(resource string, ttl time.Duration) (bool, error) {
	key := dl.keyBuilder.Lock(resource)
	result := dl.client.SetNX(key, "locked", ttl)
	return result.Val(), result.Err()
}

func (dl *DistributedLock) Release(resource string) error {
	key := dl.keyBuilder.Lock(resource)
	return dl.client.Del(key).Err()
}

// RateLimiter implements rate limiting using sliding window
type RateLimiter struct {
	client     redis.Client
	keyBuilder *redis.KeyBuilder
}

func NewRateLimiter(client redis.Client, keyBuilder *redis.KeyBuilder) *RateLimiter {
	return &RateLimiter{
		client:     client,
		keyBuilder: keyBuilder,
	}
}

func (rl *RateLimiter) IsAllowed(userID string, limit int, window time.Duration) (bool, error) {
	key := rl.keyBuilder.ZSet("ratelimit", userID, "requests")
	now := time.Now()
	windowStart := now.Add(-window)
	
	// Remove old entries
	rl.client.ZRemRangeByScore(key, "0", fmt.Sprintf("%f", float64(windowStart.Unix())))
	
	// Count current requests
	count := rl.client.ZCount(key, fmt.Sprintf("%f", float64(windowStart.Unix())), "+inf")
	if count.Err() != nil {
		return false, count.Err()
	}
	
	if count.Val() >= int64(limit) {
		return false, nil
	}
	
	// Add current request
	rl.client.ZAdd(key, redis.Z{Score: float64(now.Unix()), Member: now.UnixNano()})
	rl.client.Expire(key, window)
	
	return true, nil
}

// PubSubManager handles pub/sub operations
type PubSubManager struct {
	client     redis.Client
	keyBuilder *redis.KeyBuilder
}

func NewPubSubManager(client redis.Client, keyBuilder *redis.KeyBuilder) *PubSubManager {
	return &PubSubManager{
		client:     client,
		keyBuilder: keyBuilder,
	}
}

func (ps *PubSubManager) Publish(entity, event string, data interface{}) error {
	channel := ps.keyBuilder.Channel(entity, event)
	
	jsonData, err := json.Marshal(data)
	if err != nil {
		return err
	}
	
	return ps.client.Publish(channel, jsonData).Err()
}

func (ps *PubSubManager) Subscribe(entity, event string) *redis.PubSub {
	channel := ps.keyBuilder.Channel(entity, event)
	return ps.client.Subscribe(channel)
}
```

## Best Practices

### 1. Naming Conventions

#### Environment Prefixing
```go
// Production
prod:myapp:hash:user:123

// Development
dev:myapp:hash:user:123

// Testing
test:myapp:hash:user:123
```

#### Data Type Prefixes
- `str:` - String values
- `hash:` - Hash maps
- `list:` - Lists
- `set:` - Sets
- `zset:` - Sorted sets
- `stream:` - Streams
- `hll:` - HyperLogLog
- `bitmap:` - Bitmaps

#### Entity Patterns
```go
// User data
user:123:profile          // User profile hash
user:123:sessions         // Active sessions hash
user:123:preferences      // User preferences hash
user:123:activity         // Activity sorted set
user:123:followers        // Followers set
user:123:following        // Following set

// Product data
product:456:details       // Product details hash
product:456:reviews       // Product reviews list
product:456:ratings       // Ratings sorted set
product:456:inventory     // Inventory counter

// Application data
app:counters:daily        // Daily counters hash
app:metrics:performance   // Performance metrics sorted set
app:config:features       // Feature flags hash
```

### 2. TTL Management
```go
// Set appropriate TTLs for different data types
func (kb *KeyBuilder) SetTTLs() {
	// Session data - 24 hours
	kb.client.Expire(kb.Session("session_id"), 24*time.Hour)
	
	// Cache data - 1 hour
	kb.client.Expire(kb.Cache("entity", "id"), 1*time.Hour)
	
	// Temporary data - 5 minutes
	kb.client.Expire(kb.Temporary("str", "temp", "data", "", 5*time.Minute), 5*time.Minute)
	
	// Rate limiting - sliding window
	kb.client.Expire(kb.ZSet("ratelimit", "user", "requests"), 1*time.Hour)
}
```

### 3. Memory Optimization
```go
// Use appropriate data structures
func (kb *KeyBuilder) OptimizeMemory() {
	// Use hashes for small collections
	kb.Hash("user", "123") // Better than multiple strings
	
	// Use sorted sets for time-series data
	kb.ZSet("metrics", "cpu", "usage") // Score as timestamp
	
	// Use HyperLogLog for unique counts
	kb.HyperLogLog("analytics", "page", "unique_visitors")
	
	// Use bitmaps for boolean flags
	kb.Bitmap("features", "user", "flags")
}
```

### 4. Performance Patterns
```go
// Batch operations
func (uc *UserCache) BatchSetUsers(users []*User) error {
	pipe := uc.client.Pipeline()
	
	for _, user := range users {
		key := uc.keyBuilder.Hash("user", user.ID)
		userData := map[string]interface{}{
			"id":    user.ID,
			"email": user.Email,
			"name":  user.Name,
		}
		pipe.HMSet(key, userData)
	}
	
	_, err := pipe.Exec()
	return err
}

// Use connection pooling and pipelining for bulk operations
func (uc *UserCache) GetMultipleUsers(userIDs []string) ([]*User, error) {
	pipe := uc.client.Pipeline()
	
	cmds := make([]*redis.StringStringMapCmd, len(userIDs))
	for i, userID := range userIDs {
		key := uc.keyBuilder.Hash("user", userID)
		cmds[i] = pipe.HGetAll(key)
	}
	
	_, err := pipe.Exec()
	if err != nil {
		return nil, err
	}
	
	users := make([]*User, 0, len(userIDs))
	for i, cmd := range cmds {
		if data := cmd.Val(); len(data) > 0 {
			user := &User{
				ID:    data["id"],
				Email: data["email"],
				Name:  data["name"],
			}
			users = append(users, user)
		}
	}
	
	return users, nil
}
```

## Key Management Utilities

```go
package utils

import (
	"fmt"
	"strings"
	"time"
	"your-app/redis"
)

// KeyAnalyzer provides utilities for key analysis and cleanup
type KeyAnalyzer struct {
	client     redis.Client
	keyBuilder *redis.KeyBuilder
}

func NewKeyAnalyzer(client redis.Client, keyBuilder *redis.KeyBuilder) *KeyAnalyzer {
	return &KeyAnalyzer{
		client:     client,
		keyBuilder: keyBuilder,
	}
}

// AnalyzeKeyspace provides statistics about key usage
func (ka *KeyAnalyzer) AnalyzeKeyspace() (*KeyspaceAnalysis, error) {
	info := ka.client.Info("keyspace")
	if info.Err() != nil {
		return nil, info.Err()
	}
	
	// Parse keyspace info and return analysis
	return &KeyspaceAnalysis{
		TotalKeys:    ka.countKeys("*"),
		UserKeys:     ka.countKeys("*:user:*"),
		SessionKeys:  ka.countKeys("*:session:*"),
		CacheKeys:    ka.countKeys("*:cache:*"),
	}, nil
}

// CleanupExpiredKeys removes keys that should have expired
func (ka *KeyAnalyzer) CleanupExpiredKeys(pattern string) error {
	keys := ka.client.Keys(pattern)
	if keys.Err() != nil {
		return keys.Err()
	}
	
	for _, key := range keys.Val() {
		ttl := ka.client.TTL(key)
		if ttl. < 0 {
			// Key has no TTL or is expired, check if it should be cleaned up
			if ka.shouldCleanup(key) {
				ka.client.Del(key)
			}
		}
	}
	
	return nil
}

// FindDuplicateKeys identifies potential duplicate keys
func (ka *KeyAnalyzer) FindDuplicateKeys() ([]string, error) {
	// Implementation to find keys that might be duplicates
	// This is application-specific logic
	return nil, nil
}

func (ka *KeyAnalyzer) countKeys(pattern string) int64 {
	keys := ka.client.Keys(pattern)
	if keys.Err() != nil {
		return 0
	}
	return int64(len(keys.Val()))
}

func (ka *KeyAnalyzer) shouldCleanup(key string) bool {
	// Check if key follows expected patterns and should be cleaned up
	parts := strings.Split(key, ":")
	if len(parts) < 3 {
		return false
	}
	
	// Check for temporary keys
	if strings.Contains(key, ":tmp:") {
		return true
	}
	
	// Check for session keys older than expected
	if parts[2] == "session" {
		// Additional logic to check session validity
		return false
	}
	
	return false
}

type KeyspaceAnalysis struct {
	TotalKeys   int64 `json:"total_keys"`
	UserKeys    int64 `json:"user_keys"`
	SessionKeys int64 `json:"session_keys"`
	CacheKeys   int64 `json:"cache_keys"`
}
```

## Migration and Maintenance

### Key Migration
```go
package migration

import (
	"fmt"
	"strings"
	"your-app/redis"
)

// KeyMigrator handles key migration between different naming schemes
type KeyMigrator struct {
	client       redis.Client
	oldBuilder   *redis.KeyBuilder
	newBuilder   *redis.KeyBuilder
}

func NewKeyMigrator(client redis.Client, oldBuilder, newBuilder *redis.KeyBuilder) *KeyMigrator {
	return &KeyMigrator{
		client:     client,
		oldBuilder: oldBuilder,
		newBuilder: newBuilder,
	}
}

// MigrateUserKeys migrates user keys to new naming scheme
func (km *KeyMigrator) MigrateUserKeys() error {
	oldPattern := km.oldBuilder.Hash("user", "*")
	keys := km.client.Keys(oldPattern)
	if keys.Err() != nil {
		return keys.Err()
	}
	
	for _, oldKey := range keys.Val() {
		// Extract user ID from old key
		userID := km.extractUserID(oldKey)
		if userID == "" {
			continue
		}
		
		// Get data from old key
		data := km.client.HGetAll(oldKey)
		if data.Err() != nil {
			continue
		}
		
		// Set data with new key
		newKey := km.newBuilder.Hash("user", userID)
		km.client.HMSet(newKey, data.Val())
		
		// Copy TTL if exists
		ttl := km.client.TTL(oldKey)
		if ttl.Val() > 0 {
			km.client.Expire(newKey, ttl.Val())
		}
		
		// Remove old key after successful migration
		km.client.Del(oldKey)
	}
	
	return nil
}

func (km *KeyMigrator) extractUserID(key string) string {
	parts := strings.Split(key, ":")
	for i, part := range parts {
		if part == "user" && i+1 < len(parts) {
			return parts[i+1]
		}
	}
	return ""
}
```

## Consequences

### Positive
- **Organization**: Clear, hierarchical key structure
- **Scalability**: Support for multiple environments and applications
- **Maintainability**: Easy to identify and manage keys
- **Conflict Prevention**: Data type prefixes prevent collisions
- **Debugging**: Easier troubleshooting with descriptive keys

### Negative
- **Key Length**: Longer keys consume more memory
- **Migration Complexity**: Changing naming schemes requires migration
- **Learning Curve**: Team needs to understand and follow conventions
- **Storage Overhead**: Prefixes add to storage requirements

### Mitigation
- **Documentation**: Provide clear naming convention guidelines
- **Tooling**: Create utilities for key analysis and management
- **Monitoring**: Track key usage and memory consumption
- **Training**: Ensure team understands naming conventions
- **Automation**: Use key builders to enforce consistency

## Related Patterns
- [012-redis-convention.md](../database/012-redis-convention.md) - General Redis conventions
- [015-debug-redis-memory.md](../database/015-debug-redis-memory.md) - Memory debugging
- [018-cache.md](018-cache.md) - Caching strategies
- [034-auth-token.md](034-auth-token.md) - Session management patterns 
