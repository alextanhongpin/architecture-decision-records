# Use Expvar for Application Metrics and Debugging

## Status

**Accepted** - Use Go's built-in `expvar` package for exposing application metrics and runtime variables in development and production environments.

## Context

Modern applications require observability into their runtime behavior, performance metrics, and operational state. While external monitoring solutions like Prometheus and OpenTelemetry are powerful, they introduce infrastructure complexity and dependencies. Go's built-in `expvar` package provides a lightweight, zero-dependency solution for exposing application metrics via HTTP endpoints.

The `expvar` package ("export variables") allows applications to expose custom metrics and runtime data without requiring external infrastructure. It's particularly valuable for:

- **Development environments** where quick debugging is needed
- **Microservices** that need lightweight monitoring
- **Applications** that require minimal external dependencies
- **Runtime debugging** and performance analysis

However, `expvar` has limitations in distributed systems where metric aggregation and persistence are required.

## Decision

We will use `expvar` as a primary metrics exposure mechanism for:

1. **Application-level metrics** (counters, gauges, histograms)
2. **Runtime debugging information** (goroutine counts, memory usage)
3. **Business metrics** (request counts, error rates, processing times)
4. **Health indicators** (last successful operations, connection status)

### Implementation Guidelines

#### 1. Core Metrics Infrastructure

```go
package metrics

import (
	"expvar"
	"runtime"
	"sync"
	"time"
)

// AppMetrics provides a centralized metrics registry
type AppMetrics struct {
	// Counters
	HttpRequests    *expvar.Int
	ErrorCount      *expvar.Int
	JobsProcessed   *expvar.Int
	
	// Gauges
	ActiveGoroutines *expvar.Int
	ConnectionPool   *expvar.Int
	
	// Custom metrics
	CustomMetrics *expvar.Map
	
	// Business metrics
	BusinessMetrics *expvar.Map
	
	mu sync.RWMutex
}

// Global metrics instance
var Metrics = NewAppMetrics()

func NewAppMetrics() *AppMetrics {
	m := &AppMetrics{
		HttpRequests:    expvar.NewInt("http_requests_total"),
		ErrorCount:      expvar.NewInt("errors_total"),
		JobsProcessed:   expvar.NewInt("jobs_processed_total"),
		ActiveGoroutines: expvar.NewInt("goroutines_active"),
		ConnectionPool:   expvar.NewInt("connection_pool_active"),
		CustomMetrics:   expvar.NewMap("custom"),
		BusinessMetrics: expvar.NewMap("business"),
	}
	
	// Register runtime metrics updater
	go m.updateRuntimeMetrics()
	
	return m
}

// updateRuntimeMetrics periodically updates runtime metrics
func (m *AppMetrics) updateRuntimeMetrics() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	
	for range ticker.C {
		m.ActiveGoroutines.Set(int64(runtime.NumGoroutine()))
		
		var memStats runtime.MemStats
		runtime.ReadMemStats(&memStats)
		m.CustomMetrics.Set("memory_alloc_bytes", &expvar.Int{}).(*expvar.Int).Set(int64(memStats.Alloc))
		m.CustomMetrics.Set("memory_sys_bytes", &expvar.Int{}).(*expvar.Int).Set(int64(memStats.Sys))
	}
}

// RecordError increments error counter with optional labeling
func (m *AppMetrics) RecordError(errorType string) {
	m.ErrorCount.Add(1)
	m.CustomMetrics.Add(errorType+"_errors", 1)
}

// RecordLatency records operation latency
func (m *AppMetrics) RecordLatency(operation string, duration time.Duration) {
	key := operation + "_latency_ms"
	m.CustomMetrics.Set(key, &expvar.Int{}).(*expvar.Int).Set(duration.Milliseconds())
}

// SetGauge sets a gauge metric value
func (m *AppMetrics) SetGauge(name string, value int64) {
	m.CustomMetrics.Set(name, &expvar.Int{}).(*expvar.Int).Set(value)
}

// IncrementCounter increments a counter metric
func (m *AppMetrics) IncrementCounter(name string) {
	m.CustomMetrics.Add(name, 1)
}
```

#### 2. HTTP Middleware Integration

```go
package middleware

import (
	"net/http"
	"strconv"
	"time"
	
	"yourapp/metrics"
)

// MetricsMiddleware records HTTP request metrics
func MetricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		
		// Increment request counter
		metrics.Metrics.HttpRequests.Add(1)
		
		// Wrap response writer to capture status code
		ww := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
		
		next.ServeHTTP(ww, r)
		
		// Record metrics
		duration := time.Since(start)
		metrics.Metrics.RecordLatency("http_request", duration)
		
		// Record status code metrics
		statusClass := strconv.Itoa(ww.statusCode/100) + "xx"
		metrics.Metrics.IncrementCounter("http_" + statusClass)
		
		if ww.statusCode >= 400 {
			metrics.Metrics.RecordError("http_error")
		}
	})
}

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}
```

