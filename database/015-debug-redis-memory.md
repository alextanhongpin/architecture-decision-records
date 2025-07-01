# Redis Memory Debugging and Optimization

## Status

`accepted`

## Context

Redis memory usage can become problematic as applications scale, leading to performance degradation, memory exhaustion, and potential data loss. Effective memory debugging and optimization strategies are essential for maintaining Redis performance and preventing memory-related issues.

### Common Memory Issues

| Issue | Symptoms | Impact | Root Causes |
|-------|----------|---------|-------------|
| **Memory Leaks** | Gradual memory increase | OOM kills, evictions | Keys without TTL, abandoned sessions |
| **Memory Fragmentation** | High memory usage vs data | Inefficient memory usage | Key churn, variable-sized objects |
| **Large Key Values** | Slow operations | Latency spikes | Poor data modeling, large JSON objects |
| **Key Explosion** | Sudden memory growth | Performance degradation | Unbounded key generation |
| **Inefficient Data Types** | Higher than expected usage | Resource waste | Poor data structure choices |

### Memory Analysis Strategies

1. **Memory Usage Analysis**: Understand current memory consumption patterns
2. **Key Space Analysis**: Identify memory-heavy keys and patterns
3. **Fragmentation Analysis**: Detect and resolve memory fragmentation
4. **Latency Monitoring**: Correlate memory usage with performance
5. **Eviction Monitoring**: Track eviction patterns and policies

## Decision

Implement a **comprehensive Redis memory debugging and optimization framework** with:

### Core Components

1. **Memory Monitoring Tools**: Built-in Redis commands and external monitoring
2. **Automated Analysis**: Scripts for regular memory analysis and reporting
3. **Alert System**: Proactive alerts for memory issues
4. **Optimization Strategies**: Systematic approaches to reduce memory usage
5. **Prevention Measures**: Policies and practices to prevent memory issues

## Implementation

### Redis Memory Analysis Commands

```bash
#!/bin/bash
# redis-memory-analysis.sh - Comprehensive Redis memory analysis

# Set Redis connection parameters
REDIS_CLI="redis-cli"
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}
REDIS_AUTH=${REDIS_AUTH}

if [ ! -z "$REDIS_AUTH" ]; then
    REDIS_CLI="redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_AUTH"
else
    REDIS_CLI="redis-cli -h $REDIS_HOST -p $REDIS_PORT"
fi

echo "=== Redis Memory Analysis Report ==="
echo "Generated at: $(date)"
echo

# 1. Basic memory information
echo "=== Memory Overview ==="
$REDIS_CLI INFO memory | grep -E "used_memory|used_memory_human|used_memory_rss|used_memory_peak|mem_fragmentation_ratio|maxmemory"
echo

# 2. Memory usage by database
echo "=== Memory Usage by Database ==="
$REDIS_CLI INFO keyspace
echo

# 3. Memory doctor analysis
echo "=== Memory Doctor Analysis ==="
$REDIS_CLI MEMORY DOCTOR
echo

# 4. Memory usage breakdown
echo "=== Memory Usage Breakdown ==="
$REDIS_CLI MEMORY USAGE-BYTES
echo

# 5. Largest keys analysis
echo "=== Top 10 Largest Keys ==="
$REDIS_CLI --bigkeys | head -20
echo

# 6. Key pattern analysis
echo "=== Key Pattern Analysis ==="
echo "Analyzing key patterns..."

# Get sample of keys for pattern analysis
$REDIS_CLI --scan --pattern "*" | head -1000 | \
    awk -F: '{print $1}' | sort | uniq -c | sort -nr | head -10
echo

# 7. Memory stats by type
echo "=== Memory Usage by Data Type ==="
$REDIS_CLI --memkeys --memkeys-samples 1000
echo

# 8. Fragmentation analysis
echo "=== Fragmentation Analysis ==="
USED_MEMORY=$($REDIS_CLI INFO memory | grep "used_memory:" | cut -d: -f2 | tr -d '\r')
USED_MEMORY_RSS=$($REDIS_CLI INFO memory | grep "used_memory_rss:" | cut -d: -f2 | tr -d '\r')
FRAGMENTATION_RATIO=$($REDIS_CLI INFO memory | grep "mem_fragmentation_ratio:" | cut -d: -f2 | tr -d '\r')

echo "Used Memory: $USED_MEMORY bytes"
echo "RSS Memory: $USED_MEMORY_RSS bytes"
echo "Fragmentation Ratio: $FRAGMENTATION_RATIO"

if (( $(echo "$FRAGMENTATION_RATIO > 1.5" | bc -l) )); then
    echo "WARNING: High fragmentation detected!"
fi
echo

# 9. Eviction statistics
echo "=== Eviction Statistics ==="
$REDIS_CLI INFO stats | grep -E "evicted_keys|expired_keys|keyspace_hits|keyspace_misses"
echo

# 10. Slow operations that might affect memory
echo "=== Recent Slow Operations ==="
$REDIS_CLI SLOWLOG GET 10
echo

echo "=== Analysis Complete ==="
```

