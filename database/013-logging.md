# Database Logging

## Status

`accepted`

## Context

Database performance monitoring and query analysis are critical for maintaining application health, identifying bottlenecks, and optimizing data access patterns. Without proper logging, issues like slow queries, missing indexes, and poor query patterns go undetected until they impact users.

### Logging Requirements

We need to monitor and log:

- **Query Performance**: Execution time, rows processed, plans used
- **Bad Queries**: Malformed SQL, inefficient patterns, missing indexes
- **Usage Patterns**: Query frequency, access patterns, peak times
- **Cache Performance**: Hit rates, miss patterns, eviction metrics
- **Connection Health**: Pool usage, timeouts, deadlocks
- **Security Events**: Failed authentications, suspicious queries
- **Schema Changes**: DDL operations, migration events

### Logging Challenges

| Challenge | Impact | Solution |
|-----------|---------|----------|
| **Performance Overhead** | Logging can slow down queries | Selective logging, async processing |
| **Volume Management** | Too many logs overwhelm storage | Intelligent sampling, log levels |
| **Sensitive Data** | Queries may contain PII | Parameter sanitization, masking |
| **Correlation** | Hard to trace issues across services | Distributed tracing, correlation IDs |
| **Alert Fatigue** | Too many alerts reduce effectiveness | Smart thresholds, aggregation |

## Decision

Implement a **multi-layer database logging strategy** that combines:

1. **Application-Level Logging**: Custom query instrumentation and metrics
2. **Database-Level Logging**: PostgreSQL slow query logs and performance insights
3. **Infrastructure Logging**: Connection pools, proxy metrics, and resource usage
4. **Observability Integration**: OpenTelemetry tracing and Prometheus metrics

### Architecture Overview

```
Application Layer
├── Query Instrumentation (Go)
├── Connection Pool Monitoring
├── Cache Performance Tracking
└── Custom Metrics Collection

Database Layer
├── PostgreSQL Slow Query Log
├── pg_stat_statements Extension
├── Query Plan Analysis
└── Lock Monitoring

Infrastructure Layer
├── Connection Proxy Logs
├── Resource Usage Metrics
├── Network Performance
└── Backup/Recovery Logs

Observability Stack
├── OpenTelemetry Traces
├── Prometheus Metrics
├── Grafana Dashboards
└── Alert Manager Rules
```

## Implementation

### Application-Level Query Instrumentation

