# Database-Backed Background Job System

## Status
Accepted

## Context
Background job processing is essential for handling long-running tasks, sending emails, processing images, generating reports, and other asynchronous operations. A reliable job queue system must ensure jobs are not lost, provide retry mechanisms, and scale efficiently.

## Problem
Traditional message queue solutions often introduce additional infrastructure complexity:

1. **Infrastructure overhead**: Separate queue systems (Redis, RabbitMQ) require additional maintenance
2. **Operational complexity**: Multiple systems to monitor and maintain
3. **Data consistency**: Jobs and application data may become inconsistent across systems
4. **Development complexity**: Different APIs and patterns for job handling vs data persistence

## Decision
We will implement a database-backed background job system similar to SolidQueue, using PostgreSQL as both the application database and job queue storage. This approach provides ACID guarantees, reduces infrastructure complexity, and leverages existing database operational expertise.

## Implementation

### Database Schema

```sql
-- Job queue table
CREATE TABLE jobs (
    id BIGSERIAL PRIMARY KEY,
    queue_name VARCHAR(255) NOT NULL DEFAULT 'default',
    job_class VARCHAR(255) NOT NULL,
    arguments JSONB NOT NULL DEFAULT '{}',
    priority INTEGER NOT NULL DEFAULT 0,
    scheduled_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    started_at TIMESTAMP WITH TIME ZONE,
    finished_at TIMESTAMP WITH TIME ZONE,
    failed_at TIMESTAMP WITH TIME ZONE,
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 3,
    error_message TEXT,
    error_backtrace TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'pending'
);

-- Indexes for performance
CREATE INDEX idx_jobs_queue_status_scheduled ON jobs (queue_name, status, scheduled_at) 
    WHERE status IN ('pending', 'retrying');
CREATE INDEX idx_jobs_status ON jobs (status);
CREATE INDEX idx_jobs_scheduled_at ON jobs (scheduled_at);
CREATE INDEX idx_jobs_created_at ON jobs (created_at);

-- Failed jobs table for analysis
CREATE TABLE failed_jobs (
    id BIGSERIAL PRIMARY KEY,
    original_job_id BIGINT NOT NULL,
    queue_name VARCHAR(255) NOT NULL,
    job_class VARCHAR(255) NOT NULL,
    arguments JSONB NOT NULL,
    error_message TEXT NOT NULL,
    error_backtrace TEXT,
    failed_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL
);

-- Job execution locks table (for distributed processing)
CREATE TABLE job_locks (
    id BIGSERIAL PRIMARY KEY,
    job_id BIGINT NOT NULL UNIQUE REFERENCES jobs(id),
    worker_id VARCHAR(255) NOT NULL,
    locked_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE INDEX idx_job_locks_expires_at ON job_locks (expires_at);
```

### Core Job System