### Go Memory Monitoring Framework

```go
package monitoring

import (
    "context"
    "fmt"
    "strconv"
    "strings"
    "time"
    
    "github.com/redis/go-redis/v9"
    "github.com/prometheus/client_golang/prometheus"
    "go.uber.org/zap"
)

// RedisMemoryMonitor provides comprehensive Redis memory monitoring
type RedisMemoryMonitor struct {
    client   *redis.Client
    logger   *zap.Logger
    metrics  *MemoryMetrics
    config   *MonitoringConfig
}

type MonitoringConfig struct {
    CheckInterval         time.Duration `env:"REDIS_MEMORY_CHECK_INTERVAL" default:"30s"`
    FragmentationThreshold float64      `env:"REDIS_FRAG_THRESHOLD" default:"1.5"`
    MemoryUsageThreshold   float64      `env:"REDIS_MEMORY_THRESHOLD" default:"0.85"`
    LargeKeyThreshold      int64        `env:"REDIS_LARGE_KEY_THRESHOLD" default:"1048576"` // 1MB
    SlowlogThreshold       int64        `env:"REDIS_SLOWLOG_THRESHOLD" default:"100"`       // 100ms
}

type MemoryMetrics struct {
    usedMemory         prometheus.Gauge
    usedMemoryRSS      prometheus.Gauge
    fragmentation      prometheus.Gauge
    keyCount           *prometheus.GaugeVec
    largeKeys          prometheus.Gauge
    evictedKeys        prometheus.Counter
    expiredKeys        prometheus.Counter
    memoryEfficiency   prometheus.Gauge
}

type MemoryInfo struct {
    UsedMemory        int64   `json:"used_memory"`
    UsedMemoryHuman   string  `json:"used_memory_human"`
    UsedMemoryRSS     int64   `json:"used_memory_rss"`
    UsedMemoryPeak    int64   `json:"used_memory_peak"`
    MaxMemory         int64   `json:"maxmemory"`
    FragmentationRatio float64 `json:"fragmentation_ratio"`
    MemoryEfficiency   float64 `json:"memory_efficiency"`
}

type KeyAnalysis struct {
    Pattern    string `json:"pattern"`
    Count      int64  `json:"count"`
    TotalSize  int64  `json:"total_size"`
    AvgSize    int64  `json:"avg_size"`
    LargestKey string `json:"largest_key"`
    LargestSize int64 `json:"largest_size"`
}

func NewRedisMemoryMonitor(client *redis.Client, logger *zap.Logger, 
    config *MonitoringConfig) *RedisMemoryMonitor {
    
    return &RedisMemoryMonitor{
        client:  client,
        logger:  logger,
        metrics: newMemoryMetrics(),
        config:  config,
    }
}

// StartMonitoring begins continuous memory monitoring
func (rmm *RedisMemoryMonitor) StartMonitoring(ctx context.Context) {
    ticker := time.NewTicker(rmm.config.CheckInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            if err := rmm.analyzeMemory(ctx); err != nil {
                rmm.logger.Error("Memory analysis failed", zap.Error(err))
            }
        }
    }
}

// analyzeMemory performs comprehensive memory analysis
func (rmm *RedisMemoryMonitor) analyzeMemory(ctx context.Context) error {
    // Get memory info
    memInfo, err := rmm.getMemoryInfo(ctx)
    if err != nil {
        return fmt.Errorf("failed to get memory info: %w", err)
    }
    
    // Update metrics
    rmm.updateMetrics(memInfo)
    
    // Check for issues
    rmm.checkMemoryIssues(memInfo)
    
    // Analyze key patterns
    if err := rmm.analyzeKeyPatterns(ctx); err != nil {
        rmm.logger.Error("Key pattern analysis failed", zap.Error(err))
    }
    
    // Check for large keys
    if err := rmm.checkLargeKeys(ctx); err != nil {
        rmm.logger.Error("Large key check failed", zap.Error(err))
    }
    
    return nil
}

// getMemoryInfo retrieves current Redis memory information
func (rmm *RedisMemoryMonitor) getMemoryInfo(ctx context.Context) (*MemoryInfo, error) {
    info, err := rmm.client.Info(ctx, "memory").Result()
    if err != nil {
        return nil, err
    }
    
    memInfo := &MemoryInfo{}
    lines := strings.Split(info, "\n")
    
    for _, line := range lines {
        if strings.Contains(line, ":") {
            parts := strings.Split(line, ":")
            if len(parts) != 2 {
                continue
            }
            
            key := strings.TrimSpace(parts[0])
            value := strings.TrimSpace(parts[1])
            
            switch key {
            case "used_memory":
                memInfo.UsedMemory, _ = strconv.ParseInt(value, 10, 64)
            case "used_memory_human":
                memInfo.UsedMemoryHuman = value
            case "used_memory_rss":
                memInfo.UsedMemoryRSS, _ = strconv.ParseInt(value, 10, 64)
            case "used_memory_peak":
                memInfo.UsedMemoryPeak, _ = strconv.ParseInt(value, 10, 64)
            case "maxmemory":
                memInfo.MaxMemory, _ = strconv.ParseInt(value, 10, 64)
            case "mem_fragmentation_ratio":
                memInfo.FragmentationRatio, _ = strconv.ParseFloat(value, 64)
            }
        }
    }
    
    // Calculate memory efficiency
    if memInfo.UsedMemoryPeak > 0 {
        memInfo.MemoryEfficiency = float64(memInfo.UsedMemory) / float64(memInfo.UsedMemoryPeak)
    }
    
    return memInfo, nil
}

// updateMetrics updates Prometheus metrics with current memory info
func (rmm *RedisMemoryMonitor) updateMetrics(memInfo *MemoryInfo) {
    rmm.metrics.usedMemory.Set(float64(memInfo.UsedMemory))
    rmm.metrics.usedMemoryRSS.Set(float64(memInfo.UsedMemoryRSS))
    rmm.metrics.fragmentation.Set(memInfo.FragmentationRatio)
    rmm.metrics.memoryEfficiency.Set(memInfo.MemoryEfficiency)
}

// checkMemoryIssues identifies and alerts on memory issues
func (rmm *RedisMemoryMonitor) checkMemoryIssues(memInfo *MemoryInfo) {
    // Check fragmentation
    if memInfo.FragmentationRatio > rmm.config.FragmentationThreshold {
        rmm.logger.Warn("High memory fragmentation detected",
            zap.Float64("fragmentation_ratio", memInfo.FragmentationRatio),
            zap.Float64("threshold", rmm.config.FragmentationThreshold),
        )
    }
    
    // Check memory usage
    if memInfo.MaxMemory > 0 {
        usageRatio := float64(memInfo.UsedMemory) / float64(memInfo.MaxMemory)
        if usageRatio > rmm.config.MemoryUsageThreshold {
            rmm.logger.Warn("High memory usage detected",
                zap.Float64("usage_ratio", usageRatio),
                zap.String("used_memory", memInfo.UsedMemoryHuman),
                zap.Int64("max_memory", memInfo.MaxMemory),
            )
        }
    }
    
    // Log memory summary
    rmm.logger.Info("Memory analysis completed",
        zap.String("used_memory", memInfo.UsedMemoryHuman),
        zap.Float64("fragmentation_ratio", memInfo.FragmentationRatio),
        zap.Float64("memory_efficiency", memInfo.MemoryEfficiency),
    )
}

// analyzeKeyPatterns analyzes key distribution patterns
func (rmm *RedisMemoryMonitor) analyzeKeyPatterns(ctx context.Context) error {
    patterns := make(map[string]*KeyAnalysis)
    
    // Scan keys and analyze patterns
    iter := rmm.client.Scan(ctx, 0, "*", 1000).Iterator()
    for iter.Next(ctx) {
        key := iter.Val()
        
        // Extract pattern (first part before :)
        parts := strings.Split(key, ":")
        pattern := parts[0]
        if len(parts) > 1 {
            pattern = parts[0] + ":*"
        }
        
        if analysis, exists := patterns[pattern]; exists {
            analysis.Count++
        } else {
            patterns[pattern] = &KeyAnalysis{
                Pattern: pattern,
                Count:   1,
            }
        }
        
        // Get key size for largest keys
        if keySize, err := rmm.client.MemoryUsage(ctx, key).Result(); err == nil {
            analysis := patterns[pattern]
            analysis.TotalSize += keySize
            analysis.AvgSize = analysis.TotalSize / analysis.Count
            
            if keySize > analysis.LargestSize {
                analysis.LargestSize = keySize
                analysis.LargestKey = key
            }
        }
    }
    
    if err := iter.Err(); err != nil {
        return err
    }
    
    // Update metrics and log patterns
    for pattern, analysis := range patterns {
        rmm.metrics.keyCount.WithLabelValues(pattern).Set(float64(analysis.Count))
        
        rmm.logger.Debug("Key pattern analysis",
            zap.String("pattern", analysis.Pattern),
            zap.Int64("count", analysis.Count),
            zap.Int64("total_size", analysis.TotalSize),
            zap.Int64("avg_size", analysis.AvgSize),
        )
    }
    
    return nil
}

// checkLargeKeys identifies keys that exceed size thresholds
func (rmm *RedisMemoryMonitor) checkLargeKeys(ctx context.Context) error {
    largeKeyCount := 0
    
    iter := rmm.client.Scan(ctx, 0, "*", 100).Iterator()
    for iter.Next(ctx) {
        key := iter.Val()
        
        keySize, err := rmm.client.MemoryUsage(ctx, key).Result()
        if err != nil {
            continue
        }
        
        if keySize > rmm.config.LargeKeyThreshold {
            largeKeyCount++
            
            // Get key type for additional context
            keyType, _ := rmm.client.Type(ctx, key).Result()
            
            rmm.logger.Warn("Large key detected",
                zap.String("key", key),
                zap.Int64("size", keySize),
                zap.String("type", keyType),
                zap.String("size_human", humanizeBytes(keySize)),
            )
        }
    }
    
    rmm.metrics.largeKeys.Set(float64(largeKeyCount))
    
    return iter.Err()
}
```

