# External Config

## Status
Accepted

## Context
Configuration management becomes complex as applications scale across multiple environments and services. External configuration management provides centralized, versioned, and auditable configuration while separating configuration from application code, enabling better security, deployment flexibility, and operational control.

## Decision
We will implement external configuration management using Git-based versioning with support for multiple backends (Git repositories, cloud services, configuration servers) to enable centralized configuration management, version control, and environment-specific deployments.

## Rationale

### Benefits
- **Version Control**: Configuration changes are tracked and auditable
- **Environment Separation**: Different configurations for different environments
- **Security**: Sensitive data can be encrypted and managed separately
- **Deployment Independence**: Configuration changes without code deployment
- **Centralized Management**: Single source of truth for configuration
- **Rollback Capability**: Easy rollback to previous configurations

### Use Cases
- Multi-environment deployments (dev, staging, prod)
- Feature flag management
- Database connection strings and credentials
- Third-party service configurations
- Application behavior tuning
- Security policy configurations

## Implementation

### Configuration Management System

```go
package config

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ConfigManager handles external configuration management
type ConfigManager struct {
	providers []ConfigProvider
	cache     map[string]*ConfigValue
	cacheMu   sync.RWMutex
	watchers  []ConfigWatcher
	logger    Logger
}

// ConfigProvider interface for different configuration sources
type ConfigProvider interface {
	Name() string
	Fetch(ctx context.Context, key string) (*ConfigValue, error)
	Watch(ctx context.Context, key string, callback func(*ConfigValue)) error
	List(ctx context.Context, prefix string) ([]*ConfigValue, error)
}

// ConfigValue represents a configuration value with metadata
type ConfigValue struct {
	Key         string                 `json:"key"`
	Value       interface{}            `json:"value"`
	Environment string                 `json:"environment"`
	Version     string                 `json:"version"`
	Source      string                 `json:"source"`
	Encrypted   bool                   `json:"encrypted"`
	Metadata    map[string]interface{} `json:"metadata"`
	UpdatedAt   time.Time              `json:"updated_at"`
	TTL         time.Duration          `json:"ttl,omitempty"`
}

// ConfigWatcher handles configuration change notifications
type ConfigWatcher struct {
	Key      string
	Callback func(*ConfigValue)
}

type Logger interface {
	Info(msg string, fields ...interface{})
	Error(msg string, err error, fields ...interface{})
	Debug(msg string, fields ...interface{})
}

func NewConfigManager(providers []ConfigProvider, logger Logger) *ConfigManager {
	return &ConfigManager{
		providers: providers,
		cache:     make(map[string]*ConfigValue),
		watchers:  make([]ConfigWatcher, 0),
		logger:    logger,
	}
}

// Get retrieves a configuration value
func (cm *ConfigManager) Get(ctx context.Context, key string) (*ConfigValue, error) {
	// Check cache first
	cm.cacheMu.RLock()
	if cached, exists := cm.cache[key]; exists {
		if !cm.isExpired(cached) {
			cm.cacheMu.RUnlock()
			return cached, nil
		}
	}
	cm.cacheMu.RUnlock()

	// Try providers in order
	var lastErr error
	for _, provider := range cm.providers {
		value, err := provider.Fetch(ctx, key)
		if err != nil {
			lastErr = err
			cm.logger.Debug("Provider failed", "provider", provider.Name(), "key", key, "error", err)
			continue
		}

		// Cache the value
		cm.cacheValue(key, value)
		
		cm.logger.Info("Configuration fetched", "key", key, "source", value.Source)
		return value, nil
	}

	return nil, fmt.Errorf("configuration key not found: %s, last error: %v", key, lastErr)
}

// GetString retrieves a string configuration value
func (cm *ConfigManager) GetString(ctx context.Context, key, defaultValue string) string {
	value, err := cm.Get(ctx, key)
	if err != nil {
		cm.logger.Error("Failed to get config", err, "key", key)
		return defaultValue
	}

	if str, ok := value.Value.(string); ok {
		return str
	}

	return defaultValue
}

// GetInt retrieves an integer configuration value
func (cm *ConfigManager) GetInt(ctx context.Context, key string, defaultValue int) int {
	value, err := cm.Get(ctx, key)
	if err != nil {
		return defaultValue
	}

	switch v := value.Value.(type) {
	case int:
		return v
	case float64:
		return int(v)
	case string:
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}

	return defaultValue
}

// GetBool retrieves a boolean configuration value
func (cm *ConfigManager) GetBool(ctx context.Context, key string, defaultValue bool) bool {
	value, err := cm.Get(ctx, key)
	if err != nil {
		return defaultValue
	}

	if b, ok := value.Value.(bool); ok {
		return b
	}

	return defaultValue
}

// Watch registers a watcher for configuration changes
func (cm *ConfigManager) Watch(ctx context.Context, key string, callback func(*ConfigValue)) error {
	watcher := ConfigWatcher{
		Key:      key,
		Callback: callback,
	}
	cm.watchers = append(cm.watchers, watcher)

	// Set up watchers with all providers
	for _, provider := range cm.providers {
		if err := provider.Watch(ctx, key, cm.handleConfigChange); err != nil {
			cm.logger.Error("Failed to set up watcher", err, "provider", provider.Name(), "key", key)
		}
	}

	return nil
}

// List retrieves all configuration values with a given prefix
func (cm *ConfigManager) List(ctx context.Context, prefix string) ([]*ConfigValue, error) {
	var allValues []*ConfigValue
	seen := make(map[string]bool)

	for _, provider := range cm.providers {
		values, err := provider.List(ctx, prefix)
		if err != nil {
			cm.logger.Error("Provider list failed", err, "provider", provider.Name(), "prefix", prefix)
			continue
		}

		for _, value := range values {
			if !seen[value.Key] {
				allValues = append(allValues, value)
				seen[value.Key] = true
			}
		}
	}

	return allValues, nil
}

func (cm *ConfigManager) cacheValue(key string, value *ConfigValue) {
	cm.cacheMu.Lock()
	defer cm.cacheMu.Unlock()
	cm.cache[key] = value
}

func (cm *ConfigManager) isExpired(value *ConfigValue) bool {
	if value.TTL == 0 {
		return false
	}
	return time.Since(value.UpdatedAt) > value.TTL
}

func (cm *ConfigManager) handleConfigChange(value *ConfigValue) {
	// Update cache
	cm.cacheValue(value.Key, value)

	// Notify watchers
	for _, watcher := range cm.watchers {
		if watcher.Key == value.Key {
			go watcher.Callback(value)
		}
	}

	cm.logger.Info("Configuration updated", "key", value.Key, "source", value.Source)
}
```

