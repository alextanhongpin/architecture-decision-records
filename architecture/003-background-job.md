# Background Jobs

## Status

`draft`

## Context

We will explore how to implement background tasks in a scalable and reliable manner.

Background jobs are essential for:
- Handling time-consuming operations without blocking user requests
- Processing tasks that can be delayed or batched
- Implementing retry logic for failed operations
- Decoupling synchronous operations from asynchronous processing

Key considerations:
- Starting a background task
- Managing resources
- Scaling background tasks
- Persistence and durability
- Error handling and retries
- Monitoring and observability

## Decisions

### Job Queue Patterns

#### Simple In-Memory Queue
For lightweight applications with minimal requirements:

```go
type Job struct {
    ID      string
    Type    string
    Payload interface{}
    Retries int
}

type InMemoryQueue struct {
    jobs chan Job
    workers int
}

func (q *InMemoryQueue) Enqueue(job Job) {
    select {
    case q.jobs <- job:
    default:
        // Queue is full, handle overflow
    }
}

func (q *InMemoryQueue) Start() {
    for i := 0; i < q.workers; i++ {
        go q.worker()
    }
}

func (q *InMemoryQueue) worker() {
    for job := range q.jobs {
        if err := processJob(job); err != nil {
            // Handle retry logic
            if job.Retries < 3 {
                job.Retries++
                time.Sleep(time.Duration(job.Retries) * time.Second)
                q.Enqueue(job)
            }
        }
    }
}
```

#### Database-Backed Queue
For better durability and persistence:

```go
type JobStatus string

const (
    JobStatusPending   JobStatus = "pending"
    JobStatusRunning   JobStatus = "running"
    JobStatusCompleted JobStatus = "completed"
    JobStatusFailed    JobStatus = "failed"
)

type Job struct {
    ID          string    `db:"id"`
    Type        string    `db:"type"`
    Payload     []byte    `db:"payload"`
    Status      JobStatus `db:"status"`
    Retries     int       `db:"retries"`
    MaxRetries  int       `db:"max_retries"`
    ScheduledAt time.Time `db:"scheduled_at"`
    CreatedAt   time.Time `db:"created_at"`
    UpdatedAt   time.Time `db:"updated_at"`
}

func (q *DatabaseQueue) Enqueue(jobType string, payload interface{}) error {
    data, _ := json.Marshal(payload)
    job := Job{
        ID:          uuid.New().String(),
        Type:        jobType,
        Payload:     data,
        Status:      JobStatusPending,
        MaxRetries:  3,
        ScheduledAt: time.Now(),
        CreatedAt:   time.Now(),
        UpdatedAt:   time.Now(),
    }
    return q.db.Insert(&job)
}

func (q *DatabaseQueue) Poll() (*Job, error) {
    job := &Job{}
    err := q.db.Transaction(func(tx *sql.Tx) error {
        // Select and lock the next available job
        err := tx.QueryRow(`
            SELECT id, type, payload, status, retries, max_retries, scheduled_at 
            FROM jobs 
            WHERE status = 'pending' AND scheduled_at <= NOW()
            ORDER BY created_at ASC 
            LIMIT 1 
            FOR UPDATE SKIP LOCKED
        `).Scan(&job.ID, &job.Type, &job.Payload, &job.Status, &job.Retries, &job.MaxRetries, &job.ScheduledAt)
        
        if err != nil {
            return err
        }
        
        // Mark as running
        job.Status = JobStatusRunning
        job.UpdatedAt = time.Now()
        return q.updateJob(tx, job)
    })
    
    return job, err
}
```

### Resource Management

#### Worker Pool Pattern
Manage concurrent job processing with controlled resource usage:

```go
type WorkerPool struct {
    workerCount int
    jobChannel  chan Job
    quit        chan bool
    wg          sync.WaitGroup
}

func NewWorkerPool(workerCount int) *WorkerPool {
    return &WorkerPool{
        workerCount: workerCount,
        jobChannel:  make(chan Job, workerCount*2), // Buffer for better throughput
        quit:        make(chan bool),
    }
}

func (wp *WorkerPool) Start() {
    for i := 0; i < wp.workerCount; i++ {
        wp.wg.Add(1)
        go wp.worker(i)
    }
}

func (wp *WorkerPool) Stop() {
    close(wp.quit)
    wp.wg.Wait()
}

func (wp *WorkerPool) worker(id int) {
    defer wp.wg.Done()
    
    for {
        select {
        case job := <-wp.jobChannel:
            log.Printf("Worker %d processing job %s", id, job.ID)
            if err := processJob(job); err != nil {
                log.Printf("Worker %d failed to process job %s: %v", id, job.ID, err)
            }
        case <-wp.quit:
            log.Printf("Worker %d shutting down", id)
            return
        }
    }
}
```

### Scaling Background Tasks

#### Horizontal Scaling
Distribute jobs across multiple instances:

```go
type DistributedQueue struct {
    instanceID string
    queue      JobQueue
}

func (dq *DistributedQueue) ClaimJob() (*Job, error) {
    job, err := dq.queue.Poll()
    if err != nil {
        return nil, err
    }
    
    // Claim the job for this instance
    job.ProcessorID = dq.instanceID
    job.ClaimedAt = time.Now()
    
    return job, dq.queue.UpdateJob(job)
}

// Heartbeat mechanism to detect failed processors
func (dq *DistributedQueue) Heartbeat() {
    ticker := time.NewTicker(30 * time.Second)
    defer ticker.Stop()
    
    for range ticker.C {
        // Update last seen timestamp
        dq.updateProcessorHeartbeat(dq.instanceID)
        
        // Reclaim jobs from dead processors
        dq.reclaimDeadJobs()
    }
}
```

#### Vertical Scaling with Priority Queues
Handle different job types with appropriate priority:

```go
type PriorityLevel int

const (
    HighPriority PriorityLevel = iota
    MediumPriority
    LowPriority
)

type PriorityQueue struct {
    queues map[PriorityLevel]chan Job
    quit   chan bool
}

func (pq *PriorityQueue) Enqueue(job Job, priority PriorityLevel) {
    select {
    case pq.queues[priority] <- job:
    default:
        // Handle full queue
    }
}

func (pq *PriorityQueue) worker() {
    for {
        select {
        case job := <-pq.queues[HighPriority]:
            processJob(job)
        case job := <-pq.queues[MediumPriority]:
            processJob(job)
        case job := <-pq.queues[LowPriority]:
            processJob(job)
        case <-pq.quit:
            return
        default:
            time.Sleep(100 * time.Millisecond) // Prevent busy waiting
        }
    }
}
```

### Error Handling and Retries

#### Exponential Backoff
Implement intelligent retry mechanisms:

```go
func (q *JobQueue) ProcessWithRetry(job *Job) error {
    maxRetries := job.MaxRetries
    
    for attempt := 0; attempt <= maxRetries; attempt++ {
        err := processJob(job)
        if err == nil {
            job.Status = JobStatusCompleted
            return q.UpdateJob(job)
        }
        
        // Check if error is retryable
        if !isRetryableError(err) {
            job.Status = JobStatusFailed
            job.Error = err.Error()
            return q.UpdateJob(job)
        }
        
        if attempt < maxRetries {
            // Exponential backoff: 2^attempt seconds
            delay := time.Duration(math.Pow(2, float64(attempt))) * time.Second
            job.ScheduledAt = time.Now().Add(delay)
            job.Retries = attempt + 1
            q.UpdateJob(job)
            return fmt.Errorf("job will be retried in %v", delay)
        }
    }
    
    // Max retries exceeded
    job.Status = JobStatusFailed
    job.Error = "max retries exceeded"
    return q.UpdateJob(job)
}

func isRetryableError(err error) bool {
    // Define which errors should trigger retries
    switch {
    case errors.Is(err, context.DeadlineExceeded):
        return true
    case errors.Is(err, syscall.ECONNREFUSED):
        return true
    case strings.Contains(err.Error(), "temporary"):
        return true
    default:
        return false
    }
}
```

### Dead Letter Queue
Handle permanently failed jobs:

```go
type DeadLetterQueue struct {
    db *sql.DB
}

func (dlq *DeadLetterQueue) Add(job Job, reason string) error {
    deadJob := DeadJob{
        OriginalJobID: job.ID,
        JobType:      job.Type,
        Payload:      job.Payload,
        FailureReason: reason,
        FailedAt:     time.Now(),
    }
    return dlq.db.Insert(&deadJob)
}

func (dlq *DeadLetterQueue) Requeue(deadJobID string) error {
    // Move job back to main queue for reprocessing
    return dlq.db.Transaction(func(tx *sql.Tx) error {
        deadJob, err := dlq.getDeadJob(tx, deadJobID)
        if err != nil {
            return err
        }
        
        newJob := Job{
            ID:       uuid.New().String(),
            Type:     deadJob.JobType,
            Payload:  deadJob.Payload,
            Status:   JobStatusPending,
            Retries:  0,
            CreatedAt: time.Now(),
        }
        
        if err := dlq.insertJob(tx, newJob); err != nil {
            return err
        }
        
        return dlq.deleteDeadJob(tx, deadJobID)
    })
}
```

## Consequences

### Benefits
- **Improved user experience**: Long-running tasks don't block user interface
- **Better resource utilization**: Background processing can be optimized independently
- **Fault tolerance**: Failed jobs can be retried automatically
- **Scalability**: Can handle varying loads by adjusting worker count

### Challenges
- **Complexity**: Additional infrastructure to manage and monitor
- **Data consistency**: Need to handle partial failures carefully  
- **Resource management**: Memory and database connections must be managed properly
- **Monitoring**: Need visibility into job queues and processing status

### Best Practices
- Always implement idempotency in job handlers
- Use database transactions for job state changes
- Implement proper timeout handling
- Monitor queue depth and processing rates
- Use structured logging for debugging
- Implement graceful shutdown mechanisms
