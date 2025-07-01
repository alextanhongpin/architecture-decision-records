# Application Metrics and Observability

## Status

`accepted`

## Context

Application instrumentation through metrics is fundamental for understanding system performance, scalability, and reliability. Without proper metrics, teams operate blindly, making it difficult to identify performance bottlenecks, capacity limits, and reliability issues before they impact users.

### Current Challenges

Modern distributed systems face several observability challenges:
- **Lack of visibility**: Cannot identify performance degradation or capacity limits
- **Difficult troubleshooting**: Hard to correlate issues across services and components
- **Reactive operations**: Problems discovered only after user impact
- **Capacity planning**: Insufficient data for scaling decisions
- **SLA compliance**: No objective measures for service level objectives

### Business Impact

Poor observability leads to:
- **User experience degradation**: Undetected performance issues
- **Operational overhead**: Manual investigation and firefighting
- **Revenue loss**: Downtime and performance issues affect business
- **Resource waste**: Over-provisioning due to lack of utilization data
- **Compliance risks**: Unable to demonstrate SLA adherence

Similar to a game character with HP/MP, agility, and strength stats, collecting application metrics provides comprehensive visibility into system health and performance characteristics.


## Decision

We will implement comprehensive application metrics using Prometheus-style instrumentation with standardized labels and dashboards for observability across all services.

### Core Metrics Strategy

For RESTful microservices, we will capture metrics for all endpoints to enable error tracing and performance monitoring when deploying new features.

#### 1. HTTP Request Metrics

Track essential HTTP metrics with standardized labels:

```go
package metrics

import (
    "net/http"
    "strconv"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
)

var (
    // Request count metric
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"service", "method", "path", "status_code", "version"},
    )
    
    // Request duration metric
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: prometheus.DefBuckets,
        },
        []string{"service", "method", "path", "status_code", "version"},
    )
    
    // Request size metric
    httpRequestSize = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_size_bytes",
            Help:    "HTTP request size in bytes",
            Buckets: prometheus.ExponentialBuckets(100, 10, 8),
        },
        []string{"service", "method", "path"},
    )
    
    // Response size metric
    httpResponseSize = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_response_size_bytes",
            Help:    "HTTP response size in bytes",
            Buckets: prometheus.ExponentialBuckets(100, 10, 8),
        },
        []string{"service", "method", "path", "status_code"},
    )
)

// HTTP middleware for metrics collection
func HTTPMetricsMiddleware(serviceName, version string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            start := time.Now()
            
            // Normalize path (remove path parameters)
            normalizedPath := normalizePath(r.URL.Path)
            
            // Wrap response writer to capture metrics
            wrapper := &metricsResponseWriter{
                ResponseWriter: w,
                statusCode:     http.StatusOK,
            }
            
            // Record request size
            if r.ContentLength > 0 {
                httpRequestSize.WithLabelValues(
                    serviceName,
                    r.Method,
                    normalizedPath,
                ).Observe(float64(r.ContentLength))
            }
            
            // Process request
            next.ServeHTTP(wrapper, r)
            
            // Record metrics
            duration := time.Since(start).Seconds()
            statusCode := strconv.Itoa(wrapper.statusCode)
            
            httpRequestsTotal.WithLabelValues(
                serviceName,
                r.Method,
                normalizedPath,
                statusCode,
                version,
            ).Inc()
            
            httpRequestDuration.WithLabelValues(
                serviceName,
                r.Method,
                normalizedPath,
                statusCode,
                version,
            ).Observe(duration)
            
            httpResponseSize.WithLabelValues(
                serviceName,
                r.Method,
                normalizedPath,
                statusCode,
            ).Observe(float64(wrapper.bytesWritten))
        })
    }
}

type metricsResponseWriter struct {
    http.ResponseWriter
    statusCode   int
    bytesWritten int64
}

func (mrw *metricsResponseWriter) WriteHeader(statusCode int) {
    mrw.statusCode = statusCode
    mrw.ResponseWriter.WriteHeader(statusCode)
}

func (mrw *metricsResponseWriter) Write(data []byte) (int, error) {
    n, err := mrw.ResponseWriter.Write(data)
    mrw.bytesWritten += int64(n)
    return n, err
}

// Normalize path to remove path parameters
func normalizePath(path string) string {
    // Replace UUIDs with placeholder
    uuidRegex := regexp.MustCompile(`/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}`)
    path = uuidRegex.ReplaceAllString(path, "/{id}")
    
    // Replace numeric IDs
    numericRegex := regexp.MustCompile(`/\d+`)
    path = numericRegex.ReplaceAllString(path, "/{id}")
    
    return path
}
```

