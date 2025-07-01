# Application Version in Database Rows

## Status

`accepted`

## Context

Rapidly evolving applications often require changes to data formats, business logic, and column semantics without breaking existing functionality. Traditional database migrations can be challenging for large tables or when multiple application versions need to coexist.

### Challenges with Schema Evolution

| Challenge | Traditional Approach | Versioned Row Approach |
|-----------|---------------------|------------------------|
| **Large Table Changes** | Expensive migrations, downtime | Gradual migration, no downtime |
| **Multiple App Versions** | All must use same format | Each version handles its data |
| **Rollbacks** | Complex schema rollbacks | Application logic rollbacks |
| **A/B Testing** | Difficult with schema changes | Easy version-based testing |
| **Data Format Evolution** | Breaking changes | Backward compatibility |

### Common Use Cases

- **Format Changes**: Reference number formats, ID generation strategies
- **Business Logic Evolution**: Calculation methods, validation rules
- **Data Interpretation**: Column meaning changes, enum value evolution
- **Feature Flags**: Version-based feature enablement
- **Migration Safety**: Gradual rollout of data format changes

### Example Evolution Scenarios

```sql
-- Scenario 1: Reference Number Format Change
-- v1: 'REF-210101-001' (prefix-date-sequence)
-- v2: 'uuid4-generated-string'
-- v3: 'custom-business-logic-format'

-- Scenario 2: Address Storage Evolution
-- v1: Single 'address' text field
-- v2: Structured address with separate city, state, zip
-- v3: Geolocation-enhanced address with coordinates
```

## Decision

Implement **version-aware row storage** with the following strategies:

### Core Versioning Architecture

1. **Version Column**: Add `app_version` or `data_version` to tables requiring evolution
2. **Backward Compatibility**: Applications handle multiple versions gracefully
3. **Gradual Migration**: New data uses new versions, existing data remains
4. **Version-Specific Logic**: Business logic branches based on version
5. **Migration Strategies**: Background processes upgrade data when needed

## Implementation

### Database Schema Design

```sql
-- Base versioned table structure
CREATE TABLE products (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    
    -- Version tracking
    app_version VARCHAR(20) NOT NULL DEFAULT '1.0.0',
    data_version INTEGER NOT NULL DEFAULT 1,
    
    -- Flexible data storage for version-specific fields
    metadata JSONB DEFAULT '{}',
    
    -- Standard audit fields
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    created_by_version VARCHAR(20),
    updated_by_version VARCHAR(20)
);

-- Index on version for efficient queries
CREATE INDEX idx_products_data_version ON products(data_version);
CREATE INDEX idx_products_app_version ON products(app_version);

-- Example: Orders table with reference number evolution
CREATE TABLE orders (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    
    -- Version-aware reference number
    reference_number VARCHAR(255) NOT NULL,
    reference_format VARCHAR(50) NOT NULL DEFAULT 'v1_sha_date',
    
    -- Order data
    total DECIMAL(10,2) NOT NULL,
    status VARCHAR(50) DEFAULT 'pending',
    
    -- Versioning
    app_version VARCHAR(20) NOT NULL DEFAULT '1.0.0',
    data_version INTEGER NOT NULL DEFAULT 1,
    metadata JSONB DEFAULT '{}',
    
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Unique constraint considering version compatibility
CREATE UNIQUE INDEX idx_orders_reference_format 
ON orders(reference_number, reference_format);
```

### Go Version Handler Framework

