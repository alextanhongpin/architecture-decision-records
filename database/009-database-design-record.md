# Database Design Records (DDR)

## Status
**Accepted**

## Context
Database design decisions have long-lasting impacts on system performance, maintainability, and business logic implementation. Unlike application code, database schemas are harder to refactor and often persist for years. Poor database design documentation leads to:

- **Legacy Schema Confusion**: Developers struggle to understand existing table relationships and constraints
- **Business Logic Fragmentation**: Critical logic scattered across application layers and database triggers
- **Inconsistent Implementations**: Different services implementing similar logic differently
- **Performance Issues**: Suboptimal indexes and query patterns due to lack of design rationale
- **Data Integrity Problems**: Missing constraints and validation logic
- **Knowledge Loss**: Database design decisions lost when team members leave

Database design records provide structured documentation for schema decisions, ensuring consistency, maintainability, and knowledge transfer across teams.

## Decision
We will create Database Design Records (DDRs) for all significant database features, following a standardized template that documents schemas, constraints, indexes, triggers, and business logic rationale.

## Implementation

### 1. DDR Template Structure

```markdown
# DDR-001: User Authentication and Profile Management

## Status
[Proposed | Accepted | Deprecated | Superseded by DDR-XXX]

## Context
Brief description of the business requirement and technical constraints.

## Problem Statement
What specific database design challenge are we solving?

## Considered Solutions
### Solution A: Single Table Approach
- Description
- Pros/Cons
- Performance implications

### Solution B: Normalized Approach
- Description  
- Pros/Cons
- Performance implications

## Decision
Which solution was chosen and why.

## Schema Design
[SQL schema definitions]

## Business Rules
[Constraints and validation logic]

## Indexes and Performance
[Index strategy and query patterns]

## Migration Strategy
[How to implement the changes]

## Monitoring and Alerts
[Performance metrics to track]

## Consequences
Positive and negative impacts of the decision.

## Related DDRs
References to other relevant design records.
```

### 2. Example DDR: E-commerce Order Management

```markdown
# DDR-003: E-commerce Order Management System

## Status
**Accepted** (2024-01-15)

## Context
Our e-commerce platform needs to handle orders with multiple items, varying payment methods, shipping options, and order states. The system must support:
- Order creation and modification
- Inventory management integration
- Payment processing workflows
- Order fulfillment tracking
- Financial reporting and analytics

## Problem Statement
Design a database schema that efficiently handles complex order workflows while maintaining data consistency, supporting high transaction volumes, and enabling comprehensive reporting.

## Considered Solutions

### Solution A: Single Orders Table
Store all order information in one denormalized table.

**Pros:**
- Simple queries for basic order retrieval
- No joins required for order display

**Cons:**
- Data duplication for order items
- Difficult to maintain referential integrity
- Poor performance for complex queries
- Limited flexibility for varying product attributes

### Solution B: Normalized Order Schema
Separate tables for orders, order items, products, and related entities.

**Pros:**
- Normalized data structure reduces redundancy
- Referential integrity through foreign keys
- Flexible product catalog support
- Efficient storage and updates

**Cons:**
- More complex queries requiring joins
- Potential performance impact for order listing

### Solution C: Hybrid Approach with JSON
Normalized structure with JSON columns for flexible attributes.

**Pros:**
- Balance between normalization and flexibility
- Efficient storage for varying product attributes
- Good query performance with proper indexing

**Cons:**
- Limited SQL operations on JSON data
- Potential data type inconsistencies

## Decision
We choose **Solution B (Normalized Schema)** with strategic denormalization for performance-critical queries. This provides the best balance of data integrity, query flexibility, and maintainability.

## Schema Design

```sql
-- Core order tracking
CREATE TABLE orders (
    id BIGSERIAL PRIMARY KEY,
    order_number VARCHAR(50) UNIQUE NOT NULL,
    customer_id BIGINT NOT NULL REFERENCES customers(id),
    status order_status_enum NOT NULL DEFAULT 'pending',
    
    -- Financial information
    subtotal_amount DECIMAL(15,2) NOT NULL,
    tax_amount DECIMAL(15,2) NOT NULL DEFAULT 0,
    shipping_amount DECIMAL(15,2) NOT NULL DEFAULT 0,
    discount_amount DECIMAL(15,2) NOT NULL DEFAULT 0,
    total_amount DECIMAL(15,2) NOT NULL,
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    
    -- Shipping information
    shipping_address_id BIGINT REFERENCES addresses(id),
    shipping_method VARCHAR(50),
    estimated_delivery_date DATE,
    
    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    placed_at TIMESTAMP WITH TIME ZONE,
    version INTEGER DEFAULT 1,
    
    -- Constraints
    CONSTRAINT chk_order_amounts CHECK (
        subtotal_amount >= 0 AND 
        tax_amount >= 0 AND 
        shipping_amount >= 0 AND 
        discount_amount >= 0 AND
        total_amount = subtotal_amount + tax_amount + shipping_amount - discount_amount
    ),
    CONSTRAINT chk_order_dates CHECK (placed_at >= created_at)
);

