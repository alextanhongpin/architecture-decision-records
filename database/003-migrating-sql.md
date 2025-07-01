# Safe SQL Migration Strategies

## Status
**Accepted**

## Context
Database migrations are critical operations that can cause downtime, data loss, or performance issues if not executed safely. When using ORMs, generated SQL is often hidden from developers, making it difficult to validate migration safety before production deployment.

Ensuring safe SQL migrations requires comprehensive validation, testing, and monitoring strategies to minimize risks and enable rollback capabilities.

## Decision
We will implement a multi-layered approach to safe SQL migrations that includes schema dumping, validation, testing, and monitoring to ensure database changes are applied safely and can be rolled back if necessary.

## Implementation

### 1. Schema Dumping and Version Control

```bash
#!/bin/bash
# scripts/dump-schema.sh - Dump and version control database schema

# MySQL schema dump
mysqldump -h localhost -u user -p --no-data --routines --triggers database_name > schema/mysql_schema.sql

# PostgreSQL schema dump
pg_dump -h localhost -U user -d database_name --schema-only --no-privileges --no-owner > schema/postgres_schema.sql

# Add to version control
git add schema/
git commit -m "Update schema dump after migration"
```

```go
// pkg/migration/dumper.go
package migration

import (
    "fmt"
    "os"
    "os/exec"
    "path/filepath"
    "time"
)

type SchemaDumper struct {
    DBType     string
    Host       string
    Port       int
    User       string
    Database   string
    OutputDir  string
}

func (s *SchemaDumper) DumpSchema() error {
    timestamp := time.Now().Format("20060102_150405")
    filename := fmt.Sprintf("%s_schema_%s.sql", s.DBType, timestamp)
    outputPath := filepath.Join(s.OutputDir, filename)
    
    var cmd *exec.Cmd
    switch s.DBType {
    case "mysql":
        cmd = exec.Command("mysqldump",
            "-h", s.Host,
            "-P", fmt.Sprintf("%d", s.Port),
            "-u", s.User,
            "--no-data",
            "--routines",
            "--triggers",
            "--single-transaction",
            s.Database,
        )
    case "postgres":
        cmd = exec.Command("pg_dump",
            "-h", s.Host,
            "-p", fmt.Sprintf("%d", s.Port),
            "-U", s.User,
            "-d", s.Database,
            "--schema-only",
            "--no-privileges",
            "--no-owner",
        )
    default:
        return fmt.Errorf("unsupported database type: %s", s.DBType)
    }
    
    output, err := cmd.Output()
    if err != nil {
        return fmt.Errorf("failed to dump schema: %w", err)
    }
    
    return os.WriteFile(outputPath, output, 0644)
}
```

### 2. Migration Validation Framework

```go
// pkg/migration/validator.go
package migration

import (
    "database/sql"
    "fmt"
    "regexp"
    "strings"
)

type MigrationValidator struct {
    db *sql.DB
}

type ValidationResult struct {
    Valid    bool
    Warnings []string
    Errors   []string
}

func NewMigrationValidator(db *sql.DB) *MigrationValidator {
    return &MigrationValidator{db: db}
}

func (v *MigrationValidator) ValidateMigration(migrationSQL string) (*ValidationResult, error) {
    result := &ValidationResult{Valid: true}
    
    // Check for dangerous operations
    dangerousOps := []string{
        "DROP TABLE",
        "DROP COLUMN",
        "DROP INDEX",
        "TRUNCATE",
        "DELETE FROM.*WHERE.*1=1",
    }
    
    upperSQL := strings.ToUpper(migrationSQL)
    for _, op := range dangerousOps {
        if matched, _ := regexp.MatchString(op, upperSQL); matched {
            result.Errors = append(result.Errors, fmt.Sprintf("Dangerous operation detected: %s", op))
            result.Valid = false
        }
    }
    
    // Check for missing WHERE clauses in UPDATE/DELETE
    if v.hasMissingWhereClause(migrationSQL) {
        result.Warnings = append(result.Warnings, "UPDATE/DELETE without WHERE clause detected")
    }
    
    // Validate syntax using EXPLAIN
    if err := v.validateSyntax(migrationSQL); err != nil {
        result.Errors = append(result.Errors, fmt.Sprintf("Syntax error: %v", err))
        result.Valid = false
    }
    
    return result, nil
}

func (v *MigrationValidator) hasMissingWhereClause(sql string) bool {
    updatePattern := `(?i)UPDATE\s+\w+\s+SET\s+.*?(?:WHERE|$)`
    deletePattern := `(?i)DELETE\s+FROM\s+\w+\s*(?:WHERE|$)`
    
    updateMatches := regexp.MustCompile(updatePattern).FindAllString(sql, -1)
    deleteMatches := regexp.MustCompile(deletePattern).FindAllString(sql, -1)
    
    for _, match := range updateMatches {
        if !strings.Contains(strings.ToUpper(match), "WHERE") {
            return true
        }
    }
    
    for _, match := range deleteMatches {
        if !strings.Contains(strings.ToUpper(match), "WHERE") {
            return true
        }
    }
    
    return false
}

func (v *MigrationValidator) validateSyntax(sql string) error {
    // Use EXPLAIN to validate syntax without executing
    _, err := v.db.Exec(fmt.Sprintf("EXPLAIN %s", sql))
    return err
}
```

