# Global Configuration Service

## Status

`accepted`

## Context

Modern applications often require dynamic configuration that can be updated without code deployments. Rather than creating multiple specialized APIs for different configuration needs, a centralized global configuration service provides a unified approach for managing feature flags, application settings, assets, and business rules.

### Current Challenges

Without centralized configuration management:
- **Configuration sprawl**: Settings scattered across multiple services and files
- **Deployment dependencies**: Configuration changes require code deployments
- **Inconsistent formats**: Different services use different configuration patterns
- **Poor auditability**: Difficult to track who changed what and when
- **Limited validation**: No standardized way to validate configuration changes
- **Asset management**: No unified approach for managing and serving static assets

### Business Requirements

- **Dynamic updates**: Change configuration without service restarts
- **Multi-environment support**: Different configs for dev, staging, production
- **Access control**: Role-based permissions for configuration management
- **Audit trail**: Track all configuration changes with attribution
- **Validation**: Ensure configuration correctness before deployment
- **Asset serving**: Unified service for images, documents, and other assets
- **API access**: RESTful interface for reading and updating configuration

## Decision

We will implement a comprehensive global configuration service that supports dynamic configuration management, asset serving, and schema validation with role-based access control.

### Architecture Overview

```go
package globalconfig

import (
    "context"
    "encoding/json"
    "time"
)

type ConfigService struct {
    repository ConfigRepository
    validator  SchemaValidator
    cache      ConfigCache
    publisher  EventPublisher
    assets     AssetManager
}

type Config struct {
    ID          string                 `json:"id" db:"id"`
    Key         string                 `json:"key" db:"key"`
    Value       interface{}            `json:"value" db:"value"`
    Type        ConfigType             `json:"type" db:"type"`
    Environment string                 `json:"environment" db:"environment"`
    Tags        []string               `json:"tags" db:"tags"`
    Schema      *ConfigSchema          `json:"schema,omitempty" db:"schema"`
    AdminID     string                 `json:"admin_id" db:"admin_id"`
    Note        string                 `json:"note,omitempty" db:"note"`
    Version     int64                  `json:"version" db:"version"`
    CreatedAt   time.Time              `json:"created_at" db:"created_at"`
    UpdatedAt   time.Time              `json:"updated_at" db:"updated_at"`
    ExpiresAt   *time.Time             `json:"expires_at,omitempty" db:"expires_at"`
}

type ConfigType string

const (
    TypeString      ConfigType = "string"
    TypeInteger     ConfigType = "integer"
    TypeFloat       ConfigType = "float"
    TypeBoolean     ConfigType = "boolean"
    TypeJSON        ConfigType = "json"
    TypeArray       ConfigType = "array"
    TypeURL         ConfigType = "url"
    TypeAsset       ConfigType = "asset"
    TypeFeatureFlag ConfigType = "feature_flag"
)

type ConfigSchema struct {
    Type        string                 `json:"type"`
    Properties  map[string]interface{} `json:"properties,omitempty"`
    Required    []string               `json:"required,omitempty"`
    Minimum     *float64               `json:"minimum,omitempty"`
    Maximum     *float64               `json:"maximum,omitempty"`
    Pattern     string                 `json:"pattern,omitempty"`
    Enum        []interface{}          `json:"enum,omitempty"`
    Description string                 `json:"description,omitempty"`
}
```

### Core Service Implementation