```go
package logging

import (
    "context"
    "database/sql"
    "database/sql/driver"
    "fmt"
    "strings"
    "time"

    "github.com/prometheus/client_golang/prometheus"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/trace"
    "go.uber.org/zap"
)

// QueryLogger handles database query logging and instrumentation
type QueryLogger struct {
    logger      *zap.Logger
    tracer      trace.Tracer
    metrics     *QueryMetrics
    config      *LoggingConfig
    sensitivePatterns []string
}

type LoggingConfig struct {
    SlowQueryThreshold time.Duration `env:"DB_SLOW_QUERY_THRESHOLD" default:"100ms"`
    LogAllQueries      bool          `env:"DB_LOG_ALL_QUERIES" default:"false"`
    LogParameters      bool          `env:"DB_LOG_PARAMETERS" default:"false"`
    SampleRate         float64       `env:"DB_LOG_SAMPLE_RATE" default:"0.1"`
    MaxQueryLength     int           `env:"DB_MAX_QUERY_LENGTH" default:"1000"`
    MaskSensitiveData  bool          `env:"DB_MASK_SENSITIVE" default:"true"`
}

type QueryMetrics struct {
    queryDuration    *prometheus.HistogramVec
    queryCount       *prometheus.CounterVec
    slowQueryCount   *prometheus.CounterVec
    connectionPool   *prometheus.GaugeVec
    cacheHitRate     *prometheus.GaugeVec
    errorCount       *prometheus.CounterVec
}

func NewQueryLogger(logger *zap.Logger, config *LoggingConfig) *QueryLogger {
    return &QueryLogger{
        logger:  logger,
        tracer:  otel.Tracer("database"),
        metrics: newQueryMetrics(),
        config:  config,
        sensitivePatterns: []string{
            "password", "token", "secret", "key", "credential",
            "ssn", "credit_card", "email", "phone",
        },
    }
}

// LoggedDB wraps sql.DB with comprehensive logging
type LoggedDB struct {
    *sql.DB
    logger *QueryLogger
}

func WrapDB(db *sql.DB, logger *QueryLogger) *LoggedDB {
    return &LoggedDB{
        DB:     db,
        logger: logger,
    }
}

// QueryContext executes a query with full instrumentation
func (ldb *LoggedDB) QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error) {
    start := time.Now()
    queryInfo := ldb.logger.analyzeQuery(query, args)
    
    // Start tracing span
    ctx, span := ldb.logger.tracer.Start(ctx, "db.query")
    defer span.End()
    
    span.SetAttributes(
        attribute.String("db.statement", queryInfo.SafeQuery),
        attribute.String("db.operation", queryInfo.Operation),
        attribute.String("db.table", queryInfo.Table),
        attribute.Int("db.parameter_count", len(args)),
    )
    
    // Execute query
    rows, err := ldb.DB.QueryContext(ctx, query, args...)
    duration := time.Since(start)
    
    // Log and record metrics
    ldb.logger.logQuery(ctx, queryInfo, duration, err)
    ldb.logger.recordMetrics(queryInfo, duration, err)
    
    if err != nil {
        span.RecordError(err)
    }
    
    return rows, err
}

// ExecContext executes a statement with full instrumentation
func (ldb *LoggedDB) ExecContext(ctx context.Context, query string, args ...interface{}) (sql.Result, error) {
    start := time.Now()
    queryInfo := ldb.logger.analyzeQuery(query, args)
    
    ctx, span := ldb.logger.tracer.Start(ctx, "db.exec")
    defer span.End()
    
    span.SetAttributes(
        attribute.String("db.statement", queryInfo.SafeQuery),
        attribute.String("db.operation", queryInfo.Operation),
        attribute.String("db.table", queryInfo.Table),
    )
    
    result, err := ldb.DB.ExecContext(ctx, query, args...)
    duration := time.Since(start)
    
    // Record affected rows if successful
    if err == nil && result != nil {
        if rowsAffected, raErr := result.RowsAffected(); raErr == nil {
            span.SetAttributes(attribute.Int64("db.rows_affected", rowsAffected))
        }
    }
    
    ldb.logger.logQuery(ctx, queryInfo, duration, err)
    ldb.logger.recordMetrics(queryInfo, duration, err)
    
    if err != nil {
        span.RecordError(err)
    }
    
    return result, err
}

// QueryInfo contains analyzed query information
type QueryInfo struct {
    RawQuery     string
    SafeQuery    string
    Operation    string
    Table        string
    Parameters   []interface{}
    IsSensitive  bool
    QueryID      string
}

// analyzeQuery extracts metadata from SQL query
func (ql *QueryLogger) analyzeQuery(query string, args []interface{}) *QueryInfo {
    normalizedQuery := strings.TrimSpace(strings.ToUpper(query))
    
    info := &QueryInfo{
        RawQuery:   query,
        Parameters: args,
        QueryID:    generateQueryID(query),
    }
    
    // Extract operation type
    if strings.HasPrefix(normalizedQuery, "SELECT") {
        info.Operation = "SELECT"
    } else if strings.HasPrefix(normalizedQuery, "INSERT") {
        info.Operation = "INSERT"
    } else if strings.HasPrefix(normalizedQuery, "UPDATE") {
        info.Operation = "UPDATE"
    } else if strings.HasPrefix(normalizedQuery, "DELETE") {
        info.Operation = "DELETE"
    } else {
        info.Operation = "OTHER"
    }
    
    // Extract table name (simplified)
    info.Table = ql.extractTableName(normalizedQuery, info.Operation)
    
    // Check for sensitive data
    info.IsSensitive = ql.containsSensitiveData(query)
    
    // Create safe query for logging
    info.SafeQuery = ql.sanitizeQuery(query, args)
    
    return info
}

// sanitizeQuery removes or masks sensitive information
func (ql *QueryLogger) sanitizeQuery(query string, args []interface{}) string {
    if !ql.config.LogParameters {
        return ql.replaceParameters(query)
    }
    
    if ql.config.MaskSensitiveData {
        return ql.maskSensitiveParameters(query, args)
    }
    
    return query
}

// logQuery writes query information to structured logs
func (ql *QueryLogger) logQuery(ctx context.Context, info *QueryInfo, duration time.Duration, err error) {
    // Skip logging based on configuration
    if !ql.config.LogAllQueries && duration < ql.config.SlowQueryThreshold && err == nil {
        return
    }
    
    // Apply sampling for high-volume queries
    if !ql.shouldSample() {
        return
    }
    
    fields := []zap.Field{
        zap.String("query_id", info.QueryID),
        zap.String("operation", info.Operation),
        zap.String("table", info.Table),
        zap.Duration("duration", duration),
        zap.Int("parameter_count", len(info.Parameters)),
        zap.Bool("is_slow", duration >= ql.config.SlowQueryThreshold),
    }
    
    if ql.config.LogParameters && !info.IsSensitive {
        fields = append(fields, zap.Any("parameters", info.Parameters))
    }
    
    // Add correlation ID from context
    if correlationID := getCorrelationID(ctx); correlationID != "" {
        fields = append(fields, zap.String("correlation_id", correlationID))
    }
    
    if err != nil {
        fields = append(fields, zap.Error(err))
        ql.logger.Error("Database query failed", fields...)
    } else if duration >= ql.config.SlowQueryThreshold {
        ql.logger.Warn("Slow database query", fields...)
    } else {
        ql.logger.Debug("Database query executed", fields...)
    }
}

// recordMetrics updates Prometheus metrics
func (ql *QueryLogger) recordMetrics(info *QueryInfo, duration time.Duration, err error) {
    labels := prometheus.Labels{
        "operation": info.Operation,
        "table":     info.Table,
    }
    
    ql.metrics.queryDuration.With(labels).Observe(duration.Seconds())
    ql.metrics.queryCount.With(labels).Inc()
    
    if duration >= ql.config.SlowQueryThreshold {
        ql.metrics.slowQueryCount.With(labels).Inc()
    }
    
    if err != nil {
        errorLabels := prometheus.Labels{
            "operation": info.Operation,
            "table":     info.Table,
            "error_type": classifyError(err),
        }
        ql.metrics.errorCount.With(errorLabels).Inc()
    }
}
```