-- Order line items
CREATE TABLE order_items (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id BIGINT NOT NULL REFERENCES products(id),
    product_variant_id BIGINT REFERENCES product_variants(id),
    
    -- Item details (denormalized for historical accuracy)
    product_name VARCHAR(255) NOT NULL,
    product_sku VARCHAR(100) NOT NULL,
    
    -- Pricing
    unit_price DECIMAL(15,2) NOT NULL,
    quantity INTEGER NOT NULL,
    line_total DECIMAL(15,2) NOT NULL,
    
    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT chk_order_item_quantity CHECK (quantity > 0),
    CONSTRAINT chk_order_item_pricing CHECK (
        unit_price >= 0 AND 
        line_total = unit_price * quantity
    ),
    CONSTRAINT uk_order_product UNIQUE (order_id, product_id, product_variant_id)
);

-- Order status transitions
CREATE TABLE order_status_history (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    status order_status_enum NOT NULL,
    previous_status order_status_enum,
    reason VARCHAR(255),
    notes TEXT,
    created_by BIGINT REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Payment tracking
CREATE TABLE order_payments (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    payment_method VARCHAR(50) NOT NULL,
    amount DECIMAL(15,2) NOT NULL,
    status payment_status_enum NOT NULL DEFAULT 'pending',
    transaction_id VARCHAR(255),
    gateway_response JSONB,
    processed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT chk_payment_amount CHECK (amount > 0)
);

-- Custom types
CREATE TYPE order_status_enum AS ENUM (
    'pending', 'confirmed', 'processing', 'shipped', 
    'delivered', 'cancelled', 'refunded'
);

CREATE TYPE payment_status_enum AS ENUM (
    'pending', 'authorized', 'captured', 'failed', 
    'cancelled', 'refunded', 'partially_refunded'
);
```

## Business Rules

### Database-Level Constraints
```sql
-- Ensure order totals are calculated correctly
ALTER TABLE orders ADD CONSTRAINT chk_order_calculation 
CHECK (total_amount = subtotal_amount + tax_amount + shipping_amount - discount_amount);

-- Prevent negative quantities
ALTER TABLE order_items ADD CONSTRAINT chk_positive_quantity 
CHECK (quantity > 0 AND unit_price >= 0);

-- Ensure payment amounts don't exceed order total
CREATE OR REPLACE FUNCTION check_payment_total() 
RETURNS TRIGGER AS $$
BEGIN
    IF (
        SELECT COALESCE(SUM(amount), 0) 
        FROM order_payments 
        WHERE order_id = NEW.order_id 
        AND status IN ('authorized', 'captured')
    ) + NEW.amount > (
        SELECT total_amount 
        FROM orders 
        WHERE id = NEW.order_id
    ) THEN
        RAISE EXCEPTION 'Payment amount exceeds order total';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_payment_total
    BEFORE INSERT OR UPDATE ON order_payments
    FOR EACH ROW EXECUTE FUNCTION check_payment_total();
```

### Application-Level Business Rules
```go
// Order business rules implementation
type OrderService struct {
    db *sql.DB
}

func (os *OrderService) CreateOrder(ctx context.Context, req CreateOrderRequest) (*Order, error) {
    // Validate business rules before database insertion
    if err := os.validateOrderCreation(req); err != nil {
        return nil, err
    }
    
    tx, err := os.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, err
    }
    defer tx.Rollback()
    
    // Create order with optimistic locking
    order, err := os.insertOrder(ctx, tx, req)
    if err != nil {
        return nil, err
    }
    
    // Reserve inventory
    if err := os.reserveInventory(ctx, tx, order.ID, req.Items); err != nil {
        return nil, err
    }
    
    // Record initial status
    if err := os.recordStatusChange(ctx, tx, order.ID, "pending", "", "Order created"); err != nil {
        return nil, err
    }
    
    return order, tx.Commit()
}