### Git-based Configuration Provider

```go
package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"your-app/config"
)

// GitConfigProvider fetches configuration from Git repositories
type GitConfigProvider struct {
	name        string
	repoURL     string
	branch      string
	localPath   string
	environment string
	encryptor   Encryptor
	refreshInterval time.Duration
	lastSync    time.Time
}

type Encryptor interface {
	Decrypt(encrypted string) (string, error)
	Encrypt(plaintext string) (string, error)
}

func NewGitConfigProvider(name, repoURL, branch, localPath, environment string, encryptor Encryptor) *GitConfigProvider {
	return &GitConfigProvider{
		name:            name,
		repoURL:         repoURL,
		branch:          branch,
		localPath:       localPath,
		environment:     environment,
		encryptor:       encryptor,
		refreshInterval: 5 * time.Minute,
	}
}

func (gcp *GitConfigProvider) Name() string {
	return gcp.name
}

func (gcp *GitConfigProvider) Fetch(ctx context.Context, key string) (*config.ConfigValue, error) {
	if err := gcp.syncRepo(ctx); err != nil {
		return nil, fmt.Errorf("failed to sync repo: %w", err)
	}

	// Look for environment-specific config first
	envConfigPath := filepath.Join(gcp.localPath, gcp.environment, key+".json")
	if value, err := gcp.loadConfigFile(envConfigPath, key); err == nil {
		return value, nil
	}

	// Fall back to common config
	commonConfigPath := filepath.Join(gcp.localPath, "common", key+".json")
	if value, err := gcp.loadConfigFile(commonConfigPath, key); err == nil {
		return value, nil
	}

	return nil, fmt.Errorf("configuration key not found: %s", key)
}

func (gcp *GitConfigProvider) Watch(ctx context.Context, key string, callback func(*config.ConfigValue)) error {
	// Implement file watching or periodic polling
	go gcp.watchForChanges(ctx, key, callback)
	return nil
}

func (gcp *GitConfigProvider) List(ctx context.Context, prefix string) ([]*config.ConfigValue, error) {
	if err := gcp.syncRepo(ctx); err != nil {
		return nil, fmt.Errorf("failed to sync repo: %w", err)
	}

	var values []*config.ConfigValue

	// List from environment directory
	envDir := filepath.Join(gcp.localPath, gcp.environment)
	if envValues, err := gcp.loadConfigsFromDir(envDir, prefix); err == nil {
		values = append(values, envValues...)
	}

	// List from common directory
	commonDir := filepath.Join(gcp.localPath, "common")
	if commonValues, err := gcp.loadConfigsFromDir(commonDir, prefix); err == nil {
		values = append(values, commonValues...)
	}

	return values, nil
}

func (gcp *GitConfigProvider) syncRepo(ctx context.Context) error {
	// Check if sync is needed
	if time.Since(gcp.lastSync) < gcp.refreshInterval {
		return nil
	}

	// Clone or pull repository
	if _, err := os.Stat(gcp.localPath); os.IsNotExist(err) {
		return gcp.cloneRepo(ctx)
	} else {
		return gcp.pullRepo(ctx)
	}
}

func (gcp *GitConfigProvider) cloneRepo(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, "git", "clone", "-b", gcp.branch, gcp.repoURL, gcp.localPath)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to clone repo: %w", err)
	}
	gcp.lastSync = time.Now()
	return nil
}

func (gcp *GitConfigProvider) pullRepo(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, "git", "-C", gcp.localPath, "pull", "origin", gcp.branch)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to pull repo: %w", err)
	}
	gcp.lastSync = time.Now()
	return nil
}

func (gcp *GitConfigProvider) loadConfigFile(filePath, key string) (*config.ConfigValue, error) {
	data, err := ioutil.ReadFile(filePath)
	if err != nil {
		return nil, err
	}

	var configData map[string]interface{}
	if err := json.Unmarshal(data, &configData); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	value := &config.ConfigValue{
		Key:         key,
		Value:       configData["value"],
		Environment: gcp.environment,
		Source:      gcp.name,
		UpdatedAt:   time.Now(),
	}

	// Handle encrypted values
	if encrypted, ok := configData["encrypted"].(bool); ok && encrypted {
		if gcp.encryptor != nil {
			if encryptedValue, ok := value.Value.(string); ok {
				decrypted, err := gcp.encryptor.Decrypt(encryptedValue)
				if err != nil {
					return nil, fmt.Errorf("failed to decrypt value: %w", err)
				}
				value.Value = decrypted
				value.Encrypted = true
			}
		}
	}

	// Handle metadata
	if metadata, ok := configData["metadata"].(map[string]interface{}); ok {
		value.Metadata = metadata
	}

	// Handle TTL
	if ttlSeconds, ok := configData["ttl"].(float64); ok {
		value.TTL = time.Duration(ttlSeconds) * time.Second
	}

	return value, nil
}

func (gcp *GitConfigProvider) loadConfigsFromDir(dirPath, prefix string) ([]*config.ConfigValue, error) {
	var values []*config.ConfigValue

	err := filepath.Walk(dirPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		if !info.IsDir() && strings.HasSuffix(path, ".json") {
			key := strings.TrimSuffix(info.Name(), ".json")
			if prefix == "" || strings.HasPrefix(key, prefix) {
				if value, err := gcp.loadConfigFile(path, key); err == nil {
					values = append(values, value)
				}
			}
		}

		return nil
	})

	return values, err
}

func (gcp *GitConfigProvider) watchForChanges(ctx context.Context, key string, callback func(*config.ConfigValue)) {
	ticker := time.NewTicker(gcp.refreshInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if value, err := gcp.Fetch(ctx, key); err == nil {
				callback(value)
			}
		}
	}
}
```

