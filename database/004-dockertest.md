# Database Testing with Docker

## Status

`accepted`

## Context

Database testing is critical for ensuring data layer reliability, but traditional approaches have significant limitations. We need a testing strategy that provides strong guarantees about SQL correctness, execution validity, and data integrity across different environments.

### Testing Approach Options

| Approach | Pros | Cons | Use Case |
|----------|------|------|----------|
| SQLite In-Memory | Fast, no setup | Different SQL dialect, limited features | Unit tests, quick validation |
| Local Database | Real environment | Setup complexity, state pollution | Development testing |
| Docker Containers | Isolated, consistent, production-like | Slower startup, resource overhead | Integration tests |
| Embedded Database | Self-contained, fast | Limited to specific databases | Specific use cases |
| WASM Database | Portable, sandboxed | Emerging technology, limited support | Future consideration |
| SQL Parser Validation | Very fast, syntax checking | No execution validation | Static analysis |

### Testing Requirements

Our database testing strategy must validate:

- **SQL Validity**: Generated queries are syntactically correct
- **Execution Success**: Statements execute without errors
- **Data Integrity**: Serialization/deserialization works correctly
- **Query Fingerprinting**: Consistent query identification
- **SQL Dumping**: Raw and normalized SQL output
- **Business Logic**: CRUD operations work as expected
- **Performance**: Query execution time within bounds
- **Concurrency**: Transactions and locking behavior
- **Migration Safety**: Schema changes don't break existing queries

## Decision

Use **Docker-based testing** with the following architecture:

### Core Testing Stack

```go
// TestDB provides isolated database instances for testing
type TestDB struct {
    Container *dockertest.Resource
    DB        *sql.DB
    Pool      *dockertest.Pool
    URL       string
}

// TestSuite manages test database lifecycle
type TestSuite struct {
    PostgresDB *TestDB
    RedisDB    *TestDB
    Cleanup    []func()
}
```

### Implementation Strategy

1. **Docker Test Framework**: Use `dockertest` for container management
2. **SQL Dump Validation**: Implement query fingerprinting and normalization
3. **Test Data Management**: Structured fixtures and factories
4. **Parallel Test Support**: Isolated databases per test suite
5. **Performance Benchmarking**: Built-in query performance testing

## Implementation

### Docker Test Setup

```go
package dbtest

import (
    "database/sql"
    "fmt"
    "log"
    "os"
    "testing"
    "time"

    "github.com/ory/dockertest/v3"
    "github.com/ory/dockertest/v3/docker"
    _ "github.com/lib/pq"
)

type TestDB struct {
    Container *dockertest.Resource
    DB        *sql.DB
    Pool      *dockertest.Pool
    URL       string
    Name      string
}

func NewTestDB(t *testing.T, dbName string) *TestDB {
    pool, err := dockertest.NewPool("")
    if err != nil {
        t.Fatalf("Could not connect to docker: %s", err)
    }

    // Configure PostgreSQL container
    resource, err := pool.RunWithOptions(&dockertest.RunOptions{
        Repository: "postgres",
        Tag:        "14-alpine",
        Env: []string{
            "POSTGRES_PASSWORD=secret",
            fmt.Sprintf("POSTGRES_DB=%s", dbName),
            "listen_addresses = '*'",
        },
    }, func(config *docker.HostConfig) {
        config.AutoRemove = true
        config.RestartPolicy = docker.RestartPolicy{Name: "no"}
    })
    if err != nil {
        t.Fatalf("Could not start resource: %s", err)
    }

    // Set expiry to kill container after 5 minutes
    resource.Expire(300)

    hostAndPort := resource.GetHostPort("5432/tcp")
    databaseUrl := fmt.Sprintf("postgres://postgres:secret@%s/%s?sslmode=disable", 
        hostAndPort, dbName)

    // Retry connection with exponential backoff
    pool.MaxWait = 120 * time.Second
    var db *sql.DB
    if err = pool.Retry(func() error {
        db, err = sql.Open("postgres", databaseUrl)
        if err != nil {
            return err
        }
        return db.Ping()
    }); err != nil {
        t.Fatalf("Could not connect to database: %s", err)
    }

    return &TestDB{
        Container: resource,
        DB:        db,
        Pool:      pool,
        URL:       databaseUrl,
        Name:      dbName,
    }
}

func (tdb *TestDB) Close() error {
    if tdb.DB != nil {
        tdb.DB.Close()
    }
    if tdb.Pool != nil && tdb.Container != nil {
        return tdb.Pool.Purge(tdb.Container)
    }
    return nil
}

// Reset clears all data but keeps schema
func (tdb *TestDB) Reset() error {
    tables := []string{
        "users", "orders", "products", "audit_logs",
    }
    
    for _, table := range tables {
        if _, err := tdb.DB.Exec(fmt.Sprintf("TRUNCATE TABLE %s CASCADE", table)); err != nil {
            return fmt.Errorf("failed to truncate %s: %w", table, err)
        }
    }
    return nil
}
```

