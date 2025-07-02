# Background Job Processing Patterns

## Status

`accepted`

## Context

Background job processing is essential for handling heavy operations without blocking user requests. Modern applications require robust patterns for batching requests, managing concurrency, and ensuring reliable execution. Key challenges include:

- **Latency vs Throughput**: Balancing immediate response with batch efficiency
- **Backpressure**: Preventing memory exhaustion under high load  
- **Error handling**: Partial batch failures and retry logic
- **Resource management**: CPU and memory bounds
- **Graceful shutdown**: Clean termination without data loss

## Decision

**Implement a comprehensive background job system with multiple processing patterns:**

### 1. Core Background Processor

```go
package background

import (
    "context"
    "errors"
    "fmt"
    "sync"
    "time"
)

// Job represents a unit of work to be processed.
type Job[T any] struct {
    ID      string
    Data    T
    Retries int
    Created time.Time
}

// Result represents the outcome of job processing.
type Result[T any] struct {
    Job   Job[T]
    Error error
}

// Handler processes a batch of jobs.
type Handler[T any] func(ctx context.Context, jobs []Job[T]) []Result[T]

// Config configures the background processor.
type Config struct {
    MaxBatchSize   int
    BatchTimeout   time.Duration
    QueueSize      int
    MaxConcurrency int
    RetryAttempts  int
    RetryDelay     time.Duration
}

// Processor handles background job execution.
type Processor[T any] struct {
    config    Config
    handler   Handler[T]
    
    // Job queue and batching
    jobQueue    chan Job[T]
    batchQueue  chan []Job[T]
    
    // Control channels
    done        chan struct{}
    wg          sync.WaitGroup
    
    // Metrics
    processed   int64
    failed      int64
    mu          sync.RWMutex
}

func NewProcessor[T any](handler Handler[T], config Config) *Processor[T] {
    if config.MaxBatchSize <= 0 {
        config.MaxBatchSize = 100
    }
    if config.BatchTimeout <= 0 {
        config.BatchTimeout = 10 * time.Millisecond
    }
    if config.QueueSize <= 0 {
        config.QueueSize = 1000
    }
    if config.MaxConcurrency <= 0 {
        config.MaxConcurrency = 10
    }
    if config.RetryAttempts <= 0 {
        config.RetryAttempts = 3
    }
    if config.RetryDelay <= 0 {
        config.RetryDelay = time.Second
    }
    
    return &Processor[T]{
        config:     config,
        handler:    handler,
        jobQueue:   make(chan Job[T], config.QueueSize),
        batchQueue: make(chan []Job[T], config.MaxConcurrency),
        done:       make(chan struct{}),
    }
}

// Start begins processing jobs in the background.
func (p *Processor[T]) Start(ctx context.Context) {
    // Start batcher goroutine
    p.wg.Add(1)
    go p.batcher(ctx)
    
    // Start worker pool
    for i := 0; i < p.config.MaxConcurrency; i++ {
        p.wg.Add(1)
        go p.worker(ctx)
    }
}

// Submit adds a job to the processing queue.
func (p *Processor[T]) Submit(job Job[T]) error {
    if job.ID == "" {
        job.ID = generateID()
    }
    if job.Created.IsZero() {
        job.Created = time.Now()
    }
    
    select {
    case p.jobQueue <- job:
        return nil
    default:
        return errors.New("queue is full")
    }
}

// SubmitMany adds multiple jobs efficiently.
func (p *Processor[T]) SubmitMany(jobs []Job[T]) error {
    for _, job := range jobs {
        if err := p.Submit(job); err != nil {
            return fmt.Errorf("submitting job %s: %w", job.ID, err)
        }
    }
    return nil
}

// Stop gracefully shuts down the processor.
func (p *Processor[T]) Stop() {
    close(p.done)
    p.wg.Wait()
}

// Flush processes all pending jobs and waits for completion.
func (p *Processor[T]) Flush(ctx context.Context) error {
    // Signal flush and wait for completion
    close(p.jobQueue)
    
    // Create new channels for remaining operations
    p.jobQueue = make(chan Job[T], p.config.QueueSize)
    
    // Wait for all workers to finish
    done := make(chan struct{})
    go func() {
        p.wg.Wait()
        close(done)
    }()
    
    select {
    case <-done:
        return nil
    case <-ctx.Done():
        return ctx.Err()
    }
}

// Stats returns processing statistics.
func (p *Processor[T]) Stats() (processed, failed int64) {
    p.mu.RLock()
    defer p.mu.RUnlock()
    return p.processed, p.failed
}

func (p *Processor[T]) batcher(ctx context.Context) {
    defer p.wg.Done()
    
    var batch []Job[T]
    ticker := time.NewTicker(p.config.BatchTimeout)
    defer ticker.Stop()
    
    flush := func() {
        if len(batch) > 0 {
            select {
            case p.batchQueue <- batch:
                batch = nil
            case <-ctx.Done():
                return
            case <-p.done:
                return
            }
        }
    }
    
    for {
        select {
        case job, ok := <-p.jobQueue:
            if !ok {
                flush()
                return
            }
            
            batch = append(batch, job)
            
            if len(batch) >= p.config.MaxBatchSize {
                flush()
                ticker.Reset(p.config.BatchTimeout)
            }
            
        case <-ticker.C:
            flush()
            
        case <-ctx.Done():
            return
            
        case <-p.done:
            return
        }
    }
}

func (p *Processor[T]) worker(ctx context.Context) {
    defer p.wg.Done()
    
    for {
        select {
        case batch, ok := <-p.batchQueue:
            if !ok {
                return
            }
            
            p.processBatch(ctx, batch)
            
        case <-ctx.Done():
            return
            
        case <-p.done:
            return
        }
    }
}

func (p *Processor[T]) processBatch(ctx context.Context, batch []Job[T]) {
    start := time.Now()
    results := p.handler(ctx, batch)
    
    p.mu.Lock()
    for _, result := range results {
        if result.Error != nil {
            p.failed++
            
            // Retry logic
            if result.Job.Retries < p.config.RetryAttempts {
                go func(job Job[T]) {
                    time.Sleep(p.config.RetryDelay * time.Duration(job.Retries+1))
                    job.Retries++
                    _ = p.Submit(job)
                }(result.Job)
            }
        } else {
            p.processed++
        }
    }
    p.mu.Unlock()
    
    // Log batch processing metrics
    duration := time.Since(start)
    fmt.Printf("Processed batch of %d jobs in %v\n", len(batch), duration)
}

func generateID() string {
    return fmt.Sprintf("%d", time.Now().UnixNano())
}
```

