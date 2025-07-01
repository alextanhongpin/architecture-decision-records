# Database-Based Rate Limiting

## Status

`accepted`

## Context

Modern applications need robust rate limiting to prevent abuse, protect resources, and ensure fair usage. While in-memory solutions like Redis are common, database-based rate limiting provides persistence, consistency, and can be more cost-effective for certain use cases. This is especially useful for applications that need to survive restarts, require exact counting, or have complex rate limiting rules.

Database-based rate limiting can handle various scenarios like API throttling, user action limits, progressive penalties for abuse, and distributed rate limiting across multiple application instances.

## Decision

Implement a comprehensive database-based rate limiting system using SQLite for performance and PostgreSQL for persistence, with support for multiple rate limiting algorithms, progressive penalties, and comprehensive monitoring.

## Architecture

### Core Components

1. **Rate Limit Storage**: Database tables for storing rate limit state
2. **Multiple Algorithms**: Support for different rate limiting strategies
3. **Progressive Penalties**: Escalating delays for repeated violations
4. **Clean-up Mechanism**: Automatic cleanup of expired records
5. **Monitoring**: Rate limit metrics and alerting
6. **Distributed Support**: Coordination across multiple instances

### Schema Design

```sql
-- SQLite version for high-performance local rate limiting
CREATE TABLE rate_limits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    resource TEXT NOT NULL,
    window_start INTEGER NOT NULL, -- Unix timestamp
    window_size INTEGER NOT NULL,  -- Window size in seconds
    request_count INTEGER NOT NULL DEFAULT 0,
    last_request_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    
    UNIQUE(user_id, resource, window_start, window_size)
);

-- Penalty tracking for progressive rate limiting
CREATE TABLE rate_limit_penalties (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    resource TEXT NOT NULL,
    violation_count INTEGER NOT NULL DEFAULT 0,
    last_violation_at INTEGER NOT NULL,
    penalty_until INTEGER, -- Unix timestamp when penalty expires
    penalty_duration INTEGER, -- Duration in seconds
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    
    UNIQUE(user_id, resource)
);

-- Rate limit configuration
CREATE TABLE rate_limit_configs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    resource TEXT NOT NULL UNIQUE,
    algorithm TEXT NOT NULL DEFAULT 'sliding_window', -- sliding_window, fixed_window, token_bucket
    max_requests INTEGER NOT NULL,
    window_size INTEGER NOT NULL, -- in seconds
    burst_size INTEGER, -- for token bucket
    refill_rate INTEGER, -- for token bucket
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Indexes for performance
CREATE INDEX idx_rate_limits_user_resource ON rate_limits(user_id, resource);
CREATE INDEX idx_rate_limits_window ON rate_limits(window_start, window_size);
CREATE INDEX idx_rate_limit_penalties_user_resource ON rate_limit_penalties(user_id, resource);
CREATE INDEX idx_rate_limit_penalties_expiry ON rate_limit_penalties(penalty_until);

-- PostgreSQL version for distributed rate limiting
-- (Similar schema with JSONB for metadata and proper timestamp types)
```

### PostgreSQL Schema for Distributed Rate Limiting

```sql
-- PostgreSQL version with enhanced features
CREATE TABLE rate_limits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT NOT NULL,
    resource TEXT NOT NULL,
    algorithm TEXT NOT NULL DEFAULT 'sliding_window',
    window_start TIMESTAMPTZ NOT NULL,
    window_size INTERVAL NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 0,
    last_request_at TIMESTAMPTZ NOT NULL,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(user_id, resource, window_start, window_size)
);

CREATE TABLE rate_limit_penalties (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT NOT NULL,
    resource TEXT NOT NULL,
    violation_count INTEGER NOT NULL DEFAULT 0,
    last_violation_at TIMESTAMPTZ NOT NULL,
    penalty_until TIMESTAMPTZ,
    penalty_duration INTERVAL,
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(user_id, resource)
);

CREATE TABLE rate_limit_configs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    resource TEXT NOT NULL UNIQUE,
    algorithm TEXT NOT NULL DEFAULT 'sliding_window',
    max_requests INTEGER NOT NULL,
    window_size INTERVAL NOT NULL,
    burst_size INTEGER,
    refill_rate INTEGER,
    progressive_penalties JSONB, -- Configuration for penalty escalation
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_rate_limits_user_resource_pg ON rate_limits(user_id, resource);
CREATE INDEX idx_rate_limits_window_pg ON rate_limits(window_start) WHERE window_start > NOW() - INTERVAL '1 day';
CREATE INDEX idx_rate_limit_penalties_user_resource_pg ON rate_limit_penalties(user_id, resource);
CREATE INDEX idx_rate_limit_penalties_expiry_pg ON rate_limit_penalties(penalty_until) WHERE penalty_until > NOW();
```