```go
func NewConfigService(repo ConfigRepository, validator SchemaValidator, cache ConfigCache, publisher EventPublisher, assets AssetManager) *ConfigService {
    return &ConfigService{
        repository: repo,
        validator:  validator,
        cache:      cache,
        publisher:  publisher,
        assets:     assets,
    }
}

func (cs *ConfigService) GetConfig(ctx context.Context, key, environment string) (*Config, error) {
    // Try cache first
    cacheKey := fmt.Sprintf("%s:%s", environment, key)
    if config, found := cs.cache.Get(cacheKey); found {
        return config.(*Config), nil
    }
    
    // Fetch from repository
    config, err := cs.repository.GetByKey(ctx, key, environment)
    if err != nil {
        return nil, fmt.Errorf("failed to get config: %w", err)
    }
    
    // Cache the result
    cs.cache.Set(cacheKey, config, 5*time.Minute)
    
    return config, nil
}

func (cs *ConfigService) SetConfig(ctx context.Context, req *SetConfigRequest) (*Config, error) {
    // Validate schema if provided
    if req.Schema != nil {
        if err := cs.validator.ValidateValue(req.Value, req.Schema); err != nil {
            return nil, fmt.Errorf("schema validation failed: %w", err)
        }
    }
    
    // Check permissions
    if err := cs.checkPermissions(ctx, req.Key, req.Environment); err != nil {
        return nil, fmt.Errorf("permission denied: %w", err)
    }
    
    // Get existing config for versioning
    existing, err := cs.repository.GetByKey(ctx, req.Key, req.Environment)
    var version int64 = 1
    if err == nil {
        version = existing.Version + 1
    }
    
    // Create new config
    config := &Config{
        ID:          generateID(),
        Key:         req.Key,
        Value:       req.Value,
        Type:        req.Type,
        Environment: req.Environment,
        Tags:        req.Tags,
        Schema:      req.Schema,
        AdminID:     getUserID(ctx),
        Note:        req.Note,
        Version:     version,
        CreatedAt:   time.Now(),
        UpdatedAt:   time.Now(),
        ExpiresAt:   req.ExpiresAt,
    }
    
    // Save to repository
    if err := cs.repository.Save(ctx, config); err != nil {
        return nil, fmt.Errorf("failed to save config: %w", err)
    }
    
    // Invalidate cache
    cacheKey := fmt.Sprintf("%s:%s", req.Environment, req.Key)
    cs.cache.Delete(cacheKey)
    
    // Publish change event
    cs.publisher.Publish("config.changed", ConfigChangedEvent{
        Key:         config.Key,
        Environment: config.Environment,
        AdminID:     config.AdminID,
        Version:     config.Version,
        ChangeType:  "updated",
    })
    
    return config, nil
}

func (cs *ConfigService) GetConfigsByTags(ctx context.Context, tags []string, environment string) ([]*Config, error) {
    return cs.repository.GetByTags(ctx, tags, environment)
}

func (cs *ConfigService) DeleteConfig(ctx context.Context, key, environment string) error {
    // Check permissions
    if err := cs.checkPermissions(ctx, key, environment); err != nil {
        return fmt.Errorf("permission denied: %w", err)
    }
    
    // Delete from repository
    if err := cs.repository.Delete(ctx, key, environment); err != nil {
        return fmt.Errorf("failed to delete config: %w", err)
    }
    
    // Invalidate cache
    cacheKey := fmt.Sprintf("%s:%s", environment, key)
    cs.cache.Delete(cacheKey)
    
    // Publish deletion event
    cs.publisher.Publish("config.deleted", ConfigChangedEvent{
        Key:         key,
        Environment: environment,
        AdminID:     getUserID(ctx),
        ChangeType:  "deleted",
    })
    
    return nil
}
```

### Feature Flag Support

```go
type FeatureFlag struct {
    Key         string             `json:"key"`
    Enabled     bool               `json:"enabled"`
    Rules       []FeatureFlagRule  `json:"rules"`
    Rollout     *RolloutConfig     `json:"rollout,omitempty"`
    Environment string             `json:"environment"`
}

type FeatureFlagRule struct {
    Condition string      `json:"condition"` // user.country == "US"
    Value     interface{} `json:"value"`
    Weight    float64     `json:"weight,omitempty"`
}

type RolloutConfig struct {
    Percentage int      `json:"percentage"` // 0-100
    UserIDs    []string `json:"user_ids,omitempty"`
    Groups     []string `json:"groups,omitempty"`
}

func (cs *ConfigService) EvaluateFeatureFlag(ctx context.Context, key string, userContext map[string]interface{}) (interface{}, error) {
    config, err := cs.GetConfig(ctx, key, getEnvironment(ctx))
    if err != nil {
        return false, err // Default to disabled
    }
    
    if config.Type != TypeFeatureFlag {
        return nil, fmt.Errorf("config %s is not a feature flag", key)
    }
    
    var flag FeatureFlag
    if err := json.Unmarshal(config.Value.([]byte), &flag); err != nil {
        return false, err
    }
    
    if !flag.Enabled {
        return false, nil
    }
    
    // Evaluate rules
    for _, rule := range flag.Rules {
        if cs.evaluateRule(rule.Condition, userContext) {
            return rule.Value, nil
        }
    }
    
    // Check rollout configuration
    if flag.Rollout != nil {
        return cs.evaluateRollout(flag.Rollout, userContext), nil
    }
    
    return flag.Enabled, nil
}

func (cs *ConfigService) evaluateRule(condition string, userContext map[string]interface{}) bool {
    // Simple rule evaluation - in production, use a more sophisticated rule engine
    // Example: "user.country == 'US' && user.premium == true"
    
    // This is a simplified implementation
    // In practice, you'd use a rule engine like github.com/Knetic/govaluate
    return true // Placeholder
}

func (cs *ConfigService) evaluateRollout(rollout *RolloutConfig, userContext map[string]interface{}) bool {
    userID, ok := userContext["user_id"].(string)
    if !ok {
        return false
    }
    
    // Check explicit user IDs
    for _, id := range rollout.UserIDs {
        if id == userID {
            return true
        }
    }
    
    // Check percentage rollout
    if rollout.Percentage > 0 {
        hash := hashUserID(userID)
        return (hash % 100) < rollout.Percentage
    }
    
    return false
}
```