```go
package versioning

import (
    "context"
    "database/sql/driver"
    "encoding/json"
    "fmt"
    "time"
)

// Version represents application version information
type Version struct {
    Major int    `json:"major"`
    Minor int    `json:"minor"`
    Patch int    `json:"patch"`
    Label string `json:"label,omitempty"`
}

func (v Version) String() string {
    if v.Label != "" {
        return fmt.Sprintf("%d.%d.%d-%s", v.Major, v.Minor, v.Patch, v.Label)
    }
    return fmt.Sprintf("%d.%d.%d", v.Major, v.Minor, v.Patch)
}

func ParseVersion(s string) (*Version, error) {
    var v Version
    _, err := fmt.Sscanf(s, "%d.%d.%d", &v.Major, &v.Minor, &v.Patch)
    if err != nil {
        return nil, fmt.Errorf("invalid version format: %s", s)
    }
    return &v, nil
}

// IsCompatible checks if this version can handle data from another version
func (v Version) IsCompatible(other Version) bool {
    // Major version compatibility
    if v.Major != other.Major {
        return false
    }
    
    // Minor version backward compatibility
    return v.Minor >= other.Minor
}

// VersionedEntity represents an entity with version awareness
type VersionedEntity interface {
    GetAppVersion() string
    GetDataVersion() int
    SetAppVersion(version string)
    SetDataVersion(version int)
    GetMetadata() map[string]interface{}
    SetMetadata(metadata map[string]interface{})
}

// VersionHandler defines how to handle different data versions
type VersionHandler interface {
    CanHandle(dataVersion int) bool
    Transform(ctx context.Context, entity VersionedEntity) error
    Validate(ctx context.Context, entity VersionedEntity) error
    Migrate(ctx context.Context, from, to int, entity VersionedEntity) error
}

// VersionManager coordinates version handling across the application
type VersionManager struct {
    currentVersion *Version
    handlers       map[int]VersionHandler
    migrators      map[string]MigrationHandler
}

type MigrationHandler func(ctx context.Context, entity VersionedEntity) error

func NewVersionManager(currentVersion string) (*VersionManager, error) {
    version, err := ParseVersion(currentVersion)
    if err != nil {
        return nil, err
    }
    
    return &VersionManager{
        currentVersion: version,
        handlers:       make(map[int]VersionHandler),
        migrators:      make(map[string]MigrationHandler),
    }, nil
}

// RegisterHandler registers a version handler for a specific data version
func (vm *VersionManager) RegisterHandler(dataVersion int, handler VersionHandler) {
    vm.handlers[dataVersion] = handler
}

// RegisterMigrator registers a migration handler for version transitions
func (vm *VersionManager) RegisterMigrator(fromTo string, migrator MigrationHandler) {
    vm.migrators[fromTo] = migrator
}

// ProcessEntity handles an entity based on its version
func (vm *VersionManager) ProcessEntity(ctx context.Context, entity VersionedEntity) error {
    dataVersion := entity.GetDataVersion()
    
    handler, exists := vm.handlers[dataVersion]
    if !exists {
        return fmt.Errorf("no handler for data version %d", dataVersion)
    }
    
    if !handler.CanHandle(dataVersion) {
        return fmt.Errorf("handler cannot process data version %d", dataVersion)
    }
    
    // Transform entity based on version
    if err := handler.Transform(ctx, entity); err != nil {
        return fmt.Errorf("transformation failed: %w", err)
    }
    
    // Validate transformed entity
    if err := handler.Validate(ctx, entity); err != nil {
        return fmt.Errorf("validation failed: %w", err)
    }
    
    return nil
}

// MigrateEntity migrates an entity from one version to another
func (vm *VersionManager) MigrateEntity(ctx context.Context, entity VersionedEntity, 
    targetVersion int) error {
    
    currentVersion := entity.GetDataVersion()
    if currentVersion == targetVersion {
        return nil // No migration needed
    }
    
    migrationKey := fmt.Sprintf("%d->%d", currentVersion, targetVersion)
    migrator, exists := vm.migrators[migrationKey]
    if !exists {
        return fmt.Errorf("no migrator for %s", migrationKey)
    }
    
    if err := migrator(ctx, entity); err != nil {
        return fmt.Errorf("migration failed: %w", err)
    }
    
    entity.SetDataVersion(targetVersion)
    entity.SetAppVersion(vm.currentVersion.String())
    
    return nil
}
```

### Product Entity with Version Support