## Implementation

### Go Rate Limiter

```go
package ratelimit

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "log"
    "math"
    "sync"
    "time"
    
    _ "github.com/mattn/go-sqlite3"
    "github.com/lib/pq"
)

type RateLimiter struct {
    db       *sql.DB
    configs  map[string]*RateLimitConfig
    mu       sync.RWMutex
    dbType   string // "sqlite" or "postgres"
}

type RateLimitConfig struct {
    Resource            string        `json:"resource"`
    Algorithm           string        `json:"algorithm"`
    MaxRequests         int           `json:"max_requests"`
    WindowSize          time.Duration `json:"window_size"`
    BurstSize           int           `json:"burst_size,omitempty"`
    RefillRate          int           `json:"refill_rate,omitempty"`
    ProgressivePenalties []PenaltyTier `json:"progressive_penalties,omitempty"`
    Enabled             bool          `json:"enabled"`
}

type PenaltyTier struct {
    ViolationCount int           `json:"violation_count"`
    PenaltyDuration time.Duration `json:"penalty_duration"`
}

type RateLimitResult struct {
    Allowed         bool          `json:"allowed"`
    Remaining       int           `json:"remaining"`
    ResetAt         time.Time     `json:"reset_at"`
    RetryAfter      time.Duration `json:"retry_after,omitempty"`
    PenaltyActive   bool          `json:"penalty_active,omitempty"`
    PenaltyUntil    time.Time     `json:"penalty_until,omitempty"`
}

func NewRateLimiter(db *sql.DB, dbType string) *RateLimiter {
    rl := &RateLimiter{
        db:      db,
        configs: make(map[string]*RateLimitConfig),
        dbType:  dbType,
    }
    
    // Load configurations
    if err := rl.loadConfigs(); err != nil {
        log.Printf("Error loading rate limit configs: %v", err)
    }
    
    // Setup periodic cleanup
    go rl.cleanupExpiredRecords()
    
    return rl
}

func (rl *RateLimiter) loadConfigs() error {
    var query string
    if rl.dbType == "sqlite" {
        query = `
            SELECT resource, algorithm, max_requests, window_size, 
                   burst_size, refill_rate, enabled
            FROM rate_limit_configs WHERE enabled = TRUE`
    } else {
        query = `
            SELECT resource, algorithm, max_requests, 
                   EXTRACT(EPOCH FROM window_size)::INTEGER as window_size,
                   burst_size, refill_rate, progressive_penalties, enabled
            FROM rate_limit_configs WHERE enabled = TRUE`
    }
    
    rows, err := rl.db.Query(query)
    if err != nil {
        return fmt.Errorf("query configs: %w", err)
    }
    defer rows.Close()
    
    rl.mu.Lock()
    defer rl.mu.Unlock()
    
    for rows.Next() {
        config := &RateLimitConfig{}
        var windowSeconds int
        var burstSize, refillRate sql.NullInt32
        var progressivePenaltiesJSON sql.NullString
        
        if rl.dbType == "sqlite" {
            err = rows.Scan(&config.Resource, &config.Algorithm, 
                &config.MaxRequests, &windowSeconds, &burstSize, 
                &refillRate, &config.Enabled)
        } else {
            err = rows.Scan(&config.Resource, &config.Algorithm, 
                &config.MaxRequests, &windowSeconds, &burstSize, 
                &refillRate, &progressivePenaltiesJSON, &config.Enabled)
        }
        
        if err != nil {
            continue
        }
        
        config.WindowSize = time.Duration(windowSeconds) * time.Second
        if burstSize.Valid {
            config.BurstSize = int(burstSize.Int32)
        }
        if refillRate.Valid {
            config.RefillRate = int(refillRate.Int32)
        }
        
        if progressivePenaltiesJSON.Valid {
            json.Unmarshal([]byte(progressivePenaltiesJSON.String), &config.ProgressivePenalties)
        }
        
        rl.configs[config.Resource] = config
    }
    
    return nil
}

func (rl *RateLimiter) CheckLimit(ctx context.Context, userID, resource string) (*RateLimitResult, error) {
    rl.mu.RLock()
    config, exists := rl.configs[resource]
    rl.mu.RUnlock()
    
    if !exists {
        return &RateLimitResult{Allowed: true}, nil
    }
    
    // Check if user is currently penalized
    if penaltyResult := rl.checkPenalty(ctx, userID, resource); penaltyResult != nil {
        return penaltyResult, nil
    }
    
    // Apply rate limiting algorithm
    switch config.Algorithm {
    case "sliding_window":
        return rl.slidingWindowCheck(ctx, userID, resource, config)
    case "fixed_window":
        return rl.fixedWindowCheck(ctx, userID, resource, config)
    case "token_bucket":
        return rl.tokenBucketCheck(ctx, userID, resource, config)
    default:
        return nil, fmt.Errorf("unsupported algorithm: %s", config.Algorithm)
    }
}

func (rl *RateLimiter) checkPenalty(ctx context.Context, userID, resource string) *RateLimitResult {
    var penaltyUntil sql.NullInt64
    var query string
    
    if rl.dbType == "sqlite" {
        query = `SELECT penalty_until FROM rate_limit_penalties 
                 WHERE user_id = ? AND resource = ? AND penalty_until > ?`
    } else {
        query = `SELECT EXTRACT(EPOCH FROM penalty_until)::BIGINT 
                 FROM rate_limit_penalties 
                 WHERE user_id = $1 AND resource = $2 AND penalty_until > NOW()`
    }
    
    now := time.Now().Unix()
    err := rl.db.QueryRowContext(ctx, query, userID, resource, now).Scan(&penaltyUntil)
    
    if err == sql.ErrNoRows {
        return nil // No active penalty
    }
    
    if err != nil {
        log.Printf("Error checking penalty: %v", err)
        return nil
    }
    
    if penaltyUntil.Valid {
        penaltyTime := time.Unix(penaltyUntil.Int64, 0)
        return &RateLimitResult{
            Allowed:       false,
            PenaltyActive: true,
            PenaltyUntil:  penaltyTime,
            RetryAfter:    time.Until(penaltyTime),
        }
    }
    
    return nil
}

func (rl *RateLimiter) slidingWindowCheck(ctx context.Context, userID, resource string, 
    config *RateLimitConfig) (*RateLimitResult, error) {
    
    tx, err := rl.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    now := time.Now()
    windowStart := now.Add(-config.WindowSize)
    
    // Count requests in the sliding window
    var requestCount int
    countQuery := `
        SELECT COALESCE(SUM(request_count), 0)
        FROM rate_limits 
        WHERE user_id = ? AND resource = ? 
        AND window_start >= ? AND window_start < ?`
    
    if rl.dbType == "postgres" {
        countQuery = `
            SELECT COALESCE(SUM(request_count), 0)
            FROM rate_limits 
            WHERE user_id = $1 AND resource = $2 
            AND window_start >= $3 AND window_start < $4`
    }
    
    err = tx.QueryRowContext(ctx, countQuery, userID, resource, 
        windowStart.Unix(), now.Unix()).Scan(&requestCount)
    if err != nil {
        return nil, fmt.Errorf("count requests: %w", err)
    }
    
    result := &RateLimitResult{
        Allowed:   requestCount < config.MaxRequests,
        Remaining: max(0, config.MaxRequests-requestCount-1),
        ResetAt:   now.Add(config.WindowSize),
    }
    
    if result.Allowed {
        // Record the request
        err = rl.recordRequest(ctx, tx, userID, resource, config, now)
        if err != nil {
            return nil, fmt.Errorf("record request: %w", err)
        }
    } else {
        // Apply penalty for rate limit violation
        err = rl.applyPenalty(ctx, tx, userID, resource, config)
        if err != nil {
            log.Printf("Error applying penalty: %v", err)
        }
        
        result.RetryAfter = config.WindowSize
    }
    
    return result, tx.Commit()
}

func (rl *RateLimiter) fixedWindowCheck(ctx context.Context, userID, resource string, 
    config *RateLimitConfig) (*RateLimitResult, error) {
    
    tx, err := rl.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    now := time.Now()
    windowStart := time.Unix(now.Unix()/int64(config.WindowSize.Seconds())*int64(config.WindowSize.Seconds()), 0)
    
    // Get or create rate limit record for this window
    var requestCount int
    var updateQuery, insertQuery string
    
    if rl.dbType == "sqlite" {
        updateQuery = `
            UPDATE rate_limits 
            SET request_count = request_count + 1, 
                last_request_at = ?, 
                updated_at = ?
            WHERE user_id = ? AND resource = ? 
            AND window_start = ? AND window_size = ?`
        
        insertQuery = `
            INSERT INTO rate_limits 
            (user_id, resource, window_start, window_size, request_count, 
             last_request_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, 1, ?, ?, ?)`
    } else {
        updateQuery = `
            UPDATE rate_limits 
            SET request_count = request_count + 1, 
                last_request_at = $1, 
                updated_at = $1
            WHERE user_id = $2 AND resource = $3 
            AND window_start = $4 AND window_size = $5`
        
        insertQuery = `
            INSERT INTO rate_limits 
            (user_id, resource, window_start, window_size, request_count, 
             last_request_at, created_at, updated_at)
            VALUES ($1, $2, $3, $4, 1, $5, $5, $5)`
    }
    
    // Try to update existing record
    var result sql.Result
    if rl.dbType == "sqlite" {
        result, err = tx.ExecContext(ctx, updateQuery, now.Unix(), now.Unix(), 
            userID, resource, windowStart.Unix(), int(config.WindowSize.Seconds()))
    } else {
        result, err = tx.ExecContext(ctx, updateQuery, now, userID, resource, 
            windowStart, config.WindowSize)
    }
    
    if err != nil {
        return nil, fmt.Errorf("update rate limit: %w", err)
    }
    
    rowsAffected, _ := result.RowsAffected()
    if rowsAffected == 0 {
        // No existing record, create new one
        if rl.dbType == "sqlite" {
            _, err = tx.ExecContext(ctx, insertQuery, userID, resource, 
                windowStart.Unix(), int(config.WindowSize.Seconds()), 
                now.Unix(), now.Unix(), now.Unix())
        } else {
            _, err = tx.ExecContext(ctx, insertQuery, userID, resource, 
                windowStart, config.WindowSize, now, now, now)
        }
        
        if err != nil {
            return nil, fmt.Errorf("insert rate limit: %w", err)
        }
        requestCount = 1
    } else {
        // Get updated count
        var countQuery string
        if rl.dbType == "sqlite" {
            countQuery = `
                SELECT request_count FROM rate_limits 
                WHERE user_id = ? AND resource = ? 
                AND window_start = ? AND window_size = ?`
        } else {
            countQuery = `
                SELECT request_count FROM rate_limits 
                WHERE user_id = $1 AND resource = $2 
                AND window_start = $3 AND window_size = $4`
        }
        
        if rl.dbType == "sqlite" {
            err = tx.QueryRowContext(ctx, countQuery, userID, resource, 
                windowStart.Unix(), int(config.WindowSize.Seconds())).Scan(&requestCount)
        } else {
            err = tx.QueryRowContext(ctx, countQuery, userID, resource, 
                windowStart, config.WindowSize).Scan(&requestCount)
        }
        
        if err != nil {
            return nil, fmt.Errorf("get request count: %w", err)
        }
    }
    
    windowEnd := windowStart.Add(config.WindowSize)
    rateLimitResult := &RateLimitResult{
        Allowed:   requestCount <= config.MaxRequests,
        Remaining: max(0, config.MaxRequests-requestCount),
        ResetAt:   windowEnd,
    }
    
    if !rateLimitResult.Allowed {
        // Apply penalty
        err = rl.applyPenalty(ctx, tx, userID, resource, config)
        if err != nil {
            log.Printf("Error applying penalty: %v", err)
        }
        
        rateLimitResult.RetryAfter = time.Until(windowEnd)
    }
    
    return rateLimitResult, tx.Commit()
}

func (rl *RateLimiter) tokenBucketCheck(ctx context.Context, userID, resource string, 
    config *RateLimitConfig) (*RateLimitResult, error) {
    
    tx, err := rl.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    now := time.Now()
    
    // Get current token count
    var tokens int
    var lastRefillAt time.Time
    
    var selectQuery string
    if rl.dbType == "sqlite" {
        selectQuery = `
            SELECT request_count, last_request_at FROM rate_limits 
            WHERE user_id = ? AND resource = ? 
            ORDER BY created_at DESC LIMIT 1`
    } else {
        selectQuery = `
            SELECT request_count, last_request_at FROM rate_limits 
            WHERE user_id = $1 AND resource = $2 
            ORDER BY created_at DESC LIMIT 1`
    }
    
    err = tx.QueryRowContext(ctx, selectQuery, userID, resource).Scan(&tokens, &lastRefillAt)
    if err == sql.ErrNoRows {
        // Initialize bucket
        tokens = config.BurstSize
        lastRefillAt = now
    } else if err != nil {
        return nil, fmt.Errorf("get token count: %w", err)
    }
    
    // Calculate tokens to add based on refill rate
    timeSinceRefill := now.Sub(lastRefillAt)
    tokensToAdd := int(timeSinceRefill.Seconds()) * config.RefillRate
    tokens = min(config.BurstSize, tokens+tokensToAdd)
    
    result := &RateLimitResult{
        Allowed:   tokens > 0,
        Remaining: max(0, tokens-1),
        ResetAt:   now.Add(time.Duration(config.BurstSize/config.RefillRate) * time.Second),
    }
    
    if result.Allowed {
        tokens--
        // Update token count
        err = rl.updateTokenCount(ctx, tx, userID, resource, tokens, now)
        if err != nil {
            return nil, fmt.Errorf("update token count: %w", err)
        }
    } else {
        // Apply penalty
        err = rl.applyPenalty(ctx, tx, userID, resource, config)
        if err != nil {
            log.Printf("Error applying penalty: %v", err)
        }
        
        result.RetryAfter = time.Duration(1.0/float64(config.RefillRate)) * time.Second
    }
    
    return result, tx.Commit()
}

func (rl *RateLimiter) recordRequest(ctx context.Context, tx *sql.Tx, userID, resource string, 
    config *RateLimitConfig, now time.Time) error {
    
    // Create a small window (e.g., 1 second) for this request
    windowStart := time.Unix(now.Unix(), 0)
    
    var upsertQuery string
    if rl.dbType == "sqlite" {
        upsertQuery = `
            INSERT INTO rate_limits 
            (user_id, resource, window_start, window_size, request_count, 
             last_request_at, created_at, updated_at)
            VALUES (?, ?, ?, 1, 1, ?, ?, ?)
            ON CONFLICT(user_id, resource, window_start, window_size)
            DO UPDATE SET 
                request_count = request_count + 1,
                last_request_at = ?,
                updated_at = ?`
    } else {
        upsertQuery = `
            INSERT INTO rate_limits 
            (user_id, resource, window_start, window_size, request_count, 
             last_request_at, created_at, updated_at)
            VALUES ($1, $2, $3, INTERVAL '1 second', 1, $4, $4, $4)
            ON CONFLICT(user_id, resource, window_start, window_size)
            DO UPDATE SET 
                request_count = rate_limits.request_count + 1,
                last_request_at = $4,
                updated_at = $4`
    }
    
    if rl.dbType == "sqlite" {
        _, err := tx.ExecContext(ctx, upsertQuery, userID, resource, 
            windowStart.Unix(), now.Unix(), now.Unix(), now.Unix(), 
            now.Unix(), now.Unix())
        return err
    } else {
        _, err := tx.ExecContext(ctx, upsertQuery, userID, resource, 
            windowStart, now, now)
        return err
    }
}

func (rl *RateLimiter) updateTokenCount(ctx context.Context, tx *sql.Tx, userID, resource string, 
    tokens int, now time.Time) error {
    
    var upsertQuery string
    if rl.dbType == "sqlite" {
        upsertQuery = `
            INSERT INTO rate_limits 
            (user_id, resource, window_start, window_size, request_count, 
             last_request_at, created_at, updated_at)
            VALUES (?, ?, ?, 0, ?, ?, ?, ?)
            ON CONFLICT(user_id, resource, window_start, window_size)
            DO UPDATE SET 
                request_count = ?,
                last_request_at = ?,
                updated_at = ?`
    } else {
        upsertQuery = `
            INSERT INTO rate_limits 
            (user_id, resource, window_start, window_size, request_count, 
             last_request_at, created_at, updated_at)
            VALUES ($1, $2, $3, INTERVAL '0 seconds', $4, $5, $5, $5)
            ON CONFLICT(user_id, resource, window_start, window_size)
            DO UPDATE SET 
                request_count = $4,
                last_request_at = $5,
                updated_at = $5`
    }
    
    windowStart := time.Unix(now.Unix(), 0)
    if rl.dbType == "sqlite" {
        _, err := tx.ExecContext(ctx, upsertQuery, userID, resource, 
            windowStart.Unix(), tokens, now.Unix(), now.Unix(), now.Unix(),
            tokens, now.Unix(), now.Unix())
        return err
    } else {
        _, err := tx.ExecContext(ctx, upsertQuery, userID, resource, 
            windowStart, tokens, now, now)
        return err
    }
}

func (rl *RateLimiter) applyPenalty(ctx context.Context, tx *sql.Tx, userID, resource string, 
    config *RateLimitConfig) error {
    
    if len(config.ProgressivePenalties) == 0 {
        return nil // No penalties configured
    }
    
    now := time.Now()
    
    // Get current violation count
    var violationCount int
    var lastViolationAt sql.NullInt64
    
    var selectQuery string
    if rl.dbType == "sqlite" {
        selectQuery = `
            SELECT violation_count, last_violation_at 
            FROM rate_limit_penalties 
            WHERE user_id = ? AND resource = ?`
    } else {
        selectQuery = `
            SELECT violation_count, EXTRACT(EPOCH FROM last_violation_at)::BIGINT 
            FROM rate_limit_penalties 
            WHERE user_id = $1 AND resource = $2`
    }
    
    err := tx.QueryRowContext(ctx, selectQuery, userID, resource).Scan(&violationCount, &lastViolationAt)
    if err == sql.ErrNoRows {
        violationCount = 0
    } else if err != nil {
        return fmt.Errorf("get violation count: %w", err)
    }
    
    // Reset violation count if last violation was more than 24 hours ago
    if lastViolationAt.Valid {
        lastViolation := time.Unix(lastViolationAt.Int64, 0)
        if now.Sub(lastViolation) > 24*time.Hour {
            violationCount = 0
        }
    }
    
    violationCount++
    
    // Find applicable penalty tier
    var penaltyDuration time.Duration
    for _, tier := range config.ProgressivePenalties {
        if violationCount >= tier.ViolationCount {
            penaltyDuration = tier.PenaltyDuration
        }
    }
    
    if penaltyDuration == 0 {
        return nil // No penalty for this violation count
    }
    
    penaltyUntil := now.Add(penaltyDuration)
    
    // Upsert penalty record
    var upsertQuery string
    if rl.dbType == "sqlite" {
        upsertQuery = `
            INSERT INTO rate_limit_penalties 
            (user_id, resource, violation_count, last_violation_at, 
             penalty_until, penalty_duration, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, resource)
            DO UPDATE SET 
                violation_count = ?,
                last_violation_at = ?,
                penalty_until = ?,
                penalty_duration = ?,
                updated_at = ?`
    } else {
        upsertQuery = `
            INSERT INTO rate_limit_penalties 
            (user_id, resource, violation_count, last_violation_at, 
             penalty_until, penalty_duration, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $4, $4)
            ON CONFLICT(user_id, resource)
            DO UPDATE SET 
                violation_count = $3,
                last_violation_at = $4,
                penalty_until = $5,
                penalty_duration = $6,
                updated_at = $4`
    }
    
    if rl.dbType == "sqlite" {
        _, err = tx.ExecContext(ctx, upsertQuery, userID, resource, 
            violationCount, now.Unix(), penaltyUntil.Unix(), 
            int(penaltyDuration.Seconds()), now.Unix(), now.Unix(),
            violationCount, now.Unix(), penaltyUntil.Unix(), 
            int(penaltyDuration.Seconds()), now.Unix())
    } else {
        _, err = tx.ExecContext(ctx, upsertQuery, userID, resource, 
            violationCount, now, penaltyUntil, penaltyDuration, now)
    }
    
    return err
}

func (rl *RateLimiter) cleanupExpiredRecords() {
    ticker := time.NewTicker(1 * time.Hour)
    defer ticker.Stop()
    
    for range ticker.C {
        ctx := context.Background()
        
        // Clean up old rate limit records
        var deleteQuery string
        if rl.dbType == "sqlite" {
            deleteQuery = `
                DELETE FROM rate_limits 
                WHERE window_start < ? - window_size - 86400` // Keep extra day for analysis
        } else {
            deleteQuery = `
                DELETE FROM rate_limits 
                WHERE window_start < NOW() - window_size - INTERVAL '1 day'`
        }
        
        if rl.dbType == "sqlite" {
            rl.db.ExecContext(ctx, deleteQuery, time.Now().Unix())
        } else {
            rl.db.ExecContext(ctx, deleteQuery)
        }
        
        // Clean up expired penalties
        var deletePenaltyQuery string
        if rl.dbType == "sqlite" {
            deletePenaltyQuery = `
                DELETE FROM rate_limit_penalties 
                WHERE penalty_until < ?`
        } else {
            deletePenaltyQuery = `
                DELETE FROM rate_limit_penalties 
                WHERE penalty_until < NOW()`
        }
        
        if rl.dbType == "sqlite" {
            rl.db.ExecContext(ctx, deletePenaltyQuery, time.Now().Unix())
        } else {
            rl.db.ExecContext(ctx, deletePenaltyQuery)
        }
    }
}

func max(a, b int) int {
    if a > b {
        return a
    }
    return b
}

func min(a, b int) int {
    if a < b {
        return a
    }
    return b
}
```

