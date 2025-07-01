# RED Monitoring Pattern

## Status
Accepted

## Context
Effective monitoring is crucial for understanding system health and performance. Without proper metrics, it's impossible to detect issues, optimize performance, or make data-driven decisions about system improvements.

## Problem
Traditional monitoring approaches often suffer from:

1. **Metric overload**: Too many metrics without clear priorities
2. **Lack of actionable insights**: Metrics that don't guide specific actions
3. **Poor signal-to-noise ratio**: Important alerts buried in noise
4. **Inconsistent measurement**: Different services using different monitoring approaches

## Decision
We will implement the RED monitoring pattern (Rate, Errors, Duration) as our primary observability strategy, supplemented by business metrics and resource utilization monitoring.

## RED Monitoring Framework

### Core RED Metrics

1. **Rate**: How many requests per second
2. **Errors**: How many requests are failing
3. **Duration**: How long requests take to process

## Implementation

### HTTP Service Monitoring

```go
package monitoring

import (
    "net/http"
    "strconv"
    "strings"
    "time"
    
    "github.com/gorilla/mux"
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    // Rate: HTTP requests per second
    HTTPRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "path", "status_code"},
    )
    
    // Duration: HTTP request duration
    HTTPRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "path", "status_code"},
    )
    
    // Errors: HTTP error rate
    HTTPRequestErrors = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_request_errors_total",
            Help: "Total number of HTTP request errors",
        },
        []string{"method", "path", "error_type"},
    )
    
    // Active requests (bonus metric)
    HTTPActiveRequests = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "http_active_requests",
            Help: "Number of active HTTP requests",
        },
        []string{"method", "path"},
    )
)

// HTTPMetricsMiddleware provides RED metrics for HTTP handlers
func HTTPMetricsMiddleware() func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            start := time.Now()
            
            // Extract path pattern from router
            pathPattern := extractPathPattern(r)
            method := r.Method
            
            // Track active requests
            HTTPActiveRequests.WithLabelValues(method, pathPattern).Inc()
            defer HTTPActiveRequests.WithLabelValues(method, pathPattern).Dec()
            
            // Wrap response writer to capture status code
            wrapper := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
            
            // Process request
            next.ServeHTTP(wrapper, r)
            
            // Record metrics
            duration := time.Since(start).Seconds()
            statusCode := strconv.Itoa(wrapper.statusCode)
            
            // Rate metric
            HTTPRequestsTotal.WithLabelValues(method, pathPattern, statusCode).Inc()
            
            // Duration metric
            HTTPRequestDuration.WithLabelValues(method, pathPattern, statusCode).Observe(duration)
            
            // Error metric (for 4xx and 5xx responses)
            if wrapper.statusCode >= 400 {
                errorType := getErrorType(wrapper.statusCode)
                HTTPRequestErrors.WithLabelValues(method, pathPattern, errorType).Inc()
            }
        })
    }
}

type responseWriter struct {
    http.ResponseWriter
    statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
    rw.statusCode = code
    rw.ResponseWriter.WriteHeader(code)
}

func extractPathPattern(r *http.Request) string {
    // Extract path pattern from mux router
    route := mux.CurrentRoute(r)
    if route == nil {
        return sanitizePath(r.URL.Path)
    }
    
    pathTemplate, err := route.GetPathTemplate()
    if err != nil {
        return sanitizePath(r.URL.Path)
    }
    
    return pathTemplate
}

func sanitizePath(path string) string {
    // Replace numeric IDs with placeholders
    parts := strings.Split(path, "/")
    for i, part := range parts {
        if isNumeric(part) || isUUID(part) {
            parts[i] = "{id}"
        }
    }
    return strings.Join(parts, "/")
}

func getErrorType(statusCode int) string {
    switch {
    case statusCode >= 400 && statusCode < 500:
        return "client_error"
    case statusCode >= 500:
        return "server_error"
    default:
        return "unknown"
    }
}
```

### Database Monitoring