```go
package model

import (
    "context"
    "encoding/json"
    "time"
)

// Product represents a versioned product entity
type Product struct {
    ID          int64                  `json:"id" db:"id"`
    Name        string                 `json:"name" db:"name"`
    Price       float64                `json:"price" db:"price"`
    
    // Version fields
    AppVersion  string                 `json:"app_version" db:"app_version"`
    DataVersion int                    `json:"data_version" db:"data_version"`
    Metadata    map[string]interface{} `json:"metadata" db:"metadata"`
    
    CreatedAt   time.Time              `json:"created_at" db:"created_at"`
    UpdatedAt   time.Time              `json:"updated_at" db:"updated_at"`
}

func (p *Product) GetAppVersion() string {
    return p.AppVersion
}

func (p *Product) GetDataVersion() int {
    return p.DataVersion
}

func (p *Product) SetAppVersion(version string) {
    p.AppVersion = version
}

func (p *Product) SetDataVersion(version int) {
    p.DataVersion = version
}

func (p *Product) GetMetadata() map[string]interface{} {
    if p.Metadata == nil {
        p.Metadata = make(map[string]interface{})
    }
    return p.Metadata
}

func (p *Product) SetMetadata(metadata map[string]interface{}) {
    p.Metadata = metadata
}

// Version-specific data accessors
func (p *Product) GetFormattedPrice() string {
    switch p.DataVersion {
    case 1:
        return fmt.Sprintf("$%.2f", p.Price)
    case 2:
        // Version 2 includes currency code
        currency := "USD"
        if curr, ok := p.GetMetadata()["currency"]; ok {
            currency = curr.(string)
        }
        return fmt.Sprintf("%.2f %s", p.Price, currency)
    case 3:
        // Version 3 includes localized formatting
        locale := "en-US"
        if loc, ok := p.GetMetadata()["locale"]; ok {
            locale = loc.(string)
        }
        return p.formatPriceForLocale(locale)
    default:
        return fmt.Sprintf("%.2f", p.Price)
    }
}

func (p *Product) formatPriceForLocale(locale string) string {
    // Implementation would use locale-specific formatting
    return fmt.Sprintf("%.2f", p.Price)
}
```

### Version-Specific Handlers

```go
package handlers

import (
    "context"
    "fmt"
    
    "github.com/your-org/app/internal/model"
    "github.com/your-org/app/internal/versioning"
)

// ProductV1Handler handles version 1 product data
type ProductV1Handler struct{}

func (h *ProductV1Handler) CanHandle(dataVersion int) bool {
    return dataVersion == 1
}

func (h *ProductV1Handler) Transform(ctx context.Context, entity versioning.VersionedEntity) error {
    product := entity.(*model.Product)
    
    // Version 1 transformations
    if product.Price < 0 {
        return fmt.Errorf("price cannot be negative in version 1")
    }
    
    // Ensure metadata has required v1 fields
    metadata := product.GetMetadata()
    if _, exists := metadata["created_by_v1"]; !exists {
        metadata["created_by_v1"] = true
        metadata["original_format"] = "simple_price"
    }
    
    return nil
}

func (h *ProductV1Handler) Validate(ctx context.Context, entity versioning.VersionedEntity) error {
    product := entity.(*model.Product)
    
    if product.Name == "" {
        return fmt.Errorf("name is required in version 1")
    }
    
    if product.Price <= 0 {
        return fmt.Errorf("price must be positive in version 1")
    }
    
    return nil
}

func (h *ProductV1Handler) Migrate(ctx context.Context, from, to int, 
    entity versioning.VersionedEntity) error {
    
    if from == 1 && to == 2 {
        return h.migrateV1ToV2(ctx, entity)
    }
    
    return fmt.Errorf("unsupported migration from v%d to v%d", from, to)
}

func (h *ProductV1Handler) migrateV1ToV2(ctx context.Context, 
    entity versioning.VersionedEntity) error {
    
    product := entity.(*model.Product)
    metadata := product.GetMetadata()
    
    // Add currency field for v2
    metadata["currency"] = "USD"
    metadata["migrated_from_v1"] = true
    metadata["migration_timestamp"] = time.Now().Unix()
    
    return nil
}

// ProductV2Handler handles version 2 product data with currency support
type ProductV2Handler struct{}

func (h *ProductV2Handler) CanHandle(dataVersion int) bool {
    return dataVersion == 2
}

func (h *ProductV2Handler) Transform(ctx context.Context, entity versioning.VersionedEntity) error {
    product := entity.(*model.Product)
    metadata := product.GetMetadata()
    
    // Ensure currency is set
    if _, exists := metadata["currency"]; !exists {
        metadata["currency"] = "USD"
    }
    
    // Validate currency format
    if currency, ok := metadata["currency"].(string); ok {
        if len(currency) != 3 {
            return fmt.Errorf("invalid currency code: %s", currency)
        }
    }
    
    return nil
}

func (h *ProductV2Handler) Validate(ctx context.Context, entity versioning.VersionedEntity) error {
    product := entity.(*model.Product)
    
    // V2 validation includes currency checks
    metadata := product.GetMetadata()
    currency, exists := metadata["currency"]
    if !exists {
        return fmt.Errorf("currency is required in version 2")
    }
    
    if currencyStr, ok := currency.(string); ok {
        if !isValidCurrency(currencyStr) {
            return fmt.Errorf("invalid currency: %s", currencyStr)
        }
    }
    
    return nil
}

func (h *ProductV2Handler) Migrate(ctx context.Context, from, to int, 
    entity versioning.VersionedEntity) error {
    
    if from == 2 && to == 3 {
        return h.migrateV2ToV3(ctx, entity)
    }
    
    return fmt.Errorf("unsupported migration from v%d to v%d", from, to)
}

func (h *ProductV2Handler) migrateV2ToV3(ctx context.Context, 
    entity versioning.VersionedEntity) error {
    
    product := entity.(*model.Product)
    metadata := product.GetMetadata()
    
    // Add locale support for v3
    metadata["locale"] = "en-US"
    metadata["timezone"] = "UTC"
    metadata["migrated_from_v2"] = true
    
    return nil
}

func isValidCurrency(currency string) bool {
    validCurrencies := map[string]bool{
        "USD": true, "EUR": true, "GBP": true, "JPY": true,
        "CAD": true, "AUD": true, "CHF": true, "CNY": true,
    }
    return validCurrencies[currency]
}
```