### Asset Management

```go
type AssetManager struct {
    storage    Storage
    processor  ImageProcessor
    baseURL    string
    validator  AssetValidator
}

type Asset struct {
    ID          string            `json:"id"`
    Filename    string            `json:"filename"`
    ContentType string            `json:"content_type"`
    Size        int64             `json:"size"`
    URL         string            `json:"url"`
    Metadata    map[string]string `json:"metadata"`
    Tags        []string          `json:"tags"`
    AdminID     string            `json:"admin_id"`
    CreatedAt   time.Time         `json:"created_at"`
}

func (am *AssetManager) UploadAsset(ctx context.Context, req *UploadAssetRequest) (*Asset, error) {
    // Validate file
    if err := am.validator.ValidateFile(req.File, req.ContentType); err != nil {
        return nil, fmt.Errorf("file validation failed: %w", err)
    }
    
    // Generate asset ID
    assetID := generateAssetID()
    
    // Process image if needed
    var processedFile []byte
    if strings.HasPrefix(req.ContentType, "image/") {
        processed, err := am.processor.ProcessImage(req.File, req.ProcessingOptions)
        if err != nil {
            return nil, fmt.Errorf("image processing failed: %w", err)
        }
        processedFile = processed
    } else {
        processedFile = req.File
    }
    
    // Upload to storage
    path := fmt.Sprintf("assets/%s/%s", assetID, req.Filename)
    if err := am.storage.Upload(ctx, path, processedFile, req.ContentType); err != nil {
        return nil, fmt.Errorf("upload failed: %w", err)
    }
    
    // Create asset record
    asset := &Asset{
        ID:          assetID,
        Filename:    req.Filename,
        ContentType: req.ContentType,
        Size:        int64(len(processedFile)),
        URL:         fmt.Sprintf("%s/%s", am.baseURL, path),
        Metadata:    req.Metadata,
        Tags:        req.Tags,
        AdminID:     getUserID(ctx),
        CreatedAt:   time.Now(),
    }
    
    return asset, nil
}

type ImageProcessingOptions struct {
    Resize     *ResizeOptions     `json:"resize,omitempty"`
    Quality    int                `json:"quality,omitempty"`
    Format     string             `json:"format,omitempty"`
    Watermark  *WatermarkOptions  `json:"watermark,omitempty"`
}

type ResizeOptions struct {
    Width  int    `json:"width"`
    Height int    `json:"height"`
    Mode   string `json:"mode"` // "fit", "fill", "crop"
}
```

### HTTP API Implementation