### 3. Pre-Migration Testing

```go
// pkg/migration/tester.go
package migration

import (
    "database/sql"
    "fmt"
    "testing"
    "time"
)

type MigrationTester struct {
    sourceDB *sql.DB
    testDB   *sql.DB
}

func NewMigrationTester(sourceDB, testDB *sql.DB) *MigrationTester {
    return &MigrationTester{
        sourceDB: sourceDB,
        testDB:   testDB,
    }
}

func (mt *MigrationTester) TestMigration(migration string) error {
    // 1. Create test data
    if err := mt.createTestData(); err != nil {
        return fmt.Errorf("failed to create test data: %w", err)
    }
    
    // 2. Record pre-migration state
    preState, err := mt.captureState()
    if err != nil {
        return fmt.Errorf("failed to capture pre-migration state: %w", err)
    }
    
    // 3. Execute migration with timeout
    if err := mt.executeWithTimeout(migration, 30*time.Second); err != nil {
        return fmt.Errorf("migration failed: %w", err)
    }
    
    // 4. Validate post-migration state
    postState, err := mt.captureState()
    if err != nil {
        return fmt.Errorf("failed to capture post-migration state: %w", err)
    }
    
    // 5. Verify data integrity
    return mt.verifyDataIntegrity(preState, postState)
}

func (mt *MigrationTester) createTestData() error {
    testQueries := []string{
        "INSERT INTO users (name, email) VALUES ('test1', 'test1@example.com')",
        "INSERT INTO users (name, email) VALUES ('test2', 'test2@example.com')",
        "INSERT INTO orders (user_id, amount) VALUES (1, 100.00)",
        "INSERT INTO orders (user_id, amount) VALUES (2, 200.00)",
    }
    
    for _, query := range testQueries {
        if _, err := mt.testDB.Exec(query); err != nil {
            return err
        }
    }
    
    return nil
}

func (mt *MigrationTester) captureState() (map[string]interface{}, error) {
    state := make(map[string]interface{})
    
    // Capture row counts
    tables := []string{"users", "orders", "products"}
    for _, table := range tables {
        var count int
        err := mt.testDB.QueryRow(fmt.Sprintf("SELECT COUNT(*) FROM %s", table)).Scan(&count)
        if err != nil && err != sql.ErrNoRows {
            return nil, err
        }
        state[fmt.Sprintf("%s_count", table)] = count
    }
    
    // Capture checksums
    state["users_checksum"], _ = mt.calculateChecksum("users", "id,name,email")
    state["orders_checksum"], _ = mt.calculateChecksum("orders", "id,user_id,amount")
    
    return state, nil
}

func (mt *MigrationTester) calculateChecksum(table, columns string) (string, error) {
    query := fmt.Sprintf("SELECT MD5(GROUP_CONCAT(%s)) FROM %s", columns, table)
    var checksum sql.NullString
    err := mt.testDB.QueryRow(query).Scan(&checksum)
    if err != nil {
        return "", err
    }
    return checksum.String, nil
}

func (mt *MigrationTester) executeWithTimeout(migration string, timeout time.Duration) error {
    done := make(chan error, 1)
    
    go func() {
        _, err := mt.testDB.Exec(migration)
        done <- err
    }()
    
    select {
    case err := <-done:
        return err
    case <-time.After(timeout):
        return fmt.Errorf("migration timed out after %v", timeout)
    }
}

func (mt *MigrationTester) verifyDataIntegrity(preState, postState map[string]interface{}) error {
    // Verify that data wasn't accidentally deleted (unless expected)
    for key, preValue := range preState {
        if strings.HasSuffix(key, "_count") {
            postValue, exists := postState[key]
            if !exists {
                continue
            }
            
            if preValue.(int) > postValue.(int) {
                return fmt.Errorf("data loss detected in %s: before=%d, after=%d", 
                    key, preValue.(int), postValue.(int))
            }
        }
    }
    
    return nil
}
```