### Reference Number Evolution Example

```go
package reference

import (
    "crypto/sha1"
    "fmt"
    "strings"
    "time"
    
    "github.com/google/uuid"
)

// ReferenceGenerator creates reference numbers based on format version
type ReferenceGenerator struct {
    format string
}

func NewReferenceGenerator(format string) *ReferenceGenerator {
    return &ReferenceGenerator{format: format}
}

// Generate creates a reference number based on the configured format
func (rg *ReferenceGenerator) Generate(data map[string]interface{}) (string, error) {
    switch rg.format {
    case "v1_sha_date":
        return rg.generateV1ShaDate(data)
    case "v2_uuid":
        return rg.generateV2UUID(data)
    case "v3_business_logic":
        return rg.generateV3BusinessLogic(data)
    default:
        return "", fmt.Errorf("unknown reference format: %s", rg.format)
    }
}

// V1: SHA-based with date (REF-210101-abc123)
func (rg *ReferenceGenerator) generateV1ShaDate(data map[string]interface{}) (string, error) {
    userID, ok := data["user_id"].(int64)
    if !ok {
        return "", fmt.Errorf("user_id required for v1 format")
    }
    
    now := time.Now()
    dateStr := now.Format("060102") // YYMMDD
    
    hash := sha1.Sum([]byte(fmt.Sprintf("%d-%s", userID, now.Format(time.RFC3339Nano))))
    hashStr := fmt.Sprintf("%x", hash)[:6]
    
    return fmt.Sprintf("REF-%s-%s", dateStr, hashStr), nil
}

// V2: UUID-based (uuid4-generated-string)
func (rg *ReferenceGenerator) generateV2UUID(data map[string]interface{}) (string, error) {
    return uuid.New().String(), nil
}

// V3: Business logic-based (BIZ-REGION-YYYYMMDD-SEQUENCE)
func (rg *ReferenceGenerator) generateV3BusinessLogic(data map[string]interface{}) (string, error) {
    region, ok := data["region"].(string)
    if !ok {
        region = "US"
    }
    
    sequence, ok := data["sequence"].(int64)
    if !ok {
        sequence = 1
    }
    
    now := time.Now()
    dateStr := now.Format("20060102") // YYYYMMDD
    
    return fmt.Sprintf("BIZ-%s-%s-%06d", strings.ToUpper(region), dateStr, sequence), nil
}

// ParseReference extracts information from reference number based on format
func ParseReference(reference, format string) (map[string]interface{}, error) {
    switch format {
    case "v1_sha_date":
        return parseV1Reference(reference)
    case "v2_uuid":
        return parseV2Reference(reference)
    case "v3_business_logic":
        return parseV3Reference(reference)
    default:
        return nil, fmt.Errorf("unknown reference format: %s", format)
    }
}

func parseV1Reference(reference string) (map[string]interface{}, error) {
    parts := strings.Split(reference, "-")
    if len(parts) != 3 || parts[0] != "REF" {
        return nil, fmt.Errorf("invalid v1 reference format")
    }
    
    return map[string]interface{}{
        "prefix": parts[0],
        "date":   parts[1],
        "hash":   parts[2],
        "format": "v1_sha_date",
    }, nil
}

func parseV2Reference(reference string) (map[string]interface{}, error) {
    if _, err := uuid.Parse(reference); err != nil {
        return nil, fmt.Errorf("invalid v2 UUID reference")
    }
    
    return map[string]interface{}{
        "uuid":   reference,
        "format": "v2_uuid",
    }, nil
}

func parseV3Reference(reference string) (map[string]interface{}, error) {
    parts := strings.Split(reference, "-")
    if len(parts) != 4 || parts[0] != "BIZ" {
        return nil, fmt.Errorf("invalid v3 reference format")
    }
    
    return map[string]interface{}{
        "prefix":   parts[0],
        "region":   parts[1],
        "date":     parts[2],
        "sequence": parts[3],
        "format":   "v3_business_logic",
    }, nil
}
```