### HTTP Middleware

```go
package middleware

import (
    "context"
    "encoding/json"
    "fmt"
    "net/http"
    "strconv"
    "time"
    
    "your-app/ratelimit"
)

type RateLimitMiddleware struct {
    limiter *ratelimit.RateLimiter
}

func NewRateLimitMiddleware(limiter *ratelimit.RateLimiter) *RateLimitMiddleware {
    return &RateLimitMiddleware{limiter: limiter}
}

func (m *RateLimitMiddleware) Handler(resource string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            userID := m.extractUserID(r)
            
            result, err := m.limiter.CheckLimit(r.Context(), userID, resource)
            if err != nil {
                http.Error(w, "Rate limit check failed", http.StatusInternalServerError)
                return
            }
            
            // Set rate limit headers
            w.Header().Set("X-RateLimit-Limit", fmt.Sprintf("%d", result.Remaining+1))
            w.Header().Set("X-RateLimit-Remaining", fmt.Sprintf("%d", result.Remaining))
            w.Header().Set("X-RateLimit-Reset", fmt.Sprintf("%d", result.ResetAt.Unix()))
            
            if !result.Allowed {
                w.Header().Set("Retry-After", fmt.Sprintf("%.0f", result.RetryAfter.Seconds()))
                
                response := map[string]interface{}{
                    "error": "Rate limit exceeded",
                    "retry_after": result.RetryAfter.Seconds(),
                }
                
                if result.PenaltyActive {
                    response["penalty_active"] = true
                    response["penalty_until"] = result.PenaltyUntil.Unix()
                }
                
                w.Header().Set("Content-Type", "application/json")
                w.WriteHeader(http.StatusTooManyRequests)
                json.NewEncoder(w).Encode(response)
                return
            }
            
            next.ServeHTTP(w, r)
        })
    }
}

func (m *RateLimitMiddleware) extractUserID(r *http.Request) string {
    // Extract user ID from request (implement based on your auth system)
    if userID := r.Header.Get("X-User-ID"); userID != "" {
        return userID
    }
    
    // Fallback to IP address
    return r.RemoteAddr
}
```