### 2. Priority Queue Background Processor

```go
package background

import (
    "container/heap"
    "context"
    "sync"
    "time"
)

// Priority levels for job processing.
const (
    PriorityLow int = iota
    PriorityNormal
    PriorityHigh
    PriorityCritical
)

// PriorityJob extends Job with priority information.
type PriorityJob[T any] struct {
    Job[T]
    Priority int
    ScheduledAt time.Time
}

// PriorityQueue implements heap.Interface for priority-based job ordering.
type PriorityQueue[T any] struct {
    jobs []PriorityJob[T]
    mu   sync.RWMutex
}

func NewPriorityQueue[T any]() *PriorityQueue[T] {
    pq := &PriorityQueue[T]{
        jobs: make([]PriorityJob[T], 0),
    }
    heap.Init(pq)
    return pq
}

func (pq *PriorityQueue[T]) Len() int {
    pq.mu.RLock()
    defer pq.mu.RUnlock()
    return len(pq.jobs)
}

func (pq *PriorityQueue[T]) Less(i, j int) bool {
    pq.mu.RLock()
    defer pq.mu.RUnlock()
    
    // Higher priority first, then by scheduled time
    if pq.jobs[i].Priority != pq.jobs[j].Priority {
        return pq.jobs[i].Priority > pq.jobs[j].Priority
    }
    return pq.jobs[i].ScheduledAt.Before(pq.jobs[j].ScheduledAt)
}

func (pq *PriorityQueue[T]) Swap(i, j int) {
    pq.mu.Lock()
    defer pq.mu.Unlock()
    pq.jobs[i], pq.jobs[j] = pq.jobs[j], pq.jobs[i]
}

func (pq *PriorityQueue[T]) Push(x interface{}) {
    pq.mu.Lock()
    defer pq.mu.Unlock()
    pq.jobs = append(pq.jobs, x.(PriorityJob[T]))
}

func (pq *PriorityQueue[T]) Pop() interface{} {
    pq.mu.Lock()
    defer pq.mu.Unlock()
    
    old := pq.jobs
    n := len(old)
    job := old[n-1]
    pq.jobs = old[0 : n-1]
    return job
}

// PriorityProcessor handles jobs with priority scheduling.
type PriorityProcessor[T any] struct {
    queue    *PriorityQueue[T]
    handler  Handler[T]
    config   Config
    
    done     chan struct{}
    wg       sync.WaitGroup
}

func NewPriorityProcessor[T any](handler Handler[T], config Config) *PriorityProcessor[T] {
    return &PriorityProcessor[T]{
        queue:   NewPriorityQueue[T](),
        handler: handler,
        config:  config,
        done:    make(chan struct{}),
    }
}

func (pp *PriorityProcessor[T]) Start(ctx context.Context) {
    for i := 0; i < pp.config.MaxConcurrency; i++ {
        pp.wg.Add(1)
        go pp.worker(ctx)
    }
}

func (pp *PriorityProcessor[T]) Submit(job Job[T], priority int, delay time.Duration) error {
    priorityJob := PriorityJob[T]{
        Job:         job,
        Priority:    priority,
        ScheduledAt: time.Now().Add(delay),
    }
    
    pp.queue.mu.Lock()
    heap.Push(pp.queue, priorityJob)
    pp.queue.mu.Unlock()
    
    return nil
}

func (pp *PriorityProcessor[T]) worker(ctx context.Context) {
    defer pp.wg.Done()
    
    ticker := time.NewTicker(pp.config.BatchTimeout)
    defer ticker.Stop()
    
    var batch []Job[T]
    
    for {
        select {
        case <-ticker.C:
            pp.processBatch(ctx, &batch)
            
        case <-ctx.Done():
            return
            
        case <-pp.done:
            return
        }
    }
}

func (pp *PriorityProcessor[T]) processBatch(ctx context.Context, batch *[]Job[T]) {
    now := time.Now()
    
    // Collect ready jobs up to batch size
    for len(*batch) < pp.config.MaxBatchSize && pp.queue.Len() > 0 {
        pp.queue.mu.Lock()
        if pp.queue.Len() > 0 {
            priorityJob := heap.Pop(pp.queue).(PriorityJob[T])
            pp.queue.mu.Unlock()
            
            if priorityJob.ScheduledAt.Before(now) || priorityJob.ScheduledAt.Equal(now) {
                *batch = append(*batch, priorityJob.Job)
            } else {
                // Put back if not ready
                pp.queue.mu.Lock()
                heap.Push(pp.queue, priorityJob)
                pp.queue.mu.Unlock()
                break
            }
        } else {
            pp.queue.mu.Unlock()
            break
        }
    }
    
    if len(*batch) > 0 {
        results := pp.handler(ctx, *batch)
        pp.handleResults(results)
        *batch = (*batch)[:0] // Clear batch
    }
}

func (pp *PriorityProcessor[T]) handleResults(results []Result[T]) {
    for _, result := range results {
        if result.Error != nil && result.Job.Retries < pp.config.RetryAttempts {
            // Retry with exponential backoff
            delay := pp.config.RetryDelay * time.Duration(1<<result.Job.Retries)
            result.Job.Retries++
            _ = pp.Submit(result.Job, PriorityLow, delay)
        }
    }
}

func (pp *PriorityProcessor[T]) Stop() {
    close(pp.done)
    pp.wg.Wait()
}
```