#### 2. Business Metrics

Track domain-specific metrics for business insights:

```go
var (
    // Business transaction metrics
    businessTransactionsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "business_transactions_total",
            Help: "Total number of business transactions",
        },
        []string{"service", "transaction_type", "status", "version"},
    )
    
    // Transaction value metrics
    transactionValue = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "transaction_value_amount",
            Help:    "Transaction value amount",
            Buckets: prometheus.ExponentialBuckets(1, 10, 10),
        },
        []string{"service", "transaction_type", "currency"},
    )
    
    // User activity metrics
    activeUsers = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "active_users_current",
            Help: "Current number of active users",
        },
        []string{"service", "time_window"},
    )
)

// Business metrics helper
type BusinessMetrics struct {
    serviceName string
    version     string
}

func NewBusinessMetrics(serviceName, version string) *BusinessMetrics {
    return &BusinessMetrics{
        serviceName: serviceName,
        version:     version,
    }
}

func (bm *BusinessMetrics) RecordTransaction(transactionType, status string, amount float64, currency string) {
    businessTransactionsTotal.WithLabelValues(
        bm.serviceName,
        transactionType,
        status,
        bm.version,
    ).Inc()
    
    if amount > 0 {
        transactionValue.WithLabelValues(
            bm.serviceName,
            transactionType,
            currency,
        ).Observe(amount)
    }
}

func (bm *BusinessMetrics) UpdateActiveUsers(timeWindow string, count float64) {
    activeUsers.WithLabelValues(
        bm.serviceName,
        timeWindow,
    ).Set(count)
}
```

#### 3. Database Metrics

Instrument database operations for performance monitoring:

```go
var (
    // Database connection metrics
    dbConnectionsActive = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "db_connections_active",
            Help: "Number of active database connections",
        },
        []string{"service", "database", "pool"},
    )
    
    dbConnectionsIdle = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "db_connections_idle",
            Help: "Number of idle database connections",
        },
        []string{"service", "database", "pool"},
    )
    
    // Database query metrics
    dbQueriesTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "db_queries_total",
            Help: "Total number of database queries",
        },
        []string{"service", "database", "operation", "table", "status"},
    )
    
    dbQueryDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "db_query_duration_seconds",
            Help:    "Database query duration in seconds",
            Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10},
        },
        []string{"service", "database", "operation", "table"},
    )
)

// Database metrics middleware
type DBMetrics struct {
    serviceName string
    database    string
}

func NewDBMetrics(serviceName, database string) *DBMetrics {
    return &DBMetrics{
        serviceName: serviceName,
        database:    database,
    }
}

func (dm *DBMetrics) RecordQuery(operation, table string, duration time.Duration, err error) {
    status := "success"
    if err != nil {
        status = "error"
    }
    
    dbQueriesTotal.WithLabelValues(
        dm.serviceName,
        dm.database,
        operation,
        table,
        status,
    ).Inc()
    
    dbQueryDuration.WithLabelValues(
        dm.serviceName,
        dm.database,
        operation,
        table,
    ).Observe(duration.Seconds())
}

func (dm *DBMetrics) UpdateConnectionStats(pool string, active, idle int) {
    dbConnectionsActive.WithLabelValues(
        dm.serviceName,
        dm.database,
        pool,
    ).Set(float64(active))
    
    dbConnectionsIdle.WithLabelValues(
        dm.serviceName,
        dm.database,
        pool,
    ).Set(float64(idle))
}
```

#### 4. External Service Metrics

Monitor external API calls and dependencies:

```go
var (
    // External service call metrics
    externalCallsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "external_calls_total",
            Help: "Total number of external service calls",
        },
        []string{"service", "target_service", "operation", "status_code"},
    )
    
    externalCallDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "external_call_duration_seconds",
            Help:    "External service call duration in seconds",
            Buckets: []float64{.01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10, 30},
        },
        []string{"service", "target_service", "operation"},
    )
    
    // Circuit breaker metrics
    circuitBreakerState = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "circuit_breaker_state",
            Help: "Circuit breaker state (0=closed, 1=half-open, 2=open)",
        },
        []string{"service", "target_service"},
    )
)

// External service metrics helper
type ExternalMetrics struct {
    serviceName string
}

func NewExternalMetrics(serviceName string) *ExternalMetrics {
    return &ExternalMetrics{serviceName: serviceName}
}

func (em *ExternalMetrics) RecordCall(targetService, operation string, duration time.Duration, statusCode int) {
    statusCodeStr := strconv.Itoa(statusCode)
    
    externalCallsTotal.WithLabelValues(
        em.serviceName,
        targetService,
        operation,
        statusCodeStr,
    ).Inc()
    
    externalCallDuration.WithLabelValues(
        em.serviceName,
        targetService,
        operation,
    ).Observe(duration.Seconds())
}

func (em *ExternalMetrics) UpdateCircuitBreakerState(targetService string, state int) {
    circuitBreakerState.WithLabelValues(
        em.serviceName,
        targetService,
    ).Set(float64(state))
}
```

