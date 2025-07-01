# Database Migration Strategy and Execution Context

## Status
**Accepted**

## Context
Database migrations require different execution strategies based on database size, table volume, and operational requirements. The choice between application-embedded migrations and external migration tools significantly impacts deployment complexity, downtime, and operational risk.

Key considerations include:
- **Database Size**: Small databases can handle simple migrations; large databases require specialized tools
- **Downtime Tolerance**: Production systems often require zero-downtime migrations
- **Lock Duration**: Some operations lock tables for extended periods, blocking concurrent access
- **Rollback Requirements**: Complex migrations need sophisticated rollback strategies
- **Team Expertise**: Different approaches require varying levels of database administration knowledge

## Decision
We will implement a hybrid migration strategy that adapts to database size and complexity:
- **Small databases (< 1GB)**: Application-embedded migrations for simplicity
- **Medium databases (1-100GB)**: External tools with careful planning
- **Large databases (> 100GB)**: Specialized online migration tools with zero-downtime strategies

## Implementation

### 1. Size-Based Migration Strategy

```go
// pkg/migration/strategy.go
package migration

import (
    "database/sql"
    "fmt"
    "log"
)

type MigrationStrategy interface {
    ShouldRunInApp(tableSize int64) bool
    GetRecommendedTool(tableSize int64) string
    EstimateDowntime(operation string, tableSize int64) time.Duration
}

type SizeBasedStrategy struct {
    SmallThreshold  int64 // 1GB in bytes
    MediumThreshold int64 // 100GB in bytes
}

func NewSizeBasedStrategy() *SizeBasedStrategy {
    return &SizeBasedStrategy{
        SmallThreshold:  1 * 1024 * 1024 * 1024,      // 1GB
        MediumThreshold: 100 * 1024 * 1024 * 1024,    // 100GB
    }
}

func (s *SizeBasedStrategy) ShouldRunInApp(tableSize int64) bool {
    return tableSize < s.SmallThreshold
}

func (s *SizeBasedStrategy) GetRecommendedTool(tableSize int64) string {
    switch {
    case tableSize < s.SmallThreshold:
        return "application-embedded"
    case tableSize < s.MediumThreshold:
        return "gh-ost"
    default:
        return "pt-online-schema-change"
    }
}

func (s *SizeBasedStrategy) EstimateDowntime(operation string, tableSize int64) time.Duration {
    // Rough estimates based on operation type and table size
    baseTime := time.Duration(tableSize/1024/1024) * time.Millisecond // 1ms per MB
    
    switch operation {
    case "ADD_COLUMN":
        return baseTime * 2
    case "DROP_COLUMN":
        return baseTime * 5
    case "ADD_INDEX":
        return baseTime * 10
    case "ALTER_COLUMN":
        return baseTime * 20
    default:
        return baseTime * 5
    }
}

// Migration context analyzer
type MigrationAnalyzer struct {
    db       *sql.DB
    strategy MigrationStrategy
}

func NewMigrationAnalyzer(db *sql.DB) *MigrationAnalyzer {
    return &MigrationAnalyzer{
        db:       db,
        strategy: NewSizeBasedStrategy(),
    }
}

func (ma *MigrationAnalyzer) AnalyzeTable(tableName string) (*TableAnalysis, error) {
    analysis := &TableAnalysis{TableName: tableName}
    
    // Get table size
    var dataSize, indexSize sql.NullInt64
    err := ma.db.QueryRow(`
        SELECT 
            ROUND(((data_length + index_length) / 1024 / 1024), 2) AS size_mb,
            ROUND((index_length / 1024 / 1024), 2) AS index_size_mb
        FROM information_schema.TABLES 
        WHERE table_schema = DATABASE() AND table_name = ?
    `, tableName).Scan(&dataSize, &indexSize)
    
    if err != nil {
        return nil, fmt.Errorf("failed to analyze table %s: %w", tableName, err)
    }
    
    analysis.DataSizeMB = dataSize.Int64
    analysis.IndexSizeMB = indexSize.Int64
    analysis.TotalSizeBytes = (dataSize.Int64 + indexSize.Int64) * 1024 * 1024
    
    // Get row count
    err = ma.db.QueryRow(fmt.Sprintf("SELECT COUNT(*) FROM %s", tableName)).Scan(&analysis.RowCount)
    if err != nil {
        return nil, err
    }
    
    // Determine strategy
    analysis.RecommendedStrategy = ma.strategy.GetRecommendedTool(analysis.TotalSizeBytes)
    analysis.ShouldRunInApp = ma.strategy.ShouldRunInApp(analysis.TotalSizeBytes)
    
    return analysis, nil
}

type TableAnalysis struct {
    TableName           string
    DataSizeMB         int64
    IndexSizeMB        int64
    TotalSizeBytes     int64
    RowCount           int64
    RecommendedStrategy string
    ShouldRunInApp     bool
}
```