### 3. Cache-Aware Background Processor

```go
// CacheProcessor optimizes database access through intelligent batching.
type CacheProcessor[K comparable, V any] struct {
    cache       Cache
    db          Database[K, V]
    singleflight *singleflight.Group
    
    cacheQueue  chan K
    dbQueue     chan K
    promises    map[K][]*Promise[V]
    
    config      Config
    done        chan struct{}
    wg          sync.WaitGroup
    mu          sync.RWMutex
}

type Promise[V any] struct {
    ch chan Result[V]
}

type Database[K comparable, V any] interface {
    GetMany(ctx context.Context, keys []K) (map[K]V, error)
}

type Cache interface {
    MGet(ctx context.Context, keys []string) (map[string][]byte, error)
    MSet(ctx context.Context, data map[string][]byte, ttl time.Duration) error
}

func NewCacheProcessor[K comparable, V any](
    cache Cache,
    db Database[K, V],
    config Config,
) *CacheProcessor[K, V] {
    return &CacheProcessor[K, V]{
        cache:        cache,
        db:           db,
        singleflight: &singleflight.Group{},
        cacheQueue:   make(chan K, config.QueueSize),
        dbQueue:      make(chan K, config.QueueSize),
        promises:     make(map[K][]*Promise[V]),
        config:       config,
        done:         make(chan struct{}),
    }
}

func (cp *CacheProcessor[K, V]) Start(ctx context.Context) {
    // Cache batch processor
    cp.wg.Add(1)
    go cp.cacheBatcher(ctx)
    
    // DB batch processor  
    cp.wg.Add(1)
    go cp.dbBatcher(ctx)
    
    // Cache workers
    for i := 0; i < cp.config.MaxConcurrency; i++ {
        cp.wg.Add(1)
        go cp.cacheWorker(ctx)
    }
    
    // DB workers
    for i := 0; i < cp.config.MaxConcurrency/2; i++ {
        cp.wg.Add(1)
        go cp.dbWorker(ctx)
    }
}

func (cp *CacheProcessor[K, V]) Get(ctx context.Context, key K) (V, error) {
    var zero V
    
    // Use singleflight to prevent duplicate requests
    result, err, _ := cp.singleflight.Do(fmt.Sprintf("%v", key), func() (interface{}, error) {
        promise := &Promise[V]{ch: make(chan Result[V], 1)}
        
        cp.mu.Lock()
        cp.promises[key] = append(cp.promises[key], promise)
        cp.mu.Unlock()
        
        // Submit to cache queue first
        select {
        case cp.cacheQueue <- key:
        case <-ctx.Done():
            return zero, ctx.Err()
        }
        
        // Wait for result
        select {
        case result := <-promise.ch:
            return result.Value, result.Error
        case <-ctx.Done():
            return zero, ctx.Err()
        }
    })
    
    if err != nil {
        return zero, err
    }
    
    return result.(V), nil
}

func (cp *CacheProcessor[K, V]) cacheBatcher(ctx context.Context) {
    defer cp.wg.Done()
    
    var batch []K
    ticker := time.NewTicker(cp.config.BatchTimeout)
    defer ticker.Stop()
    
    for {
        select {
        case key := <-cp.cacheQueue:
            batch = append(batch, key)
            
            if len(batch) >= cp.config.MaxBatchSize {
                cp.processCacheBatch(ctx, batch)
                batch = nil
                ticker.Reset(cp.config.BatchTimeout)
            }
            
        case <-ticker.C:
            if len(batch) > 0 {
                cp.processCacheBatch(ctx, batch)
                batch = nil
            }
            
        case <-ctx.Done():
            return
        case <-cp.done:
            return
        }
    }
}

func (cp *CacheProcessor[K, V]) processCacheBatch(ctx context.Context, keys []K) {
    // Convert keys to cache keys
    cacheKeys := make([]string, len(keys))
    for i, key := range keys {
        cacheKeys[i] = fmt.Sprintf("item:%v", key)
    }
    
    // Get from cache
    cached, err := cp.cache.MGet(ctx, cacheKeys)
    if err != nil {
        // On cache error, send all to DB
        for _, key := range keys {
            select {
            case cp.dbQueue <- key:
            case <-ctx.Done():
                return
            }
        }
        return
    }
    
    // Process cache results
    for i, key := range keys {
        cacheKey := cacheKeys[i]
        
        if data, exists := cached[cacheKey]; exists {
            // Cache hit - deserialize and resolve
            var value V
            if err := json.Unmarshal(data, &value); err == nil {
                cp.resolvePromises(key, value, nil)
            } else {
                // Deserialization error, fetch from DB
                select {
                case cp.dbQueue <- key:
                case <-ctx.Done():
                    return
                }
            }
        } else {
            // Cache miss - send to DB queue
            select {
            case cp.dbQueue <- key:
            case <-ctx.Done():
                return
            }
        }
    }
}

func (cp *CacheProcessor[K, V]) dbBatcher(ctx context.Context) {
    defer cp.wg.Done()
    
    var batch []K
    ticker := time.NewTicker(cp.config.BatchTimeout)
    defer ticker.Stop()
    
    for {
        select {
        case key := <-cp.dbQueue:
            batch = append(batch, key)
            
            if len(batch) >= cp.config.MaxBatchSize/2 { // Smaller batches for DB
                cp.processDBBatch(ctx, batch)
                batch = nil
                ticker.Reset(cp.config.BatchTimeout)
            }
            
        case <-ticker.C:
            if len(batch) > 0 {
                cp.processDBBatch(ctx, batch)
                batch = nil
            }
            
        case <-ctx.Done():
            return
        case <-cp.done:
            return
        }
    }
}

func (cp *CacheProcessor[K, V]) processDBBatch(ctx context.Context, keys []K) {
    // Fetch from database
    results, err := cp.db.GetMany(ctx, keys)
    if err != nil {
        // Resolve all with error
        for _, key := range keys {
            cp.resolvePromises(key, *new(V), err)
        }
        return
    }
    
    // Prepare cache data
    cacheData := make(map[string][]byte)
    
    for _, key := range keys {
        if value, exists := results[key]; exists {
            // Found in DB - cache and resolve
            if data, err := json.Marshal(value); err == nil {
                cacheKey := fmt.Sprintf("item:%v", key)
                cacheData[cacheKey] = data
            }
            cp.resolvePromises(key, value, nil)
        } else {
            // Not found in DB
            cp.resolvePromises(key, *new(V), errors.New("not found"))
            
            // Cache negative result with shorter TTL
            cacheKey := fmt.Sprintf("item:%v", key)
            cacheData[cacheKey] = []byte("null")
        }
    }
    
    // Set cache data
    if len(cacheData) > 0 {
        go func() {
            ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
            defer cancel()
            _ = cp.cache.MSet(ctx, cacheData, time.Hour)
        }()
    }
}

func (cp *CacheProcessor[K, V]) resolvePromises(key K, value V, err error) {
    cp.mu.Lock()
    promises := cp.promises[key]
    delete(cp.promises, key)
    cp.mu.Unlock()
    
    result := Result[V]{Value: value, Error: err}
    for _, promise := range promises {
        promise.ch <- result
    }
}

func (cp *CacheProcessor[K, V]) cacheWorker(ctx context.Context) {
    defer cp.wg.Done()
    // Worker implementation for cache operations
}

func (cp *CacheProcessor[K, V]) dbWorker(ctx context.Context) {
    defer cp.wg.Done()
    // Worker implementation for database operations
}

func (cp *CacheProcessor[K, V]) Stop() {
    close(cp.done)
    cp.wg.Wait()
}
```

