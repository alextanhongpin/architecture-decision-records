# Application Configuration Management

## Status

`accepted`

## Context

Application configuration management is critical for maintaining secure, flexible, and maintainable systems. Poor configuration practices lead to security vulnerabilities, deployment failures, and operational difficulties.

### Current Challenges

Modern applications face several configuration challenges:
- **Environment-specific settings**: Different values needed across development, staging, and production
- **Secret management**: Sensitive data like API keys and database passwords require special handling
- **Configuration drift**: Settings gradually diverge across environments
- **Validation complexity**: Ensuring configuration correctness before runtime
- **Size limitations**: Cloud providers impose limits on environment variable sizes
- **Runtime updates**: Need to update configuration without application restarts

### Configuration vs. Secrets

We distinguish between two types of external dependencies:

**Configuration**: Non-sensitive application settings
- Database hostnames and ports
- Feature flags and toggles
- API endpoints and timeouts
- Logging levels and formats
- No security impact if exposed

**Secrets**: Sensitive authentication data
- API keys and tokens
- Database passwords
- Encryption keys and certificates
- Significant security impact if compromised

## Decision

We will implement a layered configuration management strategy that separates concerns, validates inputs, and provides flexibility across environments.

### Configuration Architecture

#### 1. Configuration Sources (Priority Order)

```go
package config

import (
    "fmt"
    "os"
    "strconv"
    "strings"
    "time"
)

type ConfigLoader struct {
    sources []ConfigSource
}

type ConfigSource interface {
    Load(key string) (string, bool)
    Name() string
}

// Environment variables (highest priority)
type EnvSource struct{}

func (e EnvSource) Load(key string) (string, bool) {
    value := os.Getenv(key)
    return value, value != ""
}

func (e EnvSource) Name() string { return "environment" }

// Configuration files (medium priority)
type FileSource struct {
    filepath string
    data     map[string]string
}

func NewFileSource(filepath string) (*FileSource, error) {
    // Load YAML/JSON/TOML configuration file
    data, err := loadConfigFile(filepath)
    if err != nil {
        return nil, err
    }
    
    return &FileSource{
        filepath: filepath,
        data:     data,
    }, nil
}

func (f FileSource) Load(key string) (string, bool) {
    value, exists := f.data[key]
    return value, exists
}

func (f FileSource) Name() string { return fmt.Sprintf("file:%s", f.filepath) }

// External config store (lowest priority)
type ExternalSource struct {
    client ConfigStoreClient
}

func (e ExternalSource) Load(key string) (string, bool) {
    value, err := e.client.Get(key)
    if err != nil {
        return "", false
    }
    return value, true
}

func (e ExternalSource) Name() string { return "external-store" }
```

#### 2. Type-Safe Configuration Structure

```go
type AppConfig struct {
    // Server configuration
    Server ServerConfig `config:"server"`
    
    // Database configuration
    Database DatabaseConfig `config:"database"`
    
    // External services
    Services ServicesConfig `config:"services"`
    
    // Observability
    Logging LoggingConfig `config:"logging"`
    Metrics MetricsConfig `config:"metrics"`
    
    // Feature flags
    Features FeatureConfig `config:"features"`
}

type ServerConfig struct {
    Host         string        `config:"host" default:"localhost" validate:"hostname"`
    Port         int           `config:"port" default:"8080" validate:"range:1024,65535"`
    ReadTimeout  time.Duration `config:"read_timeout" default:"30s" validate:"duration"`
    WriteTimeout time.Duration `config:"write_timeout" default:"30s" validate:"duration"`
    TLS          TLSConfig     `config:"tls"`
}

type DatabaseConfig struct {
    Host            string        `config:"host" validate:"required,hostname"`
    Port            int           `config:"port" default:"5432" validate:"range:1,65535"`
    Database        string        `config:"database" validate:"required"`
    Username        string        `config:"username" validate:"required"`
    MaxConnections  int           `config:"max_connections" default:"25" validate:"min:1"`
    ConnectTimeout  time.Duration `config:"connect_timeout" default:"10s"`
    SSLMode         string        `config:"ssl_mode" default:"prefer" validate:"oneof:disable require prefer"`
}

type ServicesConfig struct {
    PaymentAPI  ServiceConfig `config:"payment_api"`
    EmailAPI    ServiceConfig `config:"email_api"`
    NotificationAPI ServiceConfig `config:"notification_api"`
}

type ServiceConfig struct {
    BaseURL        string        `config:"base_url" validate:"required,url"`
    Timeout        time.Duration `config:"timeout" default:"30s"`
    MaxRetries     int           `config:"max_retries" default:"3" validate:"min:0,max:10"`
    RateLimitRPS   float64       `config:"rate_limit_rps" default:"100" validate:"min:0"`
}

type LoggingConfig struct {
    Level  string `config:"level" default:"info" validate:"oneof:debug info warn error"`
    Format string `config:"format" default:"json" validate:"oneof:json text"`
    Output string `config:"output" default:"stdout" validate:"oneof:stdout stderr file"`
}

type FeatureConfig struct {
    EnableNewPaymentFlow bool `config:"enable_new_payment_flow" default:"false"`
    EnableAdvancedAuth   bool `config:"enable_advanced_auth" default:"false"`
    MaxUploadSizeMB      int  `config:"max_upload_size_mb" default:"10" validate:"min:1,max:100"`
}
```