### Connection Pool Monitoring

```go
package logging

import (
    "context"
    "database/sql"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "go.uber.org/zap"
)

// ConnectionPoolMonitor tracks database connection pool metrics
type ConnectionPoolMonitor struct {
    db      *sql.DB
    logger  *zap.Logger
    metrics *ConnectionPoolMetrics
    ticker  *time.Ticker
    done    chan bool
}

type ConnectionPoolMetrics struct {
    openConnections     prometheus.Gauge
    inUseConnections    prometheus.Gauge
    idleConnections     prometheus.Gauge
    waitCount           prometheus.Counter
    waitDuration        prometheus.Histogram
    maxIdleClosed       prometheus.Counter
    maxLifetimeClosed   prometheus.Counter
}

func NewConnectionPoolMonitor(db *sql.DB, logger *zap.Logger) *ConnectionPoolMonitor {
    monitor := &ConnectionPoolMonitor{
        db:      db,
        logger:  logger,
        metrics: newConnectionPoolMetrics(),
        ticker:  time.NewTicker(30 * time.Second),
        done:    make(chan bool),
    }
    
    go monitor.run()
    return monitor
}

func (cpm *ConnectionPoolMonitor) run() {
    for {
        select {
        case <-cpm.ticker.C:
            cpm.collectMetrics()
        case <-cpm.done:
            return
        }
    }
}

func (cpm *ConnectionPoolMonitor) collectMetrics() {
    stats := cpm.db.Stats()
    
    cpm.metrics.openConnections.Set(float64(stats.OpenConnections))
    cpm.metrics.inUseConnections.Set(float64(stats.InUse))
    cpm.metrics.idleConnections.Set(float64(stats.Idle))
    cpm.metrics.waitCount.Add(float64(stats.WaitCount))
    cpm.metrics.waitDuration.Observe(stats.WaitDuration.Seconds())
    cpm.metrics.maxIdleClosed.Add(float64(stats.MaxIdleClosed))
    cpm.metrics.maxLifetimeClosed.Add(float64(stats.MaxLifetimeClosed))
    
    // Log warnings for problematic states
    if stats.WaitCount > 0 {
        cpm.logger.Warn("Database connection pool experiencing waits",
            zap.Int("open_connections", stats.OpenConnections),
            zap.Int("in_use", stats.InUse),
            zap.Int64("wait_count", stats.WaitCount),
            zap.Duration("wait_duration", stats.WaitDuration),
        )
    }
    
    // Calculate connection pool utilization
    if stats.MaxOpenConnections > 0 {
        utilization := float64(stats.InUse) / float64(stats.MaxOpenConnections)
        if utilization > 0.8 {
            cpm.logger.Warn("High database connection pool utilization",
                zap.Float64("utilization", utilization),
                zap.Int("max_open", stats.MaxOpenConnections),
                zap.Int("in_use", stats.InUse),
            )
        }
    }
}

func (cpm *ConnectionPoolMonitor) Stop() {
    cpm.ticker.Stop()
    close(cpm.done)
}
```