```go
package handlers

import (
    "encoding/json"
    "net/http"
    "strconv"
    
    "github.com/gorilla/mux"
)

type ConfigHandler struct {
    service *globalconfig.ConfigService
}

func NewConfigHandler(service *globalconfig.ConfigService) *ConfigHandler {
    return &ConfigHandler{service: service}
}

func (ch *ConfigHandler) GetConfig(w http.ResponseWriter, r *http.Request) {
    vars := mux.Vars(r)
    key := vars["key"]
    environment := r.URL.Query().Get("environment")
    
    if environment == "" {
        environment = "production"
    }
    
    config, err := ch.service.GetConfig(r.Context(), key, environment)
    if err != nil {
        http.Error(w, err.Error(), http.StatusNotFound)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(config)
}

func (ch *ConfigHandler) SetConfig(w http.ResponseWriter, r *http.Request) {
    var req SetConfigRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "Invalid request body", http.StatusBadRequest)
        return
    }
    
    config, err := ch.service.SetConfig(r.Context(), &req)
    if err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusCreated)
    json.NewEncoder(w).Encode(config)
}

func (ch *ConfigHandler) GetConfigsByTags(w http.ResponseWriter, r *http.Request) {
    tags := r.URL.Query()["tags"]
    environment := r.URL.Query().Get("environment")
    
    if environment == "" {
        environment = "production"
    }
    
    configs, err := ch.service.GetConfigsByTags(r.Context(), tags, environment)
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(configs)
}

func (ch *ConfigHandler) EvaluateFeatureFlag(w http.ResponseWriter, r *http.Request) {
    vars := mux.Vars(r)
    key := vars["key"]
    
    var userContext map[string]interface{}
    if err := json.NewDecoder(r.Body).Decode(&userContext); err != nil {
        userContext = make(map[string]interface{})
    }
    
    value, err := ch.service.EvaluateFeatureFlag(r.Context(), key, userContext)
    if err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    response := map[string]interface{}{
        "key":   key,
        "value": value,
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(response)
}

// Asset upload handler
func (ch *ConfigHandler) UploadAsset(w http.ResponseWriter, r *http.Request) {
    // Parse multipart form
    if err := r.ParseMultipartForm(32 << 20); err != nil { // 32MB max
        http.Error(w, "Failed to parse form", http.StatusBadRequest)
        return
    }
    
    file, header, err := r.FormFile("file")
    if err != nil {
        http.Error(w, "No file provided", http.StatusBadRequest)
        return
    }
    defer file.Close()
    
    // Read file content
    fileBytes := make([]byte, header.Size)
    if _, err := file.Read(fileBytes); err != nil {
        http.Error(w, "Failed to read file", http.StatusInternalServerError)
        return
    }
    
    // Create upload request
    req := &UploadAssetRequest{
        File:        fileBytes,
        Filename:    header.Filename,
        ContentType: header.Header.Get("Content-Type"),
        Tags:        r.Form["tags"],
        Metadata:    make(map[string]string),
    }
    
    // Add metadata from form
    for key, values := range r.Form {
        if key != "tags" && len(values) > 0 {
            req.Metadata[key] = values[0]
        }
    }
    
    asset, err := ch.service.assets.UploadAsset(r.Context(), req)
    if err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusCreated)
    json.NewEncoder(w).Encode(asset)
}
```

### Database Schema

```sql
-- Configuration table
CREATE TABLE configs (
    id VARCHAR(36) PRIMARY KEY,
    key VARCHAR(255) NOT NULL,
    value JSONB NOT NULL,
    type VARCHAR(50) NOT NULL,
    environment VARCHAR(50) NOT NULL,
    tags TEXT[] DEFAULT '{}',
    schema JSONB,
    admin_id VARCHAR(36) NOT NULL,
    note TEXT,
    version BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,
    
    UNIQUE(key, environment)
);

-- Indexes
CREATE INDEX idx_configs_key_env ON configs(key, environment);
CREATE INDEX idx_configs_tags ON configs USING GIN(tags);
CREATE INDEX idx_configs_admin_id ON configs(admin_id);
CREATE INDEX idx_configs_created_at ON configs(created_at);

-- Config history table for audit trail
CREATE TABLE config_history (
    id VARCHAR(36) PRIMARY KEY,
    config_id VARCHAR(36) NOT NULL,
    key VARCHAR(255) NOT NULL,
    old_value JSONB,
    new_value JSONB,
    admin_id VARCHAR(36) NOT NULL,
    action VARCHAR(20) NOT NULL, -- 'created', 'updated', 'deleted'
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    FOREIGN KEY (config_id) REFERENCES configs(id)
);

-- Assets table
CREATE TABLE assets (
    id VARCHAR(36) PRIMARY KEY,
    filename VARCHAR(255) NOT NULL,
    content_type VARCHAR(100) NOT NULL,
    size BIGINT NOT NULL,
    url TEXT NOT NULL,
    metadata JSONB DEFAULT '{}',
    tags TEXT[] DEFAULT '{}',
    admin_id VARCHAR(36) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_assets_tags ON assets USING GIN(tags);
CREATE INDEX idx_assets_admin_id ON assets(admin_id);
```