### Environment Variable Provider

```go
package providers

import (
	"context"
	"os"
	"strings"
	"time"
	"your-app/config"
)

// EnvConfigProvider fetches configuration from environment variables
type EnvConfigProvider struct {
	name   string
	prefix string
}

func NewEnvConfigProvider(name, prefix string) *EnvConfigProvider {
	return &EnvConfigProvider{
		name:   name,
		prefix: prefix,
	}
}

func (ecp *EnvConfigProvider) Name() string {
	return ecp.name
}

func (ecp *EnvConfigProvider) Fetch(ctx context.Context, key string) (*config.ConfigValue, error) {
	envKey := ecp.buildEnvKey(key)
	value := os.Getenv(envKey)
	
	if value == "" {
		return nil, fmt.Errorf("environment variable not found: %s", envKey)
	}

	return &config.ConfigValue{
		Key:       key,
		Value:     value,
		Source:    ecp.name,
		UpdatedAt: time.Now(),
	}, nil
}

func (ecp *EnvConfigProvider) Watch(ctx context.Context, key string, callback func(*config.ConfigValue)) error {
	// Environment variables don't change during runtime typically
	// This could be implemented with file system watching for .env files
	return nil
}

func (ecp *EnvConfigProvider) List(ctx context.Context, prefix string) ([]*config.ConfigValue, error) {
	var values []*config.ConfigValue
	envPrefix := ecp.buildEnvKey(prefix)

	for _, env := range os.Environ() {
		if strings.HasPrefix(env, envPrefix) {
			parts := strings.SplitN(env, "=", 2)
			if len(parts) == 2 {
				key := ecp.extractKey(parts[0])
				value := &config.ConfigValue{
					Key:       key,
					Value:     parts[1],
					Source:    ecp.name,
					UpdatedAt: time.Now(),
				}
				values = append(values, value)
			}
		}
	}

	return values, nil
}

func (ecp *EnvConfigProvider) buildEnvKey(key string) string {
	if ecp.prefix == "" {
		return strings.ToUpper(strings.ReplaceAll(key, ".", "_"))
	}
	return fmt.Sprintf("%s_%s", ecp.prefix, strings.ToUpper(strings.ReplaceAll(key, ".", "_")))
}

func (ecp *EnvConfigProvider) extractKey(envKey string) string {
	if ecp.prefix != "" {
		envKey = strings.TrimPrefix(envKey, ecp.prefix+"_")
	}
	return strings.ToLower(strings.ReplaceAll(envKey, "_", "."))
}
```

