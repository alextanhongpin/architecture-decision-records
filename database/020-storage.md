# Database Storage Optimization

## Status

`accepted`

## Context

Database storage optimization is critical for maintaining performance, reducing costs, and ensuring scalability as applications grow. Poor storage design can lead to increased query times, higher infrastructure costs, and maintenance challenges. The goal is to minimize storage footprint while maintaining data integrity, query performance, and system scalability.

Modern applications generate vast amounts of data, and choosing the right storage patterns, data structures, and optimization techniques can significantly impact both performance and cost. This includes decisions about normalization, denormalization, data types, indexing strategies, and specialized data structures.

## Decision

Implement a comprehensive storage optimization strategy that includes relationship optimization, data type selection, specialized data structures, archiving strategies, and performance monitoring to achieve optimal storage utilization while maintaining system performance and scalability.

## Architecture

### Storage Optimization Strategies

1. **Relationship Optimization**: Optimize table relationships based on usage patterns
2. **Data Type Efficiency**: Choose appropriate data types for storage efficiency
3. **Specialized Data Structures**: Implement space-efficient data structures where applicable
4. **Archiving and Partitioning**: Implement data lifecycle management
5. **Compression Techniques**: Use database-level and application-level compression
6. **Index Optimization**: Strategic indexing for storage and performance balance

### Relationship Patterns

```sql
-- Pattern 1: One-to-One Optimization
-- Bad: Separate table for rarely used data
CREATE TABLE users (
    id UUID PRIMARY KEY,
    email VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_profiles (
    user_id UUID PRIMARY KEY REFERENCES users(id),
    bio TEXT,
    website VARCHAR(255),
    avatar_url VARCHAR(255)
);

-- Good: Combine when usage is high or separate when usage is low
CREATE TABLE users (
    id UUID PRIMARY KEY,
    email VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Frequently accessed profile data
    display_name VARCHAR(100),
    avatar_url VARCHAR(255),
    
    -- Rarely accessed data could be separate
    bio TEXT,
    website VARCHAR(255)
);

-- Pattern 2: One-to-Many with Limits
-- Bad: Unlimited growth
CREATE TABLE notifications (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id),
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Good: With archiving and limits
CREATE TABLE notifications (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id),
    message TEXT NOT NULL,
    is_read BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    archived_at TIMESTAMPTZ,
    
    -- Constraint to prevent excessive growth
    CONSTRAINT max_notifications_per_user CHECK (
        (SELECT COUNT(*) FROM notifications n2 WHERE n2.user_id = user_id AND n2.archived_at IS NULL) <= 100
    )
);

-- Pattern 3: Many-to-Many Optimization
-- Standard approach
CREATE TABLE user_tags (
    user_id UUID NOT NULL REFERENCES users(id),
    tag_id UUID NOT NULL REFERENCES tags(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, tag_id)
);

-- Space-efficient approach for limited relationships
CREATE TABLE users_with_tags (
    id UUID PRIMARY KEY,
    email VARCHAR(255) NOT NULL,
    tag_ids UUID[], -- Array for up to ~20 tags
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### Data Type Optimization

```sql
-- Efficient data types for storage optimization
CREATE TABLE storage_optimized_example (
    id UUID PRIMARY KEY,
    
    -- Integer optimization
    status SMALLINT NOT NULL DEFAULT 0, -- Instead of VARCHAR for enums
    priority INTEGER NOT NULL DEFAULT 0, -- 4 bytes vs 8 bytes for BIGINT
    
    -- String optimization
    country_code CHAR(2), -- Fixed length for known formats
    currency_code CHAR(3),
    email VARCHAR(255) NOT NULL, -- Reasonable limit instead of TEXT
    
    -- Boolean optimization
    flags BIT(8), -- Store multiple boolean flags in single byte
    
    -- Timestamp optimization
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Numeric optimization
    price DECIMAL(10,2), -- Precise decimal places
    percentage DECIMAL(5,2), -- 0.00 to 999.99
    
    -- JSON optimization
    metadata JSONB, -- JSONB is more storage efficient than JSON
    
    -- Arrays for limited collections
    tags TEXT[], -- Better than separate table for small collections
    coordinates POINT, -- Geometric types for spatial data
    
    -- Compressed storage for large text
    content TEXT COMPRESSION lz4 -- PostgreSQL compression
);