### Client Libraries

```go
// Go client library
package configclient

type Client struct {
    baseURL    string
    httpClient *http.Client
    cache      Cache
}

func NewClient(baseURL string) *Client {
    return &Client{
        baseURL:    baseURL,
        httpClient: &http.Client{Timeout: 30 * time.Second},
        cache:      NewMemoryCache(),
    }
}

func (c *Client) GetString(ctx context.Context, key, environment string) (string, error) {
    config, err := c.getConfig(ctx, key, environment)
    if err != nil {
        return "", err
    }
    
    value, ok := config.Value.(string)
    if !ok {
        return "", fmt.Errorf("config %s is not a string", key)
    }
    
    return value, nil
}

func (c *Client) GetBool(ctx context.Context, key, environment string) (bool, error) {
    config, err := c.getConfig(ctx, key, environment)
    if err != nil {
        return false, err
    }
    
    value, ok := config.Value.(bool)
    if !ok {
        return false, fmt.Errorf("config %s is not a boolean", key)
    }
    
    return value, nil
}

func (c *Client) IsFeatureEnabled(ctx context.Context, key string, userContext map[string]interface{}) (bool, error) {
    url := fmt.Sprintf("%s/api/v1/flags/%s/evaluate", c.baseURL, key)
    
    body, err := json.Marshal(userContext)
    if err != nil {
        return false, err
    }
    
    req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewBuffer(body))
    if err != nil {
        return false, err
    }
    
    req.Header.Set("Content-Type", "application/json")
    
    resp, err := c.httpClient.Do(req)
    if err != nil {
        return false, err
    }
    defer resp.Body.Close()
    
    var result struct {
        Key   string      `json:"key"`
        Value interface{} `json:"value"`
    }
    
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return false, err
    }
    
    enabled, ok := result.Value.(bool)
    if !ok {
        return false, fmt.Errorf("feature flag %s returned non-boolean value", key)
    }
    
    return enabled, nil
}
```

## Consequences

### Positive
- **Centralized management**: Single source of truth for all configuration
- **Dynamic updates**: Change configuration without deployments
- **Rich validation**: JSON schema validation ensures configuration correctness
- **Asset integration**: Unified service for both configuration and assets
- **Audit trail**: Complete history of configuration changes
- **Multi-environment support**: Separate configurations per environment
- **API access**: RESTful interface for integration with other services

### Negative
- **Single point of failure**: Configuration service becomes critical dependency
- **Complexity**: Additional infrastructure and operational overhead
- **Cache invalidation**: Challenging to ensure consistency across services
- **Security concerns**: Centralized sensitive configuration requires careful access control
- **Performance impact**: Network latency for configuration lookups

### Mitigation Strategies
- **High availability**: Deploy configuration service with redundancy
- **Local caching**: Implement intelligent caching to reduce latency
- **Graceful degradation**: Services should handle configuration service outages
- **Security**: Implement robust authentication and authorization
- **Monitoring**: Comprehensive monitoring and alerting for configuration service

## Best Practices

1. **Use schema validation**: Always validate configuration against schemas
2. **Implement audit logging**: Track all configuration changes with attribution
3. **Cache intelligently**: Use appropriate cache TTLs and invalidation strategies
4. **Secure access**: Implement role-based access control and rate limiting
5. **Test changes**: Validate configuration changes in non-production environments first
6. **Monitor usage**: Track configuration access patterns and performance
7. **Document schemas**: Maintain clear documentation for all configuration schemas
8. **Version control**: Keep configuration schemas and documentation in version control

## References

- [AWS AppConfig](https://docs.aws.amazon.com/appconfig/)
- [Google Firebase Remote Config](https://firebase.google.com/docs/remote-config)
- [HashiCorp Consul](https://www.consul.io/docs/dynamic-app-config)
- [etcd Configuration Management](https://etcd.io/)
- [JSON Schema Specification](https://json-schema.org/)
- [Feature Flag Best Practices](https://launchdarkly.com/blog/dos-and-donts-of-feature-flagging/)