```go
package monitoring

import (
    "context"
    "database/sql"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    // Database RED metrics
    DBQueriesTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "db_queries_total",
            Help: "Total number of database queries",
        },
        []string{"repository", "operation", "status"},
    )
    
    DBQueryDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "db_query_duration_seconds",
            Help:    "Database query duration in seconds",
            Buckets: []float64{0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10},
        },
        []string{"repository", "operation"},
    )
    
    DBQueryErrors = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "db_query_errors_total",
            Help: "Total number of database query errors",
        },
        []string{"repository", "operation", "error_type"},
    )
    
    DBActiveConnections = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "db_active_connections",
            Help: "Number of active database connections",
        },
        []string{"database"},
    )
)

// DBMetrics wraps database operations with monitoring
type DBMetrics struct {
    db         *sql.DB
    repository string
}

func NewDBMetrics(db *sql.DB, repository string) *DBMetrics {
    return &DBMetrics{
        db:         db,
        repository: repository,
    }
}

func (d *DBMetrics) QueryContext(ctx context.Context, operation, query string, args ...interface{}) (*sql.Rows, error) {
    start := time.Now()
    
    rows, err := d.db.QueryContext(ctx, query, args...)
    
    // Record metrics
    duration := time.Since(start).Seconds()
    status := "success"
    
    if err != nil {
        status = "error"
        errorType := classifyDBError(err)
        DBQueryErrors.WithLabelValues(d.repository, operation, errorType).Inc()
    }
    
    DBQueriesTotal.WithLabelValues(d.repository, operation, status).Inc()
    DBQueryDuration.WithLabelValues(d.repository, operation).Observe(duration)
    
    return rows, err
}

func (d *DBMetrics) ExecContext(ctx context.Context, operation, query string, args ...interface{}) (sql.Result, error) {
    start := time.Now()
    
    result, err := d.db.ExecContext(ctx, query, args...)
    
    // Record metrics
    duration := time.Since(start).Seconds()
    status := "success"
    
    if err != nil {
        status = "error"
        errorType := classifyDBError(err)
        DBQueryErrors.WithLabelValues(d.repository, operation, errorType).Inc()
    }
    
    DBQueriesTotal.WithLabelValues(d.repository, operation, status).Inc()
    DBQueryDuration.WithLabelValues(d.repository, operation).Observe(duration)
    
    return result, err
}

func classifyDBError(err error) string {
    // Classify database errors
    errStr := err.Error()
    switch {
    case strings.Contains(errStr, "timeout"):
        return "timeout"
    case strings.Contains(errStr, "connection"):
        return "connection"
    case strings.Contains(errStr, "constraint"):
        return "constraint"
    case strings.Contains(errStr, "syntax"):
        return "syntax"
    default:
        return "other"
    }
}
```

### Cache Monitoring

```go
package monitoring

import (
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    CacheOpsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "cache_operations_total",
            Help: "Total number of cache operations",
        },
        []string{"repository", "operation", "result"},
    )
    
    CacheOpDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "cache_operation_duration_seconds",
            Help:    "Cache operation duration in seconds",
            Buckets: []float64{0.0001, 0.0005, 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1},
        },
        []string{"repository", "operation"},
    )
    
    CacheHitRatio = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "cache_hit_ratio",
            Help: "Cache hit ratio",
        },
        []string{"repository", "key_pattern"},
    )
)

// CacheMetrics wraps cache operations with monitoring
type CacheMetrics struct {
    repository string
}

func NewCacheMetrics(repository string) *CacheMetrics {
    return &CacheMetrics{repository: repository}
}

func (c *CacheMetrics) RecordGet(keyPattern string, hit bool, duration time.Duration) {
    result := "miss"
    if hit {
        result = "hit"
    }
    
    CacheOpsTotal.WithLabelValues(c.repository, "get", result).Inc()
    CacheOpDuration.WithLabelValues(c.repository, "get").Observe(duration.Seconds())
    
    // Update hit ratio (simplified - in production, use a sliding window)
    if hit {
        CacheHitRatio.WithLabelValues(c.repository, keyPattern).Set(1)
    } else {
        CacheHitRatio.WithLabelValues(c.repository, keyPattern).Set(0)
    }
}

func (c *CacheMetrics) RecordSet(keyPattern string, duration time.Duration) {
    CacheOpsTotal.WithLabelValues(c.repository, "set", "success").Inc()
    CacheOpDuration.WithLabelValues(c.repository, "set").Observe(duration.Seconds())
}

func (c *CacheMetrics) RecordDelete(keyPattern string, duration time.Duration) {
    CacheOpsTotal.WithLabelValues(c.repository, "delete", "success").Inc()
    CacheOpDuration.WithLabelValues(c.repository, "delete").Observe(duration.Seconds())
}
```

