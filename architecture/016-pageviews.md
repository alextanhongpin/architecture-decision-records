# Storing Pageviews

## Status

`draft`

## Context

We want an efficient way to store page views that can handle high write volume while providing good read performance for analytics.

The page views data should be persisted in the database with a granularity of at least 1 day.

We could further store compressed data that is more than a month/year old as summaries.

Requirements:
- Handle high write throughput (thousands of views per second)
- Efficient storage and retrieval
- Support for real-time and historical analytics
- Data compression for older data
- Scalable architecture

## Decisions

### Time-Series Database Approach

Store pageviews as time-series data with different granularities:

```go
type PageView struct {
    PageID    string    `json:"page_id"`
    UserID    string    `json:"user_id,omitempty"`
    IP        string    `json:"ip"`
    UserAgent string    `json:"user_agent"`
    Referer   string    `json:"referer,omitempty"`
    Timestamp time.Time `json:"timestamp"`
    SessionID string    `json:"session_id,omitempty"`
}

type PageViewAggregate struct {
    PageID       string    `json:"page_id"`
    Date         time.Time `json:"date"`
    Hour         int       `json:"hour,omitempty"`
    Views        int64     `json:"views"`
    UniqueViews  int64     `json:"unique_views"`
    LastUpdated  time.Time `json:"last_updated"`
}

type PageViewStore struct {
    db           *sql.DB
    redis        redis.Client
    writeBuffer  chan PageView
    bufferSize   int
    flushInterval time.Duration
}

func NewPageViewStore(db *sql.DB, redis redis.Client) *PageViewStore {
    pvs := &PageViewStore{
        db:            db,
        redis:         redis,
        writeBuffer:   make(chan PageView, 10000),
        bufferSize:    1000,
        flushInterval: 5 * time.Second,
    }
    
    go pvs.batchWriter()
    return pvs
}

func (pvs *PageViewStore) RecordPageView(pv PageView) {
    // Real-time increment in Redis
    go pvs.incrementRealTimeCounters(pv)
    
    // Buffer for batch processing
    select {
    case pvs.writeBuffer <- pv:
    default:
        // Buffer full, could implement overflow handling
        log.Printf("PageView buffer full, dropping view for page %s", pv.PageID)
    }
}

func (pvs *PageViewStore) incrementRealTimeCounters(pv PageView) {
    pipe := pvs.redis.Pipeline()
    
    // Daily counter
    dailyKey := fmt.Sprintf("pageviews:daily:%s:%s", 
        pv.PageID, pv.Timestamp.Format("2006-01-02"))
    pipe.Incr(context.Background(), dailyKey)
    pipe.Expire(context.Background(), dailyKey, 48*time.Hour)
    
    // Hourly counter
    hourlyKey := fmt.Sprintf("pageviews:hourly:%s:%s", 
        pv.PageID, pv.Timestamp.Format("2006-01-02-15"))
    pipe.Incr(context.Background(), hourlyKey)
    pipe.Expire(context.Background(), hourlyKey, 25*time.Hour)
    
    // Unique views (using HyperLogLog for memory efficiency)
    uniqueKey := fmt.Sprintf("pageviews:unique:daily:%s:%s", 
        pv.PageID, pv.Timestamp.Format("2006-01-02"))
    if pv.UserID != "" {
        pipe.PFAdd(context.Background(), uniqueKey, pv.UserID)
    } else {
        pipe.PFAdd(context.Background(), uniqueKey, pv.IP)
    }
    pipe.Expire(context.Background(), uniqueKey, 48*time.Hour)
    
    pipe.Exec(context.Background())
}

func (pvs *PageViewStore) batchWriter() {
    var batch []PageView
    ticker := time.NewTicker(pvs.flushInterval)
    defer ticker.Stop()
    
    for {
        select {
        case pv := <-pvs.writeBuffer:
            batch = append(batch, pv)
            if len(batch) >= pvs.bufferSize {
                pvs.flushBatch(batch)
                batch = batch[:0]
            }
            
        case <-ticker.C:
            if len(batch) > 0 {
                pvs.flushBatch(batch)
                batch = batch[:0]
            }
        }
    }
}

func (pvs *PageViewStore) flushBatch(batch []PageView) {
    // Store raw pageviews
    go pvs.storeRawPageViews(batch)
    
    // Update aggregates
    go pvs.updateAggregates(batch)
}

func (pvs *PageViewStore) storeRawPageViews(batch []PageView) {
    if len(batch) == 0 {
        return
    }
    
    tx, err := pvs.db.Begin()
    if err != nil {
        log.Printf("Failed to begin transaction: %v", err)
        return
    }
    defer tx.Rollback()
    
    stmt, err := tx.Prepare(`
        INSERT INTO pageviews (page_id, user_id, ip, user_agent, referer, timestamp, session_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
    `)
    if err != nil {
        log.Printf("Failed to prepare statement: %v", err)
        return
    }
    defer stmt.Close()
    
    for _, pv := range batch {
        _, err = stmt.Exec(pv.PageID, pv.UserID, pv.IP, pv.UserAgent, pv.Referer, pv.Timestamp, pv.SessionID)
        if err != nil {
            log.Printf("Failed to insert pageview: %v", err)
            continue
        }
    }
    
    if err = tx.Commit(); err != nil {
        log.Printf("Failed to commit transaction: %v", err)
    }
}
```

### Aggregation Strategy

Pre-aggregate data at multiple time granularities:

```go
func (pvs *PageViewStore) updateAggregates(batch []PageView) {
    aggregates := make(map[string]*PageViewAggregate)
    
    for _, pv := range batch {
        // Daily aggregates
        dailyKey := fmt.Sprintf("%s:%s", pv.PageID, pv.Timestamp.Format("2006-01-02"))
        if agg, exists := aggregates[dailyKey]; exists {
            agg.Views++
        } else {
            aggregates[dailyKey] = &PageViewAggregate{
                PageID: pv.PageID,
                Date:   pv.Timestamp.Truncate(24 * time.Hour),
                Views:  1,
            }
        }
        
        // Hourly aggregates
        hourlyKey := fmt.Sprintf("%s:%s:%d", pv.PageID, pv.Timestamp.Format("2006-01-02"), pv.Timestamp.Hour())
        if agg, exists := aggregates[hourlyKey]; exists {
            agg.Views++
        } else {
            aggregates[hourlyKey] = &PageViewAggregate{
                PageID: pv.PageID,
                Date:   pv.Timestamp.Truncate(24 * time.Hour),
                Hour:   pv.Timestamp.Hour(),
                Views:  1,
            }
        }
    }
    
    // Update database aggregates
    pvs.persistAggregates(aggregates)
}

func (pvs *PageViewStore) persistAggregates(aggregates map[string]*PageViewAggregate) {
    tx, err := pvs.db.Begin()
    if err != nil {
        log.Printf("Failed to begin transaction: %v", err)
        return
    }
    defer tx.Rollback()
    
    // Daily aggregates
    dailyStmt, err := tx.Prepare(`
        INSERT INTO pageview_daily_aggregates (page_id, date, views, last_updated)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (page_id, date)
        DO UPDATE SET views = pageview_daily_aggregates.views + $3, last_updated = $4
    `)
    if err != nil {
        log.Printf("Failed to prepare daily statement: %v", err)
        return
    }
    defer dailyStmt.Close()
    
    // Hourly aggregates
    hourlyStmt, err := tx.Prepare(`
        INSERT INTO pageview_hourly_aggregates (page_id, date, hour, views, last_updated)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (page_id, date, hour)
        DO UPDATE SET views = pageview_hourly_aggregates.views + $4, last_updated = $5
    `)
    if err != nil {
        log.Printf("Failed to prepare hourly statement: %v", err)
        return
    }
    defer hourlyStmt.Close()
    
    now := time.Now()
    for _, agg := range aggregates {
        if agg.Hour == 0 { // Daily aggregate
            _, err = dailyStmt.Exec(agg.PageID, agg.Date, agg.Views, now)
        } else { // Hourly aggregate
            _, err = hourlyStmt.Exec(agg.PageID, agg.Date, agg.Hour, agg.Views, now)
        }
        
        if err != nil {
            log.Printf("Failed to update aggregate: %v", err)
            continue
        }
    }
    
    if err = tx.Commit(); err != nil {
        log.Printf("Failed to commit aggregates: %v", err)
    }
}
```

### Compression and Archival

Implement data compression for older records:

```go
type ArchivedPageViews struct {
    PageID     string    `json:"page_id"`
    Month      time.Time `json:"month"`
    TotalViews int64     `json:"total_views"`
    UniqueViews int64    `json:"unique_views"`
    DailyBreakdown map[int]int64 `json:"daily_breakdown"` // day of month -> views
}

func (pvs *PageViewStore) ArchiveOldData() {
    // Archive data older than 3 months
    cutoff := time.Now().AddDate(0, -3, 0)
    
    // Compress daily data into monthly summaries
    pvs.compressToMonthly(cutoff)
    
    // Delete raw pageviews older than cutoff
    pvs.deleteOldRawData(cutoff)
}

func (pvs *PageViewStore) compressToMonthly(cutoff time.Time) {
    query := `
        SELECT page_id, DATE_TRUNC('month', date) as month, 
               SUM(views) as total_views,
               EXTRACT(day FROM date) as day,
               SUM(views) as daily_views
        FROM pageview_daily_aggregates 
        WHERE date < $1 
        GROUP BY page_id, month, day
        ORDER BY page_id, month, day
    `
    
    rows, err := pvs.db.Query(query, cutoff)
    if err != nil {
        log.Printf("Failed to query daily aggregates: %v", err)
        return
    }
    defer rows.Close()
    
    archives := make(map[string]*ArchivedPageViews)
    
    for rows.Next() {
        var pageID string
        var month time.Time
        var totalViews int64
        var day int
        var dailyViews int64
        
        err := rows.Scan(&pageID, &month, &totalViews, &day, &dailyViews)
        if err != nil {
            log.Printf("Failed to scan row: %v", err)
            continue
        }
        
        key := fmt.Sprintf("%s:%s", pageID, month.Format("2006-01"))
        if archive, exists := archives[key]; exists {
            archive.TotalViews += dailyViews
            archive.DailyBreakdown[day] = dailyViews
        } else {
            archives[key] = &ArchivedPageViews{
                PageID:     pageID,
                Month:      month,
                TotalViews: dailyViews,
                DailyBreakdown: map[int]int64{day: dailyViews},
            }
        }
    }
    
    // Store compressed data
    pvs.storeArchivedData(archives)
}

func (pvs *PageViewStore) storeArchivedData(archives map[string]*ArchivedPageViews) {
    tx, err := pvs.db.Begin()
    if err != nil {
        log.Printf("Failed to begin transaction: %v", err)
        return
    }
    defer tx.Rollback()
    
    stmt, err := tx.Prepare(`
        INSERT INTO pageview_monthly_archives (page_id, month, total_views, unique_views, daily_breakdown)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (page_id, month)
        DO UPDATE SET total_views = $3, daily_breakdown = $5
    `)
    if err != nil {
        log.Printf("Failed to prepare archive statement: %v", err)
        return
    }
    defer stmt.Close()
    
    for _, archive := range archives {
        breakdown, _ := json.Marshal(archive.DailyBreakdown)
        _, err = stmt.Exec(archive.PageID, archive.Month, archive.TotalViews, archive.UniqueViews, breakdown)
        if err != nil {
            log.Printf("Failed to insert archive: %v", err)
            continue
        }
    }
    
    if err = tx.Commit(); err != nil {
        log.Printf("Failed to commit archives: %v", err)
    }
}
```

### Analytics Queries

Provide efficient queries for common analytics needs:

```go
type PageViewAnalytics struct {
    store *PageViewStore
}

func (pva *PageViewAnalytics) GetPageViewsInRange(pageID string, start, end time.Time) (int64, error) {
    // Try Redis first for recent data
    if time.Since(start) < 48*time.Hour {
        return pva.getRecentViews(pageID, start, end)
    }
    
    // Use aggregated data for older queries
    return pva.getAggregatedViews(pageID, start, end)
}

func (pva *PageViewAnalytics) getRecentViews(pageID string, start, end time.Time) (int64, error) {
    var total int64
    
    current := start
    for current.Before(end) {
        dailyKey := fmt.Sprintf("pageviews:daily:%s:%s", 
            pageID, current.Format("2006-01-02"))
        
        count, err := pva.store.redis.Get(context.Background(), dailyKey).Int64()
        if err != nil && err != redis.Nil {
            return 0, err
        }
        
        total += count
        current = current.Add(24 * time.Hour)
    }
    
    return total, nil
}

func (pva *PageViewAnalytics) getAggregatedViews(pageID string, start, end time.Time) (int64, error) {
    query := `
        SELECT COALESCE(SUM(views), 0) 
        FROM pageview_daily_aggregates 
        WHERE page_id = $1 AND date >= $2 AND date <= $3
    `
    
    var total int64
    err := pva.store.db.QueryRow(query, pageID, start, end).Scan(&total)
    return total, err
}

func (pva *PageViewAnalytics) GetTopPages(limit int, start, end time.Time) ([]PageViewResult, error) {
    query := `
        SELECT page_id, SUM(views) as total_views
        FROM pageview_daily_aggregates 
        WHERE date >= $1 AND date <= $2
        GROUP BY page_id
        ORDER BY total_views DESC
        LIMIT $3
    `
    
    rows, err := pva.store.db.Query(query, start, end, limit)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var results []PageViewResult
    for rows.Next() {
        var result PageViewResult
        err := rows.Scan(&result.PageID, &result.Views)
        if err != nil {
            continue
        }
        results = append(results, result)
    }
    
    return results, nil
}

type PageViewResult struct {
    PageID string `json:"page_id"`
    Views  int64  `json:"views"`
}

func (pva *PageViewAnalytics) GetPageViewTrends(pageID string, days int) ([]DailyViews, error) {
    start := time.Now().AddDate(0, 0, -days)
    
    query := `
        SELECT date, views
        FROM pageview_daily_aggregates 
        WHERE page_id = $1 AND date >= $2
        ORDER BY date
    `
    
    rows, err := pva.store.db.Query(query, pageID, start)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var trends []DailyViews
    for rows.Next() {
        var trend DailyViews
        err := rows.Scan(&trend.Date, &trend.Views)
        if err != nil {
            continue
        }
        trends = append(trends, trend)
    }
    
    return trends, nil
}

type DailyViews struct {
    Date  time.Time `json:"date"`
    Views int64     `json:"views"`
}
```

### Database Schema

```sql
-- Raw pageviews table (partitioned by month)
CREATE TABLE pageviews (
    id BIGSERIAL PRIMARY KEY,
    page_id VARCHAR(255) NOT NULL,
    user_id VARCHAR(255),
    ip INET,
    user_agent TEXT,
    referer TEXT,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    session_id VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
) PARTITION BY RANGE (timestamp);

-- Create monthly partitions
CREATE TABLE pageviews_2025_01 PARTITION OF pageviews
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

-- Daily aggregates
CREATE TABLE pageview_daily_aggregates (
    page_id VARCHAR(255) NOT NULL,
    date DATE NOT NULL,
    views BIGINT NOT NULL DEFAULT 0,
    unique_views BIGINT DEFAULT 0,
    last_updated TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    PRIMARY KEY (page_id, date)
);

-- Hourly aggregates  
CREATE TABLE pageview_hourly_aggregates (
    page_id VARCHAR(255) NOT NULL,
    date DATE NOT NULL,
    hour INTEGER NOT NULL CHECK (hour >= 0 AND hour <= 23),
    views BIGINT NOT NULL DEFAULT 0,
    unique_views BIGINT DEFAULT 0,
    last_updated TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    PRIMARY KEY (page_id, date, hour)
);

-- Monthly archives
CREATE TABLE pageview_monthly_archives (
    page_id VARCHAR(255) NOT NULL,
    month DATE NOT NULL,
    total_views BIGINT NOT NULL,
    unique_views BIGINT DEFAULT 0,
    daily_breakdown JSONB,
    archived_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    PRIMARY KEY (page_id, month)
);

-- Indexes
CREATE INDEX idx_pageviews_page_timestamp ON pageviews (page_id, timestamp);
CREATE INDEX idx_pageviews_timestamp ON pageviews (timestamp);
CREATE INDEX idx_daily_agg_date ON pageview_daily_aggregates (date);
CREATE INDEX idx_hourly_agg_date_hour ON pageview_hourly_aggregates (date, hour);
```

## Consequences

### Benefits
- **High throughput**: Batch processing handles thousands of writes per second
- **Multiple granularities**: Supports real-time and historical analytics
- **Storage efficiency**: Compression reduces storage costs for old data
- **Query performance**: Pre-aggregated data enables fast analytics queries
- **Scalability**: Partitioning and Redis caching support growth

### Challenges
- **Complexity**: Multiple storage layers increase operational complexity
- **Eventual consistency**: Real-time and batch data may temporarily differ
- **Resource usage**: Redis memory usage for real-time counters
- **Data pipeline**: Requires robust error handling and monitoring

### Best Practices
- Use time-based partitioning for large tables
- Implement proper monitoring for batch processing
- Set up automated archival processes
- Use HyperLogLog for memory-efficient unique counting
- Monitor Redis memory usage and set appropriate TTLs
- Implement proper error handling and retry logic
- Consider using ClickHouse or InfluxDB for time-series workloads
- Benchmark different storage engines for your specific workload

### Performance Considerations
- Batch size should balance latency and throughput
- Use connection pooling for database connections
- Consider using async replication for read replicas
- Monitor partition pruning effectiveness
- Use appropriate indexes for common query patterns