### Configuration Management

```go
package config

import (
    "database/sql"
    "encoding/json"
    "time"
)

type ConfigManager struct {
    db *sql.DB
}

func NewConfigManager(db *sql.DB) *ConfigManager {
    return &ConfigManager{db: db}
}

func (cm *ConfigManager) SetRateLimitConfig(resource string, config *ratelimit.RateLimitConfig) error {
    penaltiesJSON, _ := json.Marshal(config.ProgressivePenalties)
    
    _, err := cm.db.Exec(`
        INSERT INTO rate_limit_configs 
        (resource, algorithm, max_requests, window_size, burst_size, refill_rate, 
         progressive_penalties, enabled, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW(), NOW())
        ON CONFLICT (resource)
        DO UPDATE SET
            algorithm = $2,
            max_requests = $3,
            window_size = $4,
            burst_size = $5,
            refill_rate = $6,
            progressive_penalties = $7,
            enabled = $8,
            updated_at = NOW()`,
        resource, config.Algorithm, config.MaxRequests, config.WindowSize,
        config.BurstSize, config.RefillRate, penaltiesJSON, config.Enabled)
    
    return err
}

// Example configurations
func (cm *ConfigManager) SetupDefaultConfigs() error {
    configs := []*ratelimit.RateLimitConfig{
        {
            Resource:    "api",
            Algorithm:   "sliding_window",
            MaxRequests: 100,
            WindowSize:  time.Minute,
            Enabled:     true,
            ProgressivePenalties: []ratelimit.PenaltyTier{
                {ViolationCount: 1, PenaltyDuration: time.Minute},
                {ViolationCount: 3, PenaltyDuration: 5 * time.Minute},
                {ViolationCount: 5, PenaltyDuration: 15 * time.Minute},
                {ViolationCount: 10, PenaltyDuration: time.Hour},
                {ViolationCount: 20, PenaltyDuration: 24 * time.Hour},
            },
        },
        {
            Resource:    "login",
            Algorithm:   "fixed_window",
            MaxRequests: 5,
            WindowSize:  time.Minute,
            Enabled:     true,
            ProgressivePenalties: []ratelimit.PenaltyTier{
                {ViolationCount: 1, PenaltyDuration: 5 * time.Minute},
                {ViolationCount: 3, PenaltyDuration: 30 * time.Minute},
                {ViolationCount: 5, PenaltyDuration: 2 * time.Hour},
            },
        },
        {
            Resource:    "upload",
            Algorithm:   "token_bucket",
            MaxRequests: 10,
            WindowSize:  time.Minute,
            BurstSize:   5,
            RefillRate:  1, // 1 token per second
            Enabled:     true,
        },
    }
    
    for _, config := range configs {
        if err := cm.SetRateLimitConfig(config.Resource, config); err != nil {
            return err
        }
    }
    
    return nil
}
```