#### 3. Configuration Loading and Validation

```go
func LoadConfig() (*AppConfig, error) {
    loader := &ConfigLoader{
        sources: []ConfigSource{
            EnvSource{},                              // Highest priority
            mustNewFileSource("config/app.yaml"),    // Medium priority  
            NewExternalSource(getConfigStoreClient()), // Lowest priority
        },
    }
    
    config := &AppConfig{}
    if err := loader.LoadInto(config); err != nil {
        return nil, fmt.Errorf("failed to load configuration: %w", err)
    }
    
    if err := validateConfig(config); err != nil {
        return nil, fmt.Errorf("configuration validation failed: %w", err)
    }
    
    return config, nil
}

func (cl *ConfigLoader) LoadInto(config interface{}) error {
    return cl.loadStruct(reflect.ValueOf(config).Elem(), "")
}

func (cl *ConfigLoader) loadStruct(v reflect.Value, prefix string) error {
    t := v.Type()
    
    for i := 0; i < v.NumField(); i++ {
        field := v.Field(i)
        fieldType := t.Field(i)
        
        if !field.CanSet() {
            continue
        }
        
        configTag := fieldType.Tag.Get("config")
        if configTag == "-" {
            continue
        }
        
        var key string
        if prefix != "" {
            key = fmt.Sprintf("%s_%s", prefix, configTag)
        } else {
            key = configTag
        }
        key = strings.ToUpper(key)
        
        // Try to load value from sources
        value, source := cl.loadValue(key)
        if value == "" {
            // Use default value if specified
            if defaultValue := fieldType.Tag.Get("default"); defaultValue != "" {
                value = defaultValue
            }
        }
        
        if err := cl.setFieldValue(field, fieldType, value, key); err != nil {
            return fmt.Errorf("failed to set field %s from %s: %w", fieldType.Name, source, err)
        }
    }
    
    return nil
}

func (cl *ConfigLoader) loadValue(key string) (string, string) {
    for _, source := range cl.sources {
        if value, found := source.Load(key); found {
            return value, source.Name()
        }
    }
    return "", "default"
}

func (cl *ConfigLoader) setFieldValue(field reflect.Value, fieldType reflect.StructField, value, key string) error {
    if value == "" {
        // Check if field is required
        if validateTag := fieldType.Tag.Get("validate"); strings.Contains(validateTag, "required") {
            return fmt.Errorf("required configuration %s is missing", key)
        }
        return nil
    }
    
    switch field.Kind() {
    case reflect.String:
        field.SetString(value)
    case reflect.Int, reflect.Int64:
        if fieldType.Type == reflect.TypeOf(time.Duration(0)) {
            duration, err := time.ParseDuration(value)
            if err != nil {
                return fmt.Errorf("invalid duration format for %s: %w", key, err)
            }
            field.SetInt(int64(duration))
        } else {
            intVal, err := strconv.ParseInt(value, 10, 64)
            if err != nil {
                return fmt.Errorf("invalid integer format for %s: %w", key, err)
            }
            field.SetInt(intVal)
        }
    case reflect.Float64:
        floatVal, err := strconv.ParseFloat(value, 64)
        if err != nil {
            return fmt.Errorf("invalid float format for %s: %w", key, err)
        }
        field.SetFloat(floatVal)
    case reflect.Bool:
        boolVal, err := strconv.ParseBool(value)
        if err != nil {
            return fmt.Errorf("invalid boolean format for %s: %w", key, err)
        }
        field.SetBool(boolVal)
    case reflect.Struct:
        // Handle nested structs
        return cl.loadStruct(field, key)
    default:
        return fmt.Errorf("unsupported field type %s for %s", field.Kind(), key)
    }
    
    return nil
}
```