### Test Suite Framework

```go
package dbtest

import (
    "context"
    "testing"
    "time"
)

type TestSuite struct {
    t         *testing.T
    db        *TestDB
    ctx       context.Context
    cancel    context.CancelFunc
    fixtures  map[string]interface{}
    cleanup   []func()
}

func NewTestSuite(t *testing.T) *TestSuite {
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    
    suite := &TestSuite{
        t:        t,
        ctx:      ctx,
        cancel:   cancel,
        fixtures: make(map[string]interface{}),
        cleanup:  make([]func(), 0),
    }
    
    // Setup database
    suite.db = NewTestDB(t, fmt.Sprintf("test_%d", time.Now().UnixNano()))
    suite.cleanup = append(suite.cleanup, func() {
        suite.db.Close()
    })
    
    // Run migrations
    if err := suite.runMigrations(); err != nil {
        t.Fatalf("Failed to run migrations: %v", err)
    }
    
    return suite
}

func (ts *TestSuite) Cleanup() {
    ts.cancel()
    for i := len(ts.cleanup) - 1; i >= 0; i-- {
        ts.cleanup[i]()
    }
}

func (ts *TestSuite) DB() *sql.DB {
    return ts.db.DB
}

func (ts *TestSuite) Context() context.Context {
    return ts.ctx
}

// LoadFixtures loads test data from fixtures
func (ts *TestSuite) LoadFixtures(fixtures map[string]interface{}) {
    for name, data := range fixtures {
        ts.fixtures[name] = data
        // Load fixture data into database
        ts.loadFixtureData(name, data)
    }
}

func (ts *TestSuite) runMigrations() error {
    migrations := []string{
        `CREATE TABLE users (
            id SERIAL PRIMARY KEY,
            email VARCHAR(255) UNIQUE NOT NULL,
            name VARCHAR(255) NOT NULL,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        )`,
        `CREATE TABLE orders (
            id SERIAL PRIMARY KEY,
            user_id INTEGER REFERENCES users(id),
            total DECIMAL(10,2) NOT NULL,
            status VARCHAR(50) DEFAULT 'pending',
            created_at TIMESTAMP DEFAULT NOW()
        )`,
        `CREATE INDEX idx_orders_user_id ON orders(user_id)`,
        `CREATE INDEX idx_orders_status ON orders(status)`,
    }
    
    for _, migration := range migrations {
        if _, err := ts.db.DB.ExecContext(ts.ctx, migration); err != nil {
            return err
        }
    }
    return nil
}
```

### SQL Query Testing and Validation

```go
package dbtest

import (
    "crypto/md5"
    "fmt"
    "regexp"
    "strings"
    "testing"
)

type QueryTest struct {
    Name         string
    Query        string
    Args         []interface{}
    ExpectedRows int
    ShouldError  bool
    Timeout      time.Duration
}

type QueryResult struct {
    Query           string
    NormalizedQuery string
    Fingerprint     string
    ExecutionTime   time.Duration
    RowsAffected    int64
    Error           error
}

// SQLTester validates SQL queries and dumps normalized versions
type SQLTester struct {
    db     *sql.DB
    logger *log.Logger
}

func NewSQLTester(db *sql.DB) *SQLTester {
    return &SQLTester{
        db:     db,
        logger: log.New(os.Stdout, "[SQL-TEST] ", log.LstdFlags),
    }
}

// TestQuery executes and validates a SQL query
func (st *SQLTester) TestQuery(t *testing.T, test QueryTest) QueryResult {
    result := QueryResult{
        Query: test.Query,
    }
    
    // Normalize query for fingerprinting
    result.NormalizedQuery = st.normalizeQuery(test.Query)
    result.Fingerprint = st.generateFingerprint(result.NormalizedQuery)
    
    // Log query details
    st.logger.Printf("Testing Query: %s", test.Name)
    st.logger.Printf("Raw SQL: %s", test.Query)
    st.logger.Printf("Normalized: %s", result.NormalizedQuery)
    st.logger.Printf("Fingerprint: %s", result.Fingerprint)
    
    // Execute query with timeout
    ctx := context.Background()
    if test.Timeout > 0 {
        var cancel context.CancelFunc
        ctx, cancel = context.WithTimeout(ctx, test.Timeout)
        defer cancel()
    }
    
    start := time.Now()
    rows, err := st.db.QueryContext(ctx, test.Query, test.Args...)
    result.ExecutionTime = time.Since(start)
    
    if err != nil {
        result.Error = err
        if !test.ShouldError {
            t.Errorf("Query %s failed unexpectedly: %v", test.Name, err)
        }
        return result
    }
    
    if test.ShouldError {
        t.Errorf("Query %s should have failed but succeeded", test.Name)
    }
    
    // Count rows
    rowCount := 0
    for rows.Next() {
        rowCount++
    }
    rows.Close()
    
    if test.ExpectedRows >= 0 && rowCount != test.ExpectedRows {
        t.Errorf("Query %s returned %d rows, expected %d", 
            test.Name, rowCount, test.ExpectedRows)
    }
    
    st.logger.Printf("Execution Time: %v", result.ExecutionTime)
    st.logger.Printf("Rows Returned: %d", rowCount)
    
    return result
}

// normalizeQuery standardizes SQL formatting for consistent fingerprinting
func (st *SQLTester) normalizeQuery(query string) string {
    // Remove extra whitespace
    re := regexp.MustCompile(`\s+`)
    normalized := re.ReplaceAllString(strings.TrimSpace(query), " ")
    
    // Convert to uppercase
    normalized = strings.ToUpper(normalized)
    
    // Replace parameter markers with placeholders
    paramRe := regexp.MustCompile(`\$\d+`)
    normalized = paramRe.ReplaceAllString(normalized, "?")
    
    // Remove string literals
    stringRe := regexp.MustCompile(`'[^']*'`)
    normalized = stringRe.ReplaceAllString(normalized, "?")
    
    // Remove numeric literals
    numRe := regexp.MustCompile(`\b\d+\b`)
    normalized = numRe.ReplaceAllString(normalized, "?")
    
    return normalized
}