-- Specialized columns for specific use cases
CREATE TABLE user_analytics (
    user_id UUID PRIMARY KEY,
    
    -- Bit fields for feature flags
    feature_flags BIT(64), -- 64 boolean flags in 8 bytes
    
    -- Compact date storage
    birth_date DATE, -- 4 bytes vs 8 bytes for TIMESTAMPTZ
    
    -- IP address optimization
    ip_address INET, -- 12-16 bytes vs 39 bytes for VARCHAR
    
    -- UUID vs BIGINT for IDs
    session_id BIGINT, -- 8 bytes vs 16 bytes for UUID when sequence is acceptable
    
    -- Range types for efficiency
    active_hours INT4RANGE, -- Store time ranges compactly
    
    -- HStore for key-value pairs
    preferences HSTORE -- More efficient than JSONB for simple key-value
);
```

### Specialized Data Structures

```sql
-- Bloom Filter Implementation
CREATE TABLE bloom_filters (
    id UUID PRIMARY KEY,
    filter_name VARCHAR(100) NOT NULL UNIQUE,
    bit_array BYTEA NOT NULL,
    hash_functions INTEGER NOT NULL DEFAULT 3,
    expected_elements INTEGER NOT NULL,
    false_positive_rate DECIMAL(10,8) NOT NULL DEFAULT 0.01,
    element_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- HyperLogLog for cardinality estimation
CREATE TABLE cardinality_estimates (
    id UUID PRIMARY KEY,
    entity_type VARCHAR(100) NOT NULL,
    entity_id VARCHAR(255) NOT NULL,
    hll_data BYTEA NOT NULL, -- HyperLogLog data
    estimated_count BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(entity_type, entity_id)
);

-- Sparse data optimization
CREATE TABLE user_attributes (
    user_id UUID NOT NULL REFERENCES users(id),
    attribute_name VARCHAR(100) NOT NULL,
    attribute_value TEXT NOT NULL,
    data_type VARCHAR(20) NOT NULL DEFAULT 'string',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    PRIMARY KEY (user_id, attribute_name)
);

-- Time-series data optimization
CREATE TABLE metrics_compressed (
    id BIGSERIAL PRIMARY KEY,
    metric_name VARCHAR(100) NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    value DOUBLE PRECISION NOT NULL,
    tags JSONB
) PARTITION BY RANGE (timestamp);

-- Create partitions for time-series data
CREATE TABLE metrics_compressed_2024_01 PARTITION OF metrics_compressed
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
```

## Implementation

### Go Storage Optimizer

```go
package storage

import (
    "context"
    "database/sql"
    "encoding/binary"
    "fmt"
    "hash/fnv"
    "math"
    "time"
    
    "github.com/google/uuid"
    "github.com/lib/pq"
)

type StorageOptimizer struct {
    db *sql.DB
}

type BloomFilter struct {
    ID               uuid.UUID `json:"id"`
    FilterName       string    `json:"filter_name"`
    BitArray         []byte    `json:"bit_array"`
    HashFunctions    int       `json:"hash_functions"`
    ExpectedElements int       `json:"expected_elements"`
    FalsePositiveRate float64  `json:"false_positive_rate"`
    ElementCount     int       `json:"element_count"`
    CreatedAt        time.Time `json:"created_at"`
    UpdatedAt        time.Time `json:"updated_at"`
}

func NewStorageOptimizer(db *sql.DB) *StorageOptimizer {
    return &StorageOptimizer{db: db}
}

// Bloom Filter Operations
func (s *StorageOptimizer) CreateBloomFilter(ctx context.Context, name string, 
    expectedElements int, falsePositiveRate float64) (*BloomFilter, error) {
    
    // Calculate optimal parameters
    bitArraySize := s.calculateOptimalBitsPerElement(expectedElements, falsePositiveRate)
    hashFunctions := s.calculateOptimalHashFunctions(bitArraySize, expectedElements)
    
    bf := &BloomFilter{
        ID:                uuid.New(),
        FilterName:        name,
        BitArray:          make([]byte, bitArraySize/8),
        HashFunctions:     hashFunctions,
        ExpectedElements:  expectedElements,
        FalsePositiveRate: falsePositiveRate,
        ElementCount:      0,
        CreatedAt:         time.Now(),
        UpdatedAt:         time.Now(),
    }
    
    query := `
        INSERT INTO bloom_filters 
        (id, filter_name, bit_array, hash_functions, expected_elements, 
         false_positive_rate, element_count, created_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`
    
    _, err := s.db.ExecContext(ctx, query, bf.ID, bf.FilterName, bf.BitArray,
        bf.HashFunctions, bf.ExpectedElements, bf.FalsePositiveRate,
        bf.ElementCount, bf.CreatedAt, bf.UpdatedAt)
    
    if err != nil {
        return nil, fmt.Errorf("create bloom filter: %w", err)
    }
    
    return bf, nil
}

func (s *StorageOptimizer) AddToBloomFilter(ctx context.Context, filterName, element string) error {
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Get current filter
    var bf BloomFilter
    query := `
        SELECT id, bit_array, hash_functions, element_count
        FROM bloom_filters 
        WHERE filter_name = $1 
        FOR UPDATE`
    
    err = tx.QueryRowContext(ctx, query, filterName).Scan(
        &bf.ID, &bf.BitArray, &bf.HashFunctions, &bf.ElementCount)
    
    if err != nil {
        return fmt.Errorf("get bloom filter: %w", err)
    }
    
    // Add element to bit array
    s.addElementToBitArray(bf.BitArray, element, bf.HashFunctions)
    
    // Update filter
    updateQuery := `
        UPDATE bloom_filters 
        SET bit_array = $1, element_count = $2, updated_at = NOW()
        WHERE id = $3`
    
    _, err = tx.ExecContext(ctx, updateQuery, bf.BitArray, bf.ElementCount+1, bf.ID)
    if err != nil {
        return fmt.Errorf("update bloom filter: %w", err)
    }
    
    return tx.Commit()
}

func (s *StorageOptimizer) CheckBloomFilter(ctx context.Context, filterName, element string) (bool, error) {
    var bitArray []byte
    var hashFunctions int
    
    query := `
        SELECT bit_array, hash_functions 
        FROM bloom_filters 
        WHERE filter_name = $1`
    
    err := s.db.QueryRowContext(ctx, query, filterName).Scan(&bitArray, &hashFunctions)
    if err != nil {
        return false, fmt.Errorf("get bloom filter: %w", err)
    }
    
    return s.checkElementInBitArray(bitArray, element, hashFunctions), nil
}

func (s *StorageOptimizer) addElementToBitArray(bitArray []byte, element string, hashFunctions int) {
    for i := 0; i < hashFunctions; i++ {
        hash := s.hashWithSeed(element, uint32(i))
        bitIndex := hash % uint32(len(bitArray)*8)
        byteIndex := bitIndex / 8
        bitOffset := bitIndex % 8
        bitArray[byteIndex] |= 1 << bitOffset
    }
}

func (s *StorageOptimizer) checkElementInBitArray(bitArray []byte, element string, hashFunctions int) bool {
    for i := 0; i < hashFunctions; i++ {
        hash := s.hashWithSeed(element, uint32(i))
        bitIndex := hash % uint32(len(bitArray)*8)
        byteIndex := bitIndex / 8
        bitOffset := bitIndex % 8
        
        if (bitArray[byteIndex] & (1 << bitOffset)) == 0 {
            return false
        }
    }
    return true
}

func (s *StorageOptimizer) hashWithSeed(data string, seed uint32) uint32 {
    h := fnv.New32a()
    binary.Write(h, binary.LittleEndian, seed)
    h.Write([]byte(data))
    return h.Sum32()
}

func (s *StorageOptimizer) calculateOptimalBitsPerElement(expectedElements int, falsePositiveRate float64) int {
    return int(math.Ceil(-float64(expectedElements) * math.Log(falsePositiveRate) / (math.Log(2) * math.Log(2))))
}

func (s *StorageOptimizer) calculateOptimalHashFunctions(bitArraySize, expectedElements int) int {
    return int(math.Ceil(float64(bitArraySize) / float64(expectedElements) * math.Log(2)))
}

// Sparse Data Management
func (s *StorageOptimizer) SetUserAttribute(ctx context.Context, userID uuid.UUID, 
    attributeName, attributeValue, dataType string) error {
    
    query := `
        INSERT INTO user_attributes (user_id, attribute_name, attribute_value, data_type)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (user_id, attribute_name)
        DO UPDATE SET 
            attribute_value = EXCLUDED.attribute_value,
            data_type = EXCLUDED.data_type`
    
    _, err := s.db.ExecContext(ctx, query, userID, attributeName, attributeValue, dataType)
    return err
}

func (s *StorageOptimizer) GetUserAttributes(ctx context.Context, userID uuid.UUID) (map[string]interface{}, error) {
    query := `
        SELECT attribute_name, attribute_value, data_type
        FROM user_attributes 
        WHERE user_id = $1`
    
    rows, err := s.db.QueryContext(ctx, query, userID)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    attributes := make(map[string]interface{})
    for rows.Next() {
        var name, value, dataType string
        if err := rows.Scan(&name, &value, &dataType); err != nil {
            continue
        }
        
        // Convert based on data type
        switch dataType {
        case "integer":
            if intVal, err := strconv.Atoi(value); err == nil {
                attributes[name] = intVal
            }
        case "float":
            if floatVal, err := strconv.ParseFloat(value, 64); err == nil {
                attributes[name] = floatVal
            }
        case "boolean":
            attributes[name] = value == "true"
        default:
            attributes[name] = value
        }
    }
    
    return attributes, nil
}

// Batch Operations for Efficiency
func (s *StorageOptimizer) BatchInsertNotifications(ctx context.Context, 
    notifications []Notification) error {
    
    if len(notifications) == 0 {
        return nil
    }
    
    // Use COPY for bulk inserts
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    stmt, err := tx.PrepareContext(ctx, pq.CopyIn("notifications", 
        "id", "user_id", "message", "created_at"))
    if err != nil {
        return fmt.Errorf("prepare copy: %w", err)
    }
    
    for _, notification := range notifications {
        _, err = stmt.ExecContext(ctx, notification.ID, notification.UserID, 
            notification.Message, notification.CreatedAt)
        if err != nil {
            return fmt.Errorf("copy notification: %w", err)
        }
    }
    
    _, err = stmt.ExecContext(ctx)
    if err != nil {
        return fmt.Errorf("flush copy: %w", err)
    }
    
    if err = stmt.Close(); err != nil {
        return fmt.Errorf("close copy: %w", err)
    }
    
    return tx.Commit()
}

// Data Archiving
func (s *StorageOptimizer) ArchiveOldNotifications(ctx context.Context, olderThan time.Duration) (int64, error) {
    query := `
        UPDATE notifications 
        SET archived_at = NOW()
        WHERE created_at < NOW() - INTERVAL '%d seconds'
        AND archived_at IS NULL`
    
    result, err := s.db.ExecContext(ctx, fmt.Sprintf(query, int(olderThan.Seconds())))
    if err != nil {
        return 0, fmt.Errorf("archive notifications: %w", err)
    }
    
    return result.RowsAffected()
}

func (s *StorageOptimizer) DeleteArchivedNotifications(ctx context.Context, archivedBefore time.Time) (int64, error) {
    query := `
        DELETE FROM notifications 
        WHERE archived_at IS NOT NULL 
        AND archived_at < $1`
    
    result, err := s.db.ExecContext(ctx, query, archivedBefore)
    if err != nil {
        return 0, fmt.Errorf("delete archived notifications: %w", err)
    }
    
    return result.RowsAffected()
}

// Storage Analytics
func (s *StorageOptimizer) GetTableSizes(ctx context.Context) ([]TableSize, error) {
    query := `
        SELECT 
            schemaname,
            tablename,
            pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
            pg_total_relation_size(schemaname||'.'||tablename) as size_bytes
        FROM pg_tables 
        WHERE schemaname = 'public'
        ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC`
    
    rows, err := s.db.QueryContext(ctx, query)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var sizes []TableSize
    for rows.Next() {
        var size TableSize
        if err := rows.Scan(&size.SchemaName, &size.TableName, &size.Size, &size.SizeBytes); err != nil {
            continue
        }
        sizes = append(sizes, size)
    }
    
    return sizes, nil
}

type TableSize struct {
    SchemaName string `json:"schema_name"`
    TableName  string `json:"table_name"`
    Size       string `json:"size"`
    SizeBytes  int64  `json:"size_bytes"`
}

type Notification struct {
    ID        uuid.UUID `json:"id"`
    UserID    uuid.UUID `json:"user_id"`
    Message   string    `json:"message"`
    CreatedAt time.Time `json:"created_at"`
}
```

### Compression Utilities

```go
package compression

import (
    "bytes"
    "compress/gzip"
    "compress/zlib"
    "encoding/json"
    "fmt"
    "io"
)

type CompressionService struct{}

func NewCompressionService() *CompressionService {
    return &CompressionService{}
}

// JSON compression for large JSON fields
func (c *CompressionService) CompressJSON(data interface{}) ([]byte, error) {
    jsonData, err := json.Marshal(data)
    if err != nil {
        return nil, fmt.Errorf("marshal json: %w", err)
    }
    
    var buf bytes.Buffer
    writer := gzip.NewWriter(&buf)
    
    if _, err := writer.Write(jsonData); err != nil {
        return nil, fmt.Errorf("compress data: %w", err)
    }
    
    if err := writer.Close(); err != nil {
        return nil, fmt.Errorf("close compressor: %w", err)
    }
    
    return buf.Bytes(), nil
}

func (c *CompressionService) DecompressJSON(compressedData []byte, target interface{}) error {
    reader, err := gzip.NewReader(bytes.NewReader(compressedData))
    if err != nil {
        return fmt.Errorf("create reader: %w", err)
    }
    defer reader.Close()
    
    decompressed, err := io.ReadAll(reader)
    if err != nil {
        return fmt.Errorf("read decompressed: %w", err)
    }
    
    return json.Unmarshal(decompressed, target)
}

// Text compression for large text fields
func (c *CompressionService) CompressText(text string) ([]byte, error) {
    var buf bytes.Buffer
    writer := zlib.NewWriter(&buf)
    
    if _, err := writer.Write([]byte(text)); err != nil {
        return nil, fmt.Errorf("compress text: %w", err)
    }
    
    if err := writer.Close(); err != nil {
        return nil, fmt.Errorf("close compressor: %w", err)
    }
    
    return buf.Bytes(), nil
}

func (c *CompressionService) DecompressText(compressedData []byte) (string, error) {
    reader, err := zlib.NewReader(bytes.NewReader(compressedData))
    if err != nil {
        return "", fmt.Errorf("create reader: %w", err)
    }
    defer reader.Close()
    
    decompressed, err := io.ReadAll(reader)
    if err != nil {
        return "", fmt.Errorf("read decompressed: %w", err)
    }
    
    return string(decompressed), nil
}

// Calculate compression ratio
func (c *CompressionService) CalculateCompressionRatio(original, compressed []byte) float64 {
    if len(original) == 0 {
        return 0
    }
    return float64(len(compressed)) / float64(len(original))
}
```

### Storage Monitoring

```go
package monitoring

import (
    "context"
    "database/sql"
    "log"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
)

var (
    tableSize = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "database_table_size_bytes",
            Help: "Size of database tables in bytes",
        },
        []string{"schema", "table"},
    )
    
    bloomFilterUsage = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "bloom_filter_usage_ratio",
            Help: "Bloom filter usage ratio (elements/expected)",
        },
        []string{"filter_name"},
    )
    
    compressionRatio = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name: "data_compression_ratio",
            Help: "Data compression ratios",
        },
        []string{"data_type"},
    )
)