### Release and Deployment Metrics

Differentiate between stable and canary releases for deployment monitoring:

```go
var (
    // Deployment metrics
    deploymentInfo = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "deployment_info",
            Help: "Deployment information",
        },
        []string{"service", "version", "environment", "deployment_type", "git_commit"},
    )
    
    // Feature flag metrics
    featureFlagUsage = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "feature_flag_usage_total",
            Help: "Feature flag usage count",
        },
        []string{"service", "flag_name", "flag_value", "user_segment"},
    )
)

// Deployment metrics initialization
func InitializeDeploymentMetrics(serviceName, version, environment, deploymentType, gitCommit string) {
    deploymentInfo.WithLabelValues(
        serviceName,
        version,
        environment,
        deploymentType,
        gitCommit,
    ).Set(1)
}

// Automated release tagging
func AutoAddReleaseTag() string {
    // Get from environment variables set by CI/CD
    version := os.Getenv("SERVICE_VERSION")
    gitCommit := os.Getenv("GIT_COMMIT")
    buildNumber := os.Getenv("BUILD_NUMBER")
    
    if version == "" {
        version = "unknown"
    }
    
    if gitCommit != "" && len(gitCommit) > 7 {
        gitCommit = gitCommit[:7] // Short commit hash
    }
    
    if buildNumber != "" {
        return fmt.Sprintf("%s-build.%s-%s", version, buildNumber, gitCommit)
    }
    
    return fmt.Sprintf("%s-%s", version, gitCommit)
}
``` 


### Dashboard Strategy

Create layered dashboards for different audiences and use cases:

#### 1. Service Overview Dashboard

```json
{
  "dashboard": {
    "title": "Service Overview",
    "panels": [
      {
        "title": "Request Rate",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total{service=\"$service\"}[5m])) by (service)",
            "legendFormat": "{{service}}"
          }
        ]
      },
      {
        "title": "Error Rate",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total{service=\"$service\",status_code=~\"5..\"}[5m])) / sum(rate(http_requests_total{service=\"$service\"}[5m]))",
            "legendFormat": "Error Rate %"
          }
        ]
      },
      {
        "title": "Response Time Percentiles",
        "targets": [
          {
            "expr": "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{service=\"$service\"}[5m])) by (le))",
            "legendFormat": "P50"
          },
          {
            "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service=\"$service\"}[5m])) by (le))",
            "legendFormat": "P95"
          },
          {
            "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{service=\"$service\"}[5m])) by (le))",
            "legendFormat": "P99"
          }
        ]
      }
    ]
  }
}
```

#### 2. Endpoint-Specific Dashboard

```json
{
  "dashboard": {
    "title": "Endpoint Details",
    "panels": [
      {
        "title": "Requests by Endpoint",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total{service=\"$service\"}[5m])) by (path, method)",
            "legendFormat": "{{method}} {{path}}"
          }
        ]
      },
      {
        "title": "Top Slow Endpoints",
        "targets": [
          {
            "expr": "topk(10, histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service=\"$service\"}[5m])) by (path, method, le)))",
            "legendFormat": "{{method}} {{path}}"
          }
        ]
      },
      {
        "title": "Error Rate by Endpoint",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total{service=\"$service\",status_code=~\"5..\"}[5m])) by (path, method) / sum(rate(http_requests_total{service=\"$service\"}[5m])) by (path, method)",
            "legendFormat": "{{method}} {{path}}"
          }
        ]
      }
    ]
  }
}
```

#### 3. Business Metrics Dashboard

```json
{
  "dashboard": {
    "title": "Business Metrics",
    "panels": [
      {
        "title": "Transaction Volume",
        "targets": [
          {
            "expr": "sum(rate(business_transactions_total{service=\"$service\"}[5m])) by (transaction_type)",
            "legendFormat": "{{transaction_type}}"
          }
        ]
      },
      {
        "title": "Transaction Success Rate",
        "targets": [
          {
            "expr": "sum(rate(business_transactions_total{service=\"$service\",status=\"success\"}[5m])) / sum(rate(business_transactions_total{service=\"$service\"}[5m]))",
            "legendFormat": "Success Rate %"
          }
        ]
      },
      {
        "title": "Active Users",
        "targets": [
          {
            "expr": "active_users_current{service=\"$service\"}",
            "legendFormat": "{{time_window}}"
          }
        ]
      }
    ]
  }
}
```