### Repository with Version Support

```go
package repository

import (
    "context"
    "database/sql"
    "fmt"
    
    "github.com/your-org/app/internal/model"
    "github.com/your-org/app/internal/versioning"
)

// ProductRepository handles versioned product operations
type ProductRepository struct {
    db             *sql.DB
    versionManager *versioning.VersionManager
    currentVersion string
}

func NewProductRepository(db *sql.DB, versionManager *versioning.VersionManager, 
    currentVersion string) *ProductRepository {
    
    return &ProductRepository{
        db:             db,
        versionManager: versionManager,
        currentVersion: currentVersion,
    }
}

// Create creates a new product with current version
func (pr *ProductRepository) Create(ctx context.Context, product *model.Product) error {
    product.SetAppVersion(pr.currentVersion)
    product.SetDataVersion(3) // Current data version
    
    // Process with version manager
    if err := pr.versionManager.ProcessEntity(ctx, product); err != nil {
        return fmt.Errorf("version processing failed: %w", err)
    }
    
    query := `
        INSERT INTO products (name, price, app_version, data_version, metadata)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, created_at, updated_at
    `
    
    metadataBytes, err := json.Marshal(product.GetMetadata())
    if err != nil {
        return err
    }
    
    err = pr.db.QueryRowContext(ctx, query,
        product.Name,
        product.Price,
        product.GetAppVersion(),
        product.GetDataVersion(),
        metadataBytes,
    ).Scan(&product.ID, &product.CreatedAt, &product.UpdatedAt)
    
    return err
}

// FindByID retrieves a product and processes it based on version
func (pr *ProductRepository) FindByID(ctx context.Context, id int64) (*model.Product, error) {
    query := `
        SELECT id, name, price, app_version, data_version, metadata,
               created_at, updated_at
        FROM products
        WHERE id = $1
    `
    
    var product model.Product
    var metadataBytes []byte
    
    err := pr.db.QueryRowContext(ctx, query, id).Scan(
        &product.ID,
        &product.Name,
        &product.Price,
        &product.AppVersion,
        &product.DataVersion,
        &metadataBytes,
        &product.CreatedAt,
        &product.UpdatedAt,
    )
    
    if err != nil {
        return nil, err
    }
    
    // Unmarshal metadata
    if err := json.Unmarshal(metadataBytes, &product.Metadata); err != nil {
        return nil, err
    }
    
    // Process with version manager
    if err := pr.versionManager.ProcessEntity(ctx, &product); err != nil {
        return nil, fmt.Errorf("version processing failed: %w", err)
    }
    
    return &product, nil
}

// MigrateToCurrentVersion migrates a product to the current data version
func (pr *ProductRepository) MigrateToCurrentVersion(ctx context.Context, 
    productID int64) error {
    
    product, err := pr.FindByID(ctx, productID)
    if err != nil {
        return err
    }
    
    currentDataVersion := 3 // Current version
    if product.GetDataVersion() == currentDataVersion {
        return nil // Already current
    }
    
    // Perform migration
    if err := pr.versionManager.MigrateEntity(ctx, product, currentDataVersion); err != nil {
        return err
    }
    
    // Update in database
    return pr.Update(ctx, product)
}

// Update updates a product while preserving version information
func (pr *ProductRepository) Update(ctx context.Context, product *model.Product) error {
    // Process with version manager
    if err := pr.versionManager.ProcessEntity(ctx, product); err != nil {
        return fmt.Errorf("version processing failed: %w", err)
    }
    
    query := `
        UPDATE products 
        SET name = $1, price = $2, app_version = $3, data_version = $4, 
            metadata = $5, updated_at = NOW()
        WHERE id = $6
    `
    
    metadataBytes, err := json.Marshal(product.GetMetadata())
    if err != nil {
        return err
    }
    
    _, err = pr.db.ExecContext(ctx, query,
        product.Name,
        product.Price,
        product.GetAppVersion(),
        product.GetDataVersion(),
        metadataBytes,
        product.ID,
    )
    
    return err
}

// FindByVersionRange retrieves products within a version range
func (pr *ProductRepository) FindByVersionRange(ctx context.Context, 
    minVersion, maxVersion int) ([]*model.Product, error) {
    
    query := `
        SELECT id, name, price, app_version, data_version, metadata,
               created_at, updated_at
        FROM products
        WHERE data_version BETWEEN $1 AND $2
        ORDER BY created_at DESC
    `
    
    rows, err := pr.db.QueryContext(ctx, query, minVersion, maxVersion)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var products []*model.Product
    for rows.Next() {
        var product model.Product
        var metadataBytes []byte
        
        err := rows.Scan(
            &product.ID,
            &product.Name,
            &product.Price,
            &product.AppVersion,
            &product.DataVersion,
            &metadataBytes,
            &product.CreatedAt,
            &product.UpdatedAt,
        )
        
        if err != nil {
            continue
        }
        
        // Unmarshal metadata
        if err := json.Unmarshal(metadataBytes, &product.Metadata); err != nil {
            continue
        }
        
        // Process with version manager
        if err := pr.versionManager.ProcessEntity(ctx, &product); err != nil {
            continue
        }
        
        products = append(products, &product)
    }
    
    return products, nil
}
```