### Memory Optimization Tools

```go
package optimization

import (
    "context"
    "fmt"
    "strings"
    "time"
    
    "github.com/redis/go-redis/v9"
    "go.uber.org/zap"
)

// MemoryOptimizer provides tools for Redis memory optimization
type MemoryOptimizer struct {
    client *redis.Client
    logger *zap.Logger
}

func NewMemoryOptimizer(client *redis.Client, logger *zap.Logger) *MemoryOptimizer {
    return &MemoryOptimizer{
        client: client,
        logger: logger,
    }
}

// DefragmentMemory attempts to reduce memory fragmentation
func (mo *MemoryOptimizer) DefragmentMemory(ctx context.Context) error {
    mo.logger.Info("Starting memory defragmentation")
    
    // Check if active defragmentation is available (Redis 4.0+)
    configResp, err := mo.client.ConfigGet(ctx, "activedefrag").Result()
    if err != nil {
        return fmt.Errorf("failed to check activedefrag config: %w", err)
    }
    
    if len(configResp) < 2 || configResp[1] != "yes" {
        mo.logger.Info("Active defragmentation not available, using manual approach")
        return mo.manualDefragmentation(ctx)
    }
    
    // Enable active defragmentation temporarily
    if err := mo.client.ConfigSet(ctx, "activedefrag", "yes").Err(); err != nil {
        return fmt.Errorf("failed to enable activedefrag: %w", err)
    }
    
    // Configure defragmentation settings
    configs := map[string]string{
        "active-defrag-ignore-bytes":      "100mb",
        "active-defrag-threshold-lower":   "10",
        "active-defrag-threshold-upper":   "100",
        "active-defrag-cycle-min":         "5",
        "active-defrag-cycle-max":         "75",
    }
    
    for key, value := range configs {
        if err := mo.client.ConfigSet(ctx, key, value).Err(); err != nil {
            mo.logger.Warn("Failed to set defrag config",
                zap.String("key", key),
                zap.String("value", value),
                zap.Error(err),
            )
        }
    }
    
    mo.logger.Info("Active defragmentation enabled and configured")
    return nil
}

// manualDefragmentation performs manual memory defragmentation
func (mo *MemoryOptimizer) manualDefragmentation(ctx context.Context) error {
    mo.logger.Info("Performing manual defragmentation")
    
    // Approach 1: Force memory reclaim through MEMORY PURGE
    if err := mo.client.Do(ctx, "MEMORY", "PURGE").Err(); err != nil {
        mo.logger.Warn("MEMORY PURGE failed", zap.Error(err))
    }
    
    // Approach 2: Identify and rewrite large fragmented keys
    return mo.rewriteFragmentedKeys(ctx)
}

// rewriteFragmentedKeys identifies and rewrites keys that may be fragmented
func (mo *MemoryOptimizer) rewriteFragmentedKeys(ctx context.Context) error {
    // Scan for large hash, set, or sorted set keys
    iter := mo.client.Scan(ctx, 0, "*", 100).Iterator()
    
    for iter.Next(ctx) {
        key := iter.Val()
        
        keyType, err := mo.client.Type(ctx, key).Result()
        if err != nil {
            continue
        }
        
        // Only process data structures that can be fragmented
        if keyType != "hash" && keyType != "set" && keyType != "zset" && keyType != "list" {
            continue
        }
        
        keySize, err := mo.client.MemoryUsage(ctx, key).Result()
        if err != nil {
            continue
        }
        
        // Rewrite large keys (over 1MB)
        if keySize > 1024*1024 {
            if err := mo.rewriteKey(ctx, key, keyType); err != nil {
                mo.logger.Error("Failed to rewrite key",
                    zap.String("key", key),
                    zap.Error(err),
                )
            }
        }
    }
    
    return iter.Err()
}

// rewriteKey rewrites a key to reduce fragmentation
func (mo *MemoryOptimizer) rewriteKey(ctx context.Context, key, keyType string) error {
    tempKey := key + ":temp:" + fmt.Sprintf("%d", time.Now().UnixNano())
    
    switch keyType {
    case "hash":
        return mo.rewriteHashKey(ctx, key, tempKey)
    case "set":
        return mo.rewriteSetKey(ctx, key, tempKey)
    case "zset":
        return mo.rewriteZSetKey(ctx, key, tempKey)
    case "list":
        return mo.rewriteListKey(ctx, key, tempKey)
    default:
        return fmt.Errorf("unsupported key type for rewrite: %s", keyType)
    }
}

func (mo *MemoryOptimizer) rewriteHashKey(ctx context.Context, oldKey, tempKey string) error {
    // Get all hash fields and values
    fields, err := mo.client.HGetAll(ctx, oldKey).Result()
    if err != nil {
        return err
    }
    
    // Write to temporary key
    if len(fields) > 0 {
        if err := mo.client.HMSet(ctx, tempKey, fields).Err(); err != nil {
            return err
        }
    }
    
    // Copy TTL if exists
    ttl, _ := mo.client.TTL(ctx, oldKey).Result()
    if ttl > 0 {
        mo.client.Expire(ctx, tempKey, ttl)
    }
    
    // Atomic rename
    return mo.client.Rename(ctx, tempKey, oldKey).Err()
}

func (mo *MemoryOptimizer) rewriteSetKey(ctx context.Context, oldKey, tempKey string) error {
    members, err := mo.client.SMembers(ctx, oldKey).Result()
    if err != nil {
        return err
    }
    
    if len(members) > 0 {
        if err := mo.client.SAdd(ctx, tempKey, members).Err(); err != nil {
            return err
        }
    }
    
    ttl, _ := mo.client.TTL(ctx, oldKey).Result()
    if ttl > 0 {
        mo.client.Expire(ctx, tempKey, ttl)
    }
    
    return mo.client.Rename(ctx, tempKey, oldKey).Err()
}

func (mo *MemoryOptimizer) rewriteZSetKey(ctx context.Context, oldKey, tempKey string) error {
    members, err := mo.client.ZRangeWithScores(ctx, oldKey, 0, -1).Result()
    if err != nil {
        return err
    }
    
    if len(members) > 0 {
        if err := mo.client.ZAdd(ctx, tempKey, members...).Err(); err != nil {
            return err
        }
    }
    
    ttl, _ := mo.client.TTL(ctx, oldKey).Result()
    if ttl > 0 {
        mo.client.Expire(ctx, tempKey, ttl)
    }
    
    return mo.client.Rename(ctx, tempKey, oldKey).Err()
}

func (mo *MemoryOptimizer) rewriteListKey(ctx context.Context, oldKey, tempKey string) error {
    length, err := mo.client.LLen(ctx, oldKey).Result()
    if err != nil {
        return err
    }
    
    if length > 0 {
        values, err := mo.client.LRange(ctx, oldKey, 0, -1).Result()
        if err != nil {
            return err
        }
        
        if err := mo.client.LPush(ctx, tempKey, values).Err(); err != nil {
            return err
        }
    }
    
    ttl, _ := mo.client.TTL(ctx, oldKey).Result()
    if ttl > 0 {
        mo.client.Expire(ctx, tempKey, ttl)
    }
    
    return mo.client.Rename(ctx, tempKey, oldKey).Err()
}

// CleanupExpiredKeys removes keys that should have expired
func (mo *MemoryOptimizer) CleanupExpiredKeys(ctx context.Context) error {
    mo.logger.Info("Starting expired keys cleanup")
    
    iter := mo.client.Scan(ctx, 0, "*", 1000).Iterator()
    expiredCount := 0
    
    for iter.Next(ctx) {
        key := iter.Val()
        
        // Check if key has TTL
        ttl, err := mo.client.TTL(ctx, key).Result()
        if err != nil {
            continue
        }
        
        // Key has expired but still exists (Redis lazy expiration)
        if ttl == -2 {
            if err := mo.client.Del(ctx, key).Err(); err != nil {
                mo.logger.Error("Failed to delete expired key",
                    zap.String("key", key),
                    zap.Error(err),
                )
            } else {
                expiredCount++
            }
        }
    }
    
    mo.logger.Info("Expired keys cleanup completed",
        zap.Int("expired_keys_removed", expiredCount),
    )
    
    return iter.Err()
}

// OptimizeKeyDistribution analyzes and suggests key distribution improvements
func (mo *MemoryOptimizer) OptimizeKeyDistribution(ctx context.Context) (*OptimizationReport, error) {
    report := &OptimizationReport{
        Timestamp: time.Now(),
        Suggestions: make([]Suggestion, 0),
    }
    
    // Analyze key patterns
    patterns := make(map[string]int)
    largeKeys := make([]LargeKeyInfo, 0)
    
    iter := mo.client.Scan(ctx, 0, "*", 1000).Iterator()
    for iter.Next(ctx) {
        key := iter.Val()
        
        // Extract pattern
        parts := strings.Split(key, ":")
        pattern := parts[0]
        if len(parts) > 1 {
            pattern = parts[0] + ":*"
        }
        patterns[pattern]++
        
        // Check key size
        if keySize, err := mo.client.MemoryUsage(ctx, key).Result(); err == nil {
            if keySize > 100*1024 { // 100KB
                keyType, _ := mo.client.Type(ctx, key).Result()
                largeKeys = append(largeKeys, LargeKeyInfo{
                    Key:  key,
                    Size: keySize,
                    Type: keyType,
                })
            }
        }
    }
    
    // Generate suggestions
    for pattern, count := range patterns {
        if count > 10000 {
            report.Suggestions = append(report.Suggestions, Suggestion{
                Type:        "key_pattern",
                Severity:    "medium",
                Message:     fmt.Sprintf("Pattern '%s' has %d keys - consider sharding", pattern, count),
                Pattern:     pattern,
                KeyCount:    count,
            })
        }
    }
    
    for _, largeKey := range largeKeys {
        report.Suggestions = append(report.Suggestions, Suggestion{
            Type:     "large_key",
            Severity: "high",
            Message:  fmt.Sprintf("Large key '%s' (%s) - consider breaking into smaller keys", 
                largeKey.Key, humanizeBytes(largeKey.Size)),
            Key:      largeKey.Key,
            KeySize:  largeKey.Size,
        })
    }
    
    return report, iter.Err()
}

type OptimizationReport struct {
    Timestamp   time.Time    `json:"timestamp"`
    Suggestions []Suggestion `json:"suggestions"`
}

type Suggestion struct {
    Type     string `json:"type"`
    Severity string `json:"severity"`
    Message  string `json:"message"`
    Pattern  string `json:"pattern,omitempty"`
    Key      string `json:"key,omitempty"`
    KeyCount int    `json:"key_count,omitempty"`
    KeySize  int64  `json:"key_size,omitempty"`
}

type LargeKeyInfo struct {
    Key  string `json:"key"`
    Size int64  `json:"size"`
    Type string `json:"type"`
}
```

