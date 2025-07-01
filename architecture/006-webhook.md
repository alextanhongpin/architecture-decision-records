# Webhook Architecture

## Status

`draft`

## Context

Webhooks provide a way for applications to provide real-time information to other applications through HTTP callbacks. They are essential for building event-driven integrations between services.

Key considerations for webhook architecture:
- Reliable delivery mechanisms
- Security and authentication
- Retry logic and failure handling
- Payload validation and transformation
- Monitoring and observability
- Rate limiting and throttling

## Decisions

### Webhook Provider Implementation

#### Basic Webhook Dispatcher

```go
type WebhookEvent struct {
    ID        string                 `json:"id"`
    Type      string                 `json:"type"`
    Data      map[string]interface{} `json:"data"`
    Timestamp time.Time              `json:"timestamp"`
}

type WebhookSubscription struct {
    ID       string   `json:"id"`
    URL      string   `json:"url"`
    Events   []string `json:"events"`
    Secret   string   `json:"secret"`
    Active   bool     `json:"active"`
    Headers  map[string]string `json:"headers,omitempty"`
}

type WebhookDispatcher struct {
    subscriptions map[string]*WebhookSubscription
    client        *http.Client
    retryQueue    chan RetryJob
    mutex         sync.RWMutex
}

func NewWebhookDispatcher() *WebhookDispatcher {
    return &WebhookDispatcher{
        subscriptions: make(map[string]*WebhookSubscription),
        client: &http.Client{
            Timeout: 30 * time.Second,
        },
        retryQueue: make(chan RetryJob, 1000),
    }
}

func (wd *WebhookDispatcher) Subscribe(subscription *WebhookSubscription) {
    wd.mutex.Lock()
    defer wd.mutex.Unlock()
    wd.subscriptions[subscription.ID] = subscription
}

func (wd *WebhookDispatcher) Dispatch(event WebhookEvent) {
    wd.mutex.RLock()
    defer wd.mutex.RUnlock()
    
    for _, subscription := range wd.subscriptions {
        if !subscription.Active {
            continue
        }
        
        // Check if subscription is interested in this event type
        if !wd.isInterestedInEvent(subscription, event.Type) {
            continue
        }
        
        go wd.sendWebhook(subscription, event)
    }
}

func (wd *WebhookDispatcher) sendWebhook(subscription *WebhookSubscription, event WebhookEvent) {
    payload, err := json.Marshal(event)
    if err != nil {
        log.Printf("Failed to marshal webhook payload: %v", err)
        return
    }
    
    req, err := http.NewRequest("POST", subscription.URL, bytes.NewBuffer(payload))
    if err != nil {
        log.Printf("Failed to create webhook request: %v", err)
        return
    }
    
    // Set headers
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("User-Agent", "MyApp-Webhooks/1.0")
    req.Header.Set("X-Webhook-Event", event.Type)
    req.Header.Set("X-Webhook-ID", event.ID)
    req.Header.Set("X-Webhook-Timestamp", event.Timestamp.Format(time.RFC3339))
    
    // Add custom headers
    for key, value := range subscription.Headers {
        req.Header.Set(key, value)
    }
    
    // Add signature for security
    if subscription.Secret != "" {
        signature := wd.generateSignature(payload, subscription.Secret)
        req.Header.Set("X-Webhook-Signature", signature)
    }
    
    resp, err := wd.client.Do(req)
    if err != nil {
        log.Printf("Webhook delivery failed: %v", err)
        wd.scheduleRetry(subscription, event, 1)
        return
    }
    defer resp.Body.Close()
    
    if resp.StatusCode >= 200 && resp.StatusCode < 300 {
        log.Printf("Webhook delivered successfully to %s", subscription.URL)
    } else {
        log.Printf("Webhook delivery failed with status %d", resp.StatusCode)
        wd.scheduleRetry(subscription, event, 1)
    }
}

func (wd *WebhookDispatcher) generateSignature(payload []byte, secret string) string {
    mac := hmac.New(sha256.New, []byte(secret))
    mac.Write(payload)
    return "sha256=" + hex.EncodeToString(mac.Sum(nil))
}

func (wd *WebhookDispatcher) isInterestedInEvent(subscription *WebhookSubscription, eventType string) bool {
    if len(subscription.Events) == 0 {
        return true // Subscribe to all events
    }
    
    for _, subscribedEvent := range subscription.Events {
        if subscribedEvent == eventType || subscribedEvent == "*" {
            return true
        }
    }
    
    return false
}
```