```go
package jobs

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "log"
    "time"
    
    "github.com/google/uuid"
    "github.com/lib/pq"
)

// Job represents a background job
type Job struct {
    ID           int64                  `json:"id"`
    QueueName    string                 `json:"queue_name"`
    JobClass     string                 `json:"job_class"`
    Arguments    map[string]interface{} `json:"arguments"`
    Priority     int                    `json:"priority"`
    ScheduledAt  time.Time              `json:"scheduled_at"`
    CreatedAt    time.Time              `json:"created_at"`
    StartedAt    *time.Time             `json:"started_at"`
    FinishedAt   *time.Time             `json:"finished_at"`
    FailedAt     *time.Time             `json:"failed_at"`
    Attempts     int                    `json:"attempts"`
    MaxAttempts  int                    `json:"max_attempts"`
    ErrorMessage string                 `json:"error_message"`
    Status       JobStatus              `json:"status"`
}

type JobStatus string

const (
    JobStatusPending   JobStatus = "pending"
    JobStatusRunning   JobStatus = "running"
    JobStatusCompleted JobStatus = "completed"
    JobStatusFailed    JobStatus = "failed"
    JobStatusRetrying  JobStatus = "retrying"
    JobStatusCancelled JobStatus = "cancelled"
)

// JobHandler defines the interface for job handlers
type JobHandler interface {
    Handle(ctx context.Context, args map[string]interface{}) error
    MaxAttempts() int
    RetryDelay(attempt int) time.Duration
}

// JobQueue manages background jobs
type JobQueue struct {
    db       *sql.DB
    handlers map[string]JobHandler
    workerID string
}

// NewJobQueue creates a new job queue
func NewJobQueue(db *sql.DB) *JobQueue {
    return &JobQueue{
        db:       db,
        handlers: make(map[string]JobHandler),
        workerID: uuid.New().String(),
    }
}

// RegisterHandler registers a job handler
func (jq *JobQueue) RegisterHandler(jobClass string, handler JobHandler) {
    jq.handlers[jobClass] = handler
}

// Enqueue adds a job to the queue
func (jq *JobQueue) Enqueue(ctx context.Context, jobClass string, args map[string]interface{}, opts ...EnqueueOption) (*Job, error) {
    job := &Job{
        QueueName:   "default",
        JobClass:    jobClass,
        Arguments:   args,
        Priority:    0,
        ScheduledAt: time.Now(),
        MaxAttempts: 3,
        Status:      JobStatusPending,
    }
    
    // Apply options
    for _, opt := range opts {
        opt(job)
    }
    
    argsJSON, err := json.Marshal(job.Arguments)
    if err != nil {
        return nil, fmt.Errorf("failed to marshal arguments: %w", err)
    }
    
    query := `
        INSERT INTO jobs (queue_name, job_class, arguments, priority, scheduled_at, max_attempts, status)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id, created_at
    `
    
    err = jq.db.QueryRowContext(ctx, query,
        job.QueueName, job.JobClass, argsJSON, job.Priority,
        job.ScheduledAt, job.MaxAttempts, job.Status,
    ).Scan(&job.ID, &job.CreatedAt)
    
    if err != nil {
        return nil, fmt.Errorf("failed to enqueue job: %w", err)
    }
    
    return job, nil
}

// EnqueueOption configures job enqueuing
type EnqueueOption func(*Job)

// WithQueue sets the queue name
func WithQueue(queueName string) EnqueueOption {
    return func(j *Job) {
        j.QueueName = queueName
    }
}

// WithPriority sets the job priority (higher numbers = higher priority)
func WithPriority(priority int) EnqueueOption {
    return func(j *Job) {
        j.Priority = priority
    }
}

// WithDelay schedules the job to run after a delay
func WithDelay(delay time.Duration) EnqueueOption {
    return func(j *Job) {
        j.ScheduledAt = time.Now().Add(delay)
    }
}

// WithScheduledAt schedules the job to run at a specific time
func WithScheduledAt(scheduledAt time.Time) EnqueueOption {
    return func(j *Job) {
        j.ScheduledAt = scheduledAt
    }
}

// WithMaxAttempts sets the maximum retry attempts
func WithMaxAttempts(maxAttempts int) EnqueueOption {
    return func(j *Job) {
        j.MaxAttempts = maxAttempts
    }
}

// ProcessJobs processes jobs from the queue
func (jq *JobQueue) ProcessJobs(ctx context.Context, queueNames []string, maxConcurrency int) error {
    sem := make(chan struct{}, maxConcurrency)
    
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        default:
            // Try to get a job
            job, err := jq.dequeueJob(ctx, queueNames)
            if err != nil {
                if err == sql.ErrNoRows {
                    // No jobs available, wait before trying again
                    time.Sleep(1 * time.Second)
                    continue
                }
                log.Printf("Error dequeuing job: %v", err)
                continue
            }
            
            // Process job concurrently
            sem <- struct{}{} // Acquire semaphore
            go func(job *Job) {
                defer func() { <-sem }() // Release semaphore
                jq.processJob(ctx, job)
            }(job)
        }
    }
}

// dequeueJob atomically retrieves and locks the next job
func (jq *JobQueue) dequeueJob(ctx context.Context, queueNames []string) (*Job, error) {
    tx, err := jq.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, err
    }
    defer tx.Rollback()
    
    // Build queue filter
    queueFilter := "queue_name = ANY($1)"
    if len(queueNames) == 0 {
        queueNames = []string{"default"}
    }
    
    // Lock and update job atomically
    query := fmt.Sprintf(`
        UPDATE jobs SET 
            status = 'running',
            started_at = NOW(),
            attempts = attempts + 1
        WHERE id = (
            SELECT id FROM jobs 
            WHERE %s
            AND status IN ('pending', 'retrying')
            AND scheduled_at <= NOW()
            ORDER BY priority DESC, scheduled_at ASC
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        RETURNING id, queue_name, job_class, arguments, priority, scheduled_at, 
                  created_at, started_at, attempts, max_attempts, status
    `, queueFilter)
    
    var job Job
    var argsJSON []byte
    
    err = tx.QueryRowContext(ctx, query, pq.Array(queueNames)).Scan(
        &job.ID, &job.QueueName, &job.JobClass, &argsJSON, &job.Priority,
        &job.ScheduledAt, &job.CreatedAt, &job.StartedAt, &job.Attempts,
        &job.MaxAttempts, &job.Status,
    )
    
    if err != nil {
        return nil, err
    }
    
    // Unmarshal arguments
    if err := json.Unmarshal(argsJSON, &job.Arguments); err != nil {
        return nil, fmt.Errorf("failed to unmarshal job arguments: %w", err)
    }
    
    // Create job lock
    lockExpiry := time.Now().Add(10 * time.Minute) // 10-minute lock timeout
    _, err = tx.ExecContext(ctx,
        "INSERT INTO job_locks (job_id, worker_id, expires_at) VALUES ($1, $2, $3)",
        job.ID, jq.workerID, lockExpiry)
    
    if err != nil {
        return nil, fmt.Errorf("failed to create job lock: %w", err)
    }
    
    if err := tx.Commit(); err != nil {
        return nil, err
    }
    
    return &job, nil
}

// processJob executes a single job
func (jq *JobQueue) processJob(ctx context.Context, job *Job) {
    defer jq.releaseLock(ctx, job.ID)
    
    handler, exists := jq.handlers[job.JobClass]
    if !exists {
        jq.failJob(ctx, job, fmt.Errorf("no handler registered for job class: %s", job.JobClass))
        return
    }
    
    // Execute job with timeout
    timeoutCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
    defer cancel()
    
    err := handler.Handle(timeoutCtx, job.Arguments)
    if err != nil {
        jq.handleJobError(ctx, job, handler, err)
        return
    }
    
    // Mark job as completed
    jq.completeJob(ctx, job)
}

// handleJobError handles job execution errors and retries
func (jq *JobQueue) handleJobError(ctx context.Context, job *Job, handler JobHandler, err error) {
    maxAttempts := handler.MaxAttempts()
    if maxAttempts == 0 {
        maxAttempts = job.MaxAttempts
    }
    
    if job.Attempts >= maxAttempts {
        jq.failJob(ctx, job, err)
        return
    }
    
    // Schedule retry
    retryDelay := handler.RetryDelay(job.Attempts)
    if retryDelay == 0 {
        retryDelay = time.Duration(job.Attempts*job.Attempts) * time.Second // Exponential backoff
    }
    
    scheduledAt := time.Now().Add(retryDelay)
    
    query := `
        UPDATE jobs SET 
            status = 'retrying',
            scheduled_at = $1,
            error_message = $2,
            started_at = NULL
        WHERE id = $3
    `
    
    _, updateErr := jq.db.ExecContext(ctx, query, scheduledAt, err.Error(), job.ID)
    if updateErr != nil {
        log.Printf("Failed to schedule job retry: %v", updateErr)
    }
}

// completeJob marks a job as completed
func (jq *JobQueue) completeJob(ctx context.Context, job *Job) {
    query := `
        UPDATE jobs SET 
            status = 'completed',
            finished_at = NOW(),
            error_message = ''
        WHERE id = $1
    `
    
    _, err := jq.db.ExecContext(ctx, query, job.ID)
    if err != nil {
        log.Printf("Failed to mark job as completed: %v", err)
    }
}

// failJob marks a job as permanently failed
func (jq *JobQueue) failJob(ctx context.Context, job *Job, err error) {
    tx, txErr := jq.db.BeginTx(ctx, nil)
    if txErr != nil {
        log.Printf("Failed to begin transaction for job failure: %v", txErr)
        return
    }
    defer tx.Rollback()
    
    // Update job status
    query := `
        UPDATE jobs SET 
            status = 'failed',
            failed_at = NOW(),
            error_message = $1
        WHERE id = $2
    `
    
    _, updateErr := tx.ExecContext(ctx, query, err.Error(), job.ID)
    if updateErr != nil {
        log.Printf("Failed to mark job as failed: %v", updateErr)
        return
    }
    
    // Archive to failed_jobs table
    argsJSON, _ := json.Marshal(job.Arguments)
    archiveQuery := `
        INSERT INTO failed_jobs (original_job_id, queue_name, job_class, arguments, error_message, failed_at)
        VALUES ($1, $2, $3, $4, $5, NOW())
    `
    
    _, archiveErr := tx.ExecContext(ctx, archiveQuery,
        job.ID, job.QueueName, job.JobClass, argsJSON, err.Error())
    
    if archiveErr != nil {
        log.Printf("Failed to archive failed job: %v", archiveErr)
        return
    }
    
    if commitErr := tx.Commit(); commitErr != nil {
        log.Printf("Failed to commit job failure transaction: %v", commitErr)
    }
}

// releaseLock releases the job lock
func (jq *JobQueue) releaseLock(ctx context.Context, jobID int64) {
    _, err := jq.db.ExecContext(ctx, "DELETE FROM job_locks WHERE job_id = $1", jobID)
    if err != nil {
        log.Printf("Failed to release job lock: %v", err)
    }
}

// CleanupExpiredLocks removes expired job locks
func (jq *JobQueue) CleanupExpiredLocks(ctx context.Context) error {
    query := `
        DELETE FROM job_locks 
        WHERE expires_at < NOW()
    `
    
    result, err := jq.db.ExecContext(ctx, query)
    if err != nil {
        return err
    }
    
    count, _ := result.RowsAffected()
    if count > 0 {
        log.Printf("Cleaned up %d expired job locks", count)
    }
    
    return nil
}
```

### Example Job Handlers

```go
package handlers

import (
    "context"
    "fmt"
    "log"
    "time"
    
    "your-app/pkg/email"
    "your-app/pkg/jobs"
)

// EmailJob sends emails
type EmailJob struct {
    emailService email.Service
}

func NewEmailJob(emailService email.Service) *EmailJob {
    return &EmailJob{emailService: emailService}
}

func (e *EmailJob) Handle(ctx context.Context, args map[string]interface{}) error {
    to, ok := args["to"].(string)
    if !ok {
        return fmt.Errorf("missing 'to' argument")
    }
    
    subject, ok := args["subject"].(string)
    if !ok {
        return fmt.Errorf("missing 'subject' argument")
    }
    
    body, ok := args["body"].(string)
    if !ok {
        return fmt.Errorf("missing 'body' argument")
    }
    
    return e.emailService.Send(ctx, to, subject, body)
}

func (e *EmailJob) MaxAttempts() int {
    return 5
}

func (e *EmailJob) RetryDelay(attempt int) time.Duration {
    // Exponential backoff: 1s, 4s, 9s, 16s, 25s
    return time.Duration(attempt*attempt) * time.Second
}

// ReportGenerationJob generates reports
type ReportGenerationJob struct {
    reportService ReportService
}

func NewReportGenerationJob(reportService ReportService) *ReportGenerationJob {
    return &ReportGenerationJob{reportService: reportService}
}

func (r *ReportGenerationJob) Handle(ctx context.Context, args map[string]interface{}) error {
    reportType, ok := args["report_type"].(string)
    if !ok {
        return fmt.Errorf("missing 'report_type' argument")
    }
    
    userID, ok := args["user_id"].(float64) // JSON numbers are float64
    if !ok {
        return fmt.Errorf("missing 'user_id' argument")
    }
    
    filters, _ := args["filters"].(map[string]interface{})
    
    return r.reportService.Generate(ctx, reportType, int64(userID), filters)
}

func (r *ReportGenerationJob) MaxAttempts() int {
    return 3
}

func (r *ReportGenerationJob) RetryDelay(attempt int) time.Duration {
    return time.Duration(attempt*2) * time.Minute
}

// ImageProcessingJob processes uploaded images
type ImageProcessingJob struct {
    imageService ImageService
}

func NewImageProcessingJob(imageService ImageService) *ImageProcessingJob {
    return &ImageProcessingJob{imageService: imageService}
}

func (i *ImageProcessingJob) Handle(ctx context.Context, args map[string]interface{}) error {
    imageURL, ok := args["image_url"].(string)
    if !ok {
        return fmt.Errorf("missing 'image_url' argument")
    }
    
    operations, ok := args["operations"].([]interface{})
    if !ok {
        return fmt.Errorf("missing 'operations' argument")
    }
    
    // Convert operations to string slice
    var ops []string
    for _, op := range operations {
        if opStr, ok := op.(string); ok {
            ops = append(ops, opStr)
        }
    }
    
    return i.imageService.Process(ctx, imageURL, ops)
}

func (i *ImageProcessingJob) MaxAttempts() int {
    return 2 // Image processing failures are usually permanent
}

func (i *ImageProcessingJob) RetryDelay(attempt int) time.Duration {
    return 30 * time.Second
}
```

### Worker Process

```go
package main

import (
    "context"
    "database/sql"
    "log"
    "os"
    "os/signal"
    "sync"
    "syscall"
    "time"
    
    "your-app/pkg/config"
    "your-app/pkg/database"
    "your-app/pkg/jobs"
    "your-app/pkg/handlers"
)

func main() {
    cfg, err := config.Load()
    if err != nil {
        log.Fatal("Failed to load config:", err)
    }
    
    db, err := database.Connect(cfg.Database)
    if err != nil {
        log.Fatal("Failed to connect to database:", err)
    }
    defer db.Close()
    
    // Create job queue
    jobQueue := jobs.NewJobQueue(db)
    
    // Register job handlers
    jobQueue.RegisterHandler("email", handlers.NewEmailJob(emailService))
    jobQueue.RegisterHandler("report_generation", handlers.NewReportGenerationJob(reportService))
    jobQueue.RegisterHandler("image_processing", handlers.NewImageProcessingJob(imageService))
    
    // Start worker processes
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    
    var wg sync.WaitGroup
    
    // Start job processing workers
    queues := []string{"default", "emails", "reports", "images"}
    for i := 0; i < 4; i++ { // 4 worker processes
        wg.Add(1)
        go func() {
            defer wg.Done()
            if err := jobQueue.ProcessJobs(ctx, queues, 10); err != nil {
                log.Printf("Worker error: %v", err)
            }
        }()
    }
    
    // Start cleanup worker
    wg.Add(1)
    go func() {
        defer wg.Done()
        ticker := time.NewTicker(5 * time.Minute)
        defer ticker.Stop()
        
        for {
            select {
            case <-ctx.Done():
                return
            case <-ticker.C:
                if err := jobQueue.CleanupExpiredLocks(ctx); err != nil {
                    log.Printf("Cleanup error: %v", err)
                }
            }
        }
    }()
    
    // Wait for shutdown signal
    sigChan := make(chan os.Signal, 1)
    signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
    <-sigChan
    
    log.Println("Shutting down workers...")
    cancel()
    wg.Wait()
    log.Println("Workers shut down complete")
}
```

### Usage Examples

```go
package main

import (
    "context"
    "your-app/pkg/jobs"
)

func exampleUsage(jobQueue *jobs.JobQueue) {
    ctx := context.Background()
    
    // Send email immediately
    _, err := jobQueue.Enqueue(ctx, "email", map[string]interface{}{
        "to":      "user@example.com",
        "subject": "Welcome!",
        "body":    "Welcome to our service!",
    }, jobs.WithQueue("emails"))
    
    // Generate report with delay
    _, err = jobQueue.Enqueue(ctx, "report_generation", map[string]interface{}{
        "report_type": "sales",
        "user_id":     123,
        "filters": map[string]interface{}{
            "start_date": "2024-01-01",
            "end_date":   "2024-01-31",
        },
    }, 
        jobs.WithQueue("reports"),
        jobs.WithDelay(1*time.Hour),
        jobs.WithPriority(5),
    )
    
    // Process image with high priority
    _, err = jobQueue.Enqueue(ctx, "image_processing", map[string]interface{}{
        "image_url": "https://example.com/image.jpg",
        "operations": []string{"resize", "compress", "watermark"},
    },
        jobs.WithQueue("images"),
        jobs.WithPriority(10),
        jobs.WithMaxAttempts(2),
    )
}
```

### Monitoring and Management

```go
package jobs

// JobStats represents job queue statistics
type JobStats struct {
    PendingJobs   int64 `json:"pending_jobs"`
    RunningJobs   int64 `json:"running_jobs"`
    CompletedJobs int64 `json:"completed_jobs"`
    FailedJobs    int64 `json:"failed_jobs"`
    RetryingJobs  int64 `json:"retrying_jobs"`
}

// GetStats returns job queue statistics
func (jq *JobQueue) GetStats(ctx context.Context) (*JobStats, error) {
    query := `
        SELECT 
            COUNT(CASE WHEN status = 'pending' THEN 1 END) as pending,
            COUNT(CASE WHEN status = 'running' THEN 1 END) as running,
            COUNT(CASE WHEN status = 'completed' THEN 1 END) as completed,
            COUNT(CASE WHEN status = 'failed' THEN 1 END) as failed,
            COUNT(CASE WHEN status = 'retrying' THEN 1 END) as retrying
        FROM jobs
        WHERE created_at > NOW() - INTERVAL '24 hours'
    `
    
    var stats JobStats
    err := jq.db.QueryRowContext(ctx, query).Scan(
        &stats.PendingJobs, &stats.RunningJobs, &stats.CompletedJobs,
        &stats.FailedJobs, &stats.RetryingJobs,
    )
    
    return &stats, err
}

// RetryFailedJobs retries all failed jobs
func (jq *JobQueue) RetryFailedJobs(ctx context.Context, maxAge time.Duration) (int64, error) {
    query := `
        UPDATE jobs SET 
            status = 'pending',
            scheduled_at = NOW(),
            attempts = 0,
            error_message = '',
            failed_at = NULL
        WHERE status = 'failed' 
        AND failed_at > NOW() - $1
    `
    
    result, err := jq.db.ExecContext(ctx, query, maxAge)
    if err != nil {
        return 0, err
    }
    
    return result.RowsAffected()
}

// DeleteOldJobs removes old completed/failed jobs
func (jq *JobQueue) DeleteOldJobs(ctx context.Context, maxAge time.Duration) (int64, error) {
    query := `
        DELETE FROM jobs 
        WHERE status IN ('completed', 'failed')
        AND created_at < NOW() - $1
    `
    
    result, err := jq.db.ExecContext(ctx, query, maxAge)
    if err != nil {
        return 0, err
    }
    
    return result.RowsAffected()
}
```

## Best Practices

1. **Job Idempotency**: Design jobs to be safely retryable
2. **Argument Validation**: Validate job arguments in handlers
3. **Timeouts**: Set appropriate timeouts for job execution
4. **Error Handling**: Provide meaningful error messages
5. **Monitoring**: Track job metrics and performance
6. **Cleanup**: Regularly clean up old jobs and locks
7. **Testing**: Test job handlers thoroughly
8. **Documentation**: Document job arguments and behavior

## Monitoring Dashboards

### Grafana Queries

```promql
# Job processing rate
rate(jobs_processed_total[5m])

# Job failure rate  
rate(jobs_failed_total[5m]) / rate(jobs_processed_total[5m])

# Queue depth by status
sum(jobs_queue_depth) by (status)

# Average job processing time
rate(jobs_processing_duration_seconds_sum[5m]) / rate(jobs_processing_duration_seconds_count[5m])
```

## Consequences

### Advantages
- **Simplified infrastructure**: Uses existing database, no additional queue system
- **ACID guarantees**: Jobs are stored transactionally with application data
- **Operational simplicity**: Single system to backup, monitor, and maintain
- **Cost effective**: No additional infrastructure costs
- **Familiar tooling**: Use existing database tools and expertise

### Disadvantages
- **Database load**: Additional load on primary database
- **Scaling limitations**: Limited by database performance
- **Less specialized**: Not optimized specifically for queuing like Redis/RabbitMQ
- **Polling overhead**: Requires polling for new jobs vs push-based systems
- **Lock contention**: Potential for lock contention under high load

## Migration Strategy

If migrating from Redis/RabbitMQ:

1. **Dual-write phase**: Write jobs to both systems
2. **Gradual migration**: Move job types one by one
3. **Monitoring**: Compare performance and reliability
4. **Cutover**: Switch to database-only system
5. **Cleanup**: Remove old queue system

## References
- [SolidQueue](https://github.com/rails/solid_queue) - Rails database-backed job queue
- [PostgreSQL Advisory Locks](https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS)
- [Background Job Best Practices](https://github.com/bensheldon/good_job#readme)