func (os *OrderService) validateOrderCreation(req CreateOrderRequest) error {
    // Business rule: Minimum order amount
    if req.Total < 10.00 {
        return errors.New("order total must be at least $10.00")
    }
    
    // Business rule: Maximum items per order
    if len(req.Items) > 50 {
        return errors.New("orders cannot contain more than 50 items")
    }
    
    // Business rule: Valid shipping address for physical products
    hasPhysicalProducts := false
    for _, item := range req.Items {
        if item.RequiresShipping {
            hasPhysicalProducts = true
            break
        }
    }
    
    if hasPhysicalProducts && req.ShippingAddressID == 0 {
        return errors.New("shipping address required for physical products")
    }
    
    return nil
}
```

## Indexes and Performance

### Primary Indexes
```sql
-- Order lookup and filtering
CREATE INDEX idx_orders_customer_status ON orders(customer_id, status, created_at DESC);
CREATE INDEX idx_orders_status_created ON orders(status, created_at DESC);
CREATE INDEX idx_orders_placed_at ON orders(placed_at DESC) WHERE placed_at IS NOT NULL;

-- Order items queries
CREATE INDEX idx_order_items_order_id ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(product_id, created_at DESC);

-- Status history tracking
CREATE INDEX idx_order_status_history_order ON order_status_history(order_id, created_at DESC);

-- Payment processing
CREATE INDEX idx_order_payments_order ON order_payments(order_id, status);
CREATE INDEX idx_order_payments_transaction ON order_payments(transaction_id) WHERE transaction_id IS NOT NULL;
```

### Query Optimization Examples
```sql
-- Efficient order listing with items
WITH order_summary AS (
    SELECT 
        o.id,
        o.order_number,
        o.total_amount,
        o.status,
        o.created_at,
        COUNT(oi.id) as item_count
    FROM orders o
    LEFT JOIN order_items oi ON o.id = oi.order_id
    WHERE o.customer_id = $1
    GROUP BY o.id, o.order_number, o.total_amount, o.status, o.created_at
    ORDER BY o.created_at DESC
    LIMIT 20
)
SELECT * FROM order_summary;

-- Order analytics query
SELECT 
    DATE_TRUNC('day', created_at) as order_date,
    status,
    COUNT(*) as order_count,
    SUM(total_amount) as total_revenue
FROM orders 
WHERE created_at >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY DATE_TRUNC('day', created_at), status
ORDER BY order_date DESC;
```

## Migration Strategy

### Phase 1: Schema Creation
```sql
-- Create tables in dependency order
-- 1. Reference tables (customers, products, addresses)
-- 2. Core order tables
-- 3. Related tables (payments, status history)
-- 4. Indexes and constraints
```

### Phase 2: Data Migration (if applicable)
```go
func MigrateExistingOrders(db *sql.DB) error {
    // Batch migration with progress tracking
    batchSize := 1000
    offset := 0
    
    for {
        orders, err := fetchLegacyOrders(db, offset, batchSize)
        if err != nil {
            return err
        }
        
        if len(orders) == 0 {
            break
        }
        
        if err := transformAndInsertOrders(db, orders); err != nil {
            return err
        }
        
        offset += batchSize
        log.Printf("Migrated %d orders", offset)
    }
    
    return nil
}
```

## Monitoring and Alerts

### Performance Metrics
```sql
-- Monitor query performance
SELECT 
    schemaname,
    tablename,
    attname,
    n_distinct,
    correlation
FROM pg_stats 
WHERE tablename IN ('orders', 'order_items', 'order_payments');

-- Index usage monitoring
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes 
WHERE tablename LIKE 'order%';
```

### Business Metrics
```go
type OrderMetrics struct {
    OrdersPerHour        int
    AverageOrderValue    float64
    PaymentFailureRate   float64
    InventoryConflicts   int
    StatusTransitionTime map[string]time.Duration
}

