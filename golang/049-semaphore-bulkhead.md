# Semaphore-Based Bulkhead Pattern for Resource Protection

## Status

**Accepted** - Use semaphore-based bulkhead pattern to limit concurrent operations and prevent resource exhaustion in Go applications.

## Context

In distributed systems and high-throughput applications, uncontrolled concurrent operations can lead to resource exhaustion, cascading failures, and system instability. The bulkhead pattern, borrowed from ship design, compartmentalizes failures by isolating resources into separate pools.

A semaphore-based bulkhead implementation provides:

- **Concurrency Control**: Limit simultaneous operations to prevent resource exhaustion
- **Timeout Support**: Prevent indefinite blocking when resources are unavailable
- **Graceful Degradation**: Allow some operations to proceed while protecting critical resources
- **Memory Protection**: Prevent goroutine explosion that can lead to OOM conditions

Without proper concurrency limits, applications can experience:
- Database connection pool exhaustion
- Memory pressure from excessive goroutines
- CPU thrashing from context switching overhead
- Cascading failures across service boundaries

## Decision

We will implement semaphore-based bulkheads using Go's `golang.org/x/sync/semaphore` package for:

1. **Database Operations**: Limit concurrent database queries
2. **External API Calls**: Control outbound HTTP requests
3. **File I/O Operations**: Prevent file descriptor exhaustion
4. **CPU-Intensive Tasks**: Limit concurrent processing operations
5. **Memory-Intensive Operations**: Control memory allocation patterns

### Implementation Guidelines

#### 1. Core Semaphore Wrapper

```go
package bulkhead

import (
	"context"
	"fmt"
	"time"
	
	"golang.org/x/sync/semaphore"
)

// Bulkhead provides semaphore-based resource protection
type Bulkhead struct {
	sem      *semaphore.Weighted
	name     string
	capacity int64
	timeout  time.Duration
}

// Config holds bulkhead configuration
type Config struct {
	Name     string
	Capacity int64
	Timeout  time.Duration
}

// NewBulkhead creates a new semaphore-based bulkhead
func NewBulkhead(config Config) *Bulkhead {
	if config.Capacity <= 0 {
		config.Capacity = 10 // Default capacity
	}
	if config.Timeout <= 0 {
		config.Timeout = 30 * time.Second // Default timeout
	}
	if config.Name == "" {
		config.Name = "unnamed"
	}
	
	return &Bulkhead{
		sem:      semaphore.NewWeighted(config.Capacity),
		name:     config.Name,
		capacity: config.Capacity,
		timeout:  config.Timeout,
	}
}

// Execute runs the given function within the bulkhead constraints
func (b *Bulkhead) Execute(ctx context.Context, fn func(context.Context) error) error {
	// Create timeout context
	timeoutCtx, cancel := context.WithTimeout(ctx, b.timeout)
	defer cancel()
	
	// Acquire semaphore with timeout
	if err := b.sem.Acquire(timeoutCtx, 1); err != nil {
		if timeoutCtx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("bulkhead '%s' timeout: failed to acquire resource within %v", b.name, b.timeout)
		}
		return fmt.Errorf("bulkhead '%s' acquire failed: %w", b.name, err)
	}
	defer b.sem.Release(1)
	
	// Execute the function with original context
	return fn(ctx)
}

// ExecuteWithWeight runs function with custom weight
func (b *Bulkhead) ExecuteWithWeight(ctx context.Context, weight int64, fn func(context.Context) error) error {
	if weight <= 0 || weight > b.capacity {
		return fmt.Errorf("invalid weight %d for bulkhead '%s' with capacity %d", weight, b.name, b.capacity)
	}
	
	timeoutCtx, cancel := context.WithTimeout(ctx, b.timeout)
	defer cancel()
	
	if err := b.sem.Acquire(timeoutCtx, weight); err != nil {
		if timeoutCtx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("bulkhead '%s' timeout: failed to acquire %d resources", b.name, weight)
		}
		return fmt.Errorf("bulkhead '%s' acquire failed: %w", b.name, err)
	}
	defer b.sem.Release(weight)
	
	return fn(ctx)
}

// TryExecute attempts to execute without blocking
func (b *Bulkhead) TryExecute(ctx context.Context, fn func(context.Context) error) error {
	if !b.sem.TryAcquire(1) {
		return fmt.Errorf("bulkhead '%s' at capacity", b.name)
	}
	defer b.sem.Release(1)
	
	return fn(ctx)
}

// Stats returns current bulkhead statistics
func (b *Bulkhead) Stats() BulkheadStats {
	return BulkheadStats{
		Name:     b.name,
		Capacity: b.capacity,
		Timeout:  b.timeout,
	}
}

type BulkheadStats struct {
	Name     string
	Capacity int64
	Timeout  time.Duration
}
```

#### 2. Database Bulkhead Pattern

