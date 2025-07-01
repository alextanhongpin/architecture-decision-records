# Notification System Design

## Status
Accepted

## Context
Modern applications require robust notification systems to engage users through multiple channels (email, SMS, push notifications, in-app messages). A well-designed notification system must handle high volume, provide reliable delivery, support multiple channels, and offer personalization while maintaining performance and user preferences.

## Problem
Building notification systems involves several complex challenges:

1. **Multi-channel complexity**: Supporting email, SMS, push, and in-app notifications
2. **Scale and performance**: Handling millions of notifications efficiently
3. **Delivery reliability**: Ensuring notifications are delivered despite failures
4. **User preferences**: Respecting user notification settings and frequency limits
5. **Template management**: Managing dynamic content across different channels
6. **Analytics and tracking**: Monitoring delivery rates and user engagement
7. **Compliance**: Following regulations like CAN-SPAM, GDPR

## Decision
We will implement a comprehensive notification system with the following architecture:

- **Multi-channel support** with unified API
- **Reliable delivery** using background job processing
- **Template engine** for dynamic content generation
- **User preference management** with granular controls
- **Rate limiting and frequency capping**
- **Comprehensive analytics and tracking**
- **Webhook support** for external integrations

## Architecture Overview

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Application   │───▶│  Notification   │───▶│   Background    │
│                 │    │     Service     │    │   Job Queue     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │                       │
                                ▼                       ▼
                        ┌─────────────────┐    ┌─────────────────┐
                        │   Template      │    │   Channel       │
                        │    Engine       │    │   Providers     │
                        └─────────────────┘    └─────────────────┘
                                                       │
                        ┌─────────────────┐            ▼
                        │  User Prefs &   │    ┌─────────────────┐
                        │  Rate Limiting  │    │  Email/SMS/Push │
                        └─────────────────┘    │    Providers    │
                                               └─────────────────┘
```

## Implementation

### Core Notification Service

```go
package notifications

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/google/uuid"
)

// NotificationService handles all notification operations
type NotificationService struct {
    repo          NotificationRepository
    templateEngine TemplateEngine
    jobQueue      JobQueue
    providers     map[Channel]Provider
    rateLimiter   RateLimiter
    analytics     AnalyticsService
}

// Notification represents a notification to be sent
type Notification struct {
    ID          string                 `json:"id"`
    UserID      string                 `json:"user_id"`
    Channel     Channel                `json:"channel"`
    Type        NotificationType       `json:"type"`
    Template    string                 `json:"template"`
    Data        map[string]interface{} `json:"data"`
    Priority    Priority               `json:"priority"`
    ScheduledAt time.Time              `json:"scheduled_at"`
    CreatedAt   time.Time              `json:"created_at"`
    Status      NotificationStatus     `json:"status"`
    Metadata    map[string]string      `json:"metadata"`
}

type Channel string

const (
    ChannelEmail   Channel = "email"
    ChannelSMS     Channel = "sms"
    ChannelPush    Channel = "push"
    ChannelInApp   Channel = "in_app"
    ChannelWebhook Channel = "webhook"
)

type NotificationType string

const (
    TypeWelcome         NotificationType = "welcome"
    TypePasswordReset   NotificationType = "password_reset"
    TypeOrderConfirm    NotificationType = "order_confirmation"
    TypePromotion       NotificationType = "promotion"
    TypeSystemAlert     NotificationType = "system_alert"
    TypeReminder        NotificationType = "reminder"
)

type Priority int

const (
    PriorityLow Priority = iota
    PriorityNormal
    PriorityHigh
    PriorityCritical
)

type NotificationStatus string

const (
    StatusPending    NotificationStatus = "pending"
    StatusQueued     NotificationStatus = "queued"
    StatusSending    NotificationStatus = "sending"
    StatusSent       NotificationStatus = "sent"
    StatusDelivered  NotificationStatus = "delivered"
    StatusFailed     NotificationStatus = "failed"
    StatusCancelled  NotificationStatus = "cancelled"
)

// NewNotificationService creates a new notification service
func NewNotificationService(
    repo NotificationRepository,
    templateEngine TemplateEngine,
    jobQueue JobQueue,
    rateLimiter RateLimiter,
    analytics AnalyticsService,
) *NotificationService {
    return &NotificationService{
        repo:          repo,
        templateEngine: templateEngine,
        jobQueue:      jobQueue,
        providers:     make(map[Channel]Provider),
        rateLimiter:   rateLimiter,
        analytics:     analytics,
    }
}

// RegisterProvider registers a channel provider
func (ns *NotificationService) RegisterProvider(channel Channel, provider Provider) {
    ns.providers[channel] = provider
}