### Alerting Rules

Define Prometheus alerting rules for proactive monitoring:

```yaml
groups:
- name: service_alerts
  rules:
  - alert: HighErrorRate
    expr: |
      (
        sum(rate(http_requests_total{status_code=~"5.."}[5m])) by (service)
        /
        sum(rate(http_requests_total[5m])) by (service)
      ) > 0.05
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "High error rate detected"
      description: "Service {{ $labels.service }} has error rate above 5% for 2 minutes"
      
  - alert: HighLatency
    expr: |
      histogram_quantile(0.95,
        sum(rate(http_request_duration_seconds_bucket[5m])) by (service, le)
      ) > 1.0
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "High latency detected"
      description: "Service {{ $labels.service }} P95 latency is above 1 second"
      
  - alert: DatabaseConnectionPoolExhaustion
    expr: |
      (
        db_connections_active / (db_connections_active + db_connections_idle)
      ) > 0.9
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "Database connection pool nearly exhausted"
      description: "Service {{ $labels.service }} database pool utilization above 90%"
```

### Success Rate Calculation

Calculate success rate excluding irrelevant client errors:

```promql
# Success rate excluding 4xx client errors (except 429)
sum(rate(http_requests_total{status_code!~"4..",status_code!="429"}[5m])) 
/ 
sum(rate(http_requests_total{status_code!~"4..",status_code!="429"}[5m])) + sum(rate(http_requests_total{status_code=~"5..|429"}[5m]))

# Alternative: Success rate for business-critical endpoints only
sum(rate(http_requests_total{path=~"/api/v1/(transactions|payments|orders).*",status_code=~"2.."}[5m]))
/
sum(rate(http_requests_total{path=~"/api/v1/(transactions|payments|orders).*"}[5m]))
```

## Monitoring Philosophy

Monitoring is essential for providing early insights into system behavior and should be accessible to product managers, engineers, and stakeholders. Operating without monitoring is like crossing a busy road blindfolded - you might survive most of the time, but the risk is unnecessarily high.

### RED Method

Focus on the three key signals for user-facing services:
- **Rate**: Request rate (requests per second)
- **Errors**: Error rate (percentage of failed requests)  
- **Duration**: Response time distribution (latency percentiles)

### USE Method

For resource monitoring:
- **Utilization**: How busy the resource is
- **Saturation**: How much work is queued
- **Errors**: Count of error events

### Golden Signals (Google SRE)

Four fundamental metrics for monitoring:
1. **Latency**: Time to process requests
2. **Traffic**: Demand on the system
3. **Errors**: Rate of failed requests
4. **Saturation**: Resource utilization

## Error Handling and Correlation

While metrics are essential for tracking error rates and creating alerts, they cannot replace the detailed context provided by logging. Both are essential for effective error tracking and mitigation in production.

**Metrics provide:**
- Quantitative data for alerting and trends
- Historical patterns and correlations
- Resource utilization and performance data
- Service level indicator (SLI) measurements

**Logs provide:**
- Qualitative context and details
- Specific error messages and stack traces
- Request/response data for debugging
- Timeline of events leading to issues

### Correlation Strategy

Use metrics to detect issues and logs to investigate root causes:

```go
// Example: Correlating metrics with logs
func HandleCriticalError(ctx context.Context, err error, operation string) {
    // Increment error metric
    errorMetrics.WithLabelValues(
        serviceName,
        operation,
        getErrorType(err),
    ).Inc()
    
    // Log detailed error information
    logger.Error(ctx, "Critical operation failed",
        "operation", operation,
        "error", err.Error(),
        "stack_trace", getStackTrace(),
        "correlation_id", getCorrelationID(ctx),
        "user_id", getUserID(ctx),
    )
    
    // Create alert if error rate exceeds threshold
    if shouldAlert(operation) {
        alertManager.SendAlert(Alert{
            Service:   serviceName,
            Operation: operation,
            Message:   fmt.Sprintf("High error rate in %s", operation),
            Severity:  "critical",
        })
    }
}
```

## Implementation Examples

### Complete Service Instrumentation