### PostgreSQL Configuration and Monitoring

```sql
-- PostgreSQL configuration for comprehensive logging
-- postgresql.conf settings

-- Enable slow query logging
log_min_duration_statement = 100ms
log_statement = 'all'
log_duration = on
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '

-- Enable detailed logging
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0

-- Enable query statistics
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 10000
pg_stat_statements.track = all
pg_stat_statements.track_utility = on
pg_stat_statements.save = on

-- Enable auto_explain for slow queries
auto_explain.log_min_duration = 100ms
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_timing = on
auto_explain.log_triggers = on
auto_explain.log_verbose = on
auto_explain.log_nested_statements = on

-- Log files configuration
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_file_mode = 0640
log_rotation_age = 1d
log_rotation_size = 100MB
log_truncate_on_rotation = on
```

```go
package monitoring

import (
    "context"
    "database/sql"
    "fmt"
    "time"
    
    "go.uber.org/zap"
)

// PostgreSQLMonitor collects database-level metrics and logs
type PostgreSQLMonitor struct {
    db     *sql.DB
    logger *zap.Logger
}

// SlowQuery represents a slow query from pg_stat_statements
type SlowQuery struct {
    Query         string        `db:"query"`
    Calls         int64         `db:"calls"`
    TotalTime     time.Duration `db:"total_time"`
    MeanTime      time.Duration `db:"mean_time"`
    Rows          int64         `db:"rows"`
    HitPercent    float64       `db:"hit_percent"`
    LastSeen      time.Time     `db:"last_seen"`
}

// DatabaseStats represents current database statistics
type DatabaseStats struct {
    ConnectionCount    int64 `db:"connection_count"`
    ActiveConnections  int64 `db:"active_connections"`
    IdleConnections    int64 `db:"idle_connections"`
    BlockedQueries     int64 `db:"blocked_queries"`
    LockWaits          int64 `db:"lock_waits"`
    DeadlockCount      int64 `db:"deadlock_count"`
    CacheHitRatio      float64 `db:"cache_hit_ratio"`
    TempFilesCreated   int64 `db:"temp_files_created"`
    TempBytesWritten   int64 `db:"temp_bytes_written"`
}

func NewPostgreSQLMonitor(db *sql.DB, logger *zap.Logger) *PostgreSQLMonitor {
    return &PostgreSQLMonitor{
        db:     db,
        logger: logger,
    }
}

// GetSlowQueries retrieves slow queries from pg_stat_statements
func (pm *PostgreSQLMonitor) GetSlowQueries(ctx context.Context, limit int) ([]SlowQuery, error) {
    query := `
        SELECT 
            query,
            calls,
            total_time * 1000000 as total_time, -- Convert to microseconds
            mean_time * 1000000 as mean_time,
            rows,
            100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0) AS hit_percent,
            stats_reset as last_seen
        FROM pg_stat_statements
        WHERE mean_time > 100 -- Only queries taking more than 100ms on average
        ORDER BY mean_time DESC
        LIMIT $1
    `
    
    rows, err := pm.db.QueryContext(ctx, query, limit)
    if err != nil {
        return nil, fmt.Errorf("failed to query slow queries: %w", err)
    }
    defer rows.Close()
    
    var slowQueries []SlowQuery
    for rows.Next() {
        var sq SlowQuery
        var totalTimeMicros, meanTimeMicros int64
        
        err := rows.Scan(
            &sq.Query,
            &sq.Calls,
            &totalTimeMicros,
            &meanTimeMicros,
            &sq.Rows,
            &sq.HitPercent,
            &sq.LastSeen,
        )
        if err != nil {
            continue
        }
        
        sq.TotalTime = time.Duration(totalTimeMicros) * time.Microsecond
        sq.MeanTime = time.Duration(meanTimeMicros) * time.Microsecond
        
        slowQueries = append(slowQueries, sq)
    }
    
    return slowQueries, nil
}

// GetDatabaseStats retrieves current database statistics
func (pm *PostgreSQLMonitor) GetDatabaseStats(ctx context.Context) (*DatabaseStats, error) {
    query := `
        SELECT 
            (SELECT count(*) FROM pg_stat_activity) as connection_count,
            (SELECT count(*) FROM pg_stat_activity WHERE state = 'active') as active_connections,
            (SELECT count(*) FROM pg_stat_activity WHERE state = 'idle') as idle_connections,
            (SELECT count(*) FROM pg_stat_activity WHERE waiting = true) as blocked_queries,
            (SELECT sum(deadlocks) FROM pg_stat_database) as deadlock_count,
            (SELECT 
                round(100.0 * sum(blks_hit) / (sum(blks_hit) + sum(blks_read)), 2) 
                FROM pg_stat_database WHERE blks_read > 0
            ) as cache_hit_ratio,
            (SELECT sum(temp_files) FROM pg_stat_database) as temp_files_created,
            (SELECT sum(temp_bytes) FROM pg_stat_database) as temp_bytes_written
    `
    
    var stats DatabaseStats
    err := pm.db.QueryRowContext(ctx, query).Scan(
        &stats.ConnectionCount,
        &stats.ActiveConnections,
        &stats.IdleConnections,
        &stats.BlockedQueries,
        &stats.DeadlockCount,
        &stats.CacheHitRatio,
        &stats.TempFilesCreated,
        &stats.TempBytesWritten,
    )
    
    if err != nil {
        return nil, fmt.Errorf("failed to query database stats: %w", err)
    }
    
    return &stats, nil
}

// LogSlowQueries logs slow queries with analysis
func (pm *PostgreSQLMonitor) LogSlowQueries(ctx context.Context) error {
    slowQueries, err := pm.GetSlowQueries(ctx, 10)
    if err != nil {
        return err
    }
    
    for _, sq := range slowQueries {
        pm.logger.Warn("Slow query detected",
            zap.String("query", truncateQuery(sq.Query, 200)),
            zap.Int64("calls", sq.Calls),
            zap.Duration("mean_time", sq.MeanTime),
            zap.Duration("total_time", sq.TotalTime),
            zap.Int64("rows", sq.Rows),
            zap.Float64("cache_hit_percent", sq.HitPercent),
            zap.Time("last_seen", sq.LastSeen),
        )
    }
    
    return nil
}

// MonitorLockWaits detects and logs lock waits and deadlocks
func (pm *PostgreSQLMonitor) MonitorLockWaits(ctx context.Context) error {
    query := `
        SELECT 
            blocked_locks.pid AS blocked_pid,
            blocked_activity.usename AS blocked_user,
            blocking_locks.pid AS blocking_pid,
            blocking_activity.usename AS blocking_user,
            blocked_activity.query AS blocked_statement,
            blocking_activity.query AS current_statement_in_blocking_process,
            blocked_activity.application_name AS blocked_application,
            blocking_activity.application_name AS blocking_application
        FROM pg_catalog.pg_locks blocked_locks
        JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
        JOIN pg_catalog.pg_locks blocking_locks 
            ON blocking_locks.locktype = blocked_locks.locktype
            AND blocking_locks.DATABASE IS NOT DISTINCT FROM blocked_locks.DATABASE
            AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
            AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
            AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
            AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
            AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
            AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
            AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
            AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
            AND blocking_locks.pid != blocked_locks.pid
        JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
        WHERE NOT blocked_locks.GRANTED
    `
    
    rows, err := pm.db.QueryContext(ctx, query)
    if err != nil {
        return err
    }
    defer rows.Close()
    
    lockWaitCount := 0
    for rows.Next() {
        var blockedPID, blockingPID int
        var blockedUser, blockingUser, blockedQuery, blockingQuery string
        var blockedApp, blockingApp string
        
        err := rows.Scan(&blockedPID, &blockedUser, &blockingPID, &blockingUser,
            &blockedQuery, &blockingQuery, &blockedApp, &blockingApp)
        if err != nil {
            continue
        }
        
        pm.logger.Warn("Lock wait detected",
            zap.Int("blocked_pid", blockedPID),
            zap.String("blocked_user", blockedUser),
            zap.String("blocked_app", blockedApp),
            zap.Int("blocking_pid", blockingPID),
            zap.String("blocking_user", blockingUser),
            zap.String("blocking_app", blockingApp),
            zap.String("blocked_query", truncateQuery(blockedQuery, 200)),
            zap.String("blocking_query", truncateQuery(blockingQuery, 200)),
        )
        
        lockWaitCount++
    }
    
    if lockWaitCount > 0 {
        pm.logger.Warn("Multiple lock waits detected",
            zap.Int("lock_wait_count", lockWaitCount))
    }
    
    return nil
}
```