func init() {
    prometheus.MustRegister(tableSize, bloomFilterUsage, compressionRatio)
}

type StorageMonitor struct {
    db *sql.DB
}

func NewStorageMonitor(db *sql.DB) *StorageMonitor {
    return &StorageMonitor{db: db}
}

func (m *StorageMonitor) StartMonitoring(ctx context.Context) {
    ticker := time.NewTicker(5 * time.Minute)
    defer ticker.Stop()
    
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            m.updateTableSizes(ctx)
            m.updateBloomFilterMetrics(ctx)
        }
    }
}

func (m *StorageMonitor) updateTableSizes(ctx context.Context) {
    query := `
        SELECT 
            schemaname,
            tablename,
            pg_total_relation_size(schemaname||'.'||tablename) as size_bytes
        FROM pg_tables 
        WHERE schemaname = 'public'`
    
    rows, err := m.db.QueryContext(ctx, query)
    if err != nil {
        log.Printf("Error getting table sizes: %v", err)
        return
    }
    defer rows.Close()
    
    for rows.Next() {
        var schema, table string
        var sizeBytes int64
        
        if err := rows.Scan(&schema, &table, &sizeBytes); err != nil {
            continue
        }
        
        tableSize.WithLabelValues(schema, table).Set(float64(sizeBytes))
    }
}

