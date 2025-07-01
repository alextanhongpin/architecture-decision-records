# Cron Job

## Status

`accepted`

## Context

A cron job executes at a specific time. It can be a one-off or recurring job. Cron jobs are essential for automating routine tasks like data cleanup, report generation, cache warming, and system maintenance.

Running a cron job is straightforward when the task is idempotent. However, there are many cases where execution cannot be idempotent. We need to address scenarios involving state transitions, distributed systems, leader election, and exactly-once execution guarantees.

## Decision

Use a robust cron job architecture that handles state management, leader election, and exactly-once processing through database-backed job queues and distributed coordination.

### Job State Management

Track job execution state to ensure reliability and prevent duplicate processing:

```go
type JobExecution struct {
    ID        string    `json:"id"`
    JobName   string    `json:"job_name"`
    Status    string    `json:"status"` // pending, running, completed, failed
    StartedAt time.Time `json:"started_at"`
    CompletedAt *time.Time `json:"completed_at,omitempty"`
    Error     *string   `json:"error,omitempty"`
    Metadata  map[string]interface{} `json:"metadata"`
}

func (j *JobScheduler) ExecuteJob(jobName string, fn func() error) error {
    execution := &JobExecution{
        ID:        generateID(),
        JobName:   jobName,
        Status:    "pending",
        StartedAt: time.Now(),
    }
    
    if err := j.repo.CreateExecution(execution); err != nil {
        return fmt.Errorf("failed to create job execution: %w", err)
    }
    
    execution.Status = "running"
    j.repo.UpdateExecution(execution)
    
    defer func() {
        if r := recover(); r != nil {
            execution.Status = "failed"
            errMsg := fmt.Sprintf("job panicked: %v", r)
            execution.Error = &errMsg
        }
        completedAt := time.Now()
        execution.CompletedAt = &completedAt
        j.repo.UpdateExecution(execution)
    }()
    
    if err := fn(); err != nil {
        execution.Status = "failed"
        errMsg := err.Error()
        execution.Error = &errMsg
        return err
    }
    
    execution.Status = "completed"
    return nil
}
```

### Leader Election

In distributed systems, ensure only one instance executes the cron job:

```go
type LeaderElection struct {
    store     Store
    nodeID    string
    lockKey   string
    ttl       time.Duration
    renewChan chan struct{}
}

func (le *LeaderElection) TryAcquireLock() (bool, error) {
    acquired, err := le.store.SetNX(le.lockKey, le.nodeID, le.ttl)
    if err != nil {
        return false, err
    }
    
    if acquired {
        go le.renewLock()
    }
    
    return acquired, nil
}

func (le *LeaderElection) renewLock() {
    ticker := time.NewTicker(le.ttl / 3)
    defer ticker.Stop()
    
    for {
        select {
        case <-ticker.C:
            if err := le.store.Expire(le.lockKey, le.ttl); err != nil {
                log.Printf("failed to renew lock: %v", err)
                return
            }
        case <-le.renewChan:
            return
        }
    }
}

func (j *JobScheduler) RunWithLeaderElection(jobName string, fn func() error) error {
    election := &LeaderElection{
        store:   j.store,
        nodeID:  j.nodeID,
        lockKey: fmt.Sprintf("job:lock:%s", jobName),
        ttl:     30 * time.Second,
    }
    
    acquired, err := election.TryAcquireLock()
    if err != nil {
        return fmt.Errorf("failed to acquire lock: %w", err)
    }
    
    if !acquired {
        log.Printf("job %s already running on another node", jobName)
        return nil
    }
    
    defer election.ReleaseLock()
    return j.ExecuteJob(jobName, fn)
}
```

### Exactly Once Processing

Implement idempotency through database constraints and upsert operations:

```sql
CREATE TABLE job_executions (
    id VARCHAR(255) PRIMARY KEY,
    job_name VARCHAR(255) NOT NULL,
    execution_date DATE NOT NULL,
    status VARCHAR(50) NOT NULL,
    started_at TIMESTAMP NOT NULL,
    completed_at TIMESTAMP NULL,
    error TEXT NULL,
    metadata JSONB,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(job_name, execution_date)
);

CREATE INDEX idx_job_executions_status ON job_executions(status);
CREATE INDEX idx_job_executions_job_name_date ON job_executions(job_name, execution_date);
```

```go
func (j *JobScheduler) ExecuteOnce(jobName string, date time.Time, fn func() error) error {
    executionID := fmt.Sprintf("%s:%s", jobName, date.Format("2006-01-02"))
    
    // Try to insert execution record
    execution := &JobExecution{
        ID:            executionID,
        JobName:       jobName,
        ExecutionDate: date,
        Status:        "pending",
        StartedAt:     time.Now(),
    }
    
    err := j.repo.CreateExecutionOnce(execution)
    if errors.Is(err, ErrExecutionExists) {
        log.Printf("job %s already executed for date %s", jobName, date.Format("2006-01-02"))
        return nil
    }
    if err != nil {
        return fmt.Errorf("failed to create execution record: %w", err)
    }
    
    return j.ExecuteJob(jobName, fn)
}
```

