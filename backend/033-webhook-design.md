# Webhook Design

## Status
Accepted

## Context
Webhooks are HTTP callbacks that enable real-time communication between systems by allowing services to notify other applications when specific events occur. Proper webhook design is crucial for building reliable, secure, and scalable integrations.

## Decision
We will implement a comprehensive webhook system that includes secure payload verification, reliable delivery mechanisms, proper error handling, and observability features to enable robust event-driven integrations.

## Rationale

### Benefits
- **Real-time Communication**: Immediate notification of events without polling
- **Decoupled Architecture**: Loose coupling between services
- **Scalability**: Efficient resource utilization compared to polling
- **Flexibility**: Consumers can react to events as needed
- **Integration-Friendly**: Standard HTTP-based communication

### Use Cases
- Payment processing notifications
- User account changes
- Order status updates
- Third-party service integrations
- System-to-system event notifications

## Implementation

### Core Webhook Infrastructure

```go
package webhook

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"
)

// Event represents a webhook event
type Event struct {
	ID        string                 `json:"id"`
	Type      string                 `json:"type"`
	Timestamp time.Time              `json:"timestamp"`
	Data      map[string]interface{} `json:"data"`
	Version   string                 `json:"version"`
	Source    string                 `json:"source"`
}

// Webhook represents a webhook configuration
type Webhook struct {
	ID          string            `json:"id"`
	URL         string            `json:"url"`
	Secret      string            `json:"secret"`
	Events      []string          `json:"events"`
	Headers     map[string]string `json:"headers"`
	Active      bool              `json:"active"`
	CreatedAt   time.Time         `json:"created_at"`
	UpdatedAt   time.Time         `json:"updated_at"`
	RetryConfig RetryConfig       `json:"retry_config"`
}

// RetryConfig defines retry behavior for failed deliveries
type RetryConfig struct {
	MaxAttempts int           `json:"max_attempts"`
	InitialDelay time.Duration `json:"initial_delay"`
	MaxDelay     time.Duration `json:"max_delay"`
	Multiplier   float64       `json:"multiplier"`
}

// DeliveryAttempt represents a webhook delivery attempt
type DeliveryAttempt struct {
	ID           string        `json:"id"`
	WebhookID    string        `json:"webhook_id"`
	EventID      string        `json:"event_id"`
	Attempt      int           `json:"attempt"`
	Status       string        `json:"status"`
	ResponseCode int           `json:"response_code"`
	ResponseBody string        `json:"response_body"`
	Duration     time.Duration `json:"duration"`
	Error        string        `json:"error,omitempty"`
	Timestamp    time.Time     `json:"timestamp"`
}

// WebhookService manages webhook operations
type WebhookService struct {
	store      WebhookStore
	httpClient *http.Client
	signer     *SignatureService
}

// WebhookStore interface for webhook persistence
type WebhookStore interface {
	Create(ctx context.Context, webhook *Webhook) error
	Get(ctx context.Context, id string) (*Webhook, error)
	List(ctx context.Context, filters map[string]interface{}) ([]*Webhook, error)
	Update(ctx context.Context, webhook *Webhook) error
	Delete(ctx context.Context, id string) error
	GetByEvents(ctx context.Context, eventTypes []string) ([]*Webhook, error)
	SaveDeliveryAttempt(ctx context.Context, attempt *DeliveryAttempt) error
	GetDeliveryAttempts(ctx context.Context, webhookID string, limit int) ([]*DeliveryAttempt, error)
}

func NewWebhookService(store WebhookStore, httpClient *http.Client) *WebhookService {
	if httpClient == nil {
		httpClient = &http.Client{
			Timeout: 10 * time.Second,
		}
	}

	return &WebhookService{
		store:      store,
		httpClient: httpClient,
		signer:     NewSignatureService(),
	}
}

// PublishEvent publishes an event to all registered webhooks
func (ws *WebhookService) PublishEvent(ctx context.Context, event *Event) error {
	webhooks, err := ws.store.GetByEvents(ctx, []string{event.Type})
	if err != nil {
		return fmt.Errorf("failed to get webhooks for event %s: %w", event.Type, err)
	}

	for _, webhook := range webhooks {
		if !webhook.Active {
			continue
		}

		// Deliver asynchronously
		go func(wh *Webhook) {
			if err := ws.deliverEvent(ctx, wh, event); err != nil {
				// Log error, could also emit metrics here
				fmt.Printf("Failed to deliver event %s to webhook %s: %v\n", event.ID, wh.ID, err)
			}
		}(webhook)
	}

	return nil
}

// deliverEvent delivers an event to a specific webhook with retry logic
func (ws *WebhookService) deliverEvent(ctx context.Context, webhook *Webhook, event *Event) error {
	payload, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to marshal event: %w", err)
	}

	for attempt := 1; attempt <= webhook.RetryConfig.MaxAttempts; attempt++ {
		deliveryAttempt := &DeliveryAttempt{
			ID:        generateID(),
			WebhookID: webhook.ID,
			EventID:   event.ID,
			Attempt:   attempt,
			Timestamp: time.Now(),
		}

		success, err := ws.sendRequest(ctx, webhook, payload, deliveryAttempt)
		
		// Save delivery attempt
		if saveErr := ws.store.SaveDeliveryAttempt(ctx, deliveryAttempt); saveErr != nil {
			fmt.Printf("Failed to save delivery attempt: %v\n", saveErr)
		}

		if success {
			deliveryAttempt.Status = "success"
			break
		}

		deliveryAttempt.Status = "failed"
		if err != nil {
			deliveryAttempt.Error = err.Error()
		}

		// Calculate backoff delay
		if attempt < webhook.RetryConfig.MaxAttempts {
			delay := ws.calculateBackoffDelay(attempt, webhook.RetryConfig)
			time.Sleep(delay)
		}
	}

	return nil
}

// sendRequest sends HTTP request to webhook endpoint
func (ws *WebhookService) sendRequest(ctx context.Context, webhook *Webhook, payload []byte, attempt *DeliveryAttempt) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, "POST", webhook.URL, bytes.NewBuffer(payload))
	if err != nil {
		return false, fmt.Errorf("failed to create request: %w", err)
	}

	// Set headers
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "YourApp-Webhook/1.0")
	req.Header.Set("X-Webhook-Event-Type", "")
	req.Header.Set("X-Webhook-Delivery-ID", attempt.ID)
	req.Header.Set("X-Webhook-Timestamp", strconv.FormatInt(attempt.Timestamp.Unix(), 10))

	// Add custom headers
	for key, value := range webhook.Headers {
		req.Header.Set(key, value)
	}

	// Sign payload
	signature := ws.signer.Sign(webhook.Secret, payload)
	req.Header.Set("X-Webhook-Signature-256", "sha256="+signature)

	start := time.Now()
	resp, err := ws.httpClient.Do(req)
	attempt.Duration = time.Since(start)

	if err != nil {
		return false, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	attempt.ResponseCode = resp.StatusCode

	// Read response body (limit size to prevent memory issues)
	bodyBuffer := make([]byte, 1024)
	n, _ := resp.Body.Read(bodyBuffer)
	attempt.ResponseBody = string(bodyBuffer[:n])

	// Consider 2xx status codes as successful
	return resp.StatusCode >= 200 && resp.StatusCode < 300, nil
}

// calculateBackoffDelay calculates exponential backoff delay
func (ws *WebhookService) calculateBackoffDelay(attempt int, config RetryConfig) time.Duration {
	delay := time.Duration(float64(config.InitialDelay) * (config.Multiplier * float64(attempt-1)))
	if delay > config.MaxDelay {
		delay = config.MaxDelay
	}
	return delay
}

// SignatureService handles webhook signature generation and verification
type SignatureService struct{}

func NewSignatureService() *SignatureService {
	return &SignatureService{}
}

// Sign creates HMAC-SHA256 signature for payload
func (s *SignatureService) Sign(secret string, payload []byte) string {
	secretBytes, _ := hex.DecodeString(secret)
	h := hmac.New(sha256.New, secretBytes)
	h.Write(payload)
	return hex.EncodeToString(h.Sum(nil))
}

// Verify verifies webhook signature with support for multiple secrets (for rotation)
func (s *SignatureService) Verify(secrets []string, payload []byte, signature string) bool {
	// Remove "sha256=" prefix if present
	if len(signature) > 7 && signature[:7] == "sha256=" {
		signature = signature[7:]
	}

	for _, secret := range secrets {
		expectedSignature := s.Sign(secret, payload)
		if hmac.Equal([]byte(signature), []byte(expectedSignature)) {
			return true
		}
	}
	return false
}

// GenerateSecret creates a new webhook secret
func (s *SignatureService) GenerateSecret(size int) (string, error) {
	if size <= 0 {
		size = 64 // Default 64 bytes (512 bits)
	}
	
	secret := make([]byte, size)
	if _, err := rand.Read(secret); err != nil {
		return "", fmt.Errorf("failed to generate secret: %w", err)
	}
	
	return hex.EncodeToString(secret), nil
}

func generateID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
```