### Cache Performance Monitoring

```go
package cache

import (
    "context"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "go.uber.org/zap"
)

// CacheMonitor tracks cache performance metrics
type CacheMonitor struct {
    logger  *zap.Logger
    metrics *CacheMetrics
    stats   *CacheStats
}

type CacheMetrics struct {
    hits           prometheus.Counter
    misses         prometheus.Counter
    evictions      prometheus.Counter
    errors         prometheus.Counter
    operationTime  prometheus.Histogram
    size           prometheus.Gauge
}

type CacheStats struct {
    TotalRequests int64
    Hits          int64
    Misses        int64
    HitRate       float64
    EvictionCount int64
    ErrorCount    int64
}

func NewCacheMonitor(logger *zap.Logger) *CacheMonitor {
    return &CacheMonitor{
        logger:  logger,
        metrics: newCacheMetrics(),
        stats:   &CacheStats{},
    }
}

// RecordHit records a cache hit
func (cm *CacheMonitor) RecordHit(key string, duration time.Duration) {
    cm.metrics.hits.Inc()
    cm.metrics.operationTime.Observe(duration.Seconds())
    cm.stats.Hits++
    cm.stats.TotalRequests++
    cm.updateHitRate()
    
    cm.logger.Debug("Cache hit",
        zap.String("key", maskKey(key)),
        zap.Duration("duration", duration),
    )
}

// RecordMiss records a cache miss
func (cm *CacheMonitor) RecordMiss(key string, duration time.Duration) {
    cm.metrics.misses.Inc()
    cm.metrics.operationTime.Observe(duration.Seconds())
    cm.stats.Misses++
    cm.stats.TotalRequests++
    cm.updateHitRate()
    
    cm.logger.Debug("Cache miss",
        zap.String("key", maskKey(key)),
        zap.Duration("duration", duration),
    )
}

// RecordEviction records a cache eviction
func (cm *CacheMonitor) RecordEviction(key string, reason string) {
    cm.metrics.evictions.Inc()
    cm.stats.EvictionCount++
    
    cm.logger.Info("Cache eviction",
        zap.String("key", maskKey(key)),
        zap.String("reason", reason),
    )
}

// RecordError records a cache operation error
func (cm *CacheMonitor) RecordError(operation string, err error) {
    cm.metrics.errors.Inc()
    cm.stats.ErrorCount++
    
    cm.logger.Error("Cache operation error",
        zap.String("operation", operation),
        zap.Error(err),
    )
}

func (cm *CacheMonitor) updateHitRate() {
    if cm.stats.TotalRequests > 0 {
        cm.stats.HitRate = float64(cm.stats.Hits) / float64(cm.stats.TotalRequests)
    }
}

// LogPerformanceReport logs periodic cache performance summary
func (cm *CacheMonitor) LogPerformanceReport() {
    cm.logger.Info("Cache performance report",
        zap.Int64("total_requests", cm.stats.TotalRequests),
        zap.Int64("hits", cm.stats.Hits),
        zap.Int64("misses", cm.stats.Misses),
        zap.Float64("hit_rate", cm.stats.HitRate),
        zap.Int64("evictions", cm.stats.EvictionCount),
        zap.Int64("errors", cm.stats.ErrorCount),
    )
}
```