### 4. Safe Migration Execution

```go
// pkg/migration/executor.go
package migration

import (
    "context"
    "database/sql"
    "fmt"
    "log"
    "time"
)

type SafeExecutor struct {
    db               *sql.DB
    maxExecutionTime time.Duration
    dryRun          bool
    rollbackEnabled bool
}

func NewSafeExecutor(db *sql.DB) *SafeExecutor {
    return &SafeExecutor{
        db:               db,
        maxExecutionTime: 5 * time.Minute,
        dryRun:          false,
        rollbackEnabled: true,
    }
}

func (se *SafeExecutor) ExecuteMigration(ctx context.Context, migration Migration) error {
    log.Printf("Starting migration: %s", migration.Name)
    
    // 1. Pre-execution validation
    if err := se.validateMigration(migration); err != nil {
        return fmt.Errorf("validation failed: %w", err)
    }
    
    // 2. Create savepoint for rollback
    tx, err := se.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("failed to begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // 3. Execute with timeout
    done := make(chan error, 1)
    go func() {
        done <- se.executeMigrationSQL(tx, migration.SQL)
    }()
    
    select {
    case err := <-done:
        if err != nil {
            log.Printf("Migration failed: %v", err)
            return err
        }
    case <-time.After(se.maxExecutionTime):
        return fmt.Errorf("migration timed out after %v", se.maxExecutionTime)
    case <-ctx.Done():
        return ctx.Err()
    }
    
    // 4. Validate post-execution state
    if err := se.validatePostExecution(tx); err != nil {
        return fmt.Errorf("post-execution validation failed: %w", err)
    }
    
    // 5. Commit if not dry run
    if se.dryRun {
        log.Println("Dry run mode: rolling back changes")
        return nil
    }
    
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("failed to commit migration: %w", err)
    }
    
    log.Printf("Migration completed successfully: %s", migration.Name)
    return nil
}

func (se *SafeExecutor) executeMigrationSQL(tx *sql.Tx, migrationSQL string) error {
    statements := se.splitStatements(migrationSQL)
    
    for i, stmt := range statements {
        if strings.TrimSpace(stmt) == "" {
            continue
        }
        
        log.Printf("Executing statement %d/%d", i+1, len(statements))
        
        if _, err := tx.Exec(stmt); err != nil {
            return fmt.Errorf("failed to execute statement %d: %w\nStatement: %s", i+1, err, stmt)
        }
    }
    
    return nil
}

func (se *SafeExecutor) splitStatements(sql string) []string {
    // Simple statement splitting by semicolon
    // In production, use a proper SQL parser
    return strings.Split(sql, ";")
}
```

### 5. Rollback Strategies

