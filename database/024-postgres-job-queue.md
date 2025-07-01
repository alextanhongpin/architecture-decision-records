# PostgreSQL Job Queue

## Overview

A PostgreSQL-based job queue provides reliable, persistent job processing with ACID guarantees. This approach is particularly useful for applications that already use PostgreSQL and want to avoid additional infrastructure complexity while maintaining strong consistency guarantees.

## Core Features

### Essential Requirements
- **Unique Jobs**: Prevent duplicate job execution using external identifiers
- **Transactional Enqueueing**: Add jobs atomically within database transactions
- **Multiple Queues**: Isolate different job types and processing priorities
- **Job Routing**: Route jobs to appropriate handlers based on job type
- **Execution Logs**: Track job execution history and debugging information
- **Retry Logic**: Configurable retry attempts with exponential backoff
- **Job Reset**: Re-enqueue failed jobs for manual retry
- **Delayed Execution**: Schedule jobs for future execution
- **Job History**: Persist completed jobs for auditing and monitoring

### Design Decisions
- **No Priority Queues**: Avoid priority-based processing to prevent starvation; use separate queues instead
- **History Management**: Archive completed jobs periodically to maintain performance
- **Partitioning Strategy**: Partition by date rather than status to avoid conflicts

## Database Schema

```sql
-- Main jobs table
CREATE TABLE jobs (
    id BIGSERIAL PRIMARY KEY,
    external_id VARCHAR(255) UNIQUE, -- For job uniqueness
    queue_name VARCHAR(100) NOT NULL DEFAULT 'default',
    job_type VARCHAR(100) NOT NULL,
    payload JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    priority INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,
    current_attempt INTEGER NOT NULL DEFAULT 0,
    run_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    last_error TEXT,
    result JSONB,
    
    CONSTRAINT valid_status CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'scheduled')),
    CONSTRAINT valid_attempts CHECK (current_attempt <= max_attempts)
);

-- Indexes for efficient querying
CREATE INDEX idx_jobs_queue_processing ON jobs (queue_name, status, run_at, id) 
    WHERE status IN ('pending', 'scheduled');
CREATE INDEX idx_jobs_external_id ON jobs (external_id) WHERE external_id IS NOT NULL;
CREATE INDEX idx_jobs_cleanup ON jobs (status, completed_at) WHERE status IN ('completed', 'failed');

-- Job execution logs
CREATE TABLE job_logs (
    id BIGSERIAL PRIMARY KEY,
    job_id BIGINT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    level VARCHAR(10) NOT NULL DEFAULT 'info',
    message TEXT NOT NULL,
    context JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_job_logs_job_id ON job_logs (job_id, created_at);

-- Job history (for archival)
CREATE TABLE job_history (
    LIKE jobs INCLUDING ALL
);
```


## Job Management

### Job Structure

```go
type Job struct {
    ID             int64           `json:"id" db:"id"`
    ExternalID     *string         `json:"external_id,omitempty" db:"external_id"`
    QueueName      string          `json:"queue_name" db:"queue_name"`
    JobType        string          `json:"job_type" db:"job_type"`
    Payload        json.RawMessage `json:"payload" db:"payload"`
    Status         JobStatus       `json:"status" db:"status"`
    Priority       int             `json:"priority" db:"priority"`
    MaxAttempts    int             `json:"max_attempts" db:"max_attempts"`
    CurrentAttempt int             `json:"current_attempt" db:"current_attempt"`
    RunAt          time.Time       `json:"run_at" db:"run_at"`
    CreatedAt      time.Time       `json:"created_at" db:"created_at"`
    StartedAt      *time.Time      `json:"started_at,omitempty" db:"started_at"`
    CompletedAt    *time.Time      `json:"completed_at,omitempty" db:"completed_at"`
    LastError      *string         `json:"last_error,omitempty" db:"last_error"`
    Result         json.RawMessage `json:"result,omitempty" db:"result"`
}

type JobStatus string

const (
    JobStatusPending    JobStatus = "pending"
    JobStatusProcessing JobStatus = "processing"
    JobStatusCompleted  JobStatus = "completed"
    JobStatusFailed     JobStatus = "failed"
    JobStatusScheduled  JobStatus = "scheduled"
)

type JobOptions struct {
    ExternalID  *string
    QueueName   string
    MaxAttempts int
    Priority    int
    RunAt       *time.Time
}
```

