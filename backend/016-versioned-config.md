# Versioned Configuration Management

## Status

`accepted`

## Context

Configuration management becomes complex in distributed systems with multiple environments and services. Traditional approaches of embedding configurations directly in application code or using environment variables have limitations:

- No audit trail for configuration changes
- Difficult to rollback configuration changes
- No atomic updates across multiple services
- Lack of schema validation and type safety
- Difficulty in managing configuration drift across environments

Using version-controlled configuration repositories provides better control, auditability, and deployment practices for configuration management.

## Decision

We will implement versioned configuration management using Git-based repositories with package management tools to distribute configurations across services and environments.

### Configuration Repository Structure

```
config-repo/
├── environments/
│   ├── development/
│   │   ├── api-service.yaml
│   │   ├── worker-service.yaml
│   │   └── database.yaml
│   ├── staging/
│   │   ├── api-service.yaml
│   │   ├── worker-service.yaml
│   │   └── database.yaml
│   └── production/
│       ├── api-service.yaml
│       ├── worker-service.yaml
│       └── database.yaml
├── schemas/
│   ├── api-service.schema.json
│   ├── worker-service.schema.json
│   └── database.schema.json
├── templates/
│   ├── service.template.yaml
│   └── database.template.yaml
└── scripts/
    ├── validate.sh
    ├── deploy.sh
    └── rollback.sh
```

### Implementation with Go