### Latency Monitoring

```go
package latency

import (
    "context"
    "fmt"
    "strconv"
    "strings"
    "time"
    
    "github.com/redis/go-redis/v9"
    "go.uber.org/zap"
)

// LatencyMonitor tracks Redis latency patterns
type LatencyMonitor struct {
    client *redis.Client
    logger *zap.Logger
    config *LatencyConfig
}

type LatencyConfig struct {
    ThresholdMs     int64         `env:"REDIS_LATENCY_THRESHOLD" default:"100"`
    MonitorInterval time.Duration `env:"REDIS_LATENCY_INTERVAL" default:"60s"`
    HistorySize     int           `env:"REDIS_LATENCY_HISTORY" default:"100"`
}

type LatencyEvent struct {
    EventType string    `json:"event_type"`
    Timestamp time.Time `json:"timestamp"`
    Duration  int64     `json:"duration_ms"`
    Command   string    `json:"command,omitempty"`
}

func NewLatencyMonitor(client *redis.Client, logger *zap.Logger, 
    config *LatencyConfig) *LatencyMonitor {
    
    return &LatencyMonitor{
        client: client,
        logger: logger,
        config: config,
    }
}

// StartLatencyMonitoring enables Redis latency monitoring
func (lm *LatencyMonitor) StartLatencyMonitoring(ctx context.Context) error {
    // Enable latency monitoring with threshold
    if err := lm.client.ConfigSet(ctx, "latency-monitor-threshold", 
        fmt.Sprintf("%d", lm.config.ThresholdMs)).Err(); err != nil {
        return fmt.Errorf("failed to set latency threshold: %w", err)
    }
    
    lm.logger.Info("Latency monitoring enabled",
        zap.Int64("threshold_ms", lm.config.ThresholdMs),
    )
    
    // Start periodic latency analysis
    go lm.monitorLatency(ctx)
    
    return nil
}

// monitorLatency continuously monitors and reports latency events
func (lm *LatencyMonitor) monitorLatency(ctx context.Context) {
    ticker := time.NewTicker(lm.config.MonitorInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            if err := lm.analyzeLatency(ctx); err != nil {
                lm.logger.Error("Latency analysis failed", zap.Error(err))
            }
        }
    }
}

// analyzeLatency retrieves and analyzes recent latency events
func (lm *LatencyMonitor) analyzeLatency(ctx context.Context) error {
    // Get latency doctor analysis
    doctorResult, err := lm.client.Do(ctx, "LATENCY", "DOCTOR").Result()
    if err != nil {
        return fmt.Errorf("latency doctor failed: %w", err)
    }
    
    if doctorStr, ok := doctorResult.(string); ok && len(doctorStr) > 0 {
        lm.logger.Warn("Latency doctor analysis", zap.String("analysis", doctorStr))
    }
    
    // Get latest latency events
    events, err := lm.getLatencyHistory(ctx)
    if err != nil {
        return err
    }
    
    // Analyze and log significant events
    for _, event := range events {
        if event.Duration > lm.config.ThresholdMs {
            lm.logger.Warn("High latency event detected",
                zap.String("event_type", event.EventType),
                zap.Int64("duration_ms", event.Duration),
                zap.Time("timestamp", event.Timestamp),
                zap.String("command", event.Command),
            )
        }
    }
    
    return nil
}

// getLatencyHistory retrieves recent latency events
func (lm *LatencyMonitor) getLatencyHistory(ctx context.Context) ([]LatencyEvent, error) {
    // Get list of latency events
    eventListResult, err := lm.client.Do(ctx, "LATENCY", "LATEST").Result()
    if err != nil {
        return nil, err
    }
    
    var events []LatencyEvent
    
    if eventList, ok := eventListResult.([]interface{}); ok {
        for _, eventData := range eventList {
            if eventSlice, ok := eventData.([]interface{}); ok && len(eventSlice) >= 4 {
                eventType, _ := eventSlice[0].(string)
                timestampUnix, _ := eventSlice[1].(int64)
                latency, _ := eventSlice[2].(int64)
                maxLatency, _ := eventSlice[3].(int64)
                
                event := LatencyEvent{
                    EventType: eventType,
                    Timestamp: time.Unix(timestampUnix, 0),
                    Duration:  maxLatency, // Use max latency for severity
                }
                
                // Get detailed history for this event type
                if history, err := lm.getEventHistory(ctx, eventType); err == nil {
                    event.Command = lm.analyzeEventType(eventType, history)
                }
                
                events = append(events, event)
                
                lm.logger.Debug("Latency event",
                    zap.String("type", eventType),
                    zap.Int64("latency", latency),
                    zap.Int64("max_latency", maxLatency),
                    zap.Time("timestamp", time.Unix(timestampUnix, 0)),
                )
            }
        }
    }
    
    return events, nil
}

// getEventHistory gets detailed history for a specific event type
func (lm *LatencyMonitor) getEventHistory(ctx context.Context, eventType string) ([]interface{}, error) {
    result, err := lm.client.Do(ctx, "LATENCY", "HISTORY", eventType).Result()
    if err != nil {
        return nil, err
    }
    
    if history, ok := result.([]interface{}); ok {
        return history, nil
    }
    
    return nil, nil
}

// analyzeEventType provides context for different latency event types
func (lm *LatencyMonitor) analyzeEventType(eventType string, history []interface{}) string {
    switch {
    case strings.Contains(eventType, "command"):
        return "Redis command execution"
    case strings.Contains(eventType, "fork"):
        return "Background save operation"
    case strings.Contains(eventType, "rdb"):
        return "RDB persistence operation"
    case strings.Contains(eventType, "aof"):
        return "AOF persistence operation"
    case strings.Contains(eventType, "expire"):
        return "Key expiration operation"
    case strings.Contains(eventType, "eviction"):
        return "Memory eviction operation"
    default:
        return eventType
    }
}

// GetLatencyReport generates a comprehensive latency report
func (lm *LatencyMonitor) GetLatencyReport(ctx context.Context) (*LatencyReport, error) {
    report := &LatencyReport{
        Timestamp: time.Now(),
        Events:    make([]LatencyEvent, 0),
        Summary:   make(map[string]LatencySummary),
    }
    
    // Get recent events
    events, err := lm.getLatencyHistory(ctx)
    if err != nil {
        return nil, err
    }
    
    report.Events = events
    
    // Generate summary by event type
    eventSummary := make(map[string][]int64)
    for _, event := range events {
        eventSummary[event.EventType] = append(eventSummary[event.EventType], event.Duration)
    }
    
    for eventType, durations := range eventSummary {
        summary := LatencySummary{
            EventType: eventType,
            Count:     len(durations),
        }
        
        if len(durations) > 0 {
            var total int64
            var max int64
            var min int64 = durations[0]
            
            for _, duration := range durations {
                total += duration
                if duration > max {
                    max = duration
                }
                if duration < min {
                    min = duration
                }
            }
            
            summary.Average = total / int64(len(durations))
            summary.Maximum = max
            summary.Minimum = min
        }
        
        report.Summary[eventType] = summary
    }
    
    return report, nil
}

type LatencyReport struct {
    Timestamp time.Time                  `json:"timestamp"`
    Events    []LatencyEvent             `json:"events"`
    Summary   map[string]LatencySummary  `json:"summary"`
}

type LatencySummary struct {
    EventType string `json:"event_type"`
    Count     int    `json:"count"`
    Average   int64  `json:"average_ms"`
    Maximum   int64  `json:"maximum_ms"`
    Minimum   int64  `json:"minimum_ms"`
}
```

