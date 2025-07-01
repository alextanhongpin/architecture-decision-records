# Database Architecture Decision Records

This directory contains comprehensive documentation for database-related architectural decisions, patterns, and best practices. Each document provides detailed guidance on specific database topics with practical Go implementation examples.

## Table of Contents

### Core Database Patterns
- [001-database-orm.md](001-database-orm.md) - ORM vs Raw SQL trade-offs and implementation strategies
- [002-migration-files.md](002-migration-files.md) - Database migration file organization and versioning
- [003-migrating-sql.md](003-migrating-sql.md) - Safe SQL migration practices and rollback strategies
- [006-migration.md](006-migration.md) - Advanced migration patterns and tooling

### Testing and Development
- [004-dockertest.md](004-dockertest.md) - Integration testing with Docker and PostgreSQL
- [013-logging.md](013-logging.md) - Database query logging and observability
- [015-debug-redis-memory.md](015-debug-redis-memory.md) - Redis memory optimization and debugging

### Data Integrity and Concurrency
- [007-optimistic-locking.md](007-optimistic-locking.md) - Optimistic concurrency control patterns
- [008-pessimistic-locking.md](008-pessimistic-locking.md) - Pessimistic locking strategies
- [011-idempotency.md](011-idempotency.md) - Idempotent operations and duplicate prevention

### Design and Modeling
- [009-database-design-record.md](009-database-design-record.md) - Database schema design documentation
- [010-state-machine.md](010-state-machine.md) - State machine implementation in databases
- [014-version.md](014-version.md) - Entity versioning and audit patterns
- [022-independent-schema.md](022-independent-schema.md) - Independent schema design for microservices

### Performance and Optimization
- [005-limit-text-length.md](005-limit-text-length.md) - Text field length constraints and optimization
- [018-rate-limit.md](018-rate-limit.md) - Database-based rate limiting implementation
- [019-update.md](019-update.md) - Safe update strategies and conflict resolution
- [020-storage.md](020-storage.md) - Storage optimization and data lifecycle management

### Redis and Caching
- [012-redis-convention.md](012-redis-convention.md) - Redis key naming and usage patterns
- [015-debug-redis-memory.md](015-debug-redis-memory.md) - Redis memory optimization techniques

### User Experience
- [016-user-preferences.md](016-user-preferences.md) - User preference storage and management patterns

### Advanced Patterns
- [017-deferred-computation.md](017-deferred-computation.md) - Deferred computation and batch processing
- [021-postgres-app.md](021-postgres-app.md) - PostgreSQL-centric application architecture
- [023-processing-outbox.md](023-processing-outbox.md) - Outbox pattern for reliable message processing
- [024-postgres-job-queue.md](024-postgres-job-queue.md) - PostgreSQL-based job queue implementation
- [025-postgres-queue.md](025-postgres-queue.md) - Scalable PostgreSQL queue with partitioning

## Application Layer Dependencies

### Essential Components

#### Connection Management
- **Connection Pooling**: Configure optimal pool sizes based on workload
- **Connection Lifecycle**: Proper connection acquisition and release
- **Health Checks**: Monitor connection pool health and database availability

#### Code Generation and Type Safety
- **SQLC**: Generate type-safe Go code from SQL queries
- **Schema Evolution**: Keep generated code in sync with database changes
- **Query Validation**: Compile-time validation of SQL queries

#### Migration Management
- **Test Migrations**: Automated migration testing in CI/CD pipelines
- **Production Migrations**: Safe, zero-downtime migration strategies
- **Rollback Procedures**: Reliable rollback mechanisms for failed migrations

#### Design Patterns
- **Repository Pattern**: Abstract data access logic
- **Unit of Work**: Manage transactions across multiple repositories
- **Transaction Resolver**: Coordinate distributed transactions

#### Testing Infrastructure
- **PostgreSQL Testing**: Integration tests with real database instances
- **Transaction Management**: Rollback vs forward-only test strategies
- **Test Fixtures**: Reusable test data management
- **Snapshot Testing**: SQL query result validation

#### Observability
- **SQL Logging**: Structured logging of database operations
- **Metrics Collection**: Latency, error rates, and performance metrics
- **Slow Query Logging**: Identify and optimize performance bottlenecks
- **Error Handling**: Proper handling of constraint violations and database errors

#### Operational Excellence
- **Context Timeouts**: Prevent hung database operations
- **Circuit Breakers**: Protect applications from database failures
- **Retry Logic**: Implement appropriate retry strategies
- **Monitoring**: Database health and performance monitoring