```go
package main

import (
    "context"
    "net/http"
    "time"
    
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
    // Initialize metrics
    serviceName := "user-service"
    version := AutoAddReleaseTag()
    
    // Initialize deployment metrics
    InitializeDeploymentMetrics(
        serviceName,
        version,
        os.Getenv("ENVIRONMENT"),
        os.Getenv("DEPLOYMENT_TYPE"),
        os.Getenv("GIT_COMMIT"),
    )
    
    // Create metrics instances
    businessMetrics := NewBusinessMetrics(serviceName, version)
    dbMetrics := NewDBMetrics(serviceName, "postgres")
    externalMetrics := NewExternalMetrics(serviceName)
    
    // Setup HTTP router with metrics middleware
    mux := http.NewServeMux()
    
    // Add metrics endpoint
    mux.Handle("/metrics", promhttp.Handler())
    
    // Add application endpoints
    mux.HandleFunc("/users", handleUsers(businessMetrics))
    mux.HandleFunc("/health", handleHealth)
    
    // Wrap with metrics middleware
    handler := HTTPMetricsMiddleware(serviceName, version)(mux)
    
    // Start server
    server := &http.Server{
        Addr:    ":8080",
        Handler: handler,
    }
    
    log.Printf("Starting %s version %s on port 8080", serviceName, version)
    if err := server.ListenAndServe(); err != nil {
        log.Fatal(err)
    }
}

func handleUsers(metrics *BusinessMetrics) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        
        // Business logic here
        user, err := createUser(r.Context())
        if err != nil {
            metrics.RecordTransaction("user_creation", "failed", 0, "")
            http.Error(w, err.Error(), http.StatusInternalServerError)
            return
        }
        
        // Record successful transaction
        metrics.RecordTransaction("user_creation", "success", 0, "")
        
        // Return response
        w.Header().Set("Content-Type", "application/json")
        json.NewEncoder(w).Encode(user)
        
        // Log performance
        log.Printf("User creation completed in %v", time.Since(start))
    }
}
```

### Kubernetes Deployment with Metrics

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-service
  labels:
    app: user-service
    version: v1.2.3
spec:
  replicas: 3
  selector:
    matchLabels:
      app: user-service
  template:
    metadata:
      labels:
        app: user-service
        version: v1.2.3
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: user-service
        image: user-service:v1.2.3
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: SERVICE_NAME
          value: "user-service"
        - name: SERVICE_VERSION
          value: "v1.2.3"
        - name: ENVIRONMENT
          value: "production"
        - name: DEPLOYMENT_TYPE
          value: "stable"
        - name: GIT_COMMIT
          value: "abc1234"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
```

## Consequences

### Positive
- **Proactive monitoring**: Early detection of performance and reliability issues
- **Data-driven decisions**: Objective metrics for capacity planning and optimization
- **Improved reliability**: Faster incident detection and resolution
- **Business insights**: Understanding user behavior and system usage patterns
- **SLA compliance**: Objective measurement of service level objectives

### Negative
- **Performance overhead**: Metrics collection adds CPU and memory overhead
- **Storage costs**: Time-series data requires significant storage capacity
- **Complexity**: Additional infrastructure and monitoring tools required
- **Alert fatigue**: Too many alerts can reduce effectiveness
- **Learning curve**: Teams need to understand metrics and dashboard creation

### Mitigation Strategies
- **Efficient instrumentation**: Use sampling and efficient data structures
- **Retention policies**: Implement appropriate data retention to manage storage costs
- **Alert tuning**: Carefully tune alert thresholds to reduce false positives
- **Training**: Provide team training on metrics and observability practices
- **Progressive rollout**: Start with essential metrics and expand gradually

## Best Practices

1. **Start with the basics**: Implement RED/USE method metrics first
2. **Use consistent labeling**: Standardize metric names and labels across services
3. **Monitor what matters**: Focus on user-impacting metrics and business KPIs
4. **Avoid high cardinality**: Be careful with labels that have many possible values
5. **Set up alerting**: Create meaningful alerts based on metrics
6. **Regular review**: Periodically review and optimize metrics collection
7. **Document metrics**: Maintain clear documentation of metric meanings and usage
8. **Correlate with logs**: Use metrics for detection and logs for investigation

## References

- [Prometheus Best Practices](https://prometheus.io/docs/practices/naming/)
- [Google SRE Book - Monitoring](https://sre.google/sre-book/monitoring-distributed-systems/)
- [The RED Method](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/)
- [The USE Method](http://www.brendangregg.com/usemethod.html)
- [Four Golden Signals](https://sre.google/sre-book/service-level-objectives/)
- [Grafana Dashboard Best Practices](https://grafana.com/docs/grafana/latest/best-practices/)
- [OpenTelemetry Metrics](https://opentelemetry.io/docs/specs/otel/metrics/)