## Usage Examples

### Basic Setup

```go
func main() {
    // SQLite for high-performance local rate limiting
    sqliteDB, err := sql.Open("sqlite3", "rate_limits.db")
    if err != nil {
        log.Fatal(err)
    }
    
    // PostgreSQL for distributed rate limiting
    postgresDB, err := sql.Open("postgres", "postgres://user:pass@localhost/db?sslmode=disable")
    if err != nil {
        log.Fatal(err)
    }
    
    // Create rate limiter
    limiter := ratelimit.NewRateLimiter(sqliteDB, "sqlite")
    
    // Setup configurations
    configManager := config.NewConfigManager(postgresDB)
    configManager.SetupDefaultConfigs()
    
    // Create middleware
    rateLimitMiddleware := middleware.NewRateLimitMiddleware(limiter)
    
    // Apply to routes
    http.Handle("/api/", rateLimitMiddleware.Handler("api")(apiHandler))
    http.Handle("/login", rateLimitMiddleware.Handler("login")(loginHandler))
    http.Handle("/upload", rateLimitMiddleware.Handler("upload")(uploadHandler))
    
    log.Fatal(http.ListenAndServe(":8080", nil))
}
```

### Manual Rate Limit Checking

```go
func handleRequest(w http.ResponseWriter, r *http.Request) {
    userID := "user123"
    resource := "api"
    
    result, err := limiter.CheckLimit(r.Context(), userID, resource)
    if err != nil {
        http.Error(w, "Rate limit check failed", http.StatusInternalServerError)
        return
    }
    
    if !result.Allowed {
        if result.PenaltyActive {
            // User is penalized
            w.WriteHeader(http.StatusTooManyRequests)
            json.NewEncoder(w).Encode(map[string]interface{}{
                "error": "Account temporarily suspended due to rate limit violations",
                "penalty_until": result.PenaltyUntil.Unix(),
                "retry_after": result.RetryAfter.Seconds(),
            })
            return
        }
        
        // Regular rate limit exceeded
        w.Header().Set("Retry-After", fmt.Sprintf("%.0f", result.RetryAfter.Seconds()))
        w.WriteHeader(http.StatusTooManyRequests)
        json.NewEncoder(w).Encode(map[string]interface{}{
            "error": "Rate limit exceeded",
            "retry_after": result.RetryAfter.Seconds(),
            "reset_at": result.ResetAt.Unix(),
        })
        return
    }
    
    // Process request normally
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]interface{}{
        "message": "Request processed",
        "remaining": result.Remaining,
    })
}
```