```go
package config

import (
    "context"
    "encoding/json"
    "fmt"
    "os"
    "path/filepath"
    "time"

    "gopkg.in/yaml.v3"
    "github.com/go-git/go-git/v5"
    "github.com/go-git/go-git/v5/plumbing"
)

// ConfigManager handles versioned configuration
type ConfigManager struct {
    repoURL     string
    localPath   string
    branch      string
    version     string
    environment string
}

// NewConfigManager creates a new configuration manager
func NewConfigManager(repoURL, localPath, branch, version, env string) *ConfigManager {
    return &ConfigManager{
        repoURL:     repoURL,
        localPath:   localPath,
        branch:      branch,
        version:     version,
        environment: env,
    }
}

// FetchConfig retrieves configuration from the versioned repository
func (cm *ConfigManager) FetchConfig(ctx context.Context) error {
    // Clone or pull the configuration repository
    repo, err := git.PlainClone(cm.localPath, false, &git.CloneOptions{
        URL:           cm.repoURL,
        ReferenceName: plumbing.ReferenceName(fmt.Sprintf("refs/heads/%s", cm.branch)),
        SingleBranch:  true,
    })
    
    if err != nil {
        // If already exists, try to pull
        repo, err = git.PlainOpen(cm.localPath)
        if err != nil {
            return fmt.Errorf("failed to open repository: %w", err)
        }
        
        workTree, err := repo.Worktree()
        if err != nil {
            return fmt.Errorf("failed to get worktree: %w", err)
        }
        
        err = workTree.Pull(&git.PullOptions{
            ReferenceName: plumbing.ReferenceName(fmt.Sprintf("refs/heads/%s", cm.branch)),
        })
        if err != nil && err != git.NoErrAlreadyUpToDate {
            return fmt.Errorf("failed to pull: %w", err)
        }
    }
    
    // Checkout specific version if provided
    if cm.version != "" {
        workTree, err := repo.Worktree()
        if err != nil {
            return fmt.Errorf("failed to get worktree: %w", err)
        }
        
        err = workTree.Checkout(&git.CheckoutOptions{
            Hash: plumbing.NewHash(cm.version),
        })
        if err != nil {
            return fmt.Errorf("failed to checkout version %s: %w", cm.version, err)
        }
    }
    
    return nil
}

// LoadConfig loads configuration for a specific service
func (cm *ConfigManager) LoadConfig(serviceName string, config interface{}) error {
    configPath := filepath.Join(
        cm.localPath,
        "environments",
        cm.environment,
        fmt.Sprintf("%s.yaml", serviceName),
    )
    
    data, err := os.ReadFile(configPath)
    if err != nil {
        return fmt.Errorf("failed to read config file: %w", err)
    }
    
    err = yaml.Unmarshal(data, config)
    if err != nil {
        return fmt.Errorf("failed to unmarshal config: %w", err)
    }
    
    return nil
}

// ValidateConfig validates configuration against schema
func (cm *ConfigManager) ValidateConfig(serviceName string, config interface{}) error {
    schemaPath := filepath.Join(
        cm.localPath,
        "schemas",
        fmt.Sprintf("%s.schema.json", serviceName),
    )
    
    schemaData, err := os.ReadFile(schemaPath)
    if err != nil {
        return fmt.Errorf("failed to read schema file: %w", err)
    }
    
    // Validate using JSON schema (implementation depends on chosen library)
    // This is a simplified example
    return validateJSONSchema(schemaData, config)
}

// ConfigWatcher monitors configuration changes
type ConfigWatcher struct {
    manager  *ConfigManager
    interval time.Duration
    onChange func(string)
}

// NewConfigWatcher creates a configuration watcher
func NewConfigWatcher(manager *ConfigManager, interval time.Duration, onChange func(string)) *ConfigWatcher {
    return &ConfigWatcher{
        manager:  manager,
        interval: interval,
        onChange: onChange,
    }
}

// Start begins watching for configuration changes
func (cw *ConfigWatcher) Start(ctx context.Context) error {
    ticker := time.NewTicker(cw.interval)
    defer ticker.Stop()
    
    lastCommit := ""
    
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-ticker.C:
            currentCommit, err := cw.getCurrentCommit()
            if err != nil {
                continue
            }
            
            if lastCommit != "" && lastCommit != currentCommit {
                cw.onChange("Configuration updated")
            }
            lastCommit = currentCommit
        }
    }
}

func (cw *ConfigWatcher) getCurrentCommit() (string, error) {
    repo, err := git.PlainOpen(cw.manager.localPath)
    if err != nil {
        return "", err
    }
    
    ref, err := repo.Head()
    if err != nil {
        return "", err
    }
    
    return ref.Hash().String(), nil
}

// Service configuration example
type APIServiceConfig struct {
    Server struct {
        Port    int    `yaml:"port" json:"port"`
        Host    string `yaml:"host" json:"host"`
        Timeout int    `yaml:"timeout" json:"timeout"`
    } `yaml:"server" json:"server"`
    
    Database struct {
        Host     string `yaml:"host" json:"host"`
        Port     int    `yaml:"port" json:"port"`
        Database string `yaml:"database" json:"database"`
        Username string `yaml:"username" json:"username"`
        Password string `yaml:"password" json:"password"`
    } `yaml:"database" json:"database"`
    
    Redis struct {
        Host     string `yaml:"host" json:"host"`
        Port     int    `yaml:"port" json:"port"`
        Password string `yaml:"password" json:"password"`
    } `yaml:"redis" json:"redis"`
    
    Features struct {
        EnableMetrics   bool `yaml:"enable_metrics" json:"enable_metrics"`
        EnableTracing   bool `yaml:"enable_tracing" json:"enable_tracing"`
        EnableRateLimit bool `yaml:"enable_rate_limit" json:"enable_rate_limit"`
    } `yaml:"features" json:"features"`
}

// Usage example
func ExampleUsage() error {
    ctx := context.Background()
    
    // Initialize configuration manager
    configManager := NewConfigManager(
        "https://github.com/company/config-repo.git",
        "/tmp/config",
        "main",
        "v1.2.3", // specific version
        "production",
    )
    
    // Fetch configuration
    err := configManager.FetchConfig(ctx)
    if err != nil {
        return fmt.Errorf("failed to fetch config: %w", err)
    }
    
    // Load service configuration
    var apiConfig APIServiceConfig
    err = configManager.LoadConfig("api-service", &apiConfig)
    if err != nil {
        return fmt.Errorf("failed to load config: %w", err)
    }
    
    // Validate configuration
    err = configManager.ValidateConfig("api-service", &apiConfig)
    if err != nil {
        return fmt.Errorf("config validation failed: %w", err)
    }
    
    // Start configuration watcher
    watcher := NewConfigWatcher(configManager, 30*time.Second, func(msg string) {
        fmt.Printf("Configuration change detected: %s\n", msg)
        // Reload and restart services as needed
    })
    
    go watcher.Start(ctx)
    
    return nil
}

func validateJSONSchema(schema []byte, config interface{}) error {
    // Implementation depends on chosen JSON schema library
    // Example: github.com/xeipuuv/gojsonschema
    return nil
}
```

### Configuration Deployment Pipeline