### Job Enqueuing

```go
type JobQueue struct {
    db     *sql.DB
    logger *slog.Logger
}

func NewJobQueue(db *sql.DB, logger *slog.Logger) *JobQueue {
    return &JobQueue{db: db, logger: logger}
}

// Enqueue adds a job to the queue
func (jq *JobQueue) Enqueue(ctx context.Context, jobType string, payload interface{}, opts *JobOptions) (*Job, error) {
    payloadBytes, err := json.Marshal(payload)
    if err != nil {
        return nil, fmt.Errorf("marshal payload: %w", err)
    }
    
    if opts == nil {
        opts = &JobOptions{}
    }
    
    // Set defaults
    if opts.QueueName == "" {
        opts.QueueName = "default"
    }
    if opts.MaxAttempts == 0 {
        opts.MaxAttempts = 3
    }
    if opts.RunAt == nil {
        now := time.Now()
        opts.RunAt = &now
    }
    
    job := &Job{
        ExternalID:  opts.ExternalID,
        QueueName:   opts.QueueName,
        JobType:     jobType,
        Payload:     payloadBytes,
        Status:      JobStatusPending,
        Priority:    opts.Priority,
        MaxAttempts: opts.MaxAttempts,
        RunAt:       *opts.RunAt,
    }
    
    // Determine initial status
    if opts.RunAt.After(time.Now()) {
        job.Status = JobStatusScheduled
    }
    
    query := `
        INSERT INTO jobs (external_id, queue_name, job_type, payload, status, priority, max_attempts, run_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        RETURNING id, created_at
    `
    
    err = jq.db.QueryRowContext(ctx, query,
        job.ExternalID, job.QueueName, job.JobType, job.Payload,
        job.Status, job.Priority, job.MaxAttempts, job.RunAt,
    ).Scan(&job.ID, &job.CreatedAt)
    
    if err != nil {
        if isUniqueViolation(err) && job.ExternalID != nil {
            return nil, fmt.Errorf("job with external_id %s already exists", *job.ExternalID)
        }
        return nil, fmt.Errorf("insert job: %w", err)
    }
    
    jq.logger.Info("job enqueued", 
                   "job_id", job.ID, "type", job.JobType, "queue", job.QueueName)
    
    return job, nil
}

// EnqueueTx adds a job within an existing transaction
func (jq *JobQueue) EnqueueTx(ctx context.Context, tx *sql.Tx, jobType string, payload interface{}, opts *JobOptions) (*Job, error) {
    // Similar implementation but uses tx instead of jq.db
    // This allows atomic job creation with other database operations
    payloadBytes, err := json.Marshal(payload)
    if err != nil {
        return nil, fmt.Errorf("marshal payload: %w", err)
    }
    
    if opts == nil {
        opts = &JobOptions{}
    }
    
    if opts.QueueName == "" {
        opts.QueueName = "default"
    }
    if opts.MaxAttempts == 0 {
        opts.MaxAttempts = 3
    }
    if opts.RunAt == nil {
        now := time.Now()
        opts.RunAt = &now
    }
    
    job := &Job{
        ExternalID:  opts.ExternalID,
        QueueName:   opts.QueueName,
        JobType:     jobType,
        Payload:     payloadBytes,
        Status:      JobStatusPending,
        Priority:    opts.Priority,
        MaxAttempts: opts.MaxAttempts,
        RunAt:       *opts.RunAt,
    }
    
    if opts.RunAt.After(time.Now()) {
        job.Status = JobStatusScheduled
    }
    
    query := `
        INSERT INTO jobs (external_id, queue_name, job_type, payload, status, priority, max_attempts, run_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        RETURNING id, created_at
    `
    
    err = tx.QueryRowContext(ctx, query,
        job.ExternalID, job.QueueName, job.JobType, job.Payload,
        job.Status, job.Priority, job.MaxAttempts, job.RunAt,
    ).Scan(&job.ID, &job.CreatedAt)
    
    if err != nil {
        return nil, fmt.Errorf("insert job in transaction: %w", err)
    }
    
    return job, nil
}

func isUniqueViolation(err error) bool {
    // PostgreSQL unique constraint violation code
    return strings.Contains(err.Error(), "duplicate key value") ||
           strings.Contains(err.Error(), "unique constraint")
}
```

## Job Processing

### Job Handler Interface

```go
type JobHandler interface {
    Handle(ctx context.Context, job *Job) error
}

type JobHandlerFunc func(ctx context.Context, job *Job) error

func (f JobHandlerFunc) Handle(ctx context.Context, job *Job) error {
    return f(ctx, job)
}

// Job router for different job types
type JobRouter struct {
    handlers map[string]JobHandler
    logger   *slog.Logger
}

func NewJobRouter(logger *slog.Logger) *JobRouter {
    return &JobRouter{
        handlers: make(map[string]JobHandler),
        logger:   logger,
    }
}

func (jr *JobRouter) Register(jobType string, handler JobHandler) {
    jr.handlers[jobType] = handler
}

func (jr *JobRouter) Handle(ctx context.Context, job *Job) error {
    handler, exists := jr.handlers[job.JobType]
    if !exists {
        return fmt.Errorf("no handler registered for job type: %s", job.JobType)
    }
    
    return handler.Handle(ctx, job)
}
```

### Job Processor

```go
type JobProcessor struct {
    db            *sql.DB
    router        *JobRouter
    queueName     string
    maxWorkers    int
    pollInterval  time.Duration
    logger        *slog.Logger
    metrics       *JobMetrics
    shutdown      chan struct{}
    activeWorkers atomic.Int32
}

type JobProcessorOptions struct {
    QueueName    string
    MaxWorkers   int
    PollInterval time.Duration
    Logger       *slog.Logger
}

func NewJobProcessor(db *sql.DB, router *JobRouter, opts JobProcessorOptions) *JobProcessor {
    if opts.QueueName == "" {
        opts.QueueName = "default"
    }
    if opts.MaxWorkers == 0 {
        opts.MaxWorkers = 5
    }
    if opts.PollInterval == 0 {
        opts.PollInterval = 1 * time.Second
    }
    if opts.Logger == nil {
        opts.Logger = slog.Default()
    }
    
    return &JobProcessor{
        db:           db,
        router:       router,
        queueName:    opts.QueueName,
        maxWorkers:   opts.MaxWorkers,
        pollInterval: opts.PollInterval,
        logger:       opts.Logger,
        metrics:      NewJobMetrics(),
        shutdown:     make(chan struct{}),
    }
}

func (jp *JobProcessor) Start(ctx context.Context) error {
    var wg sync.WaitGroup
    
    // Start workers
    for i := 0; i < jp.maxWorkers; i++ {
        wg.Add(1)
        go func(workerID int) {
            defer wg.Done()
            jp.worker(ctx, workerID)
        }(i)
    }
    
    // Start scheduled job promoter
    wg.Add(1)
    go func() {
        defer wg.Done()
        jp.promoteScheduledJobs(ctx)
    }()
    
    // Start metrics updater
    go jp.updateMetrics(ctx)
    
    // Wait for shutdown
    <-ctx.Done()
    close(jp.shutdown)
    wg.Wait()
    
    return nil
}

func (jp *JobProcessor) worker(ctx context.Context, workerID int) {
    jp.activeWorkers.Add(1)
    defer jp.activeWorkers.Add(-1)
    
    ticker := time.NewTicker(jp.pollInterval)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            if err := jp.processNext(ctx, workerID); err != nil {
                if !errors.Is(err, sql.ErrNoRows) {
                    jp.logger.Error("worker processing failed", 
                                   "worker_id", workerID, "error", err)
                }
            }
            
        case <-jp.shutdown:
            return
        case <-ctx.Done():
            return
        }
    }
}

func (jp *JobProcessor) processNext(ctx context.Context, workerID int) error {
    tx, err := jp.db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Select and lock next available job
    job, err := jp.selectNextJob(ctx, tx)
    if err != nil {
        return err
    }
    
    // Mark job as processing
    now := time.Now()
    job.Status = JobStatusProcessing
    job.StartedAt = &now
    job.CurrentAttempt++
    
    err = jp.updateJobStatus(ctx, tx, job)
    if err != nil {
        return fmt.Errorf("update job status: %w", err)
    }
    
    // Commit the status update
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("commit job lock: %w", err)
    }
    
    // Process the job (outside transaction to avoid long locks)
    start := time.Now()
    processingErr := jp.router.Handle(ctx, job)
    duration := time.Since(start)
    
    // Update job with result
    return jp.completeJob(ctx, job, processingErr, duration)
}

func (jp *JobProcessor) selectNextJob(ctx context.Context, tx *sql.Tx) (*Job, error) {
    query := `
        SELECT id, external_id, queue_name, job_type, payload, status, 
               priority, max_attempts, current_attempt, run_at, created_at,
               started_at, completed_at, last_error, result
        FROM jobs
        WHERE queue_name = $1 
        AND status = 'pending'
        AND run_at <= NOW()
        ORDER BY priority DESC, id ASC
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    `
    
    var job Job
    var externalID, lastError sql.NullString
    var startedAt, completedAt sql.NullTime
    var result sql.NullString
    
    err := tx.QueryRowContext(ctx, query, jp.queueName).Scan(
        &job.ID, &externalID, &job.QueueName, &job.JobType, &job.Payload,
        &job.Status, &job.Priority, &job.MaxAttempts, &job.CurrentAttempt,
        &job.RunAt, &job.CreatedAt, &startedAt, &completedAt, &lastError, &result,
    )
    
    if err != nil {
        return nil, err
    }
    
    // Handle nullable fields
    if externalID.Valid {
        job.ExternalID = &externalID.String
    }
    if startedAt.Valid {
        job.StartedAt = &startedAt.Time
    }
    if completedAt.Valid {
        job.CompletedAt = &completedAt.Time
    }
    if lastError.Valid {
        job.LastError = &lastError.String
    }
    if result.Valid {
        job.Result = json.RawMessage(result.String)
    }
    
    return &job, nil
}

func (jp *JobProcessor) updateJobStatus(ctx context.Context, tx *sql.Tx, job *Job) error {
    query := `
        UPDATE jobs 
        SET status = $1, current_attempt = $2, started_at = $3
        WHERE id = $4
    `
    
    _, err := tx.ExecContext(ctx, query, job.Status, job.CurrentAttempt, job.StartedAt, job.ID)
    return err
}

func (jp *JobProcessor) completeJob(ctx context.Context, job *Job, processingErr error, duration time.Duration) error {
    tx, err := jp.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    now := time.Now()
    job.CompletedAt = &now
    
    if processingErr != nil {
        jp.metrics.JobsFailedTotal.Inc()
        jp.logJobEvent(ctx, tx, job.ID, "error", processingErr.Error(), nil)
        
        errorMsg := processingErr.Error()
        job.LastError = &errorMsg
        
        if job.CurrentAttempt >= job.MaxAttempts {
            // Job failed permanently
            job.Status = JobStatusFailed
            jp.logger.Error("job failed permanently", 
                           "job_id", job.ID, "attempts", job.CurrentAttempt, "error", processingErr)
        } else {
            // Schedule retry with exponential backoff
            job.Status = JobStatusPending
            backoffDelay := time.Duration(job.CurrentAttempt*job.CurrentAttempt) * time.Second
            job.RunAt = now.Add(backoffDelay)
            
            jp.metrics.JobsRetriedTotal.Inc()
            jp.logger.Warn("job retry scheduled", 
                          "job_id", job.ID, "attempt", job.CurrentAttempt, "retry_at", job.RunAt)
        }
    } else {
        // Job completed successfully
        job.Status = JobStatusCompleted
        jp.metrics.JobsCompletedTotal.Inc()
        jp.metrics.JobProcessingDuration.Observe(duration.Seconds())
        
        jp.logger.Info("job completed", 
                      "job_id", job.ID, "duration", duration, "type", job.JobType)
        
        jp.logJobEvent(ctx, tx, job.ID, "info", "job completed successfully", map[string]interface{}{
            "duration_ms": duration.Milliseconds(),
        })
    }
    
    // Update job record
    query := `
        UPDATE jobs 
        SET status = $1, completed_at = $2, last_error = $3, run_at = $4
        WHERE id = $5
    `
    
    _, err = tx.ExecContext(ctx, query, job.Status, job.CompletedAt, job.LastError, job.RunAt, job.ID)
    if err != nil {
        return err
    }
    
    return tx.Commit()
}

func (jp *JobProcessor) logJobEvent(ctx context.Context, tx *sql.Tx, jobID int64, level, message string, context map[string]interface{}) {
    var contextJSON []byte
    if context != nil {
        contextJSON, _ = json.Marshal(context)
    }
    
    _, err := tx.ExecContext(ctx, `
        INSERT INTO job_logs (job_id, level, message, context)
        VALUES ($1, $2, $3, $4)
    `, jobID, level, message, contextJSON)
    
    if err != nil {
        jp.logger.Error("failed to log job event", "error", err)
    }
}
```

## Scheduled Job Management

### Promoting Scheduled Jobs

```go
func (jp *JobProcessor) promoteScheduledJobs(ctx context.Context) {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            count, err := jp.promoteReadyJobs(ctx)
            if err != nil {
                jp.logger.Error("failed to promote scheduled jobs", "error", err)
            } else if count > 0 {
                jp.logger.Info("promoted scheduled jobs", "count", count)
            }
            
        case <-ctx.Done():
            return
        }
    }
}

func (jp *JobProcessor) promoteReadyJobs(ctx context.Context) (int, error) {
    query := `
        UPDATE jobs 
        SET status = 'pending'
        WHERE status = 'scheduled' 
        AND run_at <= NOW()
        AND queue_name = $1
    `
    
    result, err := jp.db.ExecContext(ctx, query, jp.queueName)
    if err != nil {
        return 0, err
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return 0, err
    }
    
    return int(rowsAffected), nil
}
```

## Job Management Operations

### Retry Failed Jobs

```go
func (jq *JobQueue) RetryJob(ctx context.Context, jobID int64) error {
    query := `
        UPDATE jobs 
        SET status = 'pending', 
            current_attempt = 0,
            last_error = NULL,
            run_at = NOW()
        WHERE id = $1 AND status = 'failed'
    `
    
    result, err := jq.db.ExecContext(ctx, query, jobID)
    if err != nil {
        return fmt.Errorf("retry job: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return err
    }
    
    if rowsAffected == 0 {
        return fmt.Errorf("job not found or not in failed status")
    }
    
    jq.logger.Info("job retried", "job_id", jobID)
    return nil
}

func (jq *JobQueue) CancelJob(ctx context.Context, jobID int64) error {
    query := `
        UPDATE jobs 
        SET status = 'failed',
            last_error = 'cancelled by user',
            completed_at = NOW()
        WHERE id = $1 AND status IN ('pending', 'scheduled')
    `
    
    result, err := jq.db.ExecContext(ctx, query, jobID)
    if err != nil {
        return fmt.Errorf("cancel job: %w", err)
    }
    
    rowsAffected, err := result.RowsAffected()
    if err != nil {
        return err
    }
    
    if rowsAffected == 0 {
        return fmt.Errorf("job not found or not cancellable")
    }
    
    jq.logger.Info("job cancelled", "job_id", jobID)
    return nil
}
```

### Job Queries

```go
func (jq *JobQueue) GetJob(ctx context.Context, jobID int64) (*Job, error) {
    query := `
        SELECT id, external_id, queue_name, job_type, payload, status, 
               priority, max_attempts, current_attempt, run_at, created_at,
               started_at, completed_at, last_error, result
        FROM jobs
        WHERE id = $1
    `
    
    var job Job
    var externalID, lastError sql.NullString
    var startedAt, completedAt sql.NullTime
    var result sql.NullString
    
    err := jq.db.QueryRowContext(ctx, query, jobID).Scan(
        &job.ID, &externalID, &job.QueueName, &job.JobType, &job.Payload,
        &job.Status, &job.Priority, &job.MaxAttempts, &job.CurrentAttempt,
        &job.RunAt, &job.CreatedAt, &startedAt, &completedAt, &lastError, &result,
    )
    
    if err != nil {
        return nil, err
    }
    
    // Handle nullable fields
    if externalID.Valid {
        job.ExternalID = &externalID.String
    }
    if startedAt.Valid {
        job.StartedAt = &startedAt.Time
    }
    if completedAt.Valid {
        job.CompletedAt = &completedAt.Time
    }
    if lastError.Valid {
        job.LastError = &lastError.String
    }
    if result.Valid {
        job.Result = json.RawMessage(result.String)
    }
    
    return &job, nil
}

func (jq *JobQueue) ListJobs(ctx context.Context, opts ListJobsOptions) ([]Job, error) {
    query := `
        SELECT id, external_id, queue_name, job_type, payload, status, 
               priority, max_attempts, current_attempt, run_at, created_at,
               started_at, completed_at, last_error, result
        FROM jobs
        WHERE ($1 = '' OR queue_name = $1)
        AND ($2 = '' OR status = $2)
        AND ($3 = '' OR job_type = $3)
        ORDER BY created_at DESC
        LIMIT $4 OFFSET $5
    `
    
    rows, err := jq.db.QueryContext(ctx, query, 
        opts.QueueName, opts.Status, opts.JobType, opts.Limit, opts.Offset)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var jobs []Job
    for rows.Next() {
        var job Job
        var externalID, lastError sql.NullString
        var startedAt, completedAt sql.NullTime
        var result sql.NullString
        
        err := rows.Scan(
            &job.ID, &externalID, &job.QueueName, &job.JobType, &job.Payload,
            &job.Status, &job.Priority, &job.MaxAttempts, &job.CurrentAttempt,
            &job.RunAt, &job.CreatedAt, &startedAt, &completedAt, &lastError, &result,
        )
        if err != nil {
            return nil, err
        }
        
        // Handle nullable fields
        if externalID.Valid {
            job.ExternalID = &externalID.String
        }
        if startedAt.Valid {
            job.StartedAt = &startedAt.Time
        }
        if completedAt.Valid {
            job.CompletedAt = &completedAt.Time
        }
        if lastError.Valid {
            job.LastError = &lastError.String
        }
        if result.Valid {
            job.Result = json.RawMessage(result.String)
        }
        
        jobs = append(jobs, job)
    }
    
    return jobs, rows.Err()
}

type ListJobsOptions struct {
    QueueName string
    Status    string
    JobType   string
    Limit     int
    Offset    int
}
```

## Monitoring and Metrics

### Metrics Collection

```go
type JobMetrics struct {
    JobsEnqueuedTotal      prometheus.Counter
    JobsCompletedTotal     prometheus.Counter
    JobsFailedTotal        prometheus.Counter
    JobsRetriedTotal       prometheus.Counter
    JobProcessingDuration  prometheus.Histogram
    QueueDepth            prometheus.Gauge
    ActiveWorkers         prometheus.Gauge
    JobsByStatus          *prometheus.GaugeVec
    JobsByQueue           *prometheus.GaugeVec
}

func NewJobMetrics() *JobMetrics {
    return &JobMetrics{
        JobsEnqueuedTotal: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "job_queue_jobs_enqueued_total",
            Help: "Total number of jobs enqueued",
        }),
        JobsCompletedTotal: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "job_queue_jobs_completed_total",
            Help: "Total number of jobs completed successfully",
        }),
        JobsFailedTotal: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "job_queue_jobs_failed_total",
            Help: "Total number of jobs that failed permanently",
        }),
        JobsRetriedTotal: prometheus.NewCounter(prometheus.CounterOpts{
            Name: "job_queue_jobs_retried_total",
            Help: "Total number of job retries",
        }),
        JobProcessingDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
            Name:    "job_queue_processing_duration_seconds",
            Help:    "Time spent processing jobs",
            Buckets: []float64{0.01, 0.1, 0.5, 1, 5, 10, 30, 60, 300},
        }),
        QueueDepth: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "job_queue_depth",
            Help: "Number of pending jobs in the queue",
        }),
        ActiveWorkers: prometheus.NewGauge(prometheus.GaugeOpts{
            Name: "job_queue_active_workers",
            Help: "Number of active workers processing jobs",
        }),
        JobsByStatus: prometheus.NewGaugeVec(prometheus.GaugeOpts{
            Name: "job_queue_jobs_by_status",
            Help: "Number of jobs by status",
        }, []string{"status", "queue"}),
        JobsByQueue: prometheus.NewGaugeVec(prometheus.GaugeOpts{
            Name: "job_queue_jobs_by_queue",
            Help: "Number of jobs by queue",
        }, []string{"queue"}),
    }
}

func (jp *JobProcessor) updateMetrics(ctx context.Context) {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            jp.collectMetrics(ctx)
        case <-ctx.Done():
            return
        }
    }
}

func (jp *JobProcessor) collectMetrics(ctx context.Context) {
    // Update active workers
    jp.metrics.ActiveWorkers.Set(float64(jp.activeWorkers.Load()))
    
    // Update queue depth
    var queueDepth int
    err := jp.db.QueryRowContext(ctx, 
        "SELECT COUNT(*) FROM jobs WHERE queue_name = $1 AND status = 'pending'", 
        jp.queueName).Scan(&queueDepth)
    if err == nil {
        jp.metrics.QueueDepth.Set(float64(queueDepth))
    }
    
    // Update jobs by status
    rows, err := jp.db.QueryContext(ctx, `
        SELECT status, COUNT(*) 
        FROM jobs 
        WHERE queue_name = $1 
        GROUP BY status
    `, jp.queueName)
    if err != nil {
        jp.logger.Error("failed to collect status metrics", "error", err)
        return
    }
    defer rows.Close()
    
    for rows.Next() {
        var status string
        var count int
        if err := rows.Scan(&status, &count); err != nil {
            continue
        }
        jp.metrics.JobsByStatus.WithLabelValues(status, jp.queueName).Set(float64(count))
    }
}
```

## Usage Examples

### Basic Usage

```go
func main() {
    // Database connection
    db, err := sql.Open("postgres", "postgres://user:pass@localhost/db?sslmode=disable")
    if err != nil {
        panic(err)
    }
    defer db.Close()
    
    // Initialize job queue
    logger := slog.Default()
    jobQueue := NewJobQueue(db, logger)
    
    // Create job router
    router := NewJobRouter(logger)
    
    // Register job handlers
    router.Register("send_email", JobHandlerFunc(sendEmailHandler))
    router.Register("process_image", JobHandlerFunc(processImageHandler))
    router.Register("generate_report", JobHandlerFunc(generateReportHandler))
    
    // Create job processor
    processor := NewJobProcessor(db, router, JobProcessorOptions{
        QueueName:    "default",
        MaxWorkers:   10,
        PollInterval: 1 * time.Second,
        Logger:       logger,
    })
    
    // Start processing
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    
    go func() {
        if err := processor.Start(ctx); err != nil {
            logger.Error("processor failed", "error", err)
        }
    }()
    
    // Enqueue some jobs
    emailPayload := map[string]interface{}{
        "to":      "user@example.com",
        "subject": "Welcome!",
        "body":    "Welcome to our service!",
    }
    
    job, err := jobQueue.Enqueue(ctx, "send_email", emailPayload, &JobOptions{
        QueueName:   "default",
        MaxAttempts: 3,
    })
    if err != nil {
        logger.Error("failed to enqueue job", "error", err)
        return
    }
    
    logger.Info("job enqueued", "job_id", job.ID)
    
    // Keep the program running
    select {}
}

func sendEmailHandler(ctx context.Context, job *Job) error {
    var payload struct {
        To      string `json:"to"`
        Subject string `json:"subject"`
        Body    string `json:"body"`
    }
    
    if err := json.Unmarshal(job.Payload, &payload); err != nil {
        return fmt.Errorf("unmarshal payload: %w", err)
    }
    
    // Simulate email sending
    time.Sleep(100 * time.Millisecond)
    
    // In real implementation, send email using your email service
    fmt.Printf("Sending email to %s: %s\n", payload.To, payload.Subject)
    
    return nil
}

func processImageHandler(ctx context.Context, job *Job) error {
    var payload struct {
        ImageURL string `json:"image_url"`
        Width    int    `json:"width"`
        Height   int    `json:"height"`
    }
    
    if err := json.Unmarshal(job.Payload, &payload); err != nil {
        return fmt.Errorf("unmarshal payload: %w", err)
    }
    
    // Simulate image processing
    time.Sleep(2 * time.Second)
    
    fmt.Printf("Processed image %s to %dx%d\n", payload.ImageURL, payload.Width, payload.Height)
    
    return nil
}

func generateReportHandler(ctx context.Context, job *Job) error {
    var payload struct {
        ReportType string    `json:"report_type"`
        StartDate  time.Time `json:"start_date"`
        EndDate    time.Time `json:"end_date"`
    }
    
    if err := json.Unmarshal(job.Payload, &payload); err != nil {
        return fmt.Errorf("unmarshal payload: %w", err)
    }
    
    // Simulate report generation
    time.Sleep(5 * time.Second)
    
    fmt.Printf("Generated %s report for period %s to %s\n", 
               payload.ReportType, payload.StartDate.Format("2006-01-02"), 
               payload.EndDate.Format("2006-01-02"))
    
    return nil
}
```

### Advanced Usage with Transactions

```go
func CreateUserWithWelcomeEmail(ctx context.Context, db *sql.DB, jobQueue *JobQueue, userData UserData) error {
    tx, err := db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Create user
    var userID int64
    err = tx.QueryRowContext(ctx, `
        INSERT INTO users (name, email, created_at)
        VALUES ($1, $2, NOW())
        RETURNING id
    `, userData.Name, userData.Email).Scan(&userID)
    if err != nil {
        return fmt.Errorf("create user: %w", err)
    }
    
    // Schedule welcome email
    emailPayload := map[string]interface{}{
        "user_id": userID,
        "to":      userData.Email,
        "subject": "Welcome to Our Service!",
        "template": "welcome",
    }
    
    externalID := fmt.Sprintf("welcome_email_%d", userID)
    _, err = jobQueue.EnqueueTx(ctx, tx, "send_email", emailPayload, &JobOptions{
        ExternalID:  &externalID, // Prevent duplicate welcome emails
        QueueName:   "emails",
        MaxAttempts: 5,
    })
    if err != nil {
        return fmt.Errorf("enqueue welcome email: %w", err)
    }
    
    return tx.Commit()
}

type UserData struct {
    Name  string
    Email string
}
```

## Best Practices

### 1. Job Design
- Keep job payloads small and focused
- Use external IDs for important uniqueness constraints
- Design jobs to be idempotent when possible
- Separate queues for different priority levels

### 2. Error Handling
- Implement proper retry logic with exponential backoff
- Log detailed error information for debugging
- Use dead letter queues for permanently failed jobs
- Monitor retry rates and failure patterns

### 3. Performance
- Use appropriate database indexes
- Batch job operations when possible
- Monitor queue depth and processing times
- Consider partitioning for high-volume workloads

### 4. Operational Considerations
- Implement proper monitoring and alerting
- Plan for graceful shutdown of workers
- Regular cleanup of completed jobs
- Archive old jobs to maintain performance

### 5. Security
- Validate job payloads before processing
- Use proper authentication for job management APIs
- Audit job creation and execution
- Implement rate limiting for job enqueueing