### Distributed Cron with Message Queue

For complex workflows, use message queues for reliable job distribution:

```go
type CronJobMessage struct {
    JobName      string                 `json:"job_name"`
    ScheduledAt  time.Time              `json:"scheduled_at"`
    Payload      map[string]interface{} `json:"payload"`
    RetryCount   int                    `json:"retry_count"`
    MaxRetries   int                    `json:"max_retries"`
}

func (j *JobScheduler) ScheduleJob(jobName string, schedule string, payload map[string]interface{}) error {
    parser := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow)
    sched, err := parser.Parse(schedule)
    if err != nil {
        return fmt.Errorf("invalid cron schedule: %w", err)
    }
    
    nextRun := sched.Next(time.Now())
    message := &CronJobMessage{
        JobName:     jobName,
        ScheduledAt: nextRun,
        Payload:     payload,
        MaxRetries:  3,
    }
    
    return j.messageQueue.ScheduleMessage(message, nextRun)
}

func (j *JobScheduler) ProcessJobMessage(msg *CronJobMessage) error {
    if time.Now().Before(msg.ScheduledAt) {
        // Reschedule if too early
        return j.messageQueue.ScheduleMessage(msg, msg.ScheduledAt)
    }
    
    jobFunc, exists := j.registeredJobs[msg.JobName]
    if !exists {
        return fmt.Errorf("unknown job: %s", msg.JobName)
    }
    
    err := j.ExecuteOnce(msg.JobName, msg.ScheduledAt, func() error {
        return jobFunc(msg.Payload)
    })
    
    if err != nil && msg.RetryCount < msg.MaxRetries {
        msg.RetryCount++
        retryDelay := time.Duration(msg.RetryCount*msg.RetryCount) * time.Minute
        return j.messageQueue.ScheduleMessage(msg, time.Now().Add(retryDelay))
    }
    
    return err
}
```

### Monitoring and Observability

Track job execution metrics and health:

```go
type JobMetrics struct {
    ExecutionCount    int64         `json:"execution_count"`
    SuccessCount      int64         `json:"success_count"`
    FailureCount      int64         `json:"failure_count"`
    AverageExecTime   time.Duration `json:"average_exec_time"`
    LastExecutedAt    time.Time     `json:"last_executed_at"`
    LastSuccess       time.Time     `json:"last_success"`
    LastFailure       time.Time     `json:"last_failure"`
    ConsecutiveFailures int         `json:"consecutive_failures"`
}

func (j *JobScheduler) RecordMetrics(jobName string, duration time.Duration, success bool) {
    metrics := j.getOrCreateMetrics(jobName)
    
    metrics.ExecutionCount++
    if success {
        metrics.SuccessCount++
        metrics.LastSuccess = time.Now()
        metrics.ConsecutiveFailures = 0
    } else {
        metrics.FailureCount++
        metrics.LastFailure = time.Now()
        metrics.ConsecutiveFailures++
    }
    
    // Calculate rolling average
    metrics.AverageExecTime = time.Duration(
        (int64(metrics.AverageExecTime)*metrics.ExecutionCount + int64(duration)) / 
        (metrics.ExecutionCount + 1),
    )
    
    metrics.LastExecutedAt = time.Now()
    
    // Alert on consecutive failures
    if metrics.ConsecutiveFailures >= 3 {
        j.alertManager.SendAlert(fmt.Sprintf("Job %s has failed %d times consecutively", 
            jobName, metrics.ConsecutiveFailures))
    }
}
```

## Consequences

### Positive

- **Reliability**: State tracking prevents duplicate executions and enables recovery
- **Scalability**: Leader election allows horizontal scaling without conflicts
- **Observability**: Comprehensive metrics enable monitoring and alerting
- **Fault Tolerance**: Retry mechanisms and error handling improve resilience
- **Debugging**: Execution history aids in troubleshooting failures

### Negative

- **Complexity**: Additional infrastructure for state management and coordination
- **Dependencies**: Requires database and potentially message queue infrastructure
- **Latency**: Leader election and state checks add execution overhead
- **Storage**: Job execution history consumes database space

## Anti-patterns

- **Fire and Forget**: Running jobs without state tracking or error handling
- **Hardcoded Schedules**: Embedding cron expressions in code instead of configuration
- **No Timeout**: Jobs without execution timeouts can hang indefinitely
- **Shared State**: Multiple jobs modifying shared state without coordination
- **No Monitoring**: Running jobs without metrics or health checks