```go
package repository

import (
	"context"
	"database/sql"
	"time"
	
	"yourapp/bulkhead"
)

type UserRepository struct {
	db       *sql.DB
	bulkhead *bulkhead.Bulkhead
}

func NewUserRepository(db *sql.DB) *UserRepository {
	return &UserRepository{
		db: db,
		bulkhead: bulkhead.NewBulkhead(bulkhead.Config{
			Name:     "database_queries",
			Capacity: 20, // Limit to 20 concurrent DB operations
			Timeout:  10 * time.Second,
		}),
	}
}

func (r *UserRepository) GetUser(ctx context.Context, userID string) (*User, error) {
	var user User
	
	err := r.bulkhead.Execute(ctx, func(ctx context.Context) error {
		query := "SELECT id, name, email FROM users WHERE id = ?"
		row := r.db.QueryRowContext(ctx, query, userID)
		return row.Scan(&user.ID, &user.Name, &user.Email)
	})
	
	if err != nil {
		return nil, err
	}
	
	return &user, nil
}

func (r *UserRepository) CreateUser(ctx context.Context, user *User) error {
	return r.bulkhead.Execute(ctx, func(ctx context.Context) error {
		query := "INSERT INTO users (id, name, email) VALUES (?, ?, ?)"
		_, err := r.db.ExecContext(ctx, query, user.ID, user.Name, user.Email)
		return err
	})
}

// Batch operations use higher weight
func (r *UserRepository) CreateUsersBatch(ctx context.Context, users []*User) error {
	// Use weight proportional to batch size, but cap it
	weight := int64(len(users))
	if weight > 5 {
		weight = 5
	}
	
	return r.bulkhead.ExecuteWithWeight(ctx, weight, func(ctx context.Context) error {
		tx, err := r.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		defer tx.Rollback()
		
		stmt, err := tx.PrepareContext(ctx, "INSERT INTO users (id, name, email) VALUES (?, ?, ?)")
		if err != nil {
			return err
		}
		defer stmt.Close()
		
		for _, user := range users {
			if _, err := stmt.ExecContext(ctx, user.ID, user.Name, user.Email); err != nil {
				return err
			}
		}
		
		return tx.Commit()
	})
}
```

#### 3. Testing Bulkheads

```go
package bulkhead_test

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	
	"yourapp/bulkhead"
)

func TestBulkheadConcurrencyLimit(t *testing.T) {
	b := bulkhead.NewBulkhead(bulkhead.Config{
		Name:     "test",
		Capacity: 2,
		Timeout:  1 * time.Second,
	})
	
	var concurrent int64
	var maxConcurrent int64
	
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			
			err := b.Execute(context.Background(), func(ctx context.Context) error {
				current := atomic.AddInt64(&concurrent, 1)
				defer atomic.AddInt64(&concurrent, -1)
				
				// Track maximum concurrent operations
				for {
					max := atomic.LoadInt64(&maxConcurrent)
					if current <= max || atomic.CompareAndSwapInt64(&maxConcurrent, max, current) {
						break
					}
				}
				
				time.Sleep(100 * time.Millisecond)
				return nil
			})
			
			if err != nil {
				t.Errorf("Unexpected error: %v", err)
			}
		}()
	}
	
	wg.Wait()
	
	if maxConcurrent > 2 {
		t.Errorf("Expected max concurrency of 2, got %d", maxConcurrent)
	}
}

func TestBulkheadTimeout(t *testing.T) {
	b := bulkhead.NewBulkhead(bulkhead.Config{
		Name:     "test_timeout",
		Capacity: 1,
		Timeout:  100 * time.Millisecond,
	})
	
	// Start a long-running operation
	go func() {
		b.Execute(context.Background(), func(ctx context.Context) error {
			time.Sleep(500 * time.Millisecond)
			return nil
		})
	}()
	
	// Wait a bit to ensure first operation has started
	time.Sleep(50 * time.Millisecond)
	
	// This should timeout
	err := b.Execute(context.Background(), func(ctx context.Context) error {
		return nil
	})
	
	if err == nil {
		t.Error("Expected timeout error, got nil")
	}
}
```

## Consequences

### Positive

- **Resource Protection**: Prevents resource exhaustion and system overload
- **Graceful Degradation**: Allows systems to handle load spikes gracefully
- **Timeout Control**: Prevents indefinite blocking on resource acquisition
- **Flexible Weighting**: Supports different resource costs for different operations
- **Non-blocking Options**: Provides try-execute for optional operations
- **Context Integration**: Respects Go's context cancellation patterns

### Negative

- **Added Complexity**: Introduces additional abstraction layer
- **Potential Bottlenecks**: Can become a bottleneck if not sized correctly
- **Latency Impact**: Adds overhead for resource acquisition
- **Configuration Overhead**: Requires tuning for optimal performance

### Trade-offs

- **Throughput vs. Stability**: Reduces peak throughput but improves system stability
- **Simplicity vs. Resilience**: Adds complexity but provides better error isolation
- **Resource Utilization vs. Protection**: May underutilize resources to ensure protection

## Best Practices

1. **Appropriate Sizing**: Size bulkheads based on actual resource limits
2. **Timeout Configuration**: Set reasonable timeouts based on operation characteristics
3. **Monitoring**: Track bulkhead utilization and timeout rates
4. **Weight Assignment**: Use appropriate weights for resource-intensive operations
5. **Graceful Fallbacks**: Implement fallback strategies for bulkhead failures
6. **Testing**: Load test bulkheads under realistic conditions

## References

- [Bulkhead Pattern](https://docs.microsoft.com/en-us/azure/architecture/patterns/bulkhead)
- [Go Semaphore Package](https://pkg.go.dev/golang.org/x/sync/semaphore)
- [Resilience4j Bulkhead](https://resilience4j.readme.io/docs/bulkhead)
- [Circuit Breaker Pattern](https://martinfowler.com/bliki/CircuitBreaker.html)