// Send schedules a notification for delivery
func (ns *NotificationService) Send(ctx context.Context, req SendNotificationRequest) (*Notification, error) {
    // Validate request
    if err := ns.validateRequest(req); err != nil {
        return nil, fmt.Errorf("invalid request: %w", err)
    }
    
    // Check user preferences
    allowed, err := ns.checkUserPreferences(ctx, req.UserID, req.Channel, req.Type)
    if err != nil {
        return nil, fmt.Errorf("failed to check user preferences: %w", err)
    }
    if !allowed {
        return nil, fmt.Errorf("notification blocked by user preferences")
    }
    
    // Check rate limits
    allowed, err = ns.rateLimiter.Allow(ctx, req.UserID, req.Channel)
    if err != nil {
        return nil, fmt.Errorf("rate limiter error: %w", err)
    }
    if !allowed {
        return nil, fmt.Errorf("rate limit exceeded")
    }
    
    // Create notification record
    notification := &Notification{
        ID:          uuid.New().String(),
        UserID:      req.UserID,
        Channel:     req.Channel,
        Type:        req.Type,
        Template:    req.Template,
        Data:        req.Data,
        Priority:    req.Priority,
        ScheduledAt: req.ScheduledAt,
        CreatedAt:   time.Now(),
        Status:      StatusPending,
        Metadata:    req.Metadata,
    }
    
    // Save notification
    if err := ns.repo.Create(ctx, notification); err != nil {
        return nil, fmt.Errorf("failed to save notification: %w", err)
    }
    
    // Queue for processing
    jobData := map[string]interface{}{
        "notification_id": notification.ID,
    }
    
    jobOptions := []JobOption{
        WithPriority(int(req.Priority)),
        WithScheduledAt(req.ScheduledAt),
    }
    
    if req.ScheduledAt.IsZero() {
        jobOptions = append(jobOptions, WithScheduledAt(time.Now()))
    }
    
    _, err = ns.jobQueue.Enqueue(ctx, "send_notification", jobData, jobOptions...)
    if err != nil {
        // Update notification status
        notification.Status = StatusFailed
        ns.repo.Update(ctx, notification)
        return nil, fmt.Errorf("failed to queue notification: %w", err)
    }
    
    notification.Status = StatusQueued
    ns.repo.Update(ctx, notification)
    
    // Track analytics
    ns.analytics.TrackNotificationCreated(notification)
    
    return notification, nil
}

// SendNotificationRequest represents a request to send a notification
type SendNotificationRequest struct {
    UserID      string                 `json:"user_id" validate:"required"`
    Channel     Channel                `json:"channel" validate:"required"`
    Type        NotificationType       `json:"type" validate:"required"`
    Template    string                 `json:"template" validate:"required"`
    Data        map[string]interface{} `json:"data"`
    Priority    Priority               `json:"priority"`
    ScheduledAt time.Time              `json:"scheduled_at"`
    Metadata    map[string]string      `json:"metadata"`
}

// ProcessNotification processes a queued notification
func (ns *NotificationService) ProcessNotification(ctx context.Context, notificationID string) error {
    // Get notification
    notification, err := ns.repo.GetByID(ctx, notificationID)
    if err != nil {
        return fmt.Errorf("failed to get notification: %w", err)
    }
    
    // Update status
    notification.Status = StatusSending
    if err := ns.repo.Update(ctx, notification); err != nil {
        return fmt.Errorf("failed to update notification status: %w", err)
    }
    
    // Get provider
    provider, exists := ns.providers[notification.Channel]
    if !exists {
        return fmt.Errorf("no provider for channel: %s", notification.Channel)
    }
    
    // Render content
    content, err := ns.templateEngine.Render(ctx, notification.Template, notification.Data)
    if err != nil {
        ns.markFailed(ctx, notification, err)
        return fmt.Errorf("failed to render template: %w", err)
    }
    
    // Send notification
    result, err := provider.Send(ctx, SendRequest{
        UserID:       notification.UserID,
        Content:      content,
        Metadata:     notification.Metadata,
        Notification: notification,
    })
    
    if err != nil {
        ns.markFailed(ctx, notification, err)
        return fmt.Errorf("failed to send notification: %w", err)
    }
    
    // Update notification with result
    notification.Status = StatusSent
    notification.Metadata["provider_id"] = result.ProviderID
    notification.Metadata["provider_message_id"] = result.MessageID
    
    if err := ns.repo.Update(ctx, notification); err != nil {
        return fmt.Errorf("failed to update notification: %w", err)
    }
    
    // Track analytics
    ns.analytics.TrackNotificationSent(notification, result)
    
    return nil
}

// markFailed marks notification as failed
func (ns *NotificationService) markFailed(ctx context.Context, notification *Notification, err error) {
    notification.Status = StatusFailed
    notification.Metadata["error"] = err.Error()
    ns.repo.Update(ctx, notification)
    ns.analytics.TrackNotificationFailed(notification, err)
}

// validateRequest validates send notification request
func (ns *NotificationService) validateRequest(req SendNotificationRequest) error {
    if req.UserID == "" {
        return fmt.Errorf("user_id is required")
    }
    if req.Channel == "" {
        return fmt.Errorf("channel is required")
    }
    if req.Type == "" {
        return fmt.Errorf("type is required")
    }
    if req.Template == "" {
        return fmt.Errorf("template is required")
    }
    return nil
}

// checkUserPreferences checks if user allows this notification
func (ns *NotificationService) checkUserPreferences(ctx context.Context, userID string, channel Channel, notifType NotificationType) (bool, error) {
    // Implementation would check user preferences database
    // This is a simplified version
    return true, nil
}
```

### Template Engine

```go
package notifications

import (
    "bytes"
    "context"
    "fmt"
    "html/template"
    "strings"
    "sync"
)

// TemplateEngine handles notification template rendering
type TemplateEngine struct {
    templates map[string]*NotificationTemplate
    funcMap   template.FuncMap
    mu        sync.RWMutex
}