func (os *OrderService) CollectMetrics(ctx context.Context) (*OrderMetrics, error) {
    // Collect and report key business metrics
    metrics := &OrderMetrics{}
    
    // Orders per hour
    err := os.db.QueryRowContext(ctx, `
        SELECT COUNT(*) 
        FROM orders 
        WHERE created_at >= NOW() - INTERVAL '1 hour'
    `).Scan(&metrics.OrdersPerHour)
    
    // Average order value
    err = os.db.QueryRowContext(ctx, `
        SELECT AVG(total_amount) 
        FROM orders 
        WHERE created_at >= CURRENT_DATE
    `).Scan(&metrics.AverageOrderValue)
    
    return metrics, err
}
```

## Consequences

### Positive
- **Data Integrity**: Comprehensive constraints prevent invalid states
- **Performance**: Well-designed indexes support efficient queries
- **Auditability**: Complete order history and status tracking
- **Flexibility**: Schema supports various order types and workflows
- **Maintainability**: Clear documentation and business rules

### Negative
- **Complexity**: Multiple tables require careful join optimization
- **Storage Overhead**: Denormalized fields increase storage requirements
- **Migration Complexity**: Schema changes require careful planning
- **Query Complexity**: Some reports require complex multi-table joins

## Related DDRs
- [DDR-001: Customer Management](001-customer-management.md)
- [DDR-002: Product Catalog](002-product-catalog.md)
- [DDR-004: Inventory Management](004-inventory-management.md)
- [DDR-005: Payment Processing](005-payment-processing.md)
```

### 3. DDR Management Process

```go
// pkg/ddr/manager.go
package ddr

import (
    "fmt"
    "io/ioutil"
    "path/filepath"
    "regexp"
    "sort"
    "strings"
    "time"
)

type DDRManager struct {
    basePath string
}

type DDR struct {
    ID          string
    Title       string
    Status      string
    CreatedDate time.Time
    UpdatedDate time.Time
    FilePath    string
    Content     string
}

func NewDDRManager(basePath string) *DDRManager {
    return &DDRManager{basePath: basePath}
}

func (dm *DDRManager) CreateDDR(title, context string) (*DDR, error) {
    id := dm.generateNextID()
    filename := fmt.Sprintf("DDR-%s-%s.md", id, dm.slugify(title))
    filePath := filepath.Join(dm.basePath, filename)
    
    template := fmt.Sprintf(`# DDR-%s: %s

## Status
**Proposed**

## Context
%s

## Problem Statement
[Describe the specific database design challenge]

## Considered Solutions
### Solution A: [Name]
- Description
- Pros/Cons
- Performance implications

### Solution B: [Name]
- Description
- Pros/Cons
- Performance implications

## Decision
[Which solution was chosen and why]

## Schema Design
[SQL schema definitions]

## Business Rules
[Constraints and validation logic]

## Indexes and Performance
[Index strategy and query patterns]

## Migration Strategy
[How to implement the changes]

## Monitoring and Alerts
[Performance metrics to track]

## Consequences
### Positive
- [List positive impacts]

### Negative
- [List negative impacts]

## Related DDRs
- [References to other relevant design records]
`, id, title, context)

    err := ioutil.WriteFile(filePath, []byte(template), 0644)
    if err != nil {
        return nil, err
    }
    
    return &DDR{
        ID:          id,
        Title:       title,
        Status:      "Proposed",
        CreatedDate: time.Now(),
        FilePath:    filePath,
        Content:     template,
    }, nil
}

func (dm *DDRManager) ListDDRs() ([]*DDR, error) {
    files, err := filepath.Glob(filepath.Join(dm.basePath, "DDR-*.md"))
    if err != nil {
        return nil, err
    }
    
    var ddrs []*DDR
    for _, file := range files {
        ddr, err := dm.parseDDR(file)
        if err != nil {
            continue
        }
        ddrs = append(ddrs, ddr)
    }
    
    sort.Slice(ddrs, func(i, j int) bool {
        return ddrs[i].ID < ddrs[j].ID
    })
    
    return ddrs, nil
}

func (dm *DDRManager) parseDDR(filePath string) (*DDR, error) {
    content, err := ioutil.ReadFile(filePath)
    if err != nil {
        return nil, err
    }
    
    contentStr := string(content)
    
    // Extract ID from filename
    filename := filepath.Base(filePath)
    idRegex := regexp.MustCompile(`DDR-(\d+)`)
    idMatch := idRegex.FindStringSubmatch(filename)
    if len(idMatch) < 2 {
        return nil, fmt.Errorf("invalid DDR filename format: %s", filename)
    }
    
    // Extract title
    titleRegex := regexp.MustCompile(`# DDR-\d+: (.+)`)
    titleMatch := titleRegex.FindStringSubmatch(contentStr)
    title := "Unknown"
    if len(titleMatch) > 1 {
        title = titleMatch[1]
    }
    
    // Extract status
    statusRegex := regexp.MustCompile(`\*\*(.+?)\*\*`)
    statusMatch := statusRegex.FindStringSubmatch(contentStr)
    status := "Unknown"
    if len(statusMatch) > 1 {
        status = statusMatch[1]
    }
    
    return &DDR{
        ID:       idMatch[1],
        Title:    title,
        Status:   status,
        FilePath: filePath,
        Content:  contentStr,
    }, nil
}