### Alerting and Dashboards

```yaml
# prometheus-alerts.yml
groups:
  - name: database_performance
    rules:
      - alert: SlowDatabaseQueries
        expr: histogram_quantile(0.95, rate(db_query_duration_seconds_bucket[5m])) > 0.5
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Slow database queries detected"
          description: "95th percentile query time is {{ $value }}s"

      - alert: HighDatabaseErrorRate
        expr: rate(db_errors_total[5m]) > 0.1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "High database error rate"
          description: "Database error rate is {{ $value }} errors/sec"

      - alert: DatabaseConnectionPoolExhausted
        expr: db_connection_pool_in_use / db_connection_pool_max > 0.9
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Database connection pool nearly exhausted"
          description: "Connection pool utilization is {{ $value | humanizePercentage }}"

      - alert: LowCacheHitRate
        expr: cache_hit_rate < 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Low cache hit rate"
          description: "Cache hit rate is {{ $value | humanizePercentage }}"

  - name: database_health
    rules:
      - alert: DatabaseDown
        expr: up{job="postgres"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Database is down"
          description: "PostgreSQL database is not responding"

      - alert: HighLockWaits
        expr: pg_stat_database_deadlocks > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Database deadlocks detected"
          description: "{{ $value }} deadlocks detected in the last interval"
```