// NotificationTemplate represents a multi-channel template
type NotificationTemplate struct {
    ID          string            `json:"id"`
    Name        string            `json:"name"`
    Subject     string            `json:"subject,omitempty"`     // For email
    Body        string            `json:"body"`
    HTMLBody    string            `json:"html_body,omitempty"`   // For email
    SMSBody     string            `json:"sms_body,omitempty"`    // For SMS
    PushTitle   string            `json:"push_title,omitempty"`  // For push
    PushBody    string            `json:"push_body,omitempty"`   // For push
    InAppTitle  string            `json:"in_app_title,omitempty"` // For in-app
    InAppBody   string            `json:"in_app_body,omitempty"`  // For in-app
    Variables   []string          `json:"variables"`
    CreatedAt   time.Time         `json:"created_at"`
    UpdatedAt   time.Time         `json:"updated_at"`
}

// RenderedContent represents rendered notification content
type RenderedContent struct {
    Subject   string `json:"subject,omitempty"`
    Body      string `json:"body"`
    HTMLBody  string `json:"html_body,omitempty"`
    Title     string `json:"title,omitempty"`
    ImageURL  string `json:"image_url,omitempty"`
    ActionURL string `json:"action_url,omitempty"`
}

// NewTemplateEngine creates a new template engine
func NewTemplateEngine() *TemplateEngine {
    return &TemplateEngine{
        templates: make(map[string]*NotificationTemplate),
        funcMap: template.FuncMap{
            "upper":     strings.ToUpper,
            "lower":     strings.ToLower,
            "title":     strings.Title,
            "formatDate": formatDate,
            "formatCurrency": formatCurrency,
        },
    }
}

// RegisterTemplate registers a notification template
func (te *TemplateEngine) RegisterTemplate(tmpl *NotificationTemplate) error {
    te.mu.Lock()
    defer te.mu.Unlock()
    
    // Validate template
    if err := te.validateTemplate(tmpl); err != nil {
        return fmt.Errorf("invalid template: %w", err)
    }
    
    te.templates[tmpl.ID] = tmpl
    return nil
}

// Render renders a template with data
func (te *TemplateEngine) Render(ctx context.Context, templateID string, data map[string]interface{}) (*RenderedContent, error) {
    te.mu.RLock()
    tmpl, exists := te.templates[templateID]
    te.mu.RUnlock()
    
    if !exists {
        return nil, fmt.Errorf("template not found: %s", templateID)
    }
    
    content := &RenderedContent{}
    
    // Render subject
    if tmpl.Subject != "" {
        subject, err := te.renderString(tmpl.Subject, data)
        if err != nil {
            return nil, fmt.Errorf("failed to render subject: %w", err)
        }
        content.Subject = subject
    }
    
    // Render body
    if tmpl.Body != "" {
        body, err := te.renderString(tmpl.Body, data)
        if err != nil {
            return nil, fmt.Errorf("failed to render body: %w", err)
        }
        content.Body = body
    }
    
    // Render HTML body
    if tmpl.HTMLBody != "" {
        htmlBody, err := te.renderString(tmpl.HTMLBody, data)
        if err != nil {
            return nil, fmt.Errorf("failed to render HTML body: %w", err)
        }
        content.HTMLBody = htmlBody
    }
    
    // Render SMS body
    if tmpl.SMSBody != "" {
        smsBody, err := te.renderString(tmpl.SMSBody, data)
        if err != nil {
            return nil, fmt.Errorf("failed to render SMS body: %w", err)
        }
        content.Body = smsBody // For SMS, use Body field
    }
    
    // Render push notification
    if tmpl.PushTitle != "" {
        title, err := te.renderString(tmpl.PushTitle, data)
        if err != nil {
            return nil, fmt.Errorf("failed to render push title: %w", err)
        }
        content.Title = title
    }
    
    if tmpl.PushBody != "" {
        body, err := te.renderString(tmpl.PushBody, data)
        if err != nil {
            return nil, fmt.Errorf("failed to render push body: %w", err)
        }
        content.Body = body
    }
    
    // Add action URL if present in data
    if actionURL, ok := data["action_url"].(string); ok {
        content.ActionURL = actionURL
    }
    
    // Add image URL if present in data
    if imageURL, ok := data["image_url"].(string); ok {
        content.ImageURL = imageURL
    }
    
    return content, nil
}

// renderString renders a template string with data
func (te *TemplateEngine) renderString(templateStr string, data map[string]interface{}) (string, error) {
    tmpl, err := template.New("notification").Funcs(te.funcMap).Parse(templateStr)
    if err != nil {
        return "", err
    }
    
    var buf bytes.Buffer
    if err := tmpl.Execute(&buf, data); err != nil {
        return "", err
    }
    
    return buf.String(), nil
}

// validateTemplate validates template syntax
func (te *TemplateEngine) validateTemplate(tmpl *NotificationTemplate) error {
    testData := make(map[string]interface{})
    for _, variable := range tmpl.Variables {
        testData[variable] = "test_value"
    }
    
    // Test render all template parts
    if tmpl.Subject != "" {
        if _, err := te.renderString(tmpl.Subject, testData); err != nil {
            return fmt.Errorf("invalid subject template: %w", err)
        }
    }
    
    if tmpl.Body != "" {
        if _, err := te.renderString(tmpl.Body, testData); err != nil {
            return fmt.Errorf("invalid body template: %w", err)
        }
    }
    
    return nil
}

