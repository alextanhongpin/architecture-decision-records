# Database Migration Files

## Status

`accepted`

## Context

Database migrations are essential for evolving database schemas in a controlled, versioned manner across different environments. Proper migration management ensures database schema consistency, enables rollbacks when necessary, and supports collaborative development workflows.

## Decision

We will implement a comprehensive database migration strategy using modern tooling and best practices to ensure safe, reliable, and maintainable database schema evolution.

## Migration Strategy

### Tools and Framework

#### Primary Tool: dbmate
```bash
# Install dbmate
curl -fsSL -o /usr/local/bin/dbmate https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64
chmod +x /usr/local/bin/dbmate

# Configure database URL
export DATABASE_URL="postgres://user:password@localhost/myapp?sslmode=disable"

# Create new migration
dbmate new create_users_table

# Run migrations
dbmate up

# Check migration status
dbmate status
```

#### Alternative Tools
- **Atlas**: Schema-as-code migration tool
- **golang-migrate**: Pure Go migration library
- **Flyway**: Enterprise-grade migration tool
- **Liquibase**: XML/YAML-based migrations

### Migration File Structure

```
db/
├── migrations/
│   ├── 20240101120000_create_users_table.sql
│   ├── 20240101130000_add_email_index.sql
│   ├── 20240102100000_create_orders_table.sql
│   └── 20240102110000_add_foreign_keys.sql
├── schema.sql
├── seeds/
│   ├── development.sql
│   ├── test.sql
│   └── production.sql
└── dbmate.env
```

### Migration File Examples

#### Forward-Only Migration (Recommended)
```sql
-- 20240101120000_create_users_table.sql
-- migrate:up

CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    username VARCHAR(100) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    is_active BOOLEAN NOT NULL DEFAULT true,
    email_verified BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_active ON users(is_active) WHERE is_active = true;
CREATE INDEX idx_users_created_at ON users(created_at);

-- Add comments for documentation
COMMENT ON TABLE users IS 'Application users with authentication credentials';
COMMENT ON COLUMN users.email IS 'Unique email address for authentication';
COMMENT ON COLUMN users.password_hash IS 'Bcrypt hash of user password';

-- Create updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_users_updated_at 
    BEFORE UPDATE ON users 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();
```

#### Complex Migration with Data Transformation
```sql
-- 20240102150000_split_user_name.sql
-- migrate:up

-- Add new columns
ALTER TABLE users 
ADD COLUMN first_name VARCHAR(100),
ADD COLUMN last_name VARCHAR(100);

-- Migrate existing data
UPDATE users 
SET 
    first_name = SPLIT_PART(full_name, ' ', 1),
    last_name = CASE 
        WHEN ARRAY_LENGTH(STRING_TO_ARRAY(full_name, ' '), 1) > 1 
        THEN SUBSTRING(full_name FROM LENGTH(SPLIT_PART(full_name, ' ', 1)) + 2)
        ELSE ''
    END
WHERE full_name IS NOT NULL;

-- Add constraints after data migration
ALTER TABLE users 
ALTER COLUMN first_name SET NOT NULL,
ALTER COLUMN last_name SET NOT NULL;

-- Drop old column
ALTER TABLE users DROP COLUMN full_name;

-- Add indexes
CREATE INDEX idx_users_first_name ON users(first_name);
CREATE INDEX idx_users_last_name ON users(last_name);
```

### Schema Management Best Practices

#### 1. Forward-Only Migrations
```sql
-- ❌ Avoid down migrations in production
-- migrate:down
-- DROP TABLE users;

-- ✅ Use forward-only approach
-- If you need to undo, create a new migration:
-- 20240103000000_remove_unused_column.sql
ALTER TABLE users DROP COLUMN IF EXISTS deprecated_field;
```

#### 2. Schema Dump and Version Control
```bash
# Generate schema dump after migrations
dbmate dump

# Commit schema.sql to version control
git add db/schema.sql
git commit -m "Update schema after user table migration"
```