### 2. Application-Embedded Migrations (Small Databases)

```go
// pkg/migration/embedded.go
package migration

import (
    "database/sql"
    "fmt"
    "time"
)

type EmbeddedMigrator struct {
    db      *sql.DB
    timeout time.Duration
}

func NewEmbeddedMigrator(db *sql.DB) *EmbeddedMigrator {
    return &EmbeddedMigrator{
        db:      db,
        timeout: 30 * time.Second,
    }
}

func (em *EmbeddedMigrator) RunMigration(migration Migration) error {
    log.Printf("Running embedded migration: %s", migration.Name)
    
    // Check table size before proceeding
    analysis, err := NewMigrationAnalyzer(em.db).AnalyzeTable(migration.TableName)
    if err != nil {
        return fmt.Errorf("failed to analyze table: %w", err)
    }
    
    if !analysis.ShouldRunInApp {
        return fmt.Errorf("table %s (%d MB) is too large for embedded migration, use external tool: %s", 
            migration.TableName, analysis.DataSizeMB, analysis.RecommendedStrategy)
    }
    
    // Execute with timeout
    ctx, cancel := context.WithTimeout(context.Background(), em.timeout)
    defer cancel()
    
    tx, err := em.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Execute migration statements
    for _, stmt := range migration.Statements {
        log.Printf("Executing: %s", stmt)
        if _, err := tx.ExecContext(ctx, stmt); err != nil {
            return fmt.Errorf("failed to execute statement: %w", err)
        }
    }
    
    return tx.Commit()
}

// Simple migration definition
type Migration struct {
    Name       string
    TableName  string
    Statements []string
    Rollback   []string
}

// Example migrations
var SmallTableMigrations = []Migration{
    {
        Name:      "add_user_bio_column",
        TableName: "users",
        Statements: []string{
            "ALTER TABLE users ADD COLUMN bio VARCHAR(500)",
            "CREATE INDEX idx_users_bio ON users(bio(100))",
        },
        Rollback: []string{
            "DROP INDEX idx_users_bio",
            "ALTER TABLE users DROP COLUMN bio",
        },
    },
    {
        Name:      "create_user_preferences_table",
        TableName: "user_preferences",
        Statements: []string{
            `CREATE TABLE user_preferences (
                id INT PRIMARY KEY AUTO_INCREMENT,
                user_id INT NOT NULL,
                preference_key VARCHAR(100) NOT NULL,
                preference_value TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                UNIQUE KEY unique_user_preference (user_id, preference_key)
            )`,
        },
        Rollback: []string{
            "DROP TABLE user_preferences",
        },
    },
}
```

### 3. External Migration Tools Integration