### Service-Level Monitoring

```go
package monitoring

import (
    "context"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    ServiceOpsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "service_operations_total",
            Help: "Total number of service operations",
        },
        []string{"service", "action", "status"},
    )
    
    ServiceOpDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "service_operation_duration_seconds",
            Help:    "Service operation duration in seconds",
            Buckets: prometheus.DefBuckets,
        },
        []string{"service", "action"},
    )
    
    ServiceOpErrors = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "service_operation_errors_total",
            Help: "Total number of service operation errors",
        },
        []string{"service", "action", "error_type"},
    )
)

// ServiceMetrics provides monitoring for service operations
type ServiceMetrics struct {
    serviceName string
}

func NewServiceMetrics(serviceName string) *ServiceMetrics {
    return &ServiceMetrics{serviceName: serviceName}
}

func (s *ServiceMetrics) RecordOperation(ctx context.Context, action string, fn func() error) error {
    start := time.Now()
    
    err := fn()
    
    duration := time.Since(start).Seconds()
    status := "success"
    
    if err != nil {
        status = "error"
        errorType := classifyServiceError(err)
        ServiceOpErrors.WithLabelValues(s.serviceName, action, errorType).Inc()
    }
    
    ServiceOpsTotal.WithLabelValues(s.serviceName, action, status).Inc()
    ServiceOpDuration.WithLabelValues(s.serviceName, action).Observe(duration)
    
    return err
}

func classifyServiceError(err error) string {
    // Classify service errors based on error types
    switch {
    case strings.Contains(err.Error(), "timeout"):
        return "timeout"
    case strings.Contains(err.Error(), "not found"):
        return "not_found"
    case strings.Contains(err.Error(), "unauthorized"):
        return "unauthorized"
    case strings.Contains(err.Error(), "validation"):
        return "validation"
    default:
        return "other"
    }
}
```

## Business Metrics

### Product-Level Metrics

```go
package monitoring

import (
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    // Daily Active Users
    DAU = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "daily_active_users",
            Help: "Daily active users",
        },
        []string{"date"},
    )
    
    // User Actions
    UserActions = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "user_actions_total",
            Help: "Total number of user actions",
        },
        []string{"action", "user_segment"},
    )
    
    // Revenue Metrics
    Revenue = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "revenue_total",
            Help: "Total revenue",
        },
        []string{"product", "currency"},
    )
    
    // Feature Usage
    FeatureUsage = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "feature_usage_total",
            Help: "Total feature usage",
        },
        []string{"feature", "user_segment"},
    )
)

// BusinessMetrics tracks product-level metrics
type BusinessMetrics struct{}

func NewBusinessMetrics() *BusinessMetrics {
    return &BusinessMetrics{}
}

func (b *BusinessMetrics) RecordUserAction(action, userSegment string) {
    UserActions.WithLabelValues(action, userSegment).Inc()
}

func (b *BusinessMetrics) RecordRevenue(product, currency string, amount float64) {
    Revenue.WithLabelValues(product, currency).Add(amount)
}

func (b *BusinessMetrics) RecordFeatureUsage(feature, userSegment string) {
    FeatureUsage.WithLabelValues(feature, userSegment).Inc()
}

func (b *BusinessMetrics) UpdateDAU(date string, count float64) {
    DAU.WithLabelValues(date).Set(count)
}
```

## Dashboard Configuration

### Grafana Dashboard JSON