#### 3. Safe Column Operations
```sql
-- ✅ Safe: Add nullable column
ALTER TABLE users ADD COLUMN phone VARCHAR(20);

-- ✅ Safe: Add column with default
ALTER TABLE users ADD COLUMN status VARCHAR(20) NOT NULL DEFAULT 'active';

-- ⚠️ Careful: Add NOT NULL column (requires backfill)
-- Step 1: Add nullable column
ALTER TABLE users ADD COLUMN required_field VARCHAR(50);

-- Step 2: Backfill data (separate migration or deployment)
UPDATE users SET required_field = 'default_value' WHERE required_field IS NULL;

-- Step 3: Add NOT NULL constraint (separate migration)
ALTER TABLE users ALTER COLUMN required_field SET NOT NULL;
```

### Data Seeding Strategy

#### Development Seeds
```sql
-- db/seeds/development.sql
INSERT INTO users (email, username, password_hash, first_name, last_name) VALUES
('admin@example.com', 'admin', '$2a$10$hash1', 'Admin', 'User'),
('user@example.com', 'user', '$2a$10$hash2', 'Test', 'User'),
('demo@example.com', 'demo', '$2a$10$hash3', 'Demo', 'User');

INSERT INTO roles (name, description) VALUES
('admin', 'Administrator role with full access'),
('user', 'Standard user role'),
('viewer', 'Read-only access role');
```

#### Test Seeds
```sql
-- db/seeds/test.sql
-- Minimal data for testing
INSERT INTO users (email, username, password_hash, first_name, last_name) VALUES
('test@example.com', 'testuser', '$2a$10$testhash', 'Test', 'User');
```

#### Production Seeds
```sql
-- db/seeds/production.sql
-- Only essential reference data
INSERT INTO roles (name, description) VALUES
('admin', 'Administrator role'),
('user', 'Standard user role');

INSERT INTO settings (key, value) VALUES
('app_version', '1.0.0'),
('maintenance_mode', 'false');
```

### Automated Schema Diffing

#### Using Atlas
```bash
# Install Atlas
curl -sSf https://atlasgo.sh | sh

# Define desired schema
cat > schema.hcl <<EOF
table "users" {
  schema = schema.public
  column "id" {
    null = false
    type = bigserial
  }
  column "email" {
    null = false
    type = varchar(255)
  }
  primary_key {
    columns = [column.id]
  }
}
EOF

# Generate migration from current state to desired schema
atlas schema diff \
  --from "postgres://localhost:5432/myapp?sslmode=disable" \
  --to "file://schema.hcl" \
  --dev-url "docker://postgres/15/test?search_path=public"
```

#### Using migra (PostgreSQL)
```bash
# Install migra
pip install migra

# Generate diff between databases
migra postgresql:///db1 postgresql:///db2

# Generate migration from schema file
migra postgresql:///current_db file://desired_schema.sql
```

### Migration Workflow

#### Development Workflow
```bash
#!/bin/bash
# scripts/migrate.sh

set -e

# Load environment
source .env

case "${1:-}" in
  "new")
    if [ -z "$2" ]; then
      echo "Usage: $0 new migration_name"
      exit 1
    fi
    dbmate new "$2"
    ;;
  "up")
    dbmate up
    dbmate dump
    echo "Schema updated and dumped"
    ;;
  "status")
    dbmate status
    ;;
  "create-db")
    dbmate create
    ;;
  "drop-db")
    read -p "Are you sure you want to drop the database? (y/N) " confirm
    if [ "$confirm" = "y" ]; then
      dbmate drop
    fi
    ;;
  "reset")
    read -p "Reset database? This will drop and recreate. (y/N) " confirm
    if [ "$confirm" = "y" ]; then
      dbmate drop
      dbmate create
      dbmate up
      dbmate dump
      echo "Database reset complete"
    fi
    ;;
  "seed")
    ENV=${2:-development}
    if [ -f "db/seeds/${ENV}.sql" ]; then
      psql $DATABASE_URL -f "db/seeds/${ENV}.sql"
      echo "Seeded with ${ENV} data"
    else
      echo "Seed file for ${ENV} not found"
    fi
    ;;
  *)
    echo "Usage: $0 {new|up|status|create-db|drop-db|reset|seed}"
    echo ""
    echo "  new <name>    Create new migration file"
    echo "  up            Run pending migrations"
    echo "  status        Show migration status"
    echo "  create-db     Create database"
    echo "  drop-db       Drop database"
    echo "  reset         Drop, create, and migrate database"
    echo "  seed [env]    Run seed data (default: development)"
    exit 1
    ;;
esac
```