func (m *StorageMonitor) updateBloomFilterMetrics(ctx context.Context) {
    query := `
        SELECT filter_name, element_count, expected_elements
        FROM bloom_filters`
    
    rows, err := m.db.QueryContext(ctx, query)
    if err != nil {
        log.Printf("Error getting bloom filter metrics: %v", err)
        return
    }
    defer rows.Close()
    
    for rows.Next() {
        var filterName string
        var elementCount, expectedElements int
        
        if err := rows.Scan(&filterName, &elementCount, &expectedElements); err != nil {
            continue
        }
        
        usage := float64(elementCount) / float64(expectedElements)
        bloomFilterUsage.WithLabelValues(filterName).Set(usage)
    }
}

func (m *StorageMonitor) RecordCompressionRatio(dataType string, ratio float64) {
    compressionRatio.WithLabelValues(dataType).Observe(ratio)
}
```

## Usage Examples

### Setting Up Bloom Filters

```go
func setupUserEngagementTracking(db *sql.DB) error {
    optimizer := storage.NewStorageOptimizer(db)
    
    // Create bloom filter for tracking user engagement
    _, err := optimizer.CreateBloomFilter(context.Background(), 
        "user_engagement", 1000000, 0.01)
    if err != nil {
        return fmt.Errorf("create bloom filter: %w", err)
    }
    
    return nil
}