```go
// pkg/migration/rollback.go
package migration

import (
    "fmt"
    "log"
    "regexp"
    "strings"
)

type RollbackGenerator struct {
    dbType string
}

func NewRollbackGenerator(dbType string) *RollbackGenerator {
    return &RollbackGenerator{dbType: dbType}
}

func (rg *RollbackGenerator) GenerateRollback(forwardSQL string) (string, error) {
    var rollbacks []string
    
    statements := strings.Split(forwardSQL, ";")
    
    for _, stmt := range statements {
        stmt = strings.TrimSpace(stmt)
        if stmt == "" {
            continue
        }
        
        rollback, err := rg.generateStatementRollback(stmt)
        if err != nil {
            return "", err
        }
        
        if rollback != "" {
            rollbacks = append(rollbacks, rollback)
        }
    }
    
    // Reverse order for rollback
    for i, j := 0, len(rollbacks)-1; i < j; i, j = i+1, j-1 {
        rollbacks[i], rollbacks[j] = rollbacks[j], rollbacks[i]
    }
    
    return strings.Join(rollbacks, ";\n"), nil
}

func (rg *RollbackGenerator) generateStatementRollback(stmt string) (string, error) {
    upperStmt := strings.ToUpper(strings.TrimSpace(stmt))
    
    switch {
    case strings.HasPrefix(upperStmt, "CREATE TABLE"):
        return rg.rollbackCreateTable(stmt)
    case strings.HasPrefix(upperStmt, "ALTER TABLE"):
        return rg.rollbackAlterTable(stmt)
    case strings.HasPrefix(upperStmt, "CREATE INDEX"):
        return rg.rollbackCreateIndex(stmt)
    case strings.HasPrefix(upperStmt, "INSERT"):
        return rg.rollbackInsert(stmt)
    default:
        return "", fmt.Errorf("cannot generate rollback for statement: %s", stmt)
    }
}

func (rg *RollbackGenerator) rollbackCreateTable(stmt string) (string, error) {
    re := regexp.MustCompile(`CREATE TABLE\s+(\w+)`)
    matches := re.FindStringSubmatch(stmt)
    if len(matches) < 2 {
        return "", fmt.Errorf("cannot parse table name from: %s", stmt)
    }
    
    return fmt.Sprintf("DROP TABLE %s", matches[1]), nil
}

func (rg *RollbackGenerator) rollbackAlterTable(stmt string) (string, error) {
    // Handle ADD COLUMN
    if strings.Contains(strings.ToUpper(stmt), "ADD COLUMN") {
        re := regexp.MustCompile(`ALTER TABLE\s+(\w+)\s+ADD COLUMN\s+(\w+)`)
        matches := re.FindStringSubmatch(stmt)
        if len(matches) >= 3 {
            return fmt.Sprintf("ALTER TABLE %s DROP COLUMN %s", matches[1], matches[2]), nil
        }
    }
    
    // Handle DROP COLUMN (requires backup)
    if strings.Contains(strings.ToUpper(stmt), "DROP COLUMN") {
        return "", fmt.Errorf("cannot auto-generate rollback for DROP COLUMN - manual intervention required")
    }
    
    return "", fmt.Errorf("unsupported ALTER TABLE operation for rollback: %s", stmt)
}

func (rg *RollbackGenerator) rollbackCreateIndex(stmt string) (string, error) {
    re := regexp.MustCompile(`CREATE\s+(?:UNIQUE\s+)?INDEX\s+(\w+)`)
    matches := re.FindStringSubmatch(stmt)
    if len(matches) < 2 {
        return "", fmt.Errorf("cannot parse index name from: %s", stmt)
    }
    
    return fmt.Sprintf("DROP INDEX %s", matches[1]), nil
}
```

### 6. Migration Monitoring

```go
// pkg/migration/monitor.go
package migration

import (
    "context"
    "database/sql"
    "log"
    "time"
)

type MigrationMonitor struct {
    db       *sql.DB
    interval time.Duration
}

func NewMigrationMonitor(db *sql.DB) *MigrationMonitor {
    return &MigrationMonitor{
        db:       db,
        interval: 5 * time.Second,
    }
}

func (mm *MigrationMonitor) MonitorMigration(ctx context.Context, migrationName string) {
    ticker := time.NewTicker(mm.interval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            mm.collectMetrics(migrationName)
        case <-ctx.Done():
            return
        }
    }
}

func (mm *MigrationMonitor) collectMetrics(migrationName string) {
    // Monitor active connections
    var activeConnections int
    mm.db.QueryRow("SHOW STATUS LIKE 'Threads_connected'").Scan(&activeConnections)
    log.Printf("Migration %s - Active connections: %d", migrationName, activeConnections)
    
    // Monitor slow queries
    var slowQueries int
    mm.db.QueryRow("SHOW STATUS LIKE 'Slow_queries'").Scan(&slowQueries)
    log.Printf("Migration %s - Slow queries: %d", migrationName, slowQueries)
    
    // Monitor lock waits
    var lockWaits int
    mm.db.QueryRow("SHOW STATUS LIKE 'Table_locks_waited'").Scan(&lockWaits)
    log.Printf("Migration %s - Lock waits: %d", migrationName, lockWaits)
}
```

### 7. Complete Migration Workflow