// Template helper functions
func formatDate(t time.Time) string {
    return t.Format("January 2, 2006")
}

func formatCurrency(amount float64) string {
    return fmt.Sprintf("$%.2f", amount)
}
```

### Channel Providers

```go
package providers

import (
    "context"
    "fmt"
    "time"
)

// Provider interface for notification channels
type Provider interface {
    Send(ctx context.Context, req SendRequest) (*SendResult, error)
    GetStatus(ctx context.Context, messageID string) (*DeliveryStatus, error)
    ValidateConfig() error
}

// SendRequest represents a send request to a provider
type SendRequest struct {
    UserID       string
    Content      *RenderedContent
    Metadata     map[string]string
    Notification *Notification
}

// SendResult represents the result of a send operation
type SendResult struct {
    ProviderID  string
    MessageID   string
    Status      string
    Cost        float64
    Metadata    map[string]string
}

// DeliveryStatus represents delivery status
type DeliveryStatus struct {
    MessageID    string
    Status       string
    DeliveredAt  *time.Time
    FailureReason string
}

// EmailProvider sends email notifications
type EmailProvider struct {
    apiKey     string
    fromEmail  string
    fromName   string
    client     EmailClient
}

// EmailClient interface for email services (SendGrid, Mailgun, etc.)
type EmailClient interface {
    SendEmail(ctx context.Context, req EmailRequest) (*EmailResponse, error)
}

type EmailRequest struct {
    From        string
    To          string
    Subject     string
    TextBody    string
    HTMLBody    string
    Attachments []Attachment
}

type EmailResponse struct {
    MessageID string
    Status    string
}

type Attachment struct {
    Filename string
    Content  []byte
    Type     string
}

// NewEmailProvider creates a new email provider
func NewEmailProvider(apiKey, fromEmail, fromName string, client EmailClient) *EmailProvider {
    return &EmailProvider{
        apiKey:    apiKey,
        fromEmail: fromEmail,
        fromName:  fromName,
        client:    client,
    }
}

// Send sends an email notification
func (ep *EmailProvider) Send(ctx context.Context, req SendRequest) (*SendResult, error) {
    // Get user email from user service (simplified)
    userEmail := req.Metadata["email"]
    if userEmail == "" {
        return nil, fmt.Errorf("user email not found")
    }
    
    emailReq := EmailRequest{
        From:     fmt.Sprintf("%s <%s>", ep.fromName, ep.fromEmail),
        To:       userEmail,
        Subject:  req.Content.Subject,
        TextBody: req.Content.Body,
        HTMLBody: req.Content.HTMLBody,
    }
    
    resp, err := ep.client.SendEmail(ctx, emailReq)
    if err != nil {
        return nil, err
    }
    
    return &SendResult{
        ProviderID: "email",
        MessageID:  resp.MessageID,
        Status:     resp.Status,
        Cost:       0.001, // Example cost per email
    }, nil
}

// GetStatus gets delivery status
func (ep *EmailProvider) GetStatus(ctx context.Context, messageID string) (*DeliveryStatus, error) {
    // Implementation would query email provider API
    return &DeliveryStatus{
        MessageID: messageID,
        Status:    "delivered",
    }, nil
}

// ValidateConfig validates provider configuration
func (ep *EmailProvider) ValidateConfig() error {
    if ep.apiKey == "" {
        return fmt.Errorf("API key is required")
    }
    if ep.fromEmail == "" {
        return fmt.Errorf("from email is required")
    }
    return nil
}

// SMSProvider sends SMS notifications
type SMSProvider struct {
    accountSID string
    authToken  string
    fromNumber string
    client     SMSClient
}

type SMSClient interface {
    SendSMS(ctx context.Context, req SMSRequest) (*SMSResponse, error)
}

type SMSRequest struct {
    From string
    To   string
    Body string
}

type SMSResponse struct {
    SID    string
    Status string
}

// NewSMSProvider creates a new SMS provider
func NewSMSProvider(accountSID, authToken, fromNumber string, client SMSClient) *SMSProvider {
    return &SMSProvider{
        accountSID: accountSID,
        authToken:  authToken,
        fromNumber: fromNumber,
        client:     client,
    }
}

// Send sends an SMS notification
func (sp *SMSProvider) Send(ctx context.Context, req SendRequest) (*SendResult, error) {
    phoneNumber := req.Metadata["phone"]
    if phoneNumber == "" {
        return nil, fmt.Errorf("user phone number not found")
    }
    
    smsReq := SMSRequest{
        From: sp.fromNumber,
        To:   phoneNumber,
        Body: req.Content.Body,
    }
    
    resp, err := sp.client.SendSMS(ctx, smsReq)
    if err != nil {
        return nil, err
    }
    
    return &SendResult{
        ProviderID: "sms",
        MessageID:  resp.SID,
        Status:     resp.Status,
        Cost:       0.05, // Example cost per SMS
    }, nil
}

// GetStatus gets SMS delivery status
func (sp *SMSProvider) GetStatus(ctx context.Context, messageID string) (*DeliveryStatus, error) {
    // Implementation would query SMS provider API
    return &DeliveryStatus{
        MessageID: messageID,
        Status:    "delivered",
    }, nil
}