func trackUserEngagement(optimizer *storage.StorageOptimizer, userID string, action string) error {
    key := fmt.Sprintf("%s:%s", userID, action)
    return optimizer.AddToBloomFilter(context.Background(), "user_engagement", key)
}

func checkUserEngagement(optimizer *storage.StorageOptimizer, userID string, action string) (bool, error) {
    key := fmt.Sprintf("%s:%s", userID, action)
    return optimizer.CheckBloomFilter(context.Background(), "user_engagement", key)
}
```

### Efficient Data Archiving

```go
func setupDataArchiving(optimizer *storage.StorageOptimizer) {
    // Archive old notifications daily
    go func() {
        ticker := time.NewTicker(24 * time.Hour)
        defer ticker.Stop()
        
        for range ticker.C {
            // Archive notifications older than 30 days
            archived, err := optimizer.ArchiveOldNotifications(
                context.Background(), 30*24*time.Hour)
            if err != nil {
                log.Printf("Error archiving notifications: %v", err)
                continue
            }
            
            log.Printf("Archived %d notifications", archived)
            
            // Delete archived notifications older than 1 year
            deleted, err := optimizer.DeleteArchivedNotifications(
                context.Background(), time.Now().AddDate(-1, 0, 0))
            if err != nil {
                log.Printf("Error deleting archived notifications: %v", err)
                continue
            }
            
            log.Printf("Deleted %d archived notifications", deleted)
        }
    }()
}
```

### Storage Analysis

```go
func analyzeStorageUsage(optimizer *storage.StorageOptimizer) {
    sizes, err := optimizer.GetTableSizes(context.Background())
    if err != nil {
        log.Printf("Error getting table sizes: %v", err)
        return
    }
    
    log.Println("Table sizes:")
    for _, size := range sizes {
        log.Printf("  %s.%s: %s (%d bytes)", 
            size.SchemaName, size.TableName, size.Size, size.SizeBytes)
        
        // Alert on large tables
        if size.SizeBytes > 1024*1024*1024 { // 1GB
            log.Printf("  WARNING: Large table detected: %s.%s", 
                size.SchemaName, size.TableName)
        }
    }
}
```

## Best Practices

### Relationship Optimization

1. **One-to-One**: Combine tables unless data is rarely accessed
2. **One-to-Many**: Implement limits and archiving strategies
3. **Many-to-Many**: Use arrays for small, fixed-size collections
4. **Sparse Data**: Use EAV pattern or JSONB for flexible attributes

### Data Type Selection

1. **Integers**: Use smallest sufficient type (SMALLINT, INTEGER, BIGINT)
2. **Strings**: Use VARCHAR with reasonable limits instead of TEXT
3. **Timestamps**: Use appropriate precision (DATE vs TIMESTAMPTZ)
4. **Booleans**: Consider bit fields for multiple flags
5. **Arrays**: Use for small, bounded collections

### Specialized Structures

1. **Bloom Filters**: Use for set membership testing
2. **HyperLogLog**: Use for cardinality estimation
3. **Bit Fields**: Use for multiple boolean flags
4. **Ranges**: Use for interval data
5. **Geometric Types**: Use for spatial data

### Performance Considerations

1. **Indexing**: Balance between query performance and storage
2. **Partitioning**: Use for large tables with time-based access
3. **Compression**: Enable for large text/JSON fields
4. **Batch Operations**: Use COPY for bulk inserts
5. **Connection Pooling**: Optimize for concurrent access

## Consequences

### Positive

- **Reduced Storage Costs**: Optimized storage reduces infrastructure costs
- **Improved Performance**: Smaller data footprint improves query performance
- **Better Scalability**: Efficient storage scales better with data growth
- **Faster Backups**: Smaller databases backup and restore faster
- **Reduced I/O**: Less disk I/O improves overall system performance

### Negative

- **Increased Complexity**: More complex data structures and patterns
- **Development Overhead**: Additional effort in design and implementation
- **Maintenance Burden**: Specialized structures require more maintenance
- **Query Complexity**: Some optimizations make queries more complex
- **Migration Challenges**: Changing storage patterns can be difficult

## Related Patterns

- **Data Partitioning**: For managing large datasets
- **Data Archiving**: For lifecycle management
- **Compression**: For reducing storage footprint
- **Indexing Strategy**: For balancing performance and storage
- **CQRS**: For separating read/write storage optimization
- **Event Sourcing**: For audit trails without storage overhead