```json
{
  "dashboard": {
    "id": null,
    "title": "Database Performance Dashboard",
    "tags": ["database", "postgresql", "performance"],
    "timezone": "browser",
    "panels": [
      {
        "title": "Query Performance",
        "type": "graph",
        "targets": [
          {
            "expr": "histogram_quantile(0.50, rate(db_query_duration_seconds_bucket[5m]))",
            "legendFormat": "50th percentile"
          },
          {
            "expr": "histogram_quantile(0.95, rate(db_query_duration_seconds_bucket[5m]))",
            "legendFormat": "95th percentile"
          },
          {
            "expr": "histogram_quantile(0.99, rate(db_query_duration_seconds_bucket[5m]))",
            "legendFormat": "99th percentile"
          }
        ]
      },
      {
        "title": "Query Volume",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(db_queries_total[5m])",
            "legendFormat": "{{ operation }} - {{ table }}"
          }
        ]
      },
      {
        "title": "Connection Pool Status",
        "type": "stat",
        "targets": [
          {
            "expr": "db_connection_pool_open",
            "legendFormat": "Open Connections"
          },
          {
            "expr": "db_connection_pool_in_use",
            "legendFormat": "In Use"
          },
          {
            "expr": "db_connection_pool_idle",
            "legendFormat": "Idle"
          }
        ]
      },
      {
        "title": "Cache Performance",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(cache_hits_total[5m])",
            "legendFormat": "Cache Hits/sec"
          },
          {
            "expr": "rate(cache_misses_total[5m])",
            "legendFormat": "Cache Misses/sec"
          },
          {
            "expr": "cache_hits_total / (cache_hits_total + cache_misses_total)",
            "legendFormat": "Hit Rate"
          }
        ]
      }
    ]
  }
}
```

## Consequences

### Positive

- **Performance Visibility**: Clear insights into query performance and bottlenecks
- **Proactive Monitoring**: Early detection of performance degradation
- **Debugging Capability**: Detailed logs help diagnose complex issues
- **Optimization Guidance**: Data-driven decisions for performance tuning
- **Security Monitoring**: Detection of suspicious database activity
- **Capacity Planning**: Historical data supports infrastructure planning

### Negative

- **Performance Overhead**: Logging adds latency to database operations
- **Storage Costs**: Comprehensive logs require significant storage
- **Complexity**: Multiple logging layers increase system complexity
- **Alert Fatigue**: Too many metrics can overwhelm operations teams
- **Privacy Concerns**: Logs may contain sensitive data

### Mitigations

- **Selective Logging**: Use sampling and thresholds to reduce overhead
- **Log Retention**: Implement appropriate retention policies
- **Data Masking**: Automatically mask sensitive information
- **Smart Alerting**: Use intelligent thresholds and aggregation
- **Regular Review**: Periodically review logging configuration effectiveness

## Related Patterns

- **[Docker Testing](004-dockertest.md)**: Testing logging in isolated environments
- **[Redis Convention](012-redis-convention.md)**: Redis operation logging
- **[Optimistic Locking](007-optimistic-locking.md)**: Logging lock conflicts
- **[Rate Limiting](018-rate-limit.md)**: Monitoring rate limit effectiveness 