### Utility Functions

```go
package utils

import (
    "fmt"
)

// humanizeBytes converts bytes to human-readable format
func humanizeBytes(bytes int64) string {
    const unit = 1024
    if bytes < unit {
        return fmt.Sprintf("%d B", bytes)
    }
    
    div, exp := int64(unit), 0
    for n := bytes / unit; n >= unit; n /= unit {
        div *= unit
        exp++
    }
    
    return fmt.Sprintf("%.1f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

// extractKeyPattern extracts a pattern from a Redis key
func extractKeyPattern(key string) string {
    // Simple pattern extraction - can be enhanced based on needs
    parts := strings.Split(key, ":")
    if len(parts) > 1 {
        return parts[0] + ":*"
    }
    return key
}

// classifyMemoryIssue determines the severity of a memory issue
func classifyMemoryIssue(fragmentationRatio float64, memoryUsage float64) string {
    if fragmentationRatio > 2.0 || memoryUsage > 0.9 {
        return "critical"
    } else if fragmentationRatio > 1.5 || memoryUsage > 0.8 {
        return "warning"
    }
    return "normal"
}
```

## Consequences

### Positive

- **Proactive Monitoring**: Early detection of memory issues prevents outages
- **Performance Optimization**: Systematic approaches to improve Redis performance
- **Capacity Planning**: Data-driven insights for infrastructure planning
- **Debugging Capability**: Comprehensive tools for troubleshooting memory issues
- **Automated Optimization**: Scheduled maintenance reduces manual intervention
- **Cost Optimization**: Efficient memory usage reduces infrastructure costs

### Negative

- **Monitoring Overhead**: Memory analysis consumes Redis resources
- **Complexity**: Multiple monitoring tools require coordination
- **False Positives**: Aggressive monitoring may generate unnecessary alerts
- **Storage Requirements**: Extensive logging requires additional storage

### Mitigations

- **Efficient Monitoring**: Use sampling and batching to reduce overhead
- **Smart Alerting**: Implement intelligent thresholds and alert suppression
- **Scheduled Analysis**: Run intensive analysis during low-traffic periods
- **Documentation**: Comprehensive runbooks for memory issue resolution

## Related Patterns

- **[Redis Convention](012-redis-convention.md)**: Proper Redis usage patterns
- **[Rate Limiting](018-rate-limit.md)**: Memory-efficient rate limiting
- **[Logging](013-logging.md)**: Coordinated logging with memory monitoring
- **[Docker Testing](004-dockertest.md)**: Testing Redis memory usage in isolation