// ValidateConfig validates SMS provider configuration
func (sp *SMSProvider) ValidateConfig() error {
    if sp.accountSID == "" {
        return fmt.Errorf("account SID is required")
    }
    if sp.authToken == "" {
        return fmt.Errorf("auth token is required")
    }
    return nil
}

// PushProvider sends push notifications
type PushProvider struct {
    serverKey string
    client    PushClient
}

type PushClient interface {
    SendPush(ctx context.Context, req PushRequest) (*PushResponse, error)
}

type PushRequest struct {
    DeviceToken string
    Title       string
    Body        string
    Data        map[string]string
    ImageURL    string
    ActionURL   string
}

type PushResponse struct {
    MessageID string
    Status    string
}

// NewPushProvider creates a new push notification provider
func NewPushProvider(serverKey string, client PushClient) *PushProvider {
    return &PushProvider{
        serverKey: serverKey,
        client:    client,
    }
}

// Send sends a push notification
func (pp *PushProvider) Send(ctx context.Context, req SendRequest) (*SendResult, error) {
    deviceToken := req.Metadata["device_token"]
    if deviceToken == "" {
        return nil, fmt.Errorf("device token not found")
    }
    
    pushReq := PushRequest{
        DeviceToken: deviceToken,
        Title:       req.Content.Title,
        Body:        req.Content.Body,
        ImageURL:    req.Content.ImageURL,
        ActionURL:   req.Content.ActionURL,
        Data:        req.Metadata,
    }
    
    resp, err := pp.client.SendPush(ctx, pushReq)
    if err != nil {
        return nil, err
    }
    
    return &SendResult{
        ProviderID: "push",
        MessageID:  resp.MessageID,
        Status:     resp.Status,
        Cost:       0.0001, // Very low cost for push notifications
    }, nil
}

// GetStatus gets push notification status
func (pp *PushProvider) GetStatus(ctx context.Context, messageID string) (*DeliveryStatus, error) {
    return &DeliveryStatus{
        MessageID: messageID,
        Status:    "delivered",
    }, nil
}

// ValidateConfig validates push provider configuration
func (pp *PushProvider) ValidateConfig() error {
    if pp.serverKey == "" {
        return fmt.Errorf("server key is required")
    }
    return nil
}
```

### User Preferences Management

```go
package notifications

import (
    "context"
    "time"
)

// UserPreferencesService manages user notification preferences
type UserPreferencesService struct {
    repo UserPreferencesRepository
}

// UserPreferences represents user notification preferences
type UserPreferences struct {
    UserID          string                    `json:"user_id"`
    GlobalEnabled   bool                      `json:"global_enabled"`
    Channels        map[Channel]ChannelPref   `json:"channels"`
    Types           map[NotificationType]bool `json:"types"`
    QuietHours      *QuietHours               `json:"quiet_hours,omitempty"`
    Frequency       FrequencySettings         `json:"frequency"`
    CreatedAt       time.Time                 `json:"created_at"`
    UpdatedAt       time.Time                 `json:"updated_at"`
}

// ChannelPref represents preferences for a specific channel
type ChannelPref struct {
    Enabled   bool      `json:"enabled"`
    Address   string    `json:"address,omitempty"` // email, phone, device token
    Verified  bool      `json:"verified"`
    UpdatedAt time.Time `json:"updated_at"`
}

// QuietHours represents when user doesn't want notifications
type QuietHours struct {
    Enabled   bool   `json:"enabled"`
    StartTime string `json:"start_time"` // HH:MM format
    EndTime   string `json:"end_time"`   // HH:MM format
    Timezone  string `json:"timezone"`
}

// FrequencySettings controls notification frequency
type FrequencySettings struct {
    MaxPerHour int                               `json:"max_per_hour"`
    MaxPerDay  int                               `json:"max_per_day"`
    Digest     map[NotificationType]DigestPref  `json:"digest"`
}

// DigestPref represents digest preferences for notification types
type DigestPref struct {
    Enabled   bool          `json:"enabled"`
    Frequency time.Duration `json:"frequency"` // daily, weekly
    Time      string        `json:"time"`      // HH:MM when to send digest
}

// NewUserPreferencesService creates a new user preferences service
func NewUserPreferencesService(repo UserPreferencesRepository) *UserPreferencesService {
    return &UserPreferencesService{repo: repo}
}

// GetPreferences gets user notification preferences
func (ups *UserPreferencesService) GetPreferences(ctx context.Context, userID string) (*UserPreferences, error) {
    prefs, err := ups.repo.GetByUserID(ctx, userID)
    if err != nil {
        // Return default preferences if not found
        if err == ErrNotFound {
            return ups.getDefaultPreferences(userID), nil
        }
        return nil, err
    }
    return prefs, nil
}

// UpdatePreferences updates user notification preferences
func (ups *UserPreferencesService) UpdatePreferences(ctx context.Context, userID string, updates UserPreferencesUpdate) error {
    prefs, err := ups.GetPreferences(ctx, userID)
    if err != nil {
        return err
    }
    
    // Apply updates
    if updates.GlobalEnabled != nil {
        prefs.GlobalEnabled = *updates.GlobalEnabled
    }
    
    if updates.Channels != nil {
        for channel, channelPref := range updates.Channels {
            if prefs.Channels == nil {
                prefs.Channels = make(map[Channel]ChannelPref)
            }
            prefs.Channels[channel] = channelPref
        }
    }
    
    if updates.Types != nil {
        for notifType, enabled := range updates.Types {
            if prefs.Types == nil {
                prefs.Types = make(map[NotificationType]bool)
            }
            prefs.Types[notifType] = enabled
        }
    }
    
    if updates.QuietHours != nil {
        prefs.QuietHours = updates.QuietHours
    }
    
    prefs.UpdatedAt = time.Now()
    
    return ups.repo.Update(ctx, prefs)
}