func (dm *DDRManager) generateNextID() string {
    ddrs, _ := dm.ListDDRs()
    maxID := 0
    
    for _, ddr := range ddrs {
        if id := dm.parseID(ddr.ID); id > maxID {
            maxID = id
        }
    }
    
    return fmt.Sprintf("%03d", maxID+1)
}

func (dm *DDRManager) parseID(idStr string) int {
    var id int
    fmt.Sscanf(idStr, "%d", &id)
    return id
}

func (dm *DDRManager) slugify(title string) string {
    // Convert to lowercase and replace spaces with hyphens
    slug := strings.ToLower(title)
    slug = regexp.MustCompile(`[^a-z0-9\s-]`).ReplaceAllString(slug, "")
    slug = regexp.MustCompile(`\s+`).ReplaceAllString(slug, "-")
    slug = strings.Trim(slug, "-")
    
    // Limit length
    if len(slug) > 50 {
        slug = slug[:50]
    }
    
    return slug
}
```

### 4. Schema Evolution Tracking

```go
// pkg/ddr/evolution.go
package ddr

import (
    "database/sql"
    "fmt"
    "time"
)

type SchemaEvolution struct {
    db *sql.DB
}

func NewSchemaEvolution(db *sql.DB) *SchemaEvolution {
    return &SchemaEvolution{db: db}
}

// Track schema changes related to DDRs
func (se *SchemaEvolution) RecordSchemaChange(ddrID, changeType, description string, sqlStatements []string) error {
    tx, err := se.db.Begin()
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Insert schema change record
    var changeID int
    err = tx.QueryRow(`
        INSERT INTO schema_changes (ddr_id, change_type, description, created_at)
        VALUES ($1, $2, $3, $4)
        RETURNING id
    `, ddrID, changeType, description, time.Now()).Scan(&changeID)
    
    if err != nil {
        return err
    }
    
    // Insert SQL statements
    for i, stmt := range sqlStatements {
        _, err = tx.Exec(`
            INSERT INTO schema_change_statements (change_id, statement_order, sql_statement)
            VALUES ($1, $2, $3)
        `, changeID, i+1, stmt)
        
        if err != nil {
            return err
        }
    }
    
    return tx.Commit()
}

// Get schema evolution history
func (se *SchemaEvolution) GetEvolutionHistory(ddrID string) ([]SchemaChange, error) {
    rows, err := se.db.Query(`
        SELECT 
            sc.id,
            sc.ddr_id,
            sc.change_type,
            sc.description,
            sc.created_at,
            ARRAY_AGG(scs.sql_statement ORDER BY scs.statement_order) as statements
        FROM schema_changes sc
        LEFT JOIN schema_change_statements scs ON sc.id = scs.change_id
        WHERE sc.ddr_id = $1
        GROUP BY sc.id, sc.ddr_id, sc.change_type, sc.description, sc.created_at
        ORDER BY sc.created_at DESC
    `, ddrID)
    
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var changes []SchemaChange
    for rows.Next() {
        var change SchemaChange
        var statements pq.StringArray
        
        err := rows.Scan(
            &change.ID,
            &change.DDRID,
            &change.ChangeType,
            &change.Description,
            &change.CreatedAt,
            &statements,
        )
        
        if err != nil {
            continue
        }
        
        change.SQLStatements = []string(statements)
        changes = append(changes, change)
    }
    
    return changes, nil
}