#### 4. Configuration Validation

```go
import "github.com/go-playground/validator/v10"

var validate = validator.New()

func validateConfig(config *AppConfig) error {
    // Register custom validators
    validate.RegisterValidation("hostname", validateHostname)
    validate.RegisterValidation("range", validateRange)
    validate.RegisterValidation("duration", validateDuration)
    
    if err := validate.Struct(config); err != nil {
        return formatValidationErrors(err)
    }
    
    // Additional business logic validation
    if config.Database.MaxConnections > 100 {
        return errors.New("database max_connections should not exceed 100 for performance reasons")
    }
    
    if config.Server.ReadTimeout > 5*time.Minute {
        return errors.New("server read_timeout should not exceed 5 minutes")
    }
    
    return nil
}

func validateHostname(fl validator.FieldLevel) bool {
    hostname := fl.Field().String()
    if hostname == "localhost" {
        return true
    }
    // Add more hostname validation logic
    return len(hostname) > 0 && len(hostname) <= 253
}

func validateRange(fl validator.FieldLevel) bool {
    param := fl.Param()
    parts := strings.Split(param, ",")
    if len(parts) != 2 {
        return false
    }
    
    min, err1 := strconv.Atoi(parts[0])
    max, err2 := strconv.Atoi(parts[1])
    if err1 != nil || err2 != nil {
        return false
    }
    
    value := int(fl.Field().Int())
    return value >= min && value <= max
}

func formatValidationErrors(err error) error {
    var messages []string
    
    for _, err := range err.(validator.ValidationErrors) {
        message := fmt.Sprintf("Field '%s' failed validation '%s'", err.Field(), err.Tag())
        if err.Param() != "" {
            message += fmt.Sprintf(" with parameter '%s'", err.Param())
        }
        messages = append(messages, message)
    }
    
    return fmt.Errorf("validation errors:\n  %s", strings.Join(messages, "\n  "))
}
```

### Environment-Specific Configuration

#### Development Configuration

```yaml
# config/development.yaml
server:
  host: localhost
  port: 8080
  read_timeout: 10s
  write_timeout: 10s

database:
  host: localhost
  port: 5432
  database: myapp_dev
  username: dev_user
  max_connections: 5
  ssl_mode: disable

services:
  payment_api:
    base_url: https://api-sandbox.stripe.com
    timeout: 10s
    max_retries: 1
  
logging:
  level: debug
  format: text
  output: stdout

features:
  enable_new_payment_flow: true
  enable_advanced_auth: false
```

#### Production Configuration

```yaml
# config/production.yaml
server:
  host: 0.0.0.0
  port: 8080
  read_timeout: 30s
  write_timeout: 30s
  tls:
    cert_file: /etc/ssl/certs/app.crt
    key_file: /etc/ssl/private/app.key

database:
  host: prod-db.example.com
  port: 5432
  database: myapp_prod
  max_connections: 25
  connect_timeout: 5s
  ssl_mode: require

services:
  payment_api:
    base_url: https://api.stripe.com
    timeout: 30s
    max_retries: 3
    rate_limit_rps: 50

logging:
  level: info
  format: json
  output: stdout

features:
  enable_new_payment_flow: false
  enable_advanced_auth: true
  max_upload_size_mb: 50
```

### Configuration Testing