### Configuration Server Integration

```go
package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"
	"your-app/config"
)

// HTTPConfigProvider fetches configuration from HTTP endpoints
type HTTPConfigProvider struct {
	name       string
	baseURL    string
	apiKey     string
	httpClient *http.Client
	headers    map[string]string
}

func NewHTTPConfigProvider(name, baseURL, apiKey string) *HTTPConfigProvider {
	return &HTTPConfigProvider{
		name:    name,
		baseURL: baseURL,
		apiKey:  apiKey,
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
		headers: make(map[string]string),
	}
}

func (hcp *HTTPConfigProvider) Name() string {
	return hcp.name
}

func (hcp *HTTPConfigProvider) Fetch(ctx context.Context, key string) (*config.ConfigValue, error) {
	url := fmt.Sprintf("%s/config/%s", hcp.baseURL, url.PathEscape(key))
	
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}

	// Add authentication
	if hcp.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+hcp.apiKey)
	}

	// Add custom headers
	for k, v := range hcp.headers {
		req.Header.Set(k, v)
	}

	resp, err := hcp.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("configuration key not found: %s", key)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP error: %d", resp.StatusCode)
	}

	var result config.ConfigValue
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	result.Source = hcp.name
	return &result, nil
}

func (hcp *HTTPConfigProvider) Watch(ctx context.Context, key string, callback func(*config.ConfigValue)) error {
	// Implement WebSocket or Server-Sent Events for real-time updates
	// For now, use polling
	go hcp.pollForChanges(ctx, key, callback)
	return nil
}

func (hcp *HTTPConfigProvider) List(ctx context.Context, prefix string) ([]*config.ConfigValue, error) {
	url := fmt.Sprintf("%s/config", hcp.baseURL)
	if prefix != "" {
		url += "?prefix=" + url.QueryEscape(prefix)
	}

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}

	if hcp.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+hcp.apiKey)
	}

	resp, err := hcp.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP error: %d", resp.StatusCode)
	}

	var result struct {
		Configs []*config.ConfigValue `json:"configs"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	for _, cfg := range result.Configs {
		cfg.Source = hcp.name
	}

	return result.Configs, nil
}