#### Retry Mechanism

```go
type RetryJob struct {
    Subscription *WebhookSubscription
    Event        WebhookEvent
    Attempt      int
    NextRetry    time.Time
}

func (wd *WebhookDispatcher) scheduleRetry(subscription *WebhookSubscription, event WebhookEvent, attempt int) {
    maxRetries := 5
    if attempt > maxRetries {
        log.Printf("Max retries exceeded for webhook %s", subscription.ID)
        wd.handleFailedWebhook(subscription, event, attempt)
        return
    }
    
    // Exponential backoff: 2^attempt minutes
    delay := time.Duration(math.Pow(2, float64(attempt))) * time.Minute
    
    retryJob := RetryJob{
        Subscription: subscription,
        Event:        event,
        Attempt:      attempt,
        NextRetry:    time.Now().Add(delay),
    }
    
    select {
    case wd.retryQueue <- retryJob:
    default:
        log.Printf("Retry queue full, dropping retry for webhook %s", subscription.ID)
    }
}

func (wd *WebhookDispatcher) StartRetryWorker() {
    ticker := time.NewTicker(1 * time.Minute)
    defer ticker.Stop()
    
    for {
        select {
        case retryJob := <-wd.retryQueue:
            if time.Now().After(retryJob.NextRetry) {
                go wd.retryWebhook(retryJob)
            } else {
                // Put it back in the queue
                go func() {
                    time.Sleep(time.Until(retryJob.NextRetry))
                    wd.retryQueue <- retryJob
                }()
            }
        case <-ticker.C:
            // Periodic cleanup or health checks
        }
    }
}

func (wd *WebhookDispatcher) retryWebhook(job RetryJob) {
    log.Printf("Retrying webhook %s (attempt %d)", job.Subscription.ID, job.Attempt)
    
    payload, _ := json.Marshal(job.Event)
    req, _ := http.NewRequest("POST", job.Subscription.URL, bytes.NewBuffer(payload))
    
    // Set headers (similar to sendWebhook)
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("X-Webhook-Retry", strconv.Itoa(job.Attempt))
    
    if job.Subscription.Secret != "" {
        signature := wd.generateSignature(payload, job.Subscription.Secret)
        req.Header.Set("X-Webhook-Signature", signature)
    }
    
    resp, err := wd.client.Do(req)
    if err != nil || resp.StatusCode >= 400 {
        wd.scheduleRetry(job.Subscription, job.Event, job.Attempt+1)
        return
    }
    defer resp.Body.Close()
    
    log.Printf("Webhook retry successful for %s", job.Subscription.ID)
}

func (wd *WebhookDispatcher) handleFailedWebhook(subscription *WebhookSubscription, event WebhookEvent, attempts int) {
    // Log to dead letter queue or alert system
    log.Printf("Webhook permanently failed: subscription=%s, event=%s, attempts=%d", 
        subscription.ID, event.ID, attempts)
    
    // Optionally disable the subscription after too many failures
    // subscription.Active = false
}
```

### Webhook Consumer/Receiver

#### Secure Webhook Receiver