### Background Migration Service

```go
package migration

import (
    "context"
    "fmt"
    "log"
    "time"
    
    "github.com/your-org/app/internal/repository"
    "github.com/your-org/app/internal/versioning"
)

// MigrationService handles background migration of versioned data
type MigrationService struct {
    productRepo    *repository.ProductRepository
    versionManager *versioning.VersionManager
    batchSize      int
    delayBetween   time.Duration
}

func NewMigrationService(productRepo *repository.ProductRepository,
    versionManager *versioning.VersionManager) *MigrationService {
    
    return &MigrationService{
        productRepo:    productRepo,
        versionManager: versionManager,
        batchSize:      100,
        delayBetween:   time.Second,
    }
}

// MigrateOldVersions migrates products from old versions to current version
func (ms *MigrationService) MigrateOldVersions(ctx context.Context, 
    fromVersion, toVersion int) error {
    
    log.Printf("Starting migration from version %d to %d", fromVersion, toVersion)
    
    migrationQuery := `
        SELECT id 
        FROM products 
        WHERE data_version = $1 
        ORDER BY created_at 
        LIMIT $2 OFFSET $3
    `
    
    offset := 0
    migratedCount := 0
    
    for {
        rows, err := ms.productRepo.db.QueryContext(ctx, migrationQuery, 
            fromVersion, ms.batchSize, offset)
        if err != nil {
            return fmt.Errorf("migration query failed: %w", err)
        }
        
        var productIDs []int64
        for rows.Next() {
            var id int64
            if err := rows.Scan(&id); err != nil {
                continue
            }
            productIDs = append(productIDs, id)
        }
        rows.Close()
        
        if len(productIDs) == 0 {
            break // No more products to migrate
        }
        
        // Migrate batch
        for _, id := range productIDs {
            if err := ms.migrateProduct(ctx, id, toVersion); err != nil {
                log.Printf("Failed to migrate product %d: %v", id, err)
                continue
            }
            migratedCount++
        }
        
        log.Printf("Migrated batch: %d products (total: %d)", 
            len(productIDs), migratedCount)
        
        offset += ms.batchSize
        
        // Add delay between batches to reduce load
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-time.After(ms.delayBetween):
            // Continue
        }
    }
    
    log.Printf("Migration completed: %d products migrated", migratedCount)
    return nil
}

func (ms *MigrationService) migrateProduct(ctx context.Context, 
    productID int64, targetVersion int) error {
    
    product, err := ms.productRepo.FindByID(ctx, productID)
    if err != nil {
        return err
    }
    
    if product.GetDataVersion() == targetVersion {
        return nil // Already migrated
    }
    
    // Perform migration
    if err := ms.versionManager.MigrateEntity(ctx, product, targetVersion); err != nil {
        return err
    }
    
    // Update in database
    return ms.productRepo.Update(ctx, product)
}

// GetMigrationProgress returns migration progress statistics
func (ms *MigrationService) GetMigrationProgress(ctx context.Context, 
    fromVersion, toVersion int) (*MigrationProgress, error) {
    
    query := `
        SELECT 
            COUNT(*) FILTER (WHERE data_version = $1) as remaining,
            COUNT(*) FILTER (WHERE data_version = $2) as migrated,
            COUNT(*) as total
        FROM products
        WHERE data_version IN ($1, $2)
    `
    
    var progress MigrationProgress
    err := ms.productRepo.db.QueryRowContext(ctx, query, fromVersion, toVersion).Scan(
        &progress.Remaining,
        &progress.Migrated,
        &progress.Total,
    )
    
    if err != nil {
        return nil, err
    }
    
    if progress.Total > 0 {
        progress.PercentComplete = float64(progress.Migrated) / float64(progress.Total) * 100
    }
    
    return &progress, nil
}

type MigrationProgress struct {
    Remaining       int64   `json:"remaining"`
    Migrated        int64   `json:"migrated"`
    Total           int64   `json:"total"`
    PercentComplete float64 `json:"percent_complete"`
}
```