func (hcp *HTTPConfigProvider) pollForChanges(ctx context.Context, key string, callback func(*config.ConfigValue)) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	var lastVersion string

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if value, err := hcp.Fetch(ctx, key); err == nil {
				if value.Version != lastVersion {
					lastVersion = value.Version
					callback(value)
				}
			}
		}
	}
}
```

### Usage Examples and Integration

```go
package main

import (
	"context"
	"log"
	"time"
	"your-app/config"
	"your-app/providers"
)

// Application configuration structure
type AppConfig struct {
	Database DatabaseConfig `json:"database"`
	Redis    RedisConfig    `json:"redis"`
	Features FeatureFlags   `json:"features"`
	Limits   RateLimits     `json:"limits"`
}

type DatabaseConfig struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Name     string `json:"name"`
	Username string `json:"username"`
	Password string `json:"password"`
	MaxConns int    `json:"max_connections"`
}

type RedisConfig struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Password string `json:"password"`
	DB       int    `json:"db"`
}

type FeatureFlags struct {
	NewUI       bool `json:"new_ui"`
	BetaFeature bool `json:"beta_feature"`
	Maintenance bool `json:"maintenance_mode"`
}

type RateLimits struct {
	RequestsPerMinute int `json:"requests_per_minute"`
	BurstSize         int `json:"burst_size"`
}

func main() {
	// Initialize configuration providers
	providers := []config.ConfigProvider{
		providers.NewEnvConfigProvider("env", "MYAPP"),
		providers.NewGitConfigProvider(
			"git-config",
			"https://github.com/myorg/app-config.git",
			"main",
			"/tmp/app-config",
			"production",
			nil, // Add encryption provider if needed
		),
		providers.NewHTTPConfigProvider(
			"config-server",
			"https://config.myapp.com",
			"your-api-key",
		),
	}

	// Create logger (implement according to your logging framework)
	logger := &SimpleLogger{}

	// Initialize configuration manager
	configManager := config.NewConfigManager(providers, logger)

	// Load application configuration
	appConfig, err := loadAppConfig(context.Background(), configManager)
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Set up configuration watchers for dynamic updates
	setupConfigWatchers(context.Background(), configManager, appConfig)

	// Use configuration
	log.Printf("Database: %s:%d", appConfig.Database.Host, appConfig.Database.Port)
	log.Printf("Features enabled: NewUI=%v, Beta=%v", 
		appConfig.Features.NewUI, appConfig.Features.BetaFeature)

	// Your application logic here...
}