// UserPreferencesUpdate represents partial updates to preferences
type UserPreferencesUpdate struct {
    GlobalEnabled *bool                       `json:"global_enabled,omitempty"`
    Channels      map[Channel]ChannelPref     `json:"channels,omitempty"`
    Types         map[NotificationType]bool   `json:"types,omitempty"`
    QuietHours    *QuietHours                 `json:"quiet_hours,omitempty"`
}

// IsAllowed checks if notification is allowed for user
func (ups *UserPreferencesService) IsAllowed(ctx context.Context, userID string, channel Channel, notifType NotificationType) (bool, error) {
    prefs, err := ups.GetPreferences(ctx, userID)
    if err != nil {
        return false, err
    }
    
    // Check global setting
    if !prefs.GlobalEnabled {
        return false, nil
    }
    
    // Check channel setting
    if channelPref, exists := prefs.Channels[channel]; exists {
        if !channelPref.Enabled {
            return false, nil
        }
    }
    
    // Check notification type setting
    if typeEnabled, exists := prefs.Types[notifType]; exists {
        if !typeEnabled {
            return false, nil
        }
    }
    
    // Check quiet hours
    if prefs.QuietHours != nil && prefs.QuietHours.Enabled {
        if ups.isInQuietHours(prefs.QuietHours) {
            // Allow critical notifications during quiet hours
            if notifType == TypeSystemAlert {
                return true, nil
            }
            return false, nil
        }
    }
    
    return true, nil
}

// isInQuietHours checks if current time is in user's quiet hours
func (ups *UserPreferencesService) isInQuietHours(quietHours *QuietHours) bool {
    // Implementation would parse timezone and check current time
    // This is simplified
    return false
}

// getDefaultPreferences returns default preferences for new users
func (ups *UserPreferencesService) getDefaultPreferences(userID string) *UserPreferences {
    return &UserPreferences{
        UserID:        userID,
        GlobalEnabled: true,
        Channels: map[Channel]ChannelPref{
            ChannelEmail: {Enabled: true},
            ChannelPush:  {Enabled: true},
            ChannelSMS:   {Enabled: false},
            ChannelInApp: {Enabled: true},
        },
        Types: map[NotificationType]bool{
            TypeWelcome:       true,
            TypePasswordReset: true,
            TypeOrderConfirm:  true,
            TypePromotion:     false,
            TypeSystemAlert:   true,
            TypeReminder:      true,
        },
        Frequency: FrequencySettings{
            MaxPerHour: 10,
            MaxPerDay:  50,
        },
        CreatedAt: time.Now(),
        UpdatedAt: time.Now(),
    }
}
```

### Rate Limiting

```go
package notifications

import (
    "context"
    "fmt"
    "time"
    
    "github.com/go-redis/redis/v8"
)

// RateLimiter controls notification frequency
type RateLimiter struct {
    client *redis.Client
}

// NewRateLimiter creates a new rate limiter
func NewRateLimiter(client *redis.Client) *RateLimiter {
    return &RateLimiter{client: client}
}

// Allow checks if notification is allowed based on rate limits
func (rl *RateLimiter) Allow(ctx context.Context, userID string, channel Channel) (bool, error) {
    // Check hourly limit
    hourlyKey := fmt.Sprintf("rate_limit:hourly:%s:%s", userID, channel)
    hourlyCount, err := rl.client.Incr(ctx, hourlyKey).Result()
    if err != nil {
        return false, err
    }
    
    if hourlyCount == 1 {
        rl.client.Expire(ctx, hourlyKey, time.Hour)
    }
    
    if hourlyCount > 10 { // Max 10 per hour
        return false, nil
    }
    
    // Check daily limit
    dailyKey := fmt.Sprintf("rate_limit:daily:%s:%s", userID, channel)
    dailyCount, err := rl.client.Incr(ctx, dailyKey).Result()
    if err != nil {
        return false, err
    }
    
    if dailyCount == 1 {
        rl.client.Expire(ctx, dailyKey, 24*time.Hour)
    }
    
    if dailyCount > 50 { // Max 50 per day
        return false, nil
    }
    
    return true, nil
}

// GetLimits returns current rate limit usage
func (rl *RateLimiter) GetLimits(ctx context.Context, userID string, channel Channel) (*RateLimitStatus, error) {
    hourlyKey := fmt.Sprintf("rate_limit:hourly:%s:%s", userID, channel)
    dailyKey := fmt.Sprintf("rate_limit:daily:%s:%s", userID, channel)
    
    pipe := rl.client.Pipeline()
    hourlyCmd := pipe.Get(ctx, hourlyKey)
    dailyCmd := pipe.Get(ctx, dailyKey)
    
    _, err := pipe.Exec(ctx)
    if err != nil && err != redis.Nil {
        return nil, err
    }
    
    hourlyCount, _ := hourlyCmd.Int64()
    dailyCount, _ := dailyCmd.Int64()
    
    return &RateLimitStatus{
        HourlyUsed:  hourlyCount,
        HourlyLimit: 10,
        DailyUsed:   dailyCount,
        DailyLimit:  50,
    }, nil
}