```go
func TestConfigLoading(t *testing.T) {
    tests := []struct {
        name        string
        envVars     map[string]string
        configFile  string
        expectError bool
        validate    func(*AppConfig) error
    }{
        {
            name: "valid configuration",
            envVars: map[string]string{
                "SERVER_PORT":         "9000",
                "DATABASE_HOST":       "localhost",
                "DATABASE_USERNAME":   "testuser",
            },
            expectError: false,
            validate: func(config *AppConfig) error {
                if config.Server.Port != 9000 {
                    return fmt.Errorf("expected port 9000, got %d", config.Server.Port)
                }
                return nil
            },
        },
        {
            name: "missing required field",
            envVars: map[string]string{
                "SERVER_PORT": "8080",
                // DATABASE_HOST missing
            },
            expectError: true,
        },
        {
            name: "invalid port range",
            envVars: map[string]string{
                "SERVER_PORT":       "99999", // Invalid port
                "DATABASE_HOST":     "localhost",
                "DATABASE_USERNAME": "testuser",
            },
            expectError: true,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Set environment variables
            for key, value := range tt.envVars {
                os.Setenv(key, value)
                defer os.Unsetenv(key)
            }
            
            config, err := LoadConfig()
            
            if tt.expectError {
                assert.Error(t, err)
                return
            }
            
            assert.NoError(t, err)
            if tt.validate != nil {
                assert.NoError(t, tt.validate(config))
            }
        })
    }
}
```

### Size Optimization Strategies

For environments with size limitations:

```go
// Configuration compression for large configs
func CompressConfig(config map[string]string) (map[string]string, error) {
    compressed := make(map[string]string)
    
    for key, value := range config {
        if len(value) > 1000 { // Large values
            // Use external storage reference
            ref, err := storeInExternalConfig(key, value)
            if err != nil {
                return nil, err
            }
            compressed[key] = fmt.Sprintf("@external:%s", ref)
        } else {
            compressed[key] = value
        }
    }
    
    return compressed, nil
}

// Reference-based configuration
func ResolveConfigReferences(config map[string]string) error {
    for key, value := range config {
        if strings.HasPrefix(value, "@external:") {
            ref := strings.TrimPrefix(value, "@external:")
            actualValue, err := fetchFromExternalConfig(ref)
            if err != nil {
                return fmt.Errorf("failed to resolve reference %s: %w", ref, err)
            }
            config[key] = actualValue
        }
    }
    return nil
}
```

## Consequences

### Positive

- **Type safety**: Compile-time validation of configuration structure
- **Environment flexibility**: Easy configuration across different environments
- **Validation**: Runtime validation prevents configuration errors
- **Source priority**: Clear precedence order for configuration sources
- **Maintainability**: Centralized configuration management
- **Documentation**: Self-documenting through struct tags

### Negative

- **Complexity**: More elaborate than simple environment variable reading
- **Memory usage**: Configuration validation requires additional processing
- **Startup time**: Configuration loading and validation adds initialization time
- **External dependencies**: May require additional services for external configuration

### Mitigation Strategies

- **Lazy loading**: Load configuration sections on demand
- **Caching**: Cache validated configuration to avoid repeated processing
- **Graceful degradation**: Provide sensible defaults for non-critical settings
- **Configuration hot-reload**: Update configuration without restarts where possible

## Best Practices

1. **Separate secrets from configuration**: Never store sensitive data in configuration files
2. **Use environment-specific files**: Maintain separate configuration files per environment
3. **Validate early**: Fail fast during application startup if configuration is invalid
4. **Document thoroughly**: Use struct tags and comments to document configuration options
5. **Test configuration**: Include configuration loading in your test suite
6. **Monitor configuration**: Track configuration changes and their impacts
7. **Version configuration**: Keep configuration files in version control
8. **Provide defaults**: Set sensible defaults for non-critical configuration options

## References

- [The Twelve-Factor App - Config](https://12factor.net/config)
- [Go Configuration Best Practices](https://github.com/spf13/viper)
- [Kubernetes ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [AWS Parameter Store](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html)
- [HashiCorp Vault Configuration](https://www.vaultproject.io/docs/configuration)