### 4. Usage Examples and Testing

```go
// Example: Email notification processor
type EmailJob struct {
    To      string    `json:"to"`
    Subject string    `json:"subject"`
    Body    string    `json:"body"`
    Sent    time.Time `json:"sent,omitempty"`
}

func NewEmailProcessor() *Processor[EmailJob] {
    handler := func(ctx context.Context, jobs []Job[EmailJob]) []Result[EmailJob] {
        results := make([]Result[EmailJob], len(jobs))
        
        for i, job := range jobs {
            // Simulate sending email
            if err := sendEmail(job.Data); err != nil {
                results[i] = Result[EmailJob]{
                    Job:   job,
                    Error: fmt.Errorf("sending email to %s: %w", job.Data.To, err),
                }
            } else {
                job.Data.Sent = time.Now()
                results[i] = Result[EmailJob]{Job: job}
            }
        }
        
        return results
    }
    
    config := Config{
        MaxBatchSize:   50,
        BatchTimeout:   100 * time.Millisecond,
        QueueSize:      1000,
        MaxConcurrency: 5,
        RetryAttempts:  3,
        RetryDelay:     time.Second,
    }
    
    return NewProcessor(handler, config)
}

func sendEmail(email EmailJob) error {
    // Simulate email sending
    if email.To == "invalid@example.com" {
        return errors.New("invalid email address")
    }
    
    time.Sleep(10 * time.Millisecond) // Simulate network call
    return nil
}

// Testing background processors
func TestBackgroundProcessor(t *testing.T) {
    processor := NewEmailProcessor()
    
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    
    processor.Start(ctx)
    defer processor.Stop()
    
    t.Run("process single job", func(t *testing.T) {
        job := Job[EmailJob]{
            ID: "test-1",
            Data: EmailJob{
                To:      "user@example.com",
                Subject: "Test",
                Body:    "Hello World",
            },
        }
        
        err := processor.Submit(job)
        require.NoError(t, err)
        
        // Wait for processing
        time.Sleep(200 * time.Millisecond)
        
        processed, failed := processor.Stats()
        assert.Equal(t, int64(1), processed)
        assert.Equal(t, int64(0), failed)
    })
    
    t.Run("process batch of jobs", func(t *testing.T) {
        jobs := make([]Job[EmailJob], 100)
        for i := range jobs {
            jobs[i] = Job[EmailJob]{
                ID: fmt.Sprintf("batch-%d", i),
                Data: EmailJob{
                    To:      fmt.Sprintf("user%d@example.com", i),
                    Subject: "Batch Test",
                    Body:    "Batch processing",
                },
            }
        }
        
        err := processor.SubmitMany(jobs)
        require.NoError(t, err)
        
        // Wait for processing
        time.Sleep(time.Second)
        
        processed, _ := processor.Stats()
        assert.GreaterOrEqual(t, processed, int64(100))
    })
    
    t.Run("handle failures and retries", func(t *testing.T) {
        job := Job[EmailJob]{
            ID: "fail-test",
            Data: EmailJob{
                To:      "invalid@example.com", // Will cause error
                Subject: "Fail Test",
                Body:    "This should fail",
            },
        }
        
        err := processor.Submit(job)
        require.NoError(t, err)
        
        // Wait for retries
        time.Sleep(5 * time.Second)
        
        _, failed := processor.Stats()
        assert.Greater(t, failed, int64(0))
    })
}
```