### Webhook Registration and Management API

```go
package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"
	"your-app/webhook"
)

// WebhookHandler handles webhook management endpoints
type WebhookHandler struct {
	service *webhook.WebhookService
	signer  *webhook.SignatureService
}

func NewWebhookHandler(service *webhook.WebhookService) *WebhookHandler {
	return &WebhookHandler{
		service: service,
		signer:  webhook.NewSignatureService(),
	}
}

// CreateWebhook creates a new webhook
func (h *WebhookHandler) CreateWebhook(w http.ResponseWriter, r *http.Request) {
	var req struct {
		URL     string            `json:"url"`
		Events  []string          `json:"events"`
		Headers map[string]string `json:"headers,omitempty"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Validate URL
	if req.URL == "" {
		http.Error(w, "URL is required", http.StatusBadRequest)
		return
	}

	// Validate events
	if len(req.Events) == 0 {
		http.Error(w, "At least one event type is required", http.StatusBadRequest)
		return
	}

	// Generate secret
	secret, err := h.signer.GenerateSecret(64)
	if err != nil {
		http.Error(w, "Failed to generate secret", http.StatusInternalServerError)
		return
	}

	webhook := &webhook.Webhook{
		ID:      webhook.GenerateID(),
		URL:     req.URL,
		Secret:  secret,
		Events:  req.Events,
		Headers: req.Headers,
		Active:  true,
		CreatedAt: time.Now(),
		UpdatedAt: time.Now(),
		RetryConfig: webhook.RetryConfig{
			MaxAttempts:  5,
			InitialDelay: 1 * time.Second,
			MaxDelay:     300 * time.Second,
			Multiplier:   2.0,
		},
	}

	if err := h.service.Create(r.Context(), webhook); err != nil {
		http.Error(w, "Failed to create webhook", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(webhook)
}

// GetWebhook retrieves a webhook by ID
func (h *WebhookHandler) GetWebhook(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		http.Error(w, "Webhook ID is required", http.StatusBadRequest)
		return
	}

	webhook, err := h.service.Get(r.Context(), id)
	if err != nil {
		http.Error(w, "Webhook not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(webhook)
}

// ListWebhooks lists all webhooks
func (h *WebhookHandler) ListWebhooks(w http.ResponseWriter, r *http.Request) {
	filters := make(map[string]interface{})
	
	// Add query parameter filters
	if eventType := r.URL.Query().Get("event_type"); eventType != "" {
		filters["event_type"] = eventType
	}
	
	if activeStr := r.URL.Query().Get("active"); activeStr != "" {
		if active, err := strconv.ParseBool(activeStr); err == nil {
			filters["active"] = active
		}
	}

	webhooks, err := h.service.List(r.Context(), filters)
	if err != nil {
		http.Error(w, "Failed to list webhooks", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"webhooks": webhooks,
		"count":    len(webhooks),
	})
}

// UpdateWebhook updates an existing webhook
func (h *WebhookHandler) UpdateWebhook(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		http.Error(w, "Webhook ID is required", http.StatusBadRequest)
		return
	}

	webhook, err := h.service.Get(r.Context(), id)
	if err != nil {
		http.Error(w, "Webhook not found", http.StatusNotFound)
		return
	}

	var req struct {
		URL     *string            `json:"url,omitempty"`
		Events  []string          `json:"events,omitempty"`
		Headers map[string]string `json:"headers,omitempty"`
		Active  *bool             `json:"active,omitempty"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Update fields
	if req.URL != nil {
		webhook.URL = *req.URL
	}
	if req.Events != nil {
		webhook.Events = req.Events
	}
	if req.Headers != nil {
		webhook.Headers = req.Headers
	}
	if req.Active != nil {
		webhook.Active = *req.Active
	}
	webhook.UpdatedAt = time.Now()

	if err := h.service.Update(r.Context(), webhook); err != nil {
		http.Error(w, "Failed to update webhook", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(webhook)
}

// DeleteWebhook deletes a webhook
func (h *WebhookHandler) DeleteWebhook(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		http.Error(w, "Webhook ID is required", http.StatusBadRequest)
		return
	}

	if err := h.service.Delete(r.Context(), id); err != nil {
		http.Error(w, "Failed to delete webhook", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// GetDeliveryAttempts retrieves delivery attempts for a webhook
func (h *WebhookHandler) GetDeliveryAttempts(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		http.Error(w, "Webhook ID is required", http.StatusBadRequest)
		return
	}

	limit := 50
	if limitStr := r.URL.Query().Get("limit"); limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 && l <= 100 {
			limit = l
		}
	}

	attempts, err := h.service.GetDeliveryAttempts(r.Context(), id, limit)
	if err != nil {
		http.Error(w, "Failed to get delivery attempts", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"attempts": attempts,
		"count":    len(attempts),
	})
}

// RegenerateSecret generates a new secret for a webhook
func (h *WebhookHandler) RegenerateSecret(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		http.Error(w, "Webhook ID is required", http.StatusBadRequest)
		return
	}

	webhook, err := h.service.Get(r.Context(), id)
	if err != nil {
		http.Error(w, "Webhook not found", http.StatusNotFound)
		return
	}

	newSecret, err := h.signer.GenerateSecret(64)
	if err != nil {
		http.Error(w, "Failed to generate secret", http.StatusInternalServerError)
		return
	}

	webhook.Secret = newSecret
	webhook.UpdatedAt = time.Now()

	if err := h.service.Update(r.Context(), webhook); err != nil {
		http.Error(w, "Failed to update webhook", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"secret": newSecret,
	})
}
```

### Webhook Receiver Implementation

```go
package receiver

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
	"your-app/webhook"
)

// WebhookReceiver handles incoming webhook requests
type WebhookReceiver struct {
	secrets []string
	signer  *webhook.SignatureService
	handler WebhookEventHandler
}

// WebhookEventHandler processes validated webhook events
type WebhookEventHandler interface {
	Handle(event *webhook.Event) error
}

func NewWebhookReceiver(secrets []string, handler WebhookEventHandler) *WebhookReceiver {
	return &WebhookReceiver{
		secrets: secrets,
		signer:  webhook.NewSignatureService(),
		handler: handler,
	}
}

// HandleWebhook processes incoming webhook requests
func (wr *WebhookReceiver) HandleWebhook(w http.ResponseWriter, r *http.Request) {
	// Validate HTTP method
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Validate content type
	contentType := r.Header.Get("Content-Type")
	if !strings.HasPrefix(contentType, "application/json") {
		http.Error(w, "Invalid content type", http.StatusBadRequest)
		return
	}

	// Read and validate timestamp
	timestampStr := r.Header.Get("X-Webhook-Timestamp")
	if timestampStr == "" {
		http.Error(w, "Missing timestamp header", http.StatusBadRequest)
		return
	}

	timestamp, err := strconv.ParseInt(timestampStr, 10, 64)
	if err != nil {
		http.Error(w, "Invalid timestamp", http.StatusBadRequest)
		return
	}

	// Check timestamp tolerance (prevent replay attacks)
	now := time.Now().Unix()
	if now-timestamp > 300 { // 5 minutes tolerance
		http.Error(w, "Request too old", http.StatusBadRequest)
		return
	}

	// Read request body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read body", http.StatusBadRequest)
		return
	}

	// Verify signature
	signature := r.Header.Get("X-Webhook-Signature-256")
	if signature == "" {
		http.Error(w, "Missing signature", http.StatusUnauthorized)
		return
	}

	if !wr.signer.Verify(wr.secrets, body, signature) {
		http.Error(w, "Invalid signature", http.StatusUnauthorized)
		return
	}

	// Parse event
	var event webhook.Event
	if err := json.Unmarshal(body, &event); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	// Process event
	if err := wr.handler.Handle(&event); err != nil {
		// Log error but return 200 to prevent retries for invalid events
		// Use 500 only for temporary failures that should be retried
		http.Error(w, "Processing failed", http.StatusInternalServerError)
		return
	}

	// Return success
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

// Example event handler implementation
type DefaultEventHandler struct{}

func (h *DefaultEventHandler) Handle(event *webhook.Event) error {
	switch event.Type {
	case "user.created":
		return h.handleUserCreated(event)
	case "user.updated":
		return h.handleUserUpdated(event)
	case "order.completed":
		return h.handleOrderCompleted(event)
	default:
		// Unknown event type - log but don't error
		return nil
	}
}

func (h *DefaultEventHandler) handleUserCreated(event *webhook.Event) error {
	// Process user creation event
	return nil
}

func (h *DefaultEventHandler) handleUserUpdated(event *webhook.Event) error {
	// Process user update event
	return nil
}

func (h *DefaultEventHandler) handleOrderCompleted(event *webhook.Event) error {
	// Process order completion event
	return nil
}
```

### Testing Utilities

```go
package webhook_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
	"your-app/webhook"
)

// TestWebhookDelivery tests webhook delivery functionality
func TestWebhookDelivery(t *testing.T) {
	// Create test server
	var receivedEvent *webhook.Event
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var event webhook.Event
		json.NewDecoder(r.Body).Decode(&event)
		receivedEvent = &event
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	// Create webhook service
	store := &MockWebhookStore{}
	service := webhook.NewWebhookService(store, nil)

	// Create test webhook
	testWebhook := &webhook.Webhook{
		ID:     "test-webhook",
		URL:    server.URL,
		Secret: "test-secret",
		Events: []string{"test.event"},
		Active: true,
		RetryConfig: webhook.RetryConfig{
			MaxAttempts:  3,
			InitialDelay: 100 * time.Millisecond,
			MaxDelay:     1 * time.Second,
			Multiplier:   2.0,
		},
	}

	store.webhooks["test-webhook"] = testWebhook

	// Publish test event
	event := &webhook.Event{
		ID:        "test-event",
		Type:      "test.event",
		Timestamp: time.Now(),
		Data:      map[string]interface{}{"test": "data"},
		Version:   "1.0",
		Source:    "test-service",
	}

	err := service.PublishEvent(context.Background(), event)
	if err != nil {
		t.Fatalf("Failed to publish event: %v", err)
	}

	// Wait for delivery
	time.Sleep(200 * time.Millisecond)

	if receivedEvent == nil {
		t.Fatal("Event was not delivered")
	}

	if receivedEvent.ID != event.ID {
		t.Errorf("Expected event ID %s, got %s", event.ID, receivedEvent.ID)
	}
}

// TestSignatureVerification tests signature verification
func TestSignatureVerification(t *testing.T) {
	signer := webhook.NewSignatureService()
	
	secret := "test-secret"
	payload := []byte(`{"test": "data"}`)
	
	signature := signer.Sign(secret, payload)
	
	if !signer.Verify([]string{secret}, payload, signature) {
		t.Error("Signature verification failed")
	}
	
	if signer.Verify([]string{secret}, payload, "invalid-signature") {
		t.Error("Invalid signature was accepted")
	}
}

// MockWebhookStore for testing
type MockWebhookStore struct {
	webhooks map[string]*webhook.Webhook
	attempts map[string][]*webhook.DeliveryAttempt
}

func (m *MockWebhookStore) GetByEvents(ctx context.Context, eventTypes []string) ([]*webhook.Webhook, error) {
	var result []*webhook.Webhook
	for _, wh := range m.webhooks {
		for _, eventType := range eventTypes {
			for _, whEvent := range wh.Events {
				if whEvent == eventType {
					result = append(result, wh)
					break
				}
			}
		}
	}
	return result, nil
}

func (m *MockWebhookStore) SaveDeliveryAttempt(ctx context.Context, attempt *webhook.DeliveryAttempt) error {
	if m.attempts == nil {
		m.attempts = make(map[string][]*webhook.DeliveryAttempt)
	}
	m.attempts[attempt.WebhookID] = append(m.attempts[attempt.WebhookID], attempt)
	return nil
}

// Additional mock methods...
func (m *MockWebhookStore) Create(ctx context.Context, webhook *webhook.Webhook) error { return nil }
func (m *MockWebhookStore) Get(ctx context.Context, id string) (*webhook.Webhook, error) { return m.webhooks[id], nil }
func (m *MockWebhookStore) List(ctx context.Context, filters map[string]interface{}) ([]*webhook.Webhook, error) { return nil, nil }
func (m *MockWebhookStore) Update(ctx context.Context, webhook *webhook.Webhook) error { return nil }
func (m *MockWebhookStore) Delete(ctx context.Context, id string) error { return nil }
func (m *MockWebhookStore) GetDeliveryAttempts(ctx context.Context, webhookID string, limit int) ([]*webhook.DeliveryAttempt, error) { return m.attempts[webhookID], nil }
```

## Best Practices

### 1. Security
- Always verify webhook signatures using HMAC-SHA256
- Support secret rotation with multiple valid secrets
- Implement timestamp validation to prevent replay attacks
- Use HTTPS for all webhook endpoints
- Validate and sanitize all incoming data

### 2. Reliability
- Implement exponential backoff for retries
- Set reasonable timeout limits
- Handle various HTTP status codes appropriately
- Provide idempotency for webhook processing
- Log all delivery attempts for debugging

### 3. Performance
- Process webhooks asynchronously when possible
- Implement rate limiting for webhook deliveries
- Use connection pooling for HTTP clients
- Consider webhook batching for high-volume scenarios
- Monitor webhook delivery performance

### 4. Observability
- Log all webhook events and delivery attempts
- Implement metrics for success/failure rates
- Provide dashboards for webhook monitoring
- Set up alerts for high failure rates
- Track webhook processing latency

### 5. User Experience
- Provide clear webhook configuration interfaces
- Support webhook testing and validation
- Offer delivery attempt history and debugging
- Implement webhook event filtering
- Provide comprehensive documentation

## Common Patterns

### Event Types
```go
const (
	EventUserCreated    = "user.created"
	EventUserUpdated    = "user.updated"
	EventUserDeleted    = "user.deleted"
	EventOrderPlaced    = "order.placed"
	EventOrderCompleted = "order.completed"
	EventPaymentSuccess = "payment.success"
	EventPaymentFailed  = "payment.failed"
)
```

### Headers
```go
// Standard webhook headers
headers := map[string]string{
	"Content-Type":             "application/json",
	"User-Agent":               "YourApp-Webhook/1.0",
	"X-Webhook-Event-Type":     event.Type,
	"X-Webhook-Delivery-ID":    deliveryID,
	"X-Webhook-Timestamp":      timestamp,
	"X-Webhook-Signature-256":  signature,
}
```

### Response Handling
```go
// Determine retry based on status code
func shouldRetry(statusCode int) bool {
	// Retry on server errors (5xx) and rate limiting (429)
	return statusCode >= 500 || statusCode == 429
}
```

## Consequences

### Positive
- Real-time event notification capabilities
- Reduced polling and improved efficiency
- Better system decoupling and integration
- Scalable event-driven architecture
- Industry-standard communication pattern

### Negative
- Increased complexity in error handling and retries
- Network reliability dependencies
- Security considerations with signature verification
- Debugging challenges with asynchronous delivery
- Potential for webhook endpoint failures

### Mitigation
- Implement comprehensive logging and monitoring
- Provide webhook testing and debugging tools
- Use circuit breakers for failing endpoints
- Implement proper error handling and retries
- Maintain webhook delivery history for troubleshooting

## Related Patterns
- [006-webhook.md](../architecture/006-webhook.md) - Webhook architecture patterns
- [025-json-response.md](025-json-response.md) - JSON response format for webhook payloads
- [004-use-rate-limiting.md](004-use-rate-limiting.md) - Rate limiting for webhook deliveries
- [013-logging.md](013-logging.md) - Logging webhook events and deliveries
```