// generateFingerprint creates a unique identifier for the query structure
func (st *SQLTester) generateFingerprint(normalizedQuery string) string {
    hash := md5.Sum([]byte(normalizedQuery))
    return fmt.Sprintf("%x", hash)[:8]
}
```

### Repository Testing Pattern

```go
package user_test

import (
    "testing"
    "github.com/your-org/app/internal/user"
    "github.com/your-org/app/pkg/dbtest"
)

func TestUserRepository(t *testing.T) {
    suite := dbtest.NewTestSuite(t)
    defer suite.Cleanup()
    
    repo := user.NewRepository(suite.DB())
    sqlTester := dbtest.NewSQLTester(suite.DB())
    
    t.Run("CreateUser", func(t *testing.T) {
        // Test SQL query generation and execution
        queryTest := dbtest.QueryTest{
            Name:         "insert_user",
            Query:        "INSERT INTO users (email, name) VALUES ($1, $2) RETURNING id",
            Args:         []interface{}{"test@example.com", "Test User"},
            ExpectedRows: 1,
            Timeout:      5 * time.Second,
        }
        
        result := sqlTester.TestQuery(t, queryTest)
        
        // Verify query fingerprint for consistency
        expectedFingerprint := "a1b2c3d4" // Known fingerprint for this query structure
        if result.Fingerprint != expectedFingerprint {
            t.Errorf("Query fingerprint changed: got %s, want %s", 
                result.Fingerprint, expectedFingerprint)
        }
        
        // Test actual repository method
        user, err := repo.Create(suite.Context(), "test@example.com", "Test User")
        if err != nil {
            t.Fatalf("Failed to create user: %v", err)
        }
        
        if user.ID == 0 {
            t.Error("User ID should be set after creation")
        }
        
        if user.Email != "test@example.com" {
            t.Errorf("Email mismatch: got %s, want %s", user.Email, "test@example.com")
        }
    })
    
    t.Run("FindUserByEmail", func(t *testing.T) {
        // Setup test data
        suite.LoadFixtures(map[string]interface{}{
            "users": []map[string]interface{}{
                {"email": "existing@example.com", "name": "Existing User"},
            },
        })
        
        // Test query
        queryTest := dbtest.QueryTest{
            Name:         "select_user_by_email",
            Query:        "SELECT id, email, name FROM users WHERE email = $1",
            Args:         []interface{}{"existing@example.com"},
            ExpectedRows: 1,
        }
        
        sqlTester.TestQuery(t, queryTest)
        
        // Test repository method
        user, err := repo.FindByEmail(suite.Context(), "existing@example.com")
        if err != nil {
            t.Fatalf("Failed to find user: %v", err)
        }
        
        if user.Email != "existing@example.com" {
            t.Errorf("Email mismatch: got %s, want %s", 
                user.Email, "existing@example.com")
        }
    })
}
```

### Performance and Benchmark Testing

```go
package dbtest

import (
    "testing"
    "time"
)