func loadAppConfig(ctx context.Context, cm *config.ConfigManager) (*AppConfig, error) {
	cfg := &AppConfig{}

	// Load database configuration
	cfg.Database.Host = cm.GetString(ctx, "database.host", "localhost")
	cfg.Database.Port = cm.GetInt(ctx, "database.port", 5432)
	cfg.Database.Name = cm.GetString(ctx, "database.name", "myapp")
	cfg.Database.Username = cm.GetString(ctx, "database.username", "postgres")
	cfg.Database.Password = cm.GetString(ctx, "database.password", "")
	cfg.Database.MaxConns = cm.GetInt(ctx, "database.max_connections", 10)

	// Load Redis configuration
	cfg.Redis.Host = cm.GetString(ctx, "redis.host", "localhost")
	cfg.Redis.Port = cm.GetInt(ctx, "redis.port", 6379)
	cfg.Redis.Password = cm.GetString(ctx, "redis.password", "")
	cfg.Redis.DB = cm.GetInt(ctx, "redis.db", 0)

	// Load feature flags
	cfg.Features.NewUI = cm.GetBool(ctx, "features.new_ui", false)
	cfg.Features.BetaFeature = cm.GetBool(ctx, "features.beta_feature", false)
	cfg.Features.Maintenance = cm.GetBool(ctx, "features.maintenance_mode", false)

	// Load rate limits
	cfg.Limits.RequestsPerMinute = cm.GetInt(ctx, "limits.requests_per_minute", 1000)
	cfg.Limits.BurstSize = cm.GetInt(ctx, "limits.burst_size", 100)

	return cfg, nil
}

func setupConfigWatchers(ctx context.Context, cm *config.ConfigManager, appConfig *AppConfig) {
	// Watch for feature flag changes
	cm.Watch(ctx, "features.maintenance_mode", func(value *config.ConfigValue) {
		if maintenanceMode, ok := value.Value.(bool); ok {
			appConfig.Features.Maintenance = maintenanceMode
			log.Printf("Maintenance mode updated: %v", maintenanceMode)
			
			// Trigger application behavior change
			handleMaintenanceModeChange(maintenanceMode)
		}
	})

	// Watch for rate limit changes
	cm.Watch(ctx, "limits.requests_per_minute", func(value *config.ConfigValue) {
		if limit, ok := value.Value.(float64); ok {
			appConfig.Limits.RequestsPerMinute = int(limit)
			log.Printf("Rate limit updated: %d", int(limit))
			
			// Update rate limiter configuration
			updateRateLimiter(int(limit))
		}
	})
}

func handleMaintenanceModeChange(maintenanceMode bool) {
	// Implement maintenance mode logic
	if maintenanceMode {
		log.Println("Entering maintenance mode")
		// Drain connections, stop accepting new requests, etc.
	} else {
		log.Println("Exiting maintenance mode")
		// Resume normal operations
	}
}

func updateRateLimiter(newLimit int) {
	// Update rate limiter with new configuration
	log.Printf("Updating rate limiter to %d requests per minute", newLimit)
}

// SimpleLogger implements the Logger interface
type SimpleLogger struct{}

func (l *SimpleLogger) Info(msg string, fields ...interface{}) {
	log.Printf("[INFO] %s %v", msg, fields)
}

func (l *SimpleLogger) Error(msg string, err error, fields ...interface{}) {
	log.Printf("[ERROR] %s: %v %v", msg, err, fields)
}