// RateLimitStatus represents current rate limit status
type RateLimitStatus struct {
    HourlyUsed  int64 `json:"hourly_used"`
    HourlyLimit int64 `json:"hourly_limit"`
    DailyUsed   int64 `json:"daily_used"`
    DailyLimit  int64 `json:"daily_limit"`
}
```

### Analytics and Tracking

```go
package notifications

import (
    "context"
    "time"
    
    "github.com/prometheus/client_golang/prometheus"
)

// AnalyticsService tracks notification metrics
type AnalyticsService struct {
    repo    AnalyticsRepository
    metrics *NotificationMetrics
}

// NotificationMetrics contains Prometheus metrics
type NotificationMetrics struct {
    NotificationsCreated prometheus.CounterVec
    NotificationsSent    prometheus.CounterVec
    NotificationsFailed  prometheus.CounterVec
    DeliveryLatency      prometheus.HistogramVec
    ProviderCosts        prometheus.CounterVec
}

// NewAnalyticsService creates a new analytics service
func NewAnalyticsService(repo AnalyticsRepository) *AnalyticsService {
    return &AnalyticsService{
        repo: repo,
        metrics: &NotificationMetrics{
            NotificationsCreated: *prometheus.NewCounterVec(
                prometheus.CounterOpts{
                    Name: "notifications_created_total",
                    Help: "Total number of notifications created",
                },
                []string{"channel", "type"},
            ),
            NotificationsSent: *prometheus.NewCounterVec(
                prometheus.CounterOpts{
                    Name: "notifications_sent_total",
                    Help: "Total number of notifications sent",
                },
                []string{"channel", "type", "provider"},
            ),
            NotificationsFailed: *prometheus.NewCounterVec(
                prometheus.CounterOpts{
                    Name: "notifications_failed_total",
                    Help: "Total number of failed notifications",
                },
                []string{"channel", "type", "error"},
            ),
            DeliveryLatency: *prometheus.NewHistogramVec(
                prometheus.HistogramOpts{
                    Name: "notification_delivery_latency_seconds",
                    Help: "Notification delivery latency",
                },
                []string{"channel", "type"},
            ),
            ProviderCosts: *prometheus.NewCounterVec(
                prometheus.CounterOpts{
                    Name: "notification_provider_costs_total",
                    Help: "Total costs from notification providers",
                },
                []string{"provider"},
            ),
        },
    }
}

// TrackNotificationCreated tracks when notification is created
func (as *AnalyticsService) TrackNotificationCreated(notification *Notification) {
    as.metrics.NotificationsCreated.WithLabelValues(
        string(notification.Channel),
        string(notification.Type),
    ).Inc()
    
    // Store in database for detailed analytics
    event := &NotificationEvent{
        NotificationID: notification.ID,
        UserID:        notification.UserID,
        EventType:     "created",
        Channel:       notification.Channel,
        Type:          notification.Type,
        Timestamp:     time.Now(),
        Metadata: map[string]string{
            "priority": fmt.Sprintf("%d", notification.Priority),
        },
    }
    
    as.repo.SaveEvent(context.Background(), event)
}

// TrackNotificationSent tracks when notification is sent
func (as *AnalyticsService) TrackNotificationSent(notification *Notification, result *SendResult) {
    as.metrics.NotificationsSent.WithLabelValues(
        string(notification.Channel),
        string(notification.Type),
        result.ProviderID,
    ).Inc()
    
    as.metrics.ProviderCosts.WithLabelValues(result.ProviderID).Add(result.Cost)
    
    // Track delivery latency
    latency := time.Since(notification.CreatedAt).Seconds()
    as.metrics.DeliveryLatency.WithLabelValues(
        string(notification.Channel),
        string(notification.Type),
    ).Observe(latency)
    
    event := &NotificationEvent{
        NotificationID: notification.ID,
        UserID:        notification.UserID,
        EventType:     "sent",
        Channel:       notification.Channel,
        Type:          notification.Type,
        Timestamp:     time.Now(),
        Metadata: map[string]string{
            "provider_id":    result.ProviderID,
            "message_id":     result.MessageID,
            "cost":          fmt.Sprintf("%.4f", result.Cost),
            "latency_ms":    fmt.Sprintf("%.0f", latency*1000),
        },
    }
    
    as.repo.SaveEvent(context.Background(), event)
}

// TrackNotificationFailed tracks when notification fails
func (as *AnalyticsService) TrackNotificationFailed(notification *Notification, err error) {
    as.metrics.NotificationsFailed.WithLabelValues(
        string(notification.Channel),
        string(notification.Type),
        "send_error",
    ).Inc()
    
    event := &NotificationEvent{
        NotificationID: notification.ID,
        UserID:        notification.UserID,
        EventType:     "failed",
        Channel:       notification.Channel,
        Type:          notification.Type,
        Timestamp:     time.Now(),
        Metadata: map[string]string{
            "error": err.Error(),
        },
    }
    
    as.repo.SaveEvent(context.Background(), event)
}