#### CI/CD Integration
```yaml
# .github/workflows/migrate.yml
name: Database Migration

on:
  push:
    branches: [main]
    paths: ['db/migrations/**']

jobs:
  migrate:
    runs-on: ubuntu-latest
    
    services:
      postgres:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: test_db
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
    - uses: actions/checkout@v3
    
    - name: Install dbmate
      run: |
        sudo curl -fsSL -o /usr/local/bin/dbmate \
          https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64
        sudo chmod +x /usr/local/bin/dbmate
    
    - name: Run migrations
      env:
        DATABASE_URL: postgres://postgres:postgres@localhost:5432/test_db?sslmode=disable
      run: |
        dbmate up
        dbmate dump
    
    - name: Validate schema
      run: |
        # Check if schema.sql was updated
        git diff --exit-code db/schema.sql || {
          echo "Schema dump not updated. Run 'dbmate dump' and commit changes."
          exit 1
        }
```

### Advanced Migration Patterns

#### Zero-Downtime Migrations
```sql
-- Phase 1: Add new column (nullable)
-- 20240201100000_add_new_status_column.sql
ALTER TABLE orders ADD COLUMN new_status VARCHAR(20);
CREATE INDEX CONCURRENTLY idx_orders_new_status ON orders(new_status);

-- Phase 2: Backfill data (application deployment)
-- Application code handles both old and new columns

-- Phase 3: Make column NOT NULL and drop old column
-- 20240201120000_finalize_status_migration.sql
UPDATE orders SET new_status = 'pending' WHERE new_status IS NULL;
ALTER TABLE orders ALTER COLUMN new_status SET NOT NULL;
ALTER TABLE orders DROP COLUMN old_status;
ALTER TABLE orders RENAME COLUMN new_status TO status;
```

#### Large Table Modifications
```sql
-- For large tables, use batched updates
-- 20240201150000_backfill_user_roles.sql

DO $$
DECLARE
    batch_size INTEGER := 1000;
    processed INTEGER := 0;
    total_rows INTEGER;
BEGIN
    SELECT COUNT(*) INTO total_rows FROM users WHERE role_id IS NULL;
    
    WHILE processed < total_rows LOOP
        UPDATE users 
        SET role_id = 2 -- default user role
        WHERE id IN (
            SELECT id FROM users 
            WHERE role_id IS NULL 
            ORDER BY id 
            LIMIT batch_size
        );
        
        processed := processed + batch_size;
        RAISE NOTICE 'Processed % of % rows', processed, total_rows;
        
        -- Small delay to reduce load
        PERFORM pg_sleep(0.1);
    END LOOP;
END $$;
```

### Migration Validation and Testing

#### Pre-deployment Validation
```sql
-- migration_tests.sql
-- Test constraints and data integrity

-- Check for orphaned records
SELECT 'Orphaned orders' as issue, COUNT(*) as count
FROM orders o 
LEFT JOIN users u ON o.user_id = u.id 
WHERE u.id IS NULL AND o.user_id IS NOT NULL;

-- Check for duplicate emails
SELECT 'Duplicate emails' as issue, COUNT(*) as count
FROM (
    SELECT email, COUNT(*) 
    FROM users 
    GROUP BY email 
    HAVING COUNT(*) > 1
) duplicates;

-- Validate foreign key constraints
SELECT 'Invalid foreign keys' as issue, COUNT(*) as count
FROM information_schema.table_constraints tc
JOIN information_schema.referential_constraints rc 
    ON tc.constraint_name = rc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
AND NOT EXISTS (
    SELECT 1 FROM information_schema.key_column_usage
    WHERE constraint_name = tc.constraint_name
);
```