## Consequences

### Positive

- **Zero-Downtime Migrations**: Gradual data evolution without service interruption
- **Backward Compatibility**: Multiple application versions can coexist
- **Safe Rollbacks**: Easy rollback through version-specific logic
- **Flexible Evolution**: Data format changes without breaking existing functionality
- **A/B Testing**: Version-based feature testing and gradual rollouts
- **Debugging**: Clear audit trail of data evolution

### Negative

- **Complexity**: Additional logic required for version handling
- **Storage Overhead**: Version metadata increases storage requirements
- **Performance Impact**: Version checks add processing overhead
- **Code Maintenance**: Multiple version handlers need maintenance
- **Migration Coordination**: Background migrations require careful orchestration

### Mitigations

- **Automated Testing**: Comprehensive tests for all version combinations
- **Monitoring**: Track version distribution and migration progress
- **Documentation**: Clear version evolution and migration procedures
- **Cleanup Strategy**: Remove obsolete version handlers after full migration
- **Performance Optimization**: Cache version handlers and optimize checks

## Related Patterns

- **[Migration Files](002-migration-files.md)**: Database schema evolution strategies
- **[Database Design Record](009-database-design-record.md)**: Documenting version changes
- **[Optimistic Locking](007-optimistic-locking.md)**: Version-based concurrency control
- **[Independent Schema](022-independent-schema.md)**: Schema versioning for microservices