### Monitoring and Analytics

```sql
-- Current rate limit status
SELECT 
    user_id,
    resource,
    SUM(request_count) as total_requests,
    MAX(last_request_at) as last_request,
    COUNT(*) as windows
FROM rate_limits 
WHERE window_start > NOW() - INTERVAL '1 hour'
GROUP BY user_id, resource
ORDER BY total_requests DESC
LIMIT 20;

-- Users with active penalties
SELECT 
    user_id,
    resource,
    violation_count,
    penalty_until,
    penalty_duration
FROM rate_limit_penalties 
WHERE penalty_until > NOW()
ORDER BY penalty_until DESC;

-- Rate limit violations by resource
SELECT 
    resource,
    COUNT(*) as violations,
    COUNT(DISTINCT user_id) as unique_users,
    AVG(violation_count) as avg_violations_per_user
FROM rate_limit_penalties 
WHERE last_violation_at > NOW() - INTERVAL '24 hours'
GROUP BY resource;

-- Performance metrics
SELECT 
    resource,
    COUNT(*) as total_requests,
    COUNT(*) FILTER (WHERE request_count > max_requests) as violations,
    ROUND(100.0 * COUNT(*) FILTER (WHERE request_count > max_requests) / COUNT(*), 2) as violation_rate
FROM rate_limits rl
JOIN rate_limit_configs rlc ON rl.resource = rlc.resource
WHERE rl.window_start > NOW() - INTERVAL '1 hour'
GROUP BY resource;
```