```yaml
# .github/workflows/config-deploy.yml
name: Deploy Configuration

on:
  push:
    branches: [main, staging, development]
    tags: ['v*']

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Validate Configuration Schema
        run: |
          for schema in schemas/*.schema.json; do
            for env in environments/*/; do
              service=$(basename "$schema" .schema.json)
              config="$env$service.yaml"
              if [ -f "$config" ]; then
                echo "Validating $config against $schema"
                # Use ajv-cli or similar tool
                ajv validate -s "$schema" -d "$config"
              fi
            done
          done
      
      - name: Run Configuration Tests
        run: |
          ./scripts/validate.sh

  deploy:
    needs: validate
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v3
      
      - name: Create Release
        run: |
          git tag "v$(date +%Y%m%d%H%M%S)"
          git push origin --tags
      
      - name: Deploy to Production
        run: |
          ./scripts/deploy.sh production
```

### Docker Integration

```dockerfile
# Multi-stage build for configuration
FROM alpine/git as config-fetcher
ARG CONFIG_REPO_URL
ARG CONFIG_VERSION=main
ARG CONFIG_TOKEN

WORKDIR /config
RUN git clone --depth 1 --branch ${CONFIG_VERSION} \
    https://${CONFIG_TOKEN}@${CONFIG_REPO_URL#https://} .

FROM golang:1.21-alpine as builder
COPY . /app
WORKDIR /app
RUN go build -o main .

FROM alpine:latest
RUN apk --no-cache add ca-certificates git
WORKDIR /root/

# Copy configuration
COPY --from=config-fetcher /config /config

# Copy application
COPY --from=builder /app/main .

# Environment variables for configuration
ENV CONFIG_PATH=/config
ENV CONFIG_ENV=production
ENV CONFIG_SERVICE=api-service

CMD ["./main"]
```

### Package Manager Integration (Peru Example)

```yaml
# peru.yaml - Package manager for configuration
imports:
  config:
    git: https://github.com/company/config-repo.git
    rev: v1.2.3
    path: config/

# Use in deployment scripts
sync_config: |
  peru sync
  cp -r config/environments/$ENVIRONMENT/* /app/config/
```

## Benefits

1. **Version Control**: Full audit trail of configuration changes
2. **Atomic Deployments**: Deploy configuration and code together
3. **Rollback Capability**: Easy rollback to previous configuration versions
4. **Schema Validation**: Prevent invalid configurations from being deployed
5. **Environment Consistency**: Ensure configuration consistency across environments
6. **GitOps Integration**: Configuration changes follow same review process as code
7. **Dependency Management**: Manage configuration dependencies like code dependencies

## Consequences

### Positive

- **Audit Trail**: Complete history of configuration changes with blame and timestamps
- **Deployment Safety**: Schema validation prevents runtime configuration errors
- **Rollback Speed**: Quick rollback to known-good configuration versions
- **Team Collaboration**: Configuration changes go through code review process
- **Environment Parity**: Consistent configuration management across environments
- **Automation**: Configuration deployment can be fully automated

### Negative

- **Complexity**: Additional infrastructure and processes to manage
- **Bootstrap Problem**: Initial configuration needed to fetch configuration
- **Network Dependency**: Services depend on configuration repository availability
- **Storage Overhead**: Multiple copies of configuration across environments
- **Coordination**: Changes affecting multiple services require coordination

## Implementation Checklist

- [ ] Set up configuration repository with proper structure
- [ ] Define configuration schemas for all services
- [ ] Implement configuration manager in each service
- [ ] Set up validation pipeline for configuration changes
- [ ] Configure deployment automation
- [ ] Implement configuration watching and hot-reload
- [ ] Set up monitoring for configuration changes
- [ ] Document configuration management procedures
- [ ] Train team on configuration deployment process
- [ ] Implement emergency configuration rollback procedures

## Best Practices

1. **Schema First**: Always define schemas before creating configurations
2. **Environment Separation**: Keep environments completely separate
3. **Validation Gates**: Never deploy unvalidated configurations
4. **Minimal Bootstrap**: Keep bootstrap configuration minimal and stable
5. **Monitoring**: Monitor configuration changes and their effects
6. **Documentation**: Document all configuration parameters and their effects
7. **Testing**: Test configuration changes in lower environments first
8. **Secrets Management**: Never store secrets in configuration repositories

## Tools and Libraries

- **Peru**: Package manager for configuration distribution
- **Jsonnet**: Configuration templating language
- **Helm**: Kubernetes configuration management
- **Kustomize**: Kubernetes configuration customization
- **Vault**: Secrets management integration
- **Git**: Version control for configuration files 