// NotificationEvent represents an analytics event
type NotificationEvent struct {
    ID             string            `json:"id"`
    NotificationID string            `json:"notification_id"`
    UserID         string            `json:"user_id"`
    EventType      string            `json:"event_type"`
    Channel        Channel           `json:"channel"`
    Type           NotificationType  `json:"type"`
    Timestamp      time.Time         `json:"timestamp"`
    Metadata       map[string]string `json:"metadata"`
}
```

### Usage Examples

```go
package main

import (
    "context"
    "log"
    "time"
)

func main() {
    // Initialize notification service
    notificationService := setupNotificationService()
    
    // Example: Send welcome email
    welcomeUser(notificationService, "user123")
    
    // Example: Send order confirmation
    confirmOrder(notificationService, "user456", "order789")
    
    // Example: Send promotional push notification
    sendPromotion(notificationService, "user789")
}

func welcomeUser(ns *NotificationService, userID string) {
    req := SendNotificationRequest{
        UserID:   userID,
        Channel:  ChannelEmail,
        Type:     TypeWelcome,
        Template: "welcome_email",
        Data: map[string]interface{}{
            "user_name":    "John Doe",
            "company_name": "Acme Corp",
            "login_url":    "https://app.example.com/login",
        },
        Priority: PriorityNormal,
        Metadata: map[string]string{
            "email": "john@example.com",
        },
    }
    
    notification, err := ns.Send(context.Background(), req)
    if err != nil {
        log.Printf("Failed to send welcome email: %v", err)
        return
    }
    
    log.Printf("Welcome email queued: %s", notification.ID)
}

func confirmOrder(ns *NotificationService, userID, orderID string) {
    req := SendNotificationRequest{
        UserID:   userID,
        Channel:  ChannelEmail,
        Type:     TypeOrderConfirm,
        Template: "order_confirmation",
        Data: map[string]interface{}{
            "order_id":     orderID,
            "order_total":  99.99,
            "order_items":  []string{"Product A", "Product B"},
            "tracking_url": "https://track.example.com/" + orderID,
        },
        Priority: PriorityHigh,
        Metadata: map[string]string{
            "email": "customer@example.com",
        },
    }
    
    notification, err := ns.Send(context.Background(), req)
    if err != nil {
        log.Printf("Failed to send order confirmation: %v", err)
        return
    }
    
    log.Printf("Order confirmation queued: %s", notification.ID)
}

func sendPromotion(ns *NotificationService, userID string) {
    req := SendNotificationRequest{
        UserID:   userID,
        Channel:  ChannelPush,
        Type:     TypePromotion,
        Template: "flash_sale",
        Data: map[string]interface{}{
            "discount_percent": 50,
            "expires_at":      time.Now().Add(24 * time.Hour),
            "action_url":      "https://app.example.com/sale",
            "image_url":       "https://cdn.example.com/sale-banner.jpg",
        },
        Priority: PriorityLow,
        Metadata: map[string]string{
            "device_token": "abc123token",
        },
    }
    
    notification, err := ns.Send(context.Background(), req)
    if err != nil {
        log.Printf("Failed to send promotion: %v", err)
        return
    }
    
    log.Printf("Promotion notification queued: %s", notification.ID)
}
```

## Best Practices

1. **Template Management**: Use version control for templates and test thoroughly
2. **User Preferences**: Always respect user notification preferences
3. **Rate Limiting**: Implement appropriate rate limits to prevent spam
4. **Retry Logic**: Implement exponential backoff for failed deliveries
5. **Analytics**: Track delivery rates and user engagement
6. **Security**: Validate all input data and sanitize templates
7. **Performance**: Use background processing for all notifications
8. **Compliance**: Follow regulations like CAN-SPAM and GDPR

## Monitoring and Alerting

### Key Metrics
- Notification delivery rate by channel
- Processing latency
- Provider costs
- User engagement rates
- Template render errors
- Queue depth and processing time

### Alert Rules
```yaml
- alert: HighNotificationFailureRate
  expr: rate(notifications_failed_total[5m]) / rate(notifications_created_total[5m]) > 0.05
  
- alert: NotificationQueueBacklog
  expr: notification_queue_size > 10000
  
- alert: HighDeliveryLatency
  expr: histogram_quantile(0.95, rate(notification_delivery_latency_seconds_bucket[5m])) > 300
```

## Consequences

### Advantages
- **Multi-channel support**: Unified system for all notification types
- **Reliability**: Background processing with retry mechanisms
- **Scalability**: Can handle high volumes with proper infrastructure
- **User control**: Comprehensive preference management
- **Analytics**: Detailed tracking and monitoring
- **Flexibility**: Template-based content management

### Disadvantages
- **Complexity**: Significant system complexity to implement and maintain
- **Cost**: Potentially high costs for SMS and email providers
- **Compliance burden**: Need to handle various regulations
- **Template management**: Ongoing effort to maintain templates
- **Provider dependencies**: Reliance on third-party services

## References
- [Notification Service Design Patterns](https://microservices.io/patterns/data/saga.html)
- [Push Notification Best Practices](https://developer.apple.com/documentation/usernotifications)
- [Email Deliverability Guide](https://www.mailgun.com/email-deliverability/)
- [SMS Compliance Guidelines](https://www.twilio.com/docs/sms/compliance)