#### 3. Service-Level Metrics

```go
package service

import (
	"context"
	"time"
	
	"yourapp/metrics"
)

type UserService struct {
	repo UserRepository
}

func (s *UserService) CreateUser(ctx context.Context, user *User) error {
	start := time.Now()
	defer func() {
		metrics.Metrics.RecordLatency("user_create", time.Since(start))
	}()
	
	err := s.repo.Create(ctx, user)
	if err != nil {
		metrics.Metrics.RecordError("user_create")
		return err
	}
	
	metrics.Metrics.IncrementCounter("users_created")
	return nil
}

// Background job metrics
func (s *UserService) ProcessUserBatch(ctx context.Context) error {
	start := time.Now()
	defer func() {
		metrics.Metrics.RecordLatency("user_batch_process", time.Since(start))
	}()
	
	users, err := s.repo.GetPendingUsers(ctx)
	if err != nil {
		metrics.Metrics.RecordError("user_batch_fetch")
		return err
	}
	
	processed := 0
	for _, user := range users {
		if err := s.processUser(ctx, user); err != nil {
			metrics.Metrics.RecordError("user_process")
			continue
		}
		processed++
	}
	
	metrics.Metrics.CustomMetrics.Add("users_batch_processed", int64(processed))
	return nil
}
```

#### 4. Business Metrics Tracking

```go
package business

import (
	"expvar"
	"time"
	
	"yourapp/metrics"
)

// OrderMetrics tracks e-commerce specific metrics
type OrderMetrics struct {
	TotalRevenue   *expvar.Float
	OrderCount     *expvar.Int
	AverageValue   *expvar.Float
	ConversionRate *expvar.Float
}

func NewOrderMetrics() *OrderMetrics {
	om := &OrderMetrics{
		TotalRevenue:   &expvar.Float{},
		OrderCount:     expvar.NewInt("orders_total"),
		AverageValue:   &expvar.Float{},
		ConversionRate: &expvar.Float{},
	}
	
	metrics.Metrics.BusinessMetrics.Set("revenue_total", om.TotalRevenue)
	metrics.Metrics.BusinessMetrics.Set("order_average_value", om.AverageValue)
	metrics.Metrics.BusinessMetrics.Set("conversion_rate", om.ConversionRate)
	
	return om
}

func (om *OrderMetrics) RecordOrder(amount float64) {
	om.OrderCount.Add(1)
	om.TotalRevenue.Add(amount)
	
	// Update average
	count := om.OrderCount.Value()
	if count > 0 {
		avg := om.TotalRevenue.Value() / float64(count)
		om.AverageValue.Set(avg)
	}
}
```

#### 5. Health and Status Tracking

```go
package health

import (
	"context"
	"database/sql"
	"time"
	
	"yourapp/metrics"
)

type HealthChecker struct {
	db    *sql.DB
	redis RedisClient
}

func (h *HealthChecker) StartHealthChecks(ctx context.Context) {
	ticker := time.NewTicker(1 * time.Minute)
	defer ticker.Stop()
	
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			h.checkDatabase()
			h.checkRedis()
		}
	}
}

func (h *HealthChecker) checkDatabase() {
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	
	err := h.db.PingContext(ctx)
	duration := time.Since(start)
	
	if err != nil {
		metrics.Metrics.RecordError("database_health")
		metrics.Metrics.SetGauge("database_healthy", 0)
	} else {
		metrics.Metrics.SetGauge("database_healthy", 1)
	}
	
	metrics.Metrics.RecordLatency("database_ping", duration)
	metrics.Metrics.CustomMetrics.Set("database_last_check", 
		&expvar.Int{}).(*expvar.Int).Set(time.Now().Unix())
}

func (h *HealthChecker) checkRedis() {
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	
	err := h.redis.Ping(ctx).Err()
	duration := time.Since(start)
	
	if err != nil {
		metrics.Metrics.RecordError("redis_health")
		metrics.Metrics.SetGauge("redis_healthy", 0)
	} else {
		metrics.Metrics.SetGauge("redis_healthy", 1)
	}
	
	metrics.Metrics.RecordLatency("redis_ping", duration)
}
```

#### 6. Testing Metrics