## Implementation Guidelines

### Connection Pooling Best Practices

```go
// Example database configuration
type DatabaseConfig struct {
    MaxOpenConns    int           `yaml:"max_open_conns" default:"25"`
    MaxIdleConns    int           `yaml:"max_idle_conns" default:"5"`
    ConnMaxLifetime time.Duration `yaml:"conn_max_lifetime" default:"5m"`
    ConnMaxIdleTime time.Duration `yaml:"conn_max_idle_time" default:"30s"`
}

func SetupDatabase(config DatabaseConfig) (*sql.DB, error) {
    db, err := sql.Open("postgres", dsn)
    if err != nil {
        return nil, err
    }
    
    db.SetMaxOpenConns(config.MaxOpenConns)
    db.SetMaxIdleConns(config.MaxIdleConns)
    db.SetConnMaxLifetime(config.ConnMaxLifetime)
    db.SetConnMaxIdleTime(config.ConnMaxIdleTime)
    
    return db, nil
}
```

### Repository Pattern Implementation

```go
type UserRepository interface {
    Create(ctx context.Context, user *User) error
    GetByID(ctx context.Context, id int64) (*User, error)
    Update(ctx context.Context, user *User) error
    Delete(ctx context.Context, id int64) error
}

type userRepository struct {
    db *sql.DB
}

func NewUserRepository(db *sql.DB) UserRepository {
    return &userRepository{db: db}
}

func (r *userRepository) Create(ctx context.Context, user *User) error {
    query := `
        INSERT INTO users (name, email, created_at)
        VALUES ($1, $2, NOW())
        RETURNING id, created_at
    `
    
    return r.db.QueryRowContext(ctx, query, user.Name, user.Email).
        Scan(&user.ID, &user.CreatedAt)
}
```

### Testing with PostgreSQL

```go
func TestUserRepository(t *testing.T) {
    // Setup test database
    db := setupTestDB(t)
    defer db.Close()
    
    repo := NewUserRepository(db)
    
    t.Run("create user", func(t *testing.T) {
        user := &User{
            Name:  "John Doe",
            Email: "john@example.com",
        }
        
        err := repo.Create(context.Background(), user)
        require.NoError(t, err)
        assert.NotZero(t, user.ID)
        assert.NotZero(t, user.CreatedAt)
    })
}

func setupTestDB(t *testing.T) *sql.DB {
    db, err := sql.Open("postgres", testDSN)
    require.NoError(t, err)
    
    // Run migrations
    runMigrations(t, db)
    
    // Setup cleanup
    t.Cleanup(func() {
        cleanupTestData(db)
    })
    
    return db
}
```

### Metrics and Monitoring

```go
type DatabaseMetrics struct {
    QueryDuration   prometheus.HistogramVec
    QueryErrors     prometheus.CounterVec
    ConnectionPool  prometheus.GaugeVec
    SlowQueries     prometheus.Counter
}

func instrumentDatabase(db *sql.DB, metrics *DatabaseMetrics) *sql.DB {
    // Wrap database with instrumentation
    return &instrumentedDB{
        DB:      db,
        metrics: metrics,
    }
}

func (idb *instrumentedDB) QueryContext(ctx context.Context, query string, args ...interface{}) (*sql.Rows, error) {
    start := time.Now()
    
    rows, err := idb.DB.QueryContext(ctx, query, args...)
    
    duration := time.Since(start)
    idb.metrics.QueryDuration.WithLabelValues("query").Observe(duration.Seconds())
    
    if err != nil {
        idb.metrics.QueryErrors.WithLabelValues("query", "error").Inc()
    }
    
    if duration > time.Second {
        idb.metrics.SlowQueries.Inc()
        slog.Warn("slow query detected", "duration", duration, "query", query)
    }
    
    return rows, err
}
```

## Related Resources

- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Go Database/SQL Tutorial](https://go.dev/doc/tutorial/database-access)
- [SQLC Documentation](https://docs.sqlc.dev/)
- [Database Design Best Practices](https://www.postgresql.org/docs/current/ddl-best-practices.html)

## Contributing

When adding new database-related ADRs:

1. Follow the established naming convention: `XXX-topic-name.md`
2. Include practical Go implementation examples
3. Document both the decision and the rationale
4. Update this README with the new document
5. Ensure examples are tested and production-ready