func (l *SimpleLogger) Debug(msg string, fields ...interface{}) {
	log.Printf("[DEBUG] %s %v", msg, fields)
}
```

### Configuration Structure Examples

#### Git Repository Structure
```
config-repo/
├── common/
│   ├── database.json
│   ├── redis.json
│   └── features.json
├── development/
│   ├── database.json
│   └── features.json
├── staging/
│   ├── database.json
│   └── features.json
├── production/
│   ├── database.json
│   ├── redis.json
│   └── features.json
└── README.md
```

#### Configuration File Examples

**database.json (production)**
```json
{
  "value": {
    "host": "prod-db.example.com",
    "port": 5432,
    "name": "myapp_prod",
    "username": "app_user",
    "max_connections": 50
  },
  "metadata": {
    "description": "Production database configuration",
    "owner": "platform-team",
    "last_updated_by": "alice@example.com"
  },
  "ttl": 3600
}
```

**features.json (with encrypted password)**
```json
{
  "value": {
    "new_ui": true,
    "beta_feature": false,
    "maintenance_mode": false,
    "admin_password": "encrypted:AES256:abcd1234..."
  },
  "encrypted": true,
  "metadata": {
    "description": "Feature flags",
    "requires_restart": false
  }
}
```

## Best Practices

### 1. Configuration Organization
- **Environment Separation**: Separate configs by environment
- **Hierarchical Structure**: Use clear key hierarchies
- **Version Control**: Track all configuration changes
- **Documentation**: Document configuration purpose and format

### 2. Security
- **Encryption**: Encrypt sensitive configuration values
- **Access Control**: Restrict access to configuration repositories
- **Audit Logging**: Log all configuration access and changes
- **Secret Management**: Use dedicated secret management for credentials

### 3. Deployment and Rollback
- **Gradual Rollout**: Test configuration changes in staging first
- **Rollback Strategy**: Maintain ability to quickly rollback changes
- **Health Checks**: Validate configuration before applying
- **Monitoring**: Monitor application behavior after config changes

### 4. Performance
- **Caching**: Cache frequently accessed configurations
- **Batching**: Batch configuration reads when possible
- **Lazy Loading**: Load configurations on demand
- **TTL Management**: Set appropriate cache TTLs

### 5. Development Workflow
- **Local Development**: Support local configuration overrides
- **Testing**: Include configuration in automated tests
- **Documentation**: Maintain up-to-date configuration documentation
- **Validation**: Validate configuration format and values

## Migration Strategies

### From Local to External Configuration
1. **Audit Current Configuration**: Identify all configuration sources
2. **Create Configuration Schema**: Define configuration structure
3. **Set Up External Storage**: Choose and configure storage backend
4. **Implement Configuration Manager**: Add external config support
5. **Gradual Migration**: Move configurations incrementally
6. **Validate and Test**: Ensure all configurations work correctly
7. **Remove Local Configuration**: Clean up local config files

### Configuration Provider Migration
```go
// Migration helper
func migrateConfiguration(oldProvider, newProvider config.ConfigProvider) error {
	ctx := context.Background()
	
	// List all configurations from old provider
	configs, err := oldProvider.List(ctx, "")
	if err != nil {
		return err
	}
	
	// Migrate each configuration to new provider
	for _, cfg := range configs {
		// Validate and transform if needed
		if err := validateConfig(cfg); err != nil {
			log.Printf("Skipping invalid config %s: %v", cfg.Key, err)
			continue
		}
		
		// Store in new provider (implementation depends on provider)
		if err := storeConfig(newProvider, cfg); err != nil {
			log.Printf("Failed to migrate config %s: %v", cfg.Key, err)
		}
	}
	
	return nil
}
```

## Consequences

### Positive
- **Version Control**: All configuration changes are tracked and auditable
- **Environment Management**: Clear separation between different environments
- **Dynamic Updates**: Configuration can be changed without code deployment
- **Centralized Management**: Single source of truth for all configurations
- **Security**: Sensitive data can be encrypted and managed securely
- **Rollback Capability**: Easy to rollback to previous configurations

### Negative
- **Complexity**: Additional infrastructure and management overhead
- **Dependencies**: Application depends on external configuration services
- **Network Requirements**: Need network access to configuration sources
- **Caching Challenges**: Need to balance freshness with performance
- **Debugging**: More complex debugging when configuration issues occur

### Mitigation
- **Fallback Mechanisms**: Provide default values and fallback configurations
- **Local Caching**: Cache configurations locally to handle network issues
- **Monitoring**: Monitor configuration service health and performance
- **Documentation**: Maintain comprehensive configuration documentation
- **Testing**: Include configuration testing in CI/CD pipelines

## Related Patterns
- [010-config.md](010-config.md) - Application configuration management
- [015-global-config.md](015-global-config.md) - Global configuration patterns
- [016-versioned-config.md](016-versioned-config.md) - Configuration versioning
- [013-logging.md](013-logging.md) - Configuration change logging