```go
package metrics_test

import (
	"expvar"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
	
	"yourapp/metrics"
)

func TestMetricsCollection(t *testing.T) {
	// Reset metrics for testing
	m := metrics.NewAppMetrics()
	
	// Test counter increment
	initial := m.HttpRequests.Value()
	m.HttpRequests.Add(1)
	
	if m.HttpRequests.Value() != initial+1 {
		t.Errorf("Expected counter to increment by 1")
	}
}

func TestMetricsEndpoint(t *testing.T) {
	// Create test server with expvar handler
	mux := http.NewServeMux()
	mux.Handle("/debug/vars", expvar.Handler())
	
	server := httptest.NewServer(mux)
	defer server.Close()
	
	// Make request to metrics endpoint
	resp, err := http.Get(server.URL + "/debug/vars")
	if err != nil {
		t.Fatalf("Failed to get metrics: %v", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		t.Errorf("Expected 200, got %d", resp.StatusCode)
	}
	
	// Verify content type
	contentType := resp.Header.Get("Content-Type")
	if contentType != "application/json; charset=utf-8" {
		t.Errorf("Expected JSON content type, got %s", contentType)
	}
}

func TestErrorRecording(t *testing.T) {
	m := metrics.NewAppMetrics()
	
	initial := m.ErrorCount.Value()
	m.RecordError("test_error")
	
	if m.ErrorCount.Value() != initial+1 {
		t.Errorf("Error count should increment")
	}
	
	// Check custom error metric
	errorVar := m.CustomMetrics.Get("test_error_errors")
	if errorVar == nil {
		t.Errorf("Custom error metric should be created")
	}
}

func BenchmarkMetricsRecording(b *testing.B) {
	m := metrics.NewAppMetrics()
	
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			m.IncrementCounter("benchmark_test")
			m.RecordLatency("benchmark_op", time.Millisecond)
		}
	})
}
```

#### 7. Production Setup

```go
package main

import (
	"context"
	"expvar"
	"net/http"
	"log"
	
	"yourapp/metrics"
	"yourapp/middleware"
)

func main() {
	// Initialize metrics
	metrics.Metrics = metrics.NewAppMetrics()
	
	// Setup HTTP server with metrics middleware
	mux := http.NewServeMux()
	
	// Expose metrics endpoint
	mux.Handle("/debug/vars", expvar.Handler())
	
	// Application routes
	mux.Handle("/api/", middleware.MetricsMiddleware(apiHandler()))
	
	// Start health checks
	healthChecker := &health.HealthChecker{}
	go healthChecker.StartHealthChecks(context.Background())
	
	log.Println("Server starting on :8080")
	log.Println("Metrics available at http://localhost:8080/debug/vars")
	
	if err := http.ListenAndServe(":8080", mux); err != nil {
		log.Fatal(err)
	}
}

func apiHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Simulate some work
		time.Sleep(10 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})
}
```

## Consequences

### Positive

- **Zero Dependencies**: No external infrastructure required
- **Built-in Concurrency**: Thread-safe operations handled by the standard library
- **HTTP Exposure**: Metrics automatically available via HTTP endpoint
- **JSON Format**: Easy integration with monitoring tools
- **Low Overhead**: Minimal performance impact
- **Development Friendly**: Immediate visibility into application state

### Negative

- **No Persistence**: Metrics reset on application restart
- **Single Node**: No built-in aggregation across multiple instances
- **Limited Visualization**: Requires external tools for dashboards
- **No Alerting**: No built-in alerting capabilities
- **Memory Usage**: All metrics stored in memory

### Trade-offs

- **Simplicity vs. Features**: Gains simplicity but loses advanced monitoring features
- **Development vs. Production**: Excellent for development, limited for large-scale production
- **Internal vs. External**: Great for internal debugging, requires external tools for comprehensive monitoring

## Best Practices

1. **Combine with External Monitoring**: Use alongside Prometheus/OpenTelemetry for production
2. **Secure Metrics Endpoint**: Restrict access to `/debug/vars` in production
3. **Memory Management**: Monitor memory usage of metrics collection
4. **Consistent Naming**: Use standardized metric naming conventions
5. **Regular Cleanup**: Remove unused metrics to prevent memory leaks

## References

- [Go expvar Package Documentation](https://pkg.go.dev/expvar)
- [Effective Go: Web Servers](https://golang.org/doc/effective_go.html#web_servers)
- [Prometheus Exposition Formats](https://prometheus.io/docs/instrumenting/exposition_formats/)
- [The USE Method](http://www.brendangregg.com/usemethod.html)