```go
type WebhookReceiver struct {
    secret        string
    eventHandlers map[string]func(WebhookEvent) error
    mutex         sync.RWMutex
}

func NewWebhookReceiver(secret string) *WebhookReceiver {
    return &WebhookReceiver{
        secret:        secret,
        eventHandlers: make(map[string]func(WebhookEvent) error),
    }
}

func (wr *WebhookReceiver) RegisterHandler(eventType string, handler func(WebhookEvent) error) {
    wr.mutex.Lock()
    defer wr.mutex.Unlock()
    wr.eventHandlers[eventType] = handler
}

func (wr *WebhookReceiver) HandleWebhook(w http.ResponseWriter, r *http.Request) {
    // Verify HTTP method
    if r.Method != http.MethodPost {
        http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
        return
    }
    
    // Read body
    body, err := io.ReadAll(r.Body)
    if err != nil {
        http.Error(w, "Failed to read request body", http.StatusBadRequest)
        return
    }
    
    // Verify signature
    if wr.secret != "" {
        signature := r.Header.Get("X-Webhook-Signature")
        if !wr.verifySignature(body, signature) {
            http.Error(w, "Invalid signature", http.StatusUnauthorized)
            return
        }
    }
    
    // Parse webhook event
    var event WebhookEvent
    if err := json.Unmarshal(body, &event); err != nil {
        http.Error(w, "Invalid JSON payload", http.StatusBadRequest)
        return
    }
    
    // Check for replay attacks
    timestamp := r.Header.Get("X-Webhook-Timestamp")
    if timestamp != "" {
        if !wr.isValidTimestamp(timestamp) {
            http.Error(w, "Request too old", http.StatusUnauthorized)
            return
        }
    }
    
    // Handle the event
    wr.mutex.RLock()
    handler, exists := wr.eventHandlers[event.Type]
    wr.mutex.RUnlock()
    
    if !exists {
        log.Printf("No handler for event type: %s", event.Type)
        w.WriteHeader(http.StatusOK) // Still return 200 to avoid retries
        return
    }
    
    if err := handler(event); err != nil {
        log.Printf("Handler failed for event %s: %v", event.ID, err)
        http.Error(w, "Handler failed", http.StatusInternalServerError)
        return
    }
    
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("OK"))
}

func (wr *WebhookReceiver) verifySignature(payload []byte, signature string) bool {
    if signature == "" {
        return false
    }
    
    // Remove "sha256=" prefix if present
    signature = strings.TrimPrefix(signature, "sha256=")
    
    mac := hmac.New(sha256.New, []byte(wr.secret))
    mac.Write(payload)
    expectedSignature := hex.EncodeToString(mac.Sum(nil))
    
    return hmac.Equal([]byte(signature), []byte(expectedSignature))
}

func (wr *WebhookReceiver) isValidTimestamp(timestampStr string) bool {
    timestamp, err := time.Parse(time.RFC3339, timestampStr)
    if err != nil {
        return false
    }
    
    // Allow up to 5 minutes of clock skew
    age := time.Since(timestamp)
    return age <= 5*time.Minute && age >= -5*time.Minute
}
```

### Idempotency and Deduplication

```go
type WebhookDeduplicator struct {
    processedEvents map[string]time.Time
    mutex          sync.RWMutex
    cleanupTicker  *time.Ticker
}

func NewWebhookDeduplicator() *WebhookDeduplicator {
    wd := &WebhookDeduplicator{
        processedEvents: make(map[string]time.Time),
        cleanupTicker:   time.NewTicker(1 * time.Hour),
    }
    
    go wd.cleanup()
    return wd
}

func (wd *WebhookDeduplicator) IsProcessed(eventID string) bool {
    wd.mutex.RLock()
    defer wd.mutex.RUnlock()
    
    _, exists := wd.processedEvents[eventID]
    return exists
}

func (wd *WebhookDeduplicator) MarkProcessed(eventID string) {
    wd.mutex.Lock()
    defer wd.mutex.Unlock()
    
    wd.processedEvents[eventID] = time.Now()
}

func (wd *WebhookDeduplicator) cleanup() {
    for range wd.cleanupTicker.C {
        wd.mutex.Lock()
        cutoff := time.Now().Add(-24 * time.Hour)
        
        for eventID, processedAt := range wd.processedEvents {
            if processedAt.Before(cutoff) {
                delete(wd.processedEvents, eventID)
            }
        }
        wd.mutex.Unlock()
    }
}

// Enhanced webhook receiver with deduplication
func (wr *WebhookReceiver) HandleWebhookWithDeduplication(w http.ResponseWriter, r *http.Request, deduplicator *WebhookDeduplicator) {
    // ... existing validation code ...
    
    var event WebhookEvent
    if err := json.Unmarshal(body, &event); err != nil {
        http.Error(w, "Invalid JSON payload", http.StatusBadRequest)
        return
    }
    
    // Check for duplicate
    if deduplicator.IsProcessed(event.ID) {
        log.Printf("Duplicate webhook event received: %s", event.ID)
        w.WriteHeader(http.StatusOK)
        return
    }
    
    // Process the event
    wr.mutex.RLock()
    handler, exists := wr.eventHandlers[event.Type]
    wr.mutex.RUnlock()
    
    if exists {
        if err := handler(event); err != nil {
            log.Printf("Handler failed for event %s: %v", event.ID, err)
            http.Error(w, "Handler failed", http.StatusInternalServerError)
            return
        }
    }
    
    // Mark as processed only after successful handling
    deduplicator.MarkProcessed(event.ID)
    
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("OK"))
}
```