#### Automated Testing
```go
// migration_test.go
package database

import (
    "database/sql"
    "testing"
    
    _ "github.com/lib/pq"
)

func TestMigrations(t *testing.T) {
    db, err := sql.Open("postgres", "postgres://localhost/test_db?sslmode=disable")
    if err != nil {
        t.Fatal(err)
    }
    defer db.Close()

    // Test that all tables exist
    tables := []string{"users", "orders", "products"}
    for _, table := range tables {
        var exists bool
        err := db.QueryRow(`
            SELECT EXISTS (
                SELECT FROM information_schema.tables 
                WHERE table_name = $1
            )`, table).Scan(&exists)
        
        if err != nil {
            t.Fatalf("Error checking table %s: %v", table, err)
        }
        
        if !exists {
            t.Errorf("Table %s does not exist", table)
        }
    }

    // Test constraints
    var constraintCount int
    err = db.QueryRow(`
        SELECT COUNT(*) 
        FROM information_schema.table_constraints 
        WHERE constraint_type = 'FOREIGN KEY'
    `).Scan(&constraintCount)
    
    if err != nil {
        t.Fatal(err)
    }
    
    if constraintCount == 0 {
        t.Error("No foreign key constraints found")
    }
}
```

### Configuration Management

#### Environment Configuration
```bash
# .env.development
DATABASE_URL=postgres://user:password@localhost:5432/myapp_dev?sslmode=disable
DBMATE_MIGRATIONS_DIR=db/migrations
DBMATE_SCHEMA_FILE=db/schema.sql

# .env.test
DATABASE_URL=postgres://user:password@localhost:5432/myapp_test?sslmode=disable
DBMATE_MIGRATIONS_DIR=db/migrations
DBMATE_SCHEMA_FILE=db/schema.sql

# .env.production
DATABASE_URL=postgres://user:password@prod-db:5432/myapp_prod?sslmode=require
DBMATE_MIGRATIONS_DIR=db/migrations
DBMATE_SCHEMA_FILE=db/schema.sql
DBMATE_NO_DUMP_SCHEMA=true  # Don't auto-dump in production
```

#### Docker Integration
```dockerfile
# Dockerfile.migrate
FROM amacneil/dbmate:latest

COPY db/ /db/
WORKDIR /

ENTRYPOINT ["dbmate"]
```

```yaml
# docker-compose.yml
version: '3.8'
services:
  migrate:
    build:
      context: .
      dockerfile: Dockerfile.migrate
    environment:
      - DATABASE_URL=postgres://user:password@db:5432/myapp?sslmode=disable
    depends_on:
      - db
    command: up

  db:
    image: postgres:15
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
```

## Best Practices

### 1. Migration Safety
- Always test migrations on a copy of production data
- Use transactions where possible (PostgreSQL)
- Implement migration locks to prevent concurrent runs
- Monitor migration performance and lock duration

### 2. Naming Conventions
```
YYYYMMDDHHMMSS_descriptive_name.sql

Examples:
20240101120000_create_users_table.sql
20240101130000_add_email_index_to_users.sql
20240102100000_create_orders_table.sql
20240102110000_add_foreign_key_orders_users.sql
```

### 3. Documentation
- Include comments in migration files
- Document breaking changes
- Maintain changelog of schema changes
- Use descriptive commit messages

### 4. Performance Considerations
- Create indexes concurrently for large tables
- Use batched updates for large data migrations
- Monitor query execution plans
- Consider maintenance windows for risky migrations

## Consequences

### Positive
- **Consistency**: Database schema consistency across environments
- **Auditability**: Complete history of schema changes
- **Collaboration**: Multiple developers can work on schema changes safely
- **Automation**: Automated deployment and testing capabilities
- **Rollback**: Easy rollback capabilities through version control

### Negative
- **Complexity**: Additional tooling and process overhead
- **Coordination**: Requires coordination between code and schema changes
- **Testing**: Need comprehensive testing of migrations
- **Performance**: Large migrations can impact database performance

### Mitigation
- **Training**: Ensure team understands migration best practices
- **Automation**: Automate testing and validation processes
- **Monitoring**: Monitor migration performance and impact
- **Documentation**: Maintain clear documentation and procedures
- **Staging**: Always test migrations in staging environment first

## Related Patterns
- [006-migration.md](006-migration.md) - General migration strategies
- [003-migrating-sql.md](003-migrating-sql.md) - SQL migration patterns
- [021-postgres-app.md](021-postgres-app.md) - PostgreSQL application patterns
- [014-version.md](014-version.md) - Database versioning strategies