## Best Practices

### Performance Optimization

1. **Use SQLite for Hot Data**: Store frequently accessed rate limit data in SQLite for faster access
2. **Batch Operations**: Group database operations where possible
3. **Connection Pooling**: Configure appropriate connection pools
4. **Index Optimization**: Ensure proper indexes on lookup columns
5. **Cleanup Strategy**: Regularly clean up expired records

### Security Considerations

1. **User Identification**: Use consistent and secure user identification
2. **Rate Limit Bypass**: Protect against bypass attempts
3. **DDoS Protection**: Implement additional protections for severe attacks
4. **Audit Logging**: Log rate limit violations for analysis
5. **Configuration Security**: Secure rate limit configuration changes

### Monitoring and Alerting

1. **Queue Monitoring**: Monitor rate limit check performance
2. **Violation Tracking**: Track patterns in rate limit violations
3. **System Health**: Monitor database performance and connection health
4. **Business Metrics**: Track impact on legitimate users
5. **Alerting**: Set up alerts for unusual patterns or system issues

## Consequences

### Positive

- **Persistence**: Rate limits survive application restarts
- **Consistency**: Exact counting and consistent behavior
- **Flexibility**: Support for complex rate limiting scenarios
- **Auditability**: Complete audit trail of rate limit decisions
- **Cost Effective**: No need for separate caching infrastructure
- **Distributed Support**: Works across multiple application instances

### Negative

- **Performance Overhead**: Database queries for each rate limit check
- **Complexity**: More complex than simple in-memory solutions
- **Database Load**: Additional load on database systems
- **Latency**: Higher latency compared to memory-based solutions
- **Scaling Challenges**: May require database optimization for high load

## Related Patterns

- **Circuit Breaker**: For protecting downstream services
- **Bulkhead**: For isolating rate limit failures
- **Retry Pattern**: For handling rate limit errors
- **Distributed Locking**: For coordinating rate limits across instances
- **Event Sourcing**: For audit trails of rate limit events