```go
// pkg/migration/external.go
package migration

import (
    "fmt"
    "os/exec"
    "strings"
)

type ExternalMigrator struct {
    dbConfig DatabaseConfig
    tool     string
}

type DatabaseConfig struct {
    Host     string
    Port     int
    Database string
    Username string
    Password string
}

func NewExternalMigrator(config DatabaseConfig, tool string) *ExternalMigrator {
    return &ExternalMigrator{
        dbConfig: config,
        tool:     tool,
    }
}

// gh-ost migration for medium-sized tables
func (em *ExternalMigrator) RunGhostMigration(tableName, alterStatement string) error {
    cmd := exec.Command("gh-ost",
        fmt.Sprintf("--user=%s", em.dbConfig.Username),
        fmt.Sprintf("--password=%s", em.dbConfig.Password),
        fmt.Sprintf("--host=%s", em.dbConfig.Host),
        fmt.Sprintf("--port=%d", em.dbConfig.Port),
        fmt.Sprintf("--database=%s", em.dbConfig.Database),
        fmt.Sprintf("--table=%s", tableName),
        fmt.Sprintf("--alter=%s", alterStatement),
        "--execute",
        "--allow-on-master",
        "--concurrent-rowcount",
        "--default-retries=120",
        "--chunk-size=1000",
        "--max-load=Threads_running=25",
        "--critical-load=Threads_running=1000",
        "--throttle-control-replicas=replica1.domain.com:3306",
    )
    
    output, err := cmd.CombinedOutput()
    if err != nil {
        return fmt.Errorf("gh-ost migration failed: %w\nOutput: %s", err, string(output))
    }
    
    log.Printf("gh-ost migration completed successfully:\n%s", string(output))
    return nil
}

// pt-online-schema-change for large tables
func (em *ExternalMigrator) RunPercondaToolkit(tableName, alterStatement string) error {
    dsn := fmt.Sprintf("h=%s,P=%d,u=%s,p=%s,D=%s",
        em.dbConfig.Host, em.dbConfig.Port, em.dbConfig.Username,
        em.dbConfig.Password, em.dbConfig.Database)
    
    cmd := exec.Command("pt-online-schema-change",
        fmt.Sprintf("--alter=%s", alterStatement),
        fmt.Sprintf("D=%s,t=%s", em.dbConfig.Database, tableName),
        fmt.Sprintf("--host=%s", em.dbConfig.Host),
        fmt.Sprintf("--user=%s", em.dbConfig.Username),
        fmt.Sprintf("--password=%s", em.dbConfig.Password),
        "--execute",
        "--no-drop-old-table",
        "--chunk-size=1000",
        "--max-load=Threads_running:25",
        "--critical-load=Threads_running:1000",
        "--check-interval=5",
    )
    
    output, err := cmd.CombinedOutput()
    if err != nil {
        return fmt.Errorf("pt-online-schema-change failed: %w\nOutput: %s", err, string(output))
    }
    
    log.Printf("pt-online-schema-change completed successfully:\n%s", string(output))
    return nil
}
```

### 4. Zero-Downtime Migration Patterns

```go
// pkg/migration/zero_downtime.go
package migration

import (
    "database/sql"
    "time"
)

// Online column addition pattern
func AddColumnOnline(db *sql.DB, tableName, columnDef string) error {
    steps := []struct {
        name string
        sql  string
    }{
        {
            name: "Add column with default value",
            sql:  fmt.Sprintf("ALTER TABLE %s ADD COLUMN %s", tableName, columnDef),
        },
        {
            name: "Backfill existing rows in batches",
            sql:  fmt.Sprintf("UPDATE %s SET new_column = 'default_value' WHERE new_column IS NULL LIMIT 1000", tableName),
        },
    }
    
    for _, step := range steps {
        log.Printf("Executing: %s", step.name)
        
        if strings.Contains(step.sql, "UPDATE") {
            // Batch updates to avoid long locks
            if err := executeBatchUpdate(db, step.sql); err != nil {
                return err
            }
        } else {
            if _, err := db.Exec(step.sql); err != nil {
                return fmt.Errorf("failed to execute %s: %w", step.name, err)
            }
        }
    }
    
    return nil
}

func executeBatchUpdate(db *sql.DB, baseSQL string) error {
    for {
        result, err := db.Exec(baseSQL)
        if err != nil {
            return err
        }
        
        rowsAffected, _ := result.RowsAffected()
        if rowsAffected == 0 {
            break
        }
        
        // Small delay to prevent overwhelming the database
        time.Sleep(100 * time.Millisecond)
    }
    
    return nil
}

// Table rename pattern for major structural changes
func RenameTablePattern(db *sql.DB, oldTable, newTable string) error {
    // 1. Create new table with desired structure
    // 2. Set up triggers to keep tables in sync
    // 3. Copy data in batches
    // 4. Switch application to new table
    // 5. Clean up old table and triggers
    
    steps := []string{
        // Create triggers for ongoing sync
        fmt.Sprintf(`
            CREATE TRIGGER %s_insert_sync
            AFTER INSERT ON %s
            FOR EACH ROW
            INSERT INTO %s (id, name, email) VALUES (NEW.id, NEW.name, NEW.email)
        `, oldTable, oldTable, newTable),
        
        fmt.Sprintf(`
            CREATE TRIGGER %s_update_sync
            AFTER UPDATE ON %s
            FOR EACH ROW
            UPDATE %s SET name = NEW.name, email = NEW.email WHERE id = NEW.id
        `, oldTable, oldTable, newTable),
        
        fmt.Sprintf(`
            CREATE TRIGGER %s_delete_sync
            AFTER DELETE ON %s
            FOR EACH ROW
            DELETE FROM %s WHERE id = OLD.id
        `, oldTable, oldTable, newTable),
    }
    
    for _, step := range steps {
        if _, err := db.Exec(step); err != nil {
            return err
        }
    }
    
    // Copy existing data in batches
    return copyDataInBatches(db, oldTable, newTable)
}

func copyDataInBatches(db *sql.DB, source, destination string) error {
    batchSize := 1000
    offset := 0
    
    for {
        copySQL := fmt.Sprintf(`
            INSERT INTO %s (id, name, email)
            SELECT id, name, email FROM %s
            LIMIT %d OFFSET %d
        `, destination, source, batchSize, offset)
        
        result, err := db.Exec(copySQL)
        if err != nil {
            return err
        }
        
        rowsAffected, _ := result.RowsAffected()
        if rowsAffected == 0 {
            break
        }
        
        offset += batchSize
        time.Sleep(100 * time.Millisecond)
    }
    
    return nil
}
```