type SchemaChange struct {
    ID            int
    DDRID         string
    ChangeType    string
    Description   string
    SQLStatements []string
    CreatedAt     time.Time
}

// Initialize schema change tracking tables
func (se *SchemaEvolution) InitializeTables() error {
    queries := []string{
        `CREATE TABLE IF NOT EXISTS schema_changes (
            id SERIAL PRIMARY KEY,
            ddr_id VARCHAR(10) NOT NULL,
            change_type VARCHAR(50) NOT NULL,
            description TEXT,
            created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
        )`,
        `CREATE TABLE IF NOT EXISTS schema_change_statements (
            id SERIAL PRIMARY KEY,
            change_id INTEGER REFERENCES schema_changes(id) ON DELETE CASCADE,
            statement_order INTEGER NOT NULL,
            sql_statement TEXT NOT NULL
        )`,
        `CREATE INDEX IF NOT EXISTS idx_schema_changes_ddr ON schema_changes(ddr_id, created_at DESC)`,
    }
    
    for _, query := range queries {
        if _, err := se.db.Exec(query); err != nil {
            return err
        }
    }
    
    return nil
}
```

## Best Practices

### 1. DDR Creation Guidelines

- **One Feature Per DDR**: Each DDR should focus on a single database feature or domain
- **Include Alternatives**: Always document alternative solutions considered
- **Business Context**: Clearly explain the business requirements driving the design
- **Performance Considerations**: Include expected query patterns and performance requirements
- **Migration Impact**: Document the effort required to implement changes

### 2. Schema Design Principles

```sql
-- Good: Clear naming conventions
CREATE TABLE customer_orders (
    id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(id),
    order_status order_status_enum NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Good: Appropriate constraints
ALTER TABLE products ADD CONSTRAINT chk_price_positive 
CHECK (price >= 0);

-- Good: Proper indexing strategy
CREATE INDEX idx_orders_customer_status_date 
ON customer_orders(customer_id, order_status, created_at DESC);
```

### 3. Documentation Maintenance

```go
// Automated DDR validation
func ValidateDDR(content string) []ValidationError {
    var errors []ValidationError
    
    // Check required sections
    requiredSections := []string{
        "## Status", "## Context", "## Decision", 
        "## Schema Design", "## Consequences",
    }
    
    for _, section := range requiredSections {
        if !strings.Contains(content, section) {
            errors = append(errors, ValidationError{
                Type:    "MissingSection",
                Message: fmt.Sprintf("Required section missing: %s", section),
            })
        }
    }
    
    // Check for SQL injection patterns in schema
    dangerousPatterns := []string{"DROP TABLE", "DELETE FROM", "TRUNCATE"}
    for _, pattern := range dangerousPatterns {
        if strings.Contains(strings.ToUpper(content), pattern) {
            errors = append(errors, ValidationError{
                Type:    "DangerousSQL",
                Message: fmt.Sprintf("Potentially dangerous SQL pattern found: %s", pattern),
            })
        }
    }
    
    return errors
}
```

## Consequences

### Positive
- **Knowledge Preservation**: Database design decisions are documented and searchable
- **Consistency**: Standardized approach to database design across teams
- **Faster Onboarding**: New team members can understand database rationale quickly
- **Better Decisions**: Structured evaluation of alternatives leads to better choices
- **Reduced Technical Debt**: Well-documented schemas are easier to maintain and evolve

### Negative
- **Documentation Overhead**: Requires time and effort to create and maintain DDRs
- **Process Complexity**: Teams need to adopt new documentation practices
- **Potential Delays**: DDR creation process may slow down initial development
- **Maintenance Burden**: DDRs need to be kept up-to-date as schemas evolve

## Related Patterns
- [Migration Files](002-migration-files.md) - Implementing DDR decisions through migrations
- [Safe SQL Migration](003-migrating-sql.md) - Executing schema changes safely
- [Database Versioning](014-version.md) - Managing database schema versions
- [Architecture Decision Records](../architecture/001-step-driven-development.md) - General ADR patterns