```bash
#!/bin/bash
# scripts/safe-migration.sh - Complete safe migration workflow

set -e

MIGRATION_FILE="$1"
DB_HOST="${DB_HOST:-localhost}"
DB_NAME="${DB_NAME:-myapp}"
DRY_RUN="${DRY_RUN:-false}"

if [ -z "$MIGRATION_FILE" ]; then
    echo "Usage: $0 <migration_file.sql>"
    exit 1
fi

echo "Starting safe migration workflow for: $MIGRATION_FILE"

# 1. Validate migration file exists
if [ ! -f "$MIGRATION_FILE" ]; then
    echo "Error: Migration file not found: $MIGRATION_FILE"
    exit 1
fi

# 2. Create backup
echo "Creating database backup..."
mysqldump -h "$DB_HOST" -u root -p "$DB_NAME" > "backup_$(date +%Y%m%d_%H%M%S).sql"

# 3. Run validation
echo "Validating migration..."
go run cmd/validate-migration/main.go "$MIGRATION_FILE"

# 4. Generate rollback script
echo "Generating rollback script..."
go run cmd/generate-rollback/main.go "$MIGRATION_FILE" > "rollback_$(basename $MIGRATION_FILE)"

# 5. Test migration on copy
echo "Testing migration on database copy..."
go run cmd/test-migration/main.go "$MIGRATION_FILE"

# 6. Execute migration with monitoring
if [ "$DRY_RUN" = "true" ]; then
    echo "Dry run mode - would execute: $MIGRATION_FILE"
else
    echo "Executing migration with monitoring..."
    go run cmd/execute-migration/main.go "$MIGRATION_FILE"
fi

# 7. Dump updated schema
echo "Dumping updated schema..."
scripts/dump-schema.sh

echo "Migration workflow completed successfully!"
```

## Best Practices

### 1. Migration Safety Checklist

- [ ] **Backup created** before migration execution
- [ ] **Rollback script** generated and tested
- [ ] **Validation passed** with no errors or warnings
- [ ] **Test execution** completed on database copy
- [ ] **Monitoring** enabled during execution
- [ ] **Timeout limits** configured appropriately
- [ ] **Lock detection** and handling implemented
- [ ] **Performance impact** assessed and acceptable

### 2. Schema Evolution Guidelines

```sql
-- Good: Additive changes (safe)
ALTER TABLE users ADD COLUMN phone VARCHAR(20);
CREATE INDEX idx_users_phone ON users(phone);

-- Caution: Structural changes (test required)
ALTER TABLE users MODIFY COLUMN email VARCHAR(320);
ALTER TABLE orders ADD CONSTRAINT fk_user FOREIGN KEY (user_id) REFERENCES users(id);

-- Dangerous: Destructive changes (backup + careful planning)
ALTER TABLE users DROP COLUMN old_field;
DROP INDEX idx_old_index;
```

### 3. Performance Considerations

```go
// Large table migrations with batching
func migrateInBatches(db *sql.DB, query string, batchSize int) error {
    offset := 0
    
    for {
        batchQuery := fmt.Sprintf("%s LIMIT %d OFFSET %d", query, batchSize, offset)
        result, err := db.Exec(batchQuery)
        if err != nil {
            return err
        }
        
        rowsAffected, _ := result.RowsAffected()
        if rowsAffected == 0 {
            break
        }
        
        offset += batchSize
        time.Sleep(100 * time.Millisecond) // Prevent overwhelming the database
    }
    
    return nil
}
```

## Consequences

### Positive
- **Risk Reduction**: Comprehensive validation prevents dangerous migrations
- **Rollback Capability**: Automated rollback generation enables quick recovery
- **Monitoring**: Real-time insights during migration execution
- **Documentation**: Schema dumps provide historical tracking
- **Testing**: Pre-execution testing catches issues early

### Negative
- **Complexity**: Additional tooling and processes required
- **Time Overhead**: Extended migration time due to validation steps
- **Storage**: Schema dumps and backups require additional storage
- **Learning Curve**: Team needs to understand new migration workflow

## Related Patterns
- [Migration Files](002-migration-files.md) - File organization and naming
- [Database Design Record](009-database-design-record.md) - Schema documentation
- [Optimistic Locking](007-optimistic-locking.md) - Concurrent access control
- [Version Management](014-version.md) - Database versioning strategies