### 5. Migration Orchestration

```bash
#!/bin/bash
# scripts/run-migration.sh - Intelligent migration orchestration

set -e

MIGRATION_NAME="$1"
TABLE_NAME="$2"
ALTER_STATEMENT="$3"

if [ -z "$MIGRATION_NAME" ] || [ -z "$TABLE_NAME" ]; then
    echo "Usage: $0 <migration_name> <table_name> [alter_statement]"
    exit 1
fi

echo "Analyzing table: $TABLE_NAME"

# Get table size and row count
TABLE_SIZE=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "
    SELECT ROUND(((data_length + index_length) / 1024 / 1024), 2) 
    FROM information_schema.TABLES 
    WHERE table_schema = '$DB_NAME' AND table_name = '$TABLE_NAME'
")

ROW_COUNT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "
    SELECT COUNT(*) FROM $TABLE_NAME
")

echo "Table size: ${TABLE_SIZE}MB, Row count: ${ROW_COUNT}"

# Determine migration strategy
if (( $(echo "$TABLE_SIZE < 1024" | bc -l) )); then
    echo "Using application-embedded migration for small table"
    go run cmd/migrate/main.go --embedded --migration="$MIGRATION_NAME"
elif (( $(echo "$TABLE_SIZE < 102400" | bc -l) )); then
    echo "Using gh-ost for medium table"
    gh-ost \
        --user="$DB_USER" \
        --password="$DB_PASS" \
        --host="$DB_HOST" \
        --database="$DB_NAME" \
        --table="$TABLE_NAME" \
        --alter="$ALTER_STATEMENT" \
        --execute \
        --allow-on-master \
        --concurrent-rowcount \
        --default-retries=120 \
        --chunk-size=1000 \
        --max-load=Threads_running=25 \
        --critical-load=Threads_running=1000
else
    echo "Using pt-online-schema-change for large table"
    pt-online-schema-change \
        --alter="$ALTER_STATEMENT" \
        "D=$DB_NAME,t=$TABLE_NAME" \
        --host="$DB_HOST" \
        --user="$DB_USER" \
        --password="$DB_PASS" \
        --execute \
        --no-drop-old-table \
        --chunk-size=1000 \
        --max-load=Threads_running:25 \
        --critical-load=Threads_running:1000
fi

echo "Migration completed successfully!"
```

### 6. Migration Monitoring and Rollback

```go
// pkg/migration/monitor.go
package migration

import (
    "context"
    "database/sql"
    "time"
)

type MigrationMonitor struct {
    db               *sql.DB
    progressCallback func(progress MigrationProgress)
}

type MigrationProgress struct {
    TableName       string
    RowsProcessed   int64
    TotalRows       int64
    PercentComplete float64
    EstimatedTimeRemaining time.Duration
    CurrentOperation string
}

func (mm *MigrationMonitor) MonitorGhostMigration(tableName string) {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    ghostTable := fmt.Sprintf("_%s_gho", tableName)
    
    for range ticker.C {
        var processedRows, totalRows int64
        
        // Get original table row count
        err := mm.db.QueryRow(fmt.Sprintf("SELECT COUNT(*) FROM %s", tableName)).Scan(&totalRows)
        if err != nil {
            continue
        }
        
        // Get ghost table row count
        err = mm.db.QueryRow(fmt.Sprintf("SELECT COUNT(*) FROM %s", ghostTable)).Scan(&processedRows)
        if err != nil {
            continue
        }
        
        progress := MigrationProgress{
            TableName:       tableName,
            RowsProcessed:   processedRows,
            TotalRows:       totalRows,
            PercentComplete: float64(processedRows) / float64(totalRows) * 100,
            CurrentOperation: "Copying rows",
        }
        
        if mm.progressCallback != nil {
            mm.progressCallback(progress)
        }
        
        // Check if migration is complete
        if processedRows >= totalRows {
            break
        }
    }
}

// Emergency rollback functionality
type RollbackManager struct {
    db *sql.DB
}

func (rm *RollbackManager) PrepareRollback(tableName string) (*RollbackPlan, error) {
    plan := &RollbackPlan{
        TableName: tableName,
        Timestamp: time.Now(),
    }
    
    // Create table backup
    backupTable := fmt.Sprintf("%s_backup_%d", tableName, time.Now().Unix())
    createBackupSQL := fmt.Sprintf("CREATE TABLE %s AS SELECT * FROM %s", backupTable, tableName)
    
    if _, err := rm.db.Exec(createBackupSQL); err != nil {
        return nil, fmt.Errorf("failed to create backup table: %w", err)
    }
    
    plan.BackupTable = backupTable
    return plan, nil
}

func (rm *RollbackManager) ExecuteRollback(plan *RollbackPlan) error {
    // Restore from backup
    restoreSQL := fmt.Sprintf(`
        RENAME TABLE %s TO %s_old,
                     %s TO %s
    `, plan.TableName, plan.TableName, plan.BackupTable, plan.TableName)
    
    _, err := rm.db.Exec(restoreSQL)
    return err
}

type RollbackPlan struct {
    TableName   string
    BackupTable string
    Timestamp   time.Time
}
```