### Rate Limiting and Throttling

```go
type WebhookRateLimiter struct {
    limiters map[string]*rate.Limiter
    mutex    sync.RWMutex
}

func NewWebhookRateLimiter() *WebhookRateLimiter {
    return &WebhookRateLimiter{
        limiters: make(map[string]*rate.Limiter),
    }
}

func (wrl *WebhookRateLimiter) AllowWebhook(subscriptionID string) bool {
    wrl.mutex.RLock()
    limiter, exists := wrl.limiters[subscriptionID]
    wrl.mutex.RUnlock()
    
    if !exists {
        wrl.mutex.Lock()
        // Double-check after acquiring write lock
        if limiter, exists = wrl.limiters[subscriptionID]; !exists {
            // Allow 10 requests per minute
            limiter = rate.NewLimiter(rate.Every(6*time.Second), 10)
            wrl.limiters[subscriptionID] = limiter
        }
        wrl.mutex.Unlock()
    }
    
    return limiter.Allow()
}

// Enhanced dispatcher with rate limiting
func (wd *WebhookDispatcher) sendWebhookWithRateLimit(subscription *WebhookSubscription, event WebhookEvent, rateLimiter *WebhookRateLimiter) {
    if !rateLimiter.AllowWebhook(subscription.ID) {
        log.Printf("Rate limit exceeded for webhook %s", subscription.ID)
        wd.scheduleRetry(subscription, event, 1)
        return
    }
    
    // ... existing webhook sending code ...
}
```

### Monitoring and Observability

```go
type WebhookMetrics struct {
    TotalSent     int64
    TotalFailed   int64
    TotalRetries  int64
    ResponseTimes []time.Duration
    mutex         sync.RWMutex
}

func (wm *WebhookMetrics) RecordSent() {
    atomic.AddInt64(&wm.TotalSent, 1)
}

func (wm *WebhookMetrics) RecordFailed() {
    atomic.AddInt64(&wm.TotalFailed, 1)
}

func (wm *WebhookMetrics) RecordRetry() {
    atomic.AddInt64(&wm.TotalRetries, 1)
}

func (wm *WebhookMetrics) RecordResponseTime(duration time.Duration) {
    wm.mutex.Lock()
    defer wm.mutex.Unlock()
    wm.ResponseTimes = append(wm.ResponseTimes, duration)
    
    // Keep only last 1000 response times
    if len(wm.ResponseTimes) > 1000 {
        wm.ResponseTimes = wm.ResponseTimes[len(wm.ResponseTimes)-1000:]
    }
}

func (wm *WebhookMetrics) GetSuccessRate() float64 {
    total := atomic.LoadInt64(&wm.TotalSent)
    failed := atomic.LoadInt64(&wm.TotalFailed)
    
    if total == 0 {
        return 0
    }
    
    return float64(total-failed) / float64(total) * 100
}
```

## Consequences

### Benefits
- **Real-time integration**: Immediate notification of events
- **Decoupling**: Services don't need to poll for updates
- **Efficiency**: Reduces unnecessary API calls
- **Scalability**: Event-driven architecture scales well

### Challenges
- **Reliability**: Network issues can cause delivery failures
- **Security**: Need to verify webhook authenticity
- **Ordering**: Events may arrive out of order
- **Debugging**: Harder to trace webhook delivery issues

### Best Practices
- Always verify webhook signatures
- Implement idempotency in webhook handlers
- Use exponential backoff for retries
- Log all webhook activities for debugging
- Implement rate limiting to prevent abuse
- Use HTTPS for all webhook URLs
- Handle timeouts gracefully
- Provide webhook testing tools for consumers

### Security Considerations
- Validate webhook signatures using HMAC
- Check timestamp to prevent replay attacks
- Use HTTPS to encrypt webhook payloads
- Implement IP allowlisting when possible
- Rate limit webhook endpoints
- Sanitize all incoming data