## Consequences

**Benefits:**
- **Scalability**: Handle high-throughput job processing efficiently
- **Reliability**: Built-in retry logic and error handling
- **Performance**: Intelligent batching reduces overhead
- **Resource management**: Bounded queues and worker pools
- **Monitoring**: Built-in metrics and observability

**Trade-offs:**
- **Complexity**: Additional infrastructure and operational overhead
- **Latency**: Small delays due to batching
- **Memory usage**: In-memory queues consume resources
- **Failure scenarios**: Complex error handling and recovery logic

**Best Practices:**
- Use appropriate batch sizes based on operation characteristics
- Implement proper backpressure handling
- Monitor queue depths and processing latencies
- Use circuit breakers for external dependencies
- Implement graceful shutdown procedures
- Design idempotent job handlers

## References

- [Go Concurrency Patterns](https://blog.golang.org/concurrency-patterns)
- [Effective Go](https://golang.org/doc/effective_go.html)
- [Worker Pool Pattern](https://gobyexample.com/worker-pools)
// just batch
if cache
  cache.send(k)
else
  batch.send(k)

cacheBatch(n, func(keys) {
  kv := mget(keys)
  for k in keys {
    v, ok := kv[k]
    if ok {
      if v == notfound {
        pg[k].reject(notfound)
      } else {
        pg[k].resolve(v)
      }
    } else {
      db.send(k)
    }
  }
})
dbBatch(n/2, func(keys) {
  kv := sql.whereIn(keys)
  for k in keys {
    v, ok := kv[k]
    if ok {
      pg[k].resolve(v)
      if cache then cache.set(k, v, ttl) // mset can't ttl
    } else {
      pg[k].reject(keynotfound)
      if cache then cache.set(k, notfound, ttl/2)
    }
  }
})
```

actually we should just leave it to the batch function to decide:

```
kv = cache.mget(keys)
for k in keys
  v, ok = kv[k]
  if !ok {
     q.collect(k)
  } else {
     res[k] = v
  }
}
kv = db.load(q.keys)
for k in q.keys {
  v, ok = kv[k]
  if ok {
    cache.set(k, v, ttl)
  } else {
    cache.set(k, notfound, ttl/2)
  }
  res[k] = v
}
```

However, this might not optimize batching for the db if the cache hit is high.

So the first option has some merits.

```
done = make(chan bool)
ch = make(chan input)
ch = orDone(done, ch)
ch = batch(1000, 16ms)
ch = semaphore(numcpu, ch)
ch = map(ch, func() {
  // cache function
  resolve or reject cached keys
  return keys not found
})
ch = batch(100, 16ms)
ch = semaphore(numcpu, ch)
ch = map(ch, func() {
  // db function
  resolve or reject
  set cache
})
wait(ch)
```