func BenchmarkQueries(b *testing.B) {
    suite := NewTestSuite(&testing.T{})
    defer suite.Cleanup()
    
    // Load test data
    loadBenchmarkData(suite)
    
    b.Run("UserLookup", func(b *testing.B) {
        b.ResetTimer()
        for i := 0; i < b.N; i++ {
            _, err := suite.DB().QueryContext(suite.Context(),
                "SELECT id, email FROM users WHERE email = $1",
                fmt.Sprintf("user%d@example.com", i%1000))
            if err != nil {
                b.Fatal(err)
            }
        }
    })
    
    b.Run("ComplexJoin", func(b *testing.B) {
        query := `
            SELECT u.id, u.name, COUNT(o.id) as order_count
            FROM users u
            LEFT JOIN orders o ON u.id = o.user_id
            WHERE u.created_at > $1
            GROUP BY u.id, u.name
            ORDER BY order_count DESC
            LIMIT 10
        `
        
        b.ResetTimer()
        for i := 0; i < b.N; i++ {
            _, err := suite.DB().QueryContext(suite.Context(), query,
                time.Now().AddDate(0, -1, 0))
            if err != nil {
                b.Fatal(err)
            }
        }
    })
}

// Performance assertion helper
func AssertQueryPerformance(t *testing.T, query string, args []interface{}, 
    maxDuration time.Duration) {
    
    suite := NewTestSuite(t)
    defer suite.Cleanup()
    
    start := time.Now()
    _, err := suite.DB().QueryContext(suite.Context(), query, args...)
    duration := time.Since(start)
    
    if err != nil {
        t.Fatalf("Query failed: %v", err)
    }
    
    if duration > maxDuration {
        t.Errorf("Query too slow: took %v, max allowed %v", duration, maxDuration)
    }
}
```

### Test Configuration and Environment

```go
// config/test.go
package config

import (
    "os"
    "strconv"
    "time"
)

type TestConfig struct {
    DatabaseURL     string
    RedisURL        string
    TestTimeout     time.Duration
    MaxConnections  int
    EnableSQLDump   bool
    ParallelTests   bool
}

func LoadTestConfig() *TestConfig {
    config := &TestConfig{
        DatabaseURL:     getEnv("TEST_DATABASE_URL", ""),
        RedisURL:        getEnv("TEST_REDIS_URL", "redis://localhost:6379"),
        TestTimeout:     getDuration("TEST_TIMEOUT", 30*time.Second),
        MaxConnections:  getInt("TEST_MAX_CONNECTIONS", 10),
        EnableSQLDump:   getBool("TEST_ENABLE_SQL_DUMP", true),
        ParallelTests:   getBool("TEST_PARALLEL", true),
    }
    
    return config
}

func getEnv(key, defaultValue string) string {
    if value := os.Getenv(key); value != "" {
        return value
    }
    return defaultValue
}

func getDuration(key string, defaultValue time.Duration) time.Duration {
    if value := os.Getenv(key); value != "" {
        if duration, err := time.ParseDuration(value); err == nil {
            return duration
        }
    }
    return defaultValue
}

func getInt(key string, defaultValue int) int {
    if value := os.Getenv(key); value != "" {
        if intValue, err := strconv.Atoi(value); err == nil {
            return intValue
        }
    }
    return defaultValue
}

func getBool(key string, defaultValue bool) bool {
    if value := os.Getenv(key); value != "" {
        if boolValue, err := strconv.ParseBool(value); err == nil {
            return boolValue
        }
    }
    return defaultValue
}
```

## Consequences

### Positive

- **Production Parity**: Docker containers mirror production database versions
- **Isolation**: Each test suite runs against a clean database instance
- **Consistency**: Deterministic test results across different environments
- **Comprehensive Validation**: Tests cover SQL syntax, execution, and data integrity
- **Performance Monitoring**: Built-in query performance benchmarking
- **Query Fingerprinting**: Consistent query identification for monitoring
- **Parallel Testing**: Multiple test suites can run simultaneously

### Negative

- **Resource Overhead**: Docker containers consume more memory and CPU
- **Slower Startup**: Container initialization adds 2-5 seconds per test suite
- **Docker Dependency**: Requires Docker to be available in test environments
- **Complexity**: More sophisticated setup compared to in-memory databases

### Mitigations

- **Container Reuse**: Share containers across related test suites where possible
- **Resource Limits**: Configure appropriate memory and CPU limits for test containers
- **Parallel Optimization**: Use container pools to reduce startup overhead
- **Fallback Testing**: Provide SQLite fallback for environments without Docker
- **CI/CD Integration**: Pre-warm containers in CI environments

## Related Patterns

- **[Migration Files](002-migration-files.md)**: Database schema management for tests
- **[Database Design Record](009-database-design-record.md)**: Documenting test database schemas
- **[Idempotency](011-idempotency.md)**: Testing idempotent operations
- **[Rate Limiting](018-rate-limit.md)**: Testing rate-limited database operations