```json
{
  "dashboard": {
    "title": "RED Monitoring Dashboard",
    "panels": [
      {
        "title": "Request Rate",
        "type": "graph",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total[5m])) by (path)",
            "legendFormat": "{{path}}"
          }
        ]
      },
      {
        "title": "Error Rate",
        "type": "graph",
        "targets": [
          {
            "expr": "sum(rate(http_request_errors_total[5m])) by (path) / sum(rate(http_requests_total[5m])) by (path)",
            "legendFormat": "{{path}}"
          }
        ]
      },
      {
        "title": "Response Duration (p95)",
        "type": "graph",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (path, le))",
            "legendFormat": "{{path}}"
          }
        ]
      },
      {
        "title": "Database Query Duration",
        "type": "graph",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, sum(rate(db_query_duration_seconds_bucket[5m])) by (repository, operation, le))",
            "legendFormat": "{{repository}}.{{operation}}"
          }
        ]
      }
    ]
  }
}
```

## Alerting Rules

### Prometheus Alerting Rules

```yaml
# alerts.yml
groups:
  - name: red_monitoring
    rules:
      # High error rate
      - alert: HighErrorRate
        expr: sum(rate(http_request_errors_total[5m])) / sum(rate(http_requests_total[5m])) > 0.05
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High error rate detected"
          description: "Error rate is {{ $value | humanizePercentage }} for the last 5 minutes"
      
      # High response time
      - alert: HighResponseTime
        expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le)) > 1.0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High response time detected"
          description: "95th percentile response time is {{ $value }}s"
      
      # Low request rate (potential issue)
      - alert: LowRequestRate
        expr: sum(rate(http_requests_total[5m])) < 1
        for: 10m
        labels:
          severity: info
        annotations:
          summary: "Low request rate"
          description: "Request rate is {{ $value }} requests/sec"
      
      # Database query timeout
      - alert: DatabaseSlowQueries
        expr: histogram_quantile(0.95, sum(rate(db_query_duration_seconds_bucket[5m])) by (repository, le)) > 5.0
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "Slow database queries detected"
          description: "95th percentile query time is {{ $value }}s for {{ $labels.repository }}"
```

## Key Performance Indicators (KPIs)

### SLA Metrics

```promql
# Request Success Rate (SLA: 99.9%)
sum(rate(http_requests_total{status_code!~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# Response Time SLA (95th percentile < 500ms)
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))

# Availability (uptime percentage)
up / (up + (1 - up)) * 100
```

### Top-K Queries

```promql
# Top 10 slowest endpoints
topk(10, histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (path, le)))

# Top 10 endpoints by error count
topk(10, sum(rate(http_request_errors_total[5m])) by (path))

# Top 10 busiest endpoints
topk(10, sum(rate(http_requests_total[5m])) by (path))

# Top 10 slowest database operations
topk(10, histogram_quantile(0.95, sum(rate(db_query_duration_seconds_bucket[5m])) by (repository, operation, le)))
```

## Best Practices

1. **Use consistent labeling**: Maintain consistent label names across all metrics
2. **Avoid high cardinality**: Don't use user IDs or request IDs as labels
3. **Set appropriate buckets**: Use histogram buckets that align with your SLAs
4. **Monitor the monitors**: Ensure your monitoring system itself is reliable
5. **Alert on symptoms, not causes**: Alert on user-facing issues, not internal metrics
6. **Use standardized patterns**: Apply RED metrics consistently across all services

## Implementation Checklist

- [ ] HTTP middleware for RED metrics
- [ ] Database operation monitoring
- [ ] Cache operation monitoring  
- [ ] Service-level operation monitoring
- [ ] Business metrics tracking
- [ ] Grafana dashboards
- [ ] Prometheus alerting rules
- [ ] SLA/SLO definitions
- [ ] Runbook documentation
- [ ] Regular metric review process

## Consequences

### Advantages
- **Actionable insights**: RED metrics directly relate to user experience
- **Consistent monitoring**: Standardized approach across all services
- **Early problem detection**: Issues caught before they impact users significantly
- **Performance optimization**: Data-driven performance improvements
- **Business alignment**: Metrics tied to business outcomes

### Disadvantages
- **Implementation overhead**: Additional code required for instrumentation
- **Storage costs**: Prometheus storage requirements for metrics retention
- **Alert fatigue**: Potential for too many alerts if thresholds aren't tuned properly
- **Monitoring complexity**: Additional systems to maintain and monitor

## References
- [The RED Method](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/)
- [Site Reliability Engineering](https://sre.google/sre-book/)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/naming/)
  