## Best Practices

### 1. Migration Size Guidelines

| Table Size | Row Count | Recommended Tool | Estimated Downtime |
|------------|-----------|------------------|-------------------|
| < 1GB | < 1M rows | Application-embedded | < 10 seconds |
| 1-10GB | 1-10M rows | gh-ost | Near-zero |
| 10-100GB | 10-100M rows | gh-ost with tuning | Near-zero |
| > 100GB | > 100M rows | pt-online-schema-change | Near-zero |

### 2. Operation-Specific Strategies

```sql
-- Safe operations (can run online)
ALTER TABLE users ADD COLUMN phone VARCHAR(20);
CREATE INDEX CONCURRENTLY idx_users_email ON users(email);  -- PostgreSQL
ALTER TABLE posts ADD INDEX idx_title (title);  -- MySQL

-- Risky operations (require careful planning)
ALTER TABLE users MODIFY COLUMN email VARCHAR(320);  -- May lock table
ALTER TABLE posts DROP COLUMN old_field;  -- Permanent data loss
ALTER TABLE orders ADD CONSTRAINT fk_user FOREIGN KEY (user_id) REFERENCES users(id);

-- Alternative approaches for risky operations
-- Instead of DROP COLUMN, mark as deprecated first
ALTER TABLE posts ADD COLUMN old_field_deprecated BOOLEAN DEFAULT FALSE;
UPDATE posts SET old_field_deprecated = TRUE WHERE old_field IS NOT NULL;
-- Later, when safe, actually drop the column
```

### 3. Testing Strategy

```go
// Test migrations on staging environment
func TestMigrationStrategy(t *testing.T) {
    testCases := []struct {
        tableSize int64
        expected  string
    }{
        {500 * 1024 * 1024, "application-embedded"},      // 500MB
        {5 * 1024 * 1024 * 1024, "gh-ost"},              // 5GB
        {200 * 1024 * 1024 * 1024, "pt-online-schema-change"}, // 200GB
    }
    
    strategy := NewSizeBasedStrategy()
    
    for _, tc := range testCases {
        result := strategy.GetRecommendedTool(tc.tableSize)
        assert.Equal(t, tc.expected, result)
    }
}
```

## Consequences

### Positive
- **Adaptive Strategy**: Right tool for the right job based on table size
- **Minimized Downtime**: Zero-downtime migrations for production systems
- **Risk Reduction**: Comprehensive backup and rollback strategies
- **Operational Efficiency**: Automated tool selection and monitoring
- **Scalability**: Strategy scales from small startups to large enterprises

### Negative
- **Tool Complexity**: Multiple tools require different expertise and maintenance
- **Infrastructure Dependencies**: External tools need proper installation and configuration
- **Monitoring Overhead**: Advanced migrations require sophisticated monitoring
- **Decision Complexity**: Teams need to understand when to use which approach

## Related Patterns
- [Migration Files](002-migration-files.md) - File organization and naming
- [Safe SQL Migration](003-migrating-sql.md) - SQL safety validation
- [Database Design Record](009-database-design-record.md) - Schema documentation
- [Version Management](014-version.md) - Database versioning strategies
