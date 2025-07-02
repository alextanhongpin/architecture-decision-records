# Struct Tag Parsing Best Practices

## Status

**Accepted** - Implement robust and standardized struct tag parsing patterns for configuration, validation, serialization, and custom metadata.

## Context

Struct tags in Go provide a powerful mechanism for attaching metadata to struct fields, enabling features like JSON serialization, validation rules, database mappings, and custom annotations. However, struct tag parsing is often implemented incorrectly, leading to:

- **Inconsistent Parsing**: Different packages use different tag formats
- **Poor Error Handling**: Silent failures or unclear error messages
- **Performance Issues**: Inefficient reflection and parsing
- **Maintenance Overhead**: Complex, hard-to-understand tag parsing logic
- **Security Vulnerabilities**: Improper validation of tag values

Common mistakes include:
- Not handling malformed tags gracefully
- Ignoring whitespace and edge cases
- Inefficient repeated reflection calls
- Lack of validation for tag values
- Poor separation of concerns in tag parsing logic

## Decision

We will implement standardized struct tag parsing patterns that:

1. **Use reflect.StructTag Methods**: Leverage built-in tag parsing capabilities
2. **Implement Robust Validation**: Validate tag formats and values
3. **Cache Reflection Results**: Optimize performance through caching
4. **Provide Clear Error Messages**: Help developers debug tag issues
5. **Support Common Patterns**: JSON, validation, database, custom tags

### Implementation Guidelines

#### 1. Core Tag Parsing Infrastructure

```go
package tags

import (
	"fmt"
	"reflect"
	"strconv"
	"strings"
	"sync"
)

// TagParser provides structured tag parsing
type TagParser struct {
	cache sync.Map // Cache parsed tag information
}

// NewTagParser creates a new tag parser with caching
func NewTagParser() *TagParser {
	return &TagParser{}
}

// FieldInfo contains parsed information about a struct field
type FieldInfo struct {
	Field      reflect.StructField
	JSONName   string
	JSONOmit   bool
	Validate   []ValidationRule
	DBColumn   string
	CustomTags map[string]TagValue
}

// TagValue represents a parsed tag value with options
type TagValue struct {
	Value   string
	Options []string
}

// ValidationRule represents a validation constraint
type ValidationRule struct {
	Type   string
	Params []string
}

// ParseStruct parses all fields in a struct
func (p *TagParser) ParseStruct(structType reflect.Type) ([]FieldInfo, error) {
	if structType.Kind() != reflect.Struct {
		return nil, fmt.Errorf("expected struct type, got %s", structType.Kind())
	}
	
	// Check cache first
	if cached, ok := p.cache.Load(structType); ok {
		return cached.([]FieldInfo), nil
	}
	
	var fields []FieldInfo
	
	for i := 0; i < structType.NumField(); i++ {
		field := structType.Field(i)
		
		// Skip unexported fields
		if !field.IsExported() {
			continue
		}
		
		fieldInfo, err := p.parseField(field)
		if err != nil {
			return nil, fmt.Errorf("error parsing field %s: %w", field.Name, err)
		}
		
		fields = append(fields, fieldInfo)
	}
	
	// Cache results
	p.cache.Store(structType, fields)
	
	return fields, nil
}

// parseField parses tags for a single field
func (p *TagParser) parseField(field reflect.StructField) (FieldInfo, error) {
	info := FieldInfo{
		Field:      field,
		CustomTags: make(map[string]TagValue),
	}
	
	// Parse JSON tag
	if jsonTag := field.Tag.Get("json"); jsonTag != "" {
		name, opts := parseTagValue(jsonTag)
		info.JSONName = name
		info.JSONOmit = contains(opts, "omitempty")
	} else {
		info.JSONName = field.Name
	}
	
	// Parse validation tags
	if validateTag := field.Tag.Get("validate"); validateTag != "" {
		rules, err := parseValidationRules(validateTag)
		if err != nil {
			return info, fmt.Errorf("invalid validation tag: %w", err)
		}
		info.Validate = rules
	}
	
	// Parse database tag
	if dbTag := field.Tag.Get("db"); dbTag != "" {
		name, _ := parseTagValue(dbTag)
		info.DBColumn = name
	} else {
		info.DBColumn = toSnakeCase(field.Name)
	}
	
	// Parse custom tags
	customTags := []string{"config", "env", "flag", "doc"}
	for _, tagName := range customTags {
		if tagValue := field.Tag.Get(tagName); tagValue != "" {
			value, opts := parseTagValue(tagValue)
			info.CustomTags[tagName] = TagValue{
				Value:   value,
				Options: opts,
			}
		}
	}
	
	return info, nil
}

// parseTagValue parses a tag value into name and options
func parseTagValue(tag string) (string, []string) {
	parts := strings.Split(tag, ",")
	if len(parts) == 0 {
		return "", nil
	}
	
	name := strings.TrimSpace(parts[0])
	var options []string
	
	for i := 1; i < len(parts); i++ {
		opt := strings.TrimSpace(parts[i])
		if opt != "" {
			options = append(options, opt)
		}
	}
	
	return name, options
}

// parseValidationRules parses validation tag into rules
func parseValidationRules(tag string) ([]ValidationRule, error) {
	var rules []ValidationRule
	
	// Split by comma, but handle nested parentheses
	ruleParts := splitValidationRules(tag)
	
	for _, part := range ruleParts {
		rule, err := parseValidationRule(strings.TrimSpace(part))
		if err != nil {
			return nil, err
		}
		rules = append(rules, rule)
	}
	
	return rules, nil
}

// parseValidationRule parses a single validation rule
func parseValidationRule(rule string) (ValidationRule, error) {
	// Handle rules like: required, min=5, max=100, email
	if !strings.Contains(rule, "=") {
		return ValidationRule{Type: rule}, nil
	}
	
	parts := strings.SplitN(rule, "=", 2)
	if len(parts) != 2 {
		return ValidationRule{}, fmt.Errorf("invalid validation rule format: %s", rule)
	}
	
	ruleType := strings.TrimSpace(parts[0])
	paramStr := strings.TrimSpace(parts[1])
	
	// Parse parameters (handle comma-separated values)
	var params []string
	if paramStr != "" {
		params = strings.Split(paramStr, ",")
		for i, p := range params {
			params[i] = strings.TrimSpace(p)
		}
	}
	
	return ValidationRule{
		Type:   ruleType,
		Params: params,
	}, nil
}

// splitValidationRules splits validation rules handling nested structures
func splitValidationRules(rules string) []string {
	var parts []string
	var current strings.Builder
	parenDepth := 0
	
	for _, r := range rules {
		switch r {
		case '(':
			parenDepth++
			current.WriteRune(r)
		case ')':
			parenDepth--
			current.WriteRune(r)
		case ',':
			if parenDepth == 0 {
				if current.Len() > 0 {
					parts = append(parts, current.String())
					current.Reset()
				}
			} else {
				current.WriteRune(r)
			}
		default:
			current.WriteRune(r)
		}
	}
	
	if current.Len() > 0 {
		parts = append(parts, current.String())
	}
	
	return parts
}

// Utility functions
func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

func toSnakeCase(s string) string {
	var result []rune
	for i, r := range s {
		if i > 0 && isUpper(r) {
			result = append(result, '_')
		}
		result = append(result, toLower(r))
	}
	return string(result)
}

func isUpper(r rune) bool { return r >= 'A' && r <= 'Z' }
func toLower(r rune) rune {
	if isUpper(r) {
		return r + 32
	}
	return r
}
```

#### 2. Configuration Tag Parser

```go
package config

import (
	"fmt"
	"os"
	"reflect"
	"strconv"
	"strings"
	"time"
	
	"yourapp/tags"
)

// ConfigParser handles configuration struct tags
type ConfigParser struct {
	tagParser *tags.TagParser
}

// NewConfigParser creates a new configuration parser
func NewConfigParser() *ConfigParser {
	return &ConfigParser{
		tagParser: tags.NewTagParser(),
	}
}

// LoadConfig loads configuration from environment variables and defaults
func (cp *ConfigParser) LoadConfig(config interface{}) error {
	v := reflect.ValueOf(config)
	if v.Kind() != reflect.Ptr || v.Elem().Kind() != reflect.Struct {
		return fmt.Errorf("config must be a pointer to struct")
	}
	
	structValue := v.Elem()
	structType := structValue.Type()
	
	fields, err := cp.tagParser.ParseStruct(structType)
	if err != nil {
		return err
	}
	
	for _, fieldInfo := range fields {
		if err := cp.loadFieldValue(structValue, fieldInfo); err != nil {
			return fmt.Errorf("error loading field %s: %w", fieldInfo.Field.Name, err)
		}
	}
	
	return nil
}

// loadFieldValue loads a single field value from environment or default
func (cp *ConfigParser) loadFieldValue(structValue reflect.Value, fieldInfo tags.FieldInfo) error {
	fieldValue := structValue.FieldByName(fieldInfo.Field.Name)
	if !fieldValue.CanSet() {
		return nil // Skip read-only fields
	}
	
	// Get environment variable name and default value
	envTag, hasEnv := fieldInfo.CustomTags["env"]
	defaultTag, hasDefault := fieldInfo.CustomTags["default"]
	
	var envName string
	if hasEnv {
		envName = envTag.Value
	} else {
		envName = strings.ToUpper(toSnakeCase(fieldInfo.Field.Name))
	}
	
	// Try to get value from environment
	envValue := os.Getenv(envName)
	
	// Use default if environment variable is not set
	var finalValue string
	if envValue != "" {
		finalValue = envValue
	} else if hasDefault {
		finalValue = defaultTag.Value
	} else if isRequired(fieldInfo) {
		return fmt.Errorf("required environment variable %s is not set", envName)
	}
	
	// Convert and set the value
	return cp.setFieldValue(fieldValue, finalValue, fieldInfo.Field.Type)
}

// setFieldValue converts string value to appropriate type and sets field
func (cp *ConfigParser) setFieldValue(fieldValue reflect.Value, value string, fieldType reflect.Type) error {
	if value == "" {
		return nil // Leave as zero value
	}
	
	switch fieldType.Kind() {
	case reflect.String:
		fieldValue.SetString(value)
	case reflect.Bool:
		boolVal, err := strconv.ParseBool(value)
		if err != nil {
			return fmt.Errorf("invalid bool value: %s", value)
		}
		fieldValue.SetBool(boolVal)
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		if fieldType == reflect.TypeOf(time.Duration(0)) {
			duration, err := time.ParseDuration(value)
			if err != nil {
				return fmt.Errorf("invalid duration value: %s", value)
			}
			fieldValue.SetInt(int64(duration))
		} else {
			intVal, err := strconv.ParseInt(value, 10, 64)
			if err != nil {
				return fmt.Errorf("invalid int value: %s", value)
			}
			fieldValue.SetInt(intVal)
		}
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		uintVal, err := strconv.ParseUint(value, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid uint value: %s", value)
		}
		fieldValue.SetUint(uintVal)
	case reflect.Float32, reflect.Float64:
		floatVal, err := strconv.ParseFloat(value, 64)
		if err != nil {
			return fmt.Errorf("invalid float value: %s", value)
		}
		fieldValue.SetFloat(floatVal)
	case reflect.Slice:
		return cp.setSliceValue(fieldValue, value, fieldType.Elem())
	default:
		return fmt.Errorf("unsupported field type: %s", fieldType.Kind())
	}
	
	return nil
}

// setSliceValue handles slice types
func (cp *ConfigParser) setSliceValue(fieldValue reflect.Value, value string, elemType reflect.Type) error {
	if value == "" {
		return nil
	}
	
	// Split by comma
	parts := strings.Split(value, ",")
	slice := reflect.MakeSlice(fieldValue.Type(), len(parts), len(parts))
	
	for i, part := range parts {
		elemValue := slice.Index(i)
		if err := cp.setFieldValue(elemValue, strings.TrimSpace(part), elemType); err != nil {
			return err
		}
	}
	
	fieldValue.Set(slice)
	return nil
}

// isRequired checks if field is required
func isRequired(fieldInfo tags.FieldInfo) bool {
	for _, rule := range fieldInfo.Validate {
		if rule.Type == "required" {
			return true
		}
	}
	return false
}

// Example configuration struct
type AppConfig struct {
	DatabaseURL    string        `env:"DATABASE_URL" default:"postgres://localhost/app" validate:"required"`
	RedisURL       string        `env:"REDIS_URL" default:"redis://localhost:6379"`
	Port           int           `env:"PORT" default:"8080" validate:"min=1,max=65535"`
	Debug          bool          `env:"DEBUG" default:"false"`
	RequestTimeout time.Duration `env:"REQUEST_TIMEOUT" default:"30s"`
	AllowedHosts   []string      `env:"ALLOWED_HOSTS" default:"localhost,127.0.0.1"`
	MaxWorkers     int           `env:"MAX_WORKERS" default:"10" validate:"min=1,max=100"`
}

func LoadAppConfig() (*AppConfig, error) {
	config := &AppConfig{}
	parser := NewConfigParser()
	
	if err := parser.LoadConfig(config); err != nil {
		return nil, err
	}
	
	return config, nil
}
```

#### 3. Validation Tag Parser

```go
package validation

import (
	"fmt"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	
	"yourapp/tags"
)

// Validator provides struct validation based on tags
type Validator struct {
	tagParser *tags.TagParser
}

// NewValidator creates a new validator
func NewValidator() *Validator {
	return &Validator{
		tagParser: tags.NewTagParser(),
	}
}

// ValidationError represents a validation error
type ValidationError struct {
	Field   string
	Rule    string
	Message string
}

func (e ValidationError) Error() string {
	return fmt.Sprintf("validation failed for field '%s': %s", e.Field, e.Message)
}

// ValidationErrors holds multiple validation errors
type ValidationErrors []ValidationError

func (ve ValidationErrors) Error() string {
	var messages []string
	for _, err := range ve {
		messages = append(messages, err.Error())
	}
	return strings.Join(messages, "; ")
}

// Validate validates a struct based on its tags
func (v *Validator) Validate(obj interface{}) error {
	value := reflect.ValueOf(obj)
	if value.Kind() == reflect.Ptr {
		value = value.Elem()
	}
	
	if value.Kind() != reflect.Struct {
		return fmt.Errorf("can only validate struct types")
	}
	
	structType := value.Type()
	fields, err := v.tagParser.ParseStruct(structType)
	if err != nil {
		return err
	}
	
	var errors ValidationErrors
	
	for _, fieldInfo := range fields {
		fieldValue := value.FieldByName(fieldInfo.Field.Name)
		
		for _, rule := range fieldInfo.Validate {
			if err := v.validateRule(fieldValue, fieldInfo.Field.Name, rule); err != nil {
				errors = append(errors, *err)
			}
		}
	}
	
	if len(errors) > 0 {
		return errors
	}
	
	return nil
}

// validateRule validates a single rule
func (v *Validator) validateRule(fieldValue reflect.Value, fieldName string, rule tags.ValidationRule) *ValidationError {
	switch rule.Type {
	case "required":
		return v.validateRequired(fieldValue, fieldName)
	case "min":
		return v.validateMin(fieldValue, fieldName, rule.Params)
	case "max":
		return v.validateMax(fieldValue, fieldName, rule.Params)
	case "email":
		return v.validateEmail(fieldValue, fieldName)
	case "regex":
		return v.validateRegex(fieldValue, fieldName, rule.Params)
	case "oneof":
		return v.validateOneOf(fieldValue, fieldName, rule.Params)
	default:
		return &ValidationError{
			Field:   fieldName,
			Rule:    rule.Type,
			Message: fmt.Sprintf("unknown validation rule: %s", rule.Type),
		}
	}
}

// validateRequired checks if field has a value
func (v *Validator) validateRequired(fieldValue reflect.Value, fieldName string) *ValidationError {
	if isEmpty(fieldValue) {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "required",
			Message: "field is required",
		}
	}
	return nil
}

// validateMin validates minimum value/length
func (v *Validator) validateMin(fieldValue reflect.Value, fieldName string, params []string) *ValidationError {
	if len(params) == 0 {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "min",
			Message: "min validation requires a parameter",
		}
	}
	
	minValue, err := strconv.ParseFloat(params[0], 64)
	if err != nil {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "min",
			Message: fmt.Sprintf("invalid min parameter: %s", params[0]),
		}
	}
	
	switch fieldValue.Kind() {
	case reflect.String:
		if float64(len(fieldValue.String())) < minValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "min",
				Message: fmt.Sprintf("string length must be at least %.0f", minValue),
			}
		}
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		if float64(fieldValue.Int()) < minValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "min",
				Message: fmt.Sprintf("value must be at least %.0f", minValue),
			}
		}
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		if float64(fieldValue.Uint()) < minValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "min",
				Message: fmt.Sprintf("value must be at least %.0f", minValue),
			}
		}
	case reflect.Float32, reflect.Float64:
		if fieldValue.Float() < minValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "min",
				Message: fmt.Sprintf("value must be at least %g", minValue),
			}
		}
	case reflect.Slice, reflect.Array:
		if float64(fieldValue.Len()) < minValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "min",
				Message: fmt.Sprintf("slice length must be at least %.0f", minValue),
			}
		}
	}
	
	return nil
}

// validateMax validates maximum value/length
func (v *Validator) validateMax(fieldValue reflect.Value, fieldName string, params []string) *ValidationError {
	if len(params) == 0 {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "max",
			Message: "max validation requires a parameter",
		}
	}
	
	maxValue, err := strconv.ParseFloat(params[0], 64)
	if err != nil {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "max",
			Message: fmt.Sprintf("invalid max parameter: %s", params[0]),
		}
	}
	
	switch fieldValue.Kind() {
	case reflect.String:
		if float64(len(fieldValue.String())) > maxValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "max",
				Message: fmt.Sprintf("string length must be at most %.0f", maxValue),
			}
		}
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		if float64(fieldValue.Int()) > maxValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "max",
				Message: fmt.Sprintf("value must be at most %.0f", maxValue),
			}
		}
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		if float64(fieldValue.Uint()) > maxValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "max",
				Message: fmt.Sprintf("value must be at most %.0f", maxValue),
			}
		}
	case reflect.Float32, reflect.Float64:
		if fieldValue.Float() > maxValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "max",
				Message: fmt.Sprintf("value must be at most %g", maxValue),
			}
		}
	case reflect.Slice, reflect.Array:
		if float64(fieldValue.Len()) > maxValue {
			return &ValidationError{
				Field:   fieldName,
				Rule:    "max",
				Message: fmt.Sprintf("slice length must be at most %.0f", maxValue),
			}
		}
	}
	
	return nil
}

// validateEmail validates email format
func (v *Validator) validateEmail(fieldValue reflect.Value, fieldName string) *ValidationError {
	if fieldValue.Kind() != reflect.String {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "email",
			Message: "email validation can only be applied to string fields",
		}
	}
	
	email := fieldValue.String()
	if email == "" {
		return nil // Empty values are handled by required rule
	}
	
	emailRegex := regexp.MustCompile(`^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`)
	if !emailRegex.MatchString(email) {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "email",
			Message: "invalid email format",
		}
	}
	
	return nil
}

// validateRegex validates against a regex pattern
func (v *Validator) validateRegex(fieldValue reflect.Value, fieldName string, params []string) *ValidationError {
	if len(params) == 0 {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "regex",
			Message: "regex validation requires a pattern parameter",
		}
	}
	
	if fieldValue.Kind() != reflect.String {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "regex",
			Message: "regex validation can only be applied to string fields",
		}
	}
	
	pattern := params[0]
	regex, err := regexp.Compile(pattern)
	if err != nil {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "regex",
			Message: fmt.Sprintf("invalid regex pattern: %s", pattern),
		}
	}
	
	value := fieldValue.String()
	if value != "" && !regex.MatchString(value) {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "regex",
			Message: fmt.Sprintf("value does not match pattern: %s", pattern),
		}
	}
	
	return nil
}

// validateOneOf validates that value is one of allowed values
func (v *Validator) validateOneOf(fieldValue reflect.Value, fieldName string, params []string) *ValidationError {
	if len(params) == 0 {
		return &ValidationError{
			Field:   fieldName,
			Rule:    "oneof",
			Message: "oneof validation requires allowed values",
		}
	}
	
	value := fmt.Sprintf("%v", fieldValue.Interface())
	
	for _, allowed := range params {
		if value == strings.TrimSpace(allowed) {
			return nil
		}
	}
	
	return &ValidationError{
		Field:   fieldName,
		Rule:    "oneof",
		Message: fmt.Sprintf("value must be one of: %s", strings.Join(params, ", ")),
	}
}

// isEmpty checks if a value is considered empty
func isEmpty(value reflect.Value) bool {
	switch value.Kind() {
	case reflect.String:
		return value.String() == ""
	case reflect.Bool:
		return !value.Bool()
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return value.Int() == 0
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return value.Uint() == 0
	case reflect.Float32, reflect.Float64:
		return value.Float() == 0
	case reflect.Slice, reflect.Map, reflect.Array:
		return value.Len() == 0
	case reflect.Ptr, reflect.Interface:
		return value.IsNil()
	default:
		return false
	}
}

// Example usage
type User struct {
	Name     string `validate:"required,min=2,max=50"`
	Email    string `validate:"required,email"`
	Age      int    `validate:"min=18,max=120"`
	Role     string `validate:"required,oneof=admin user guest"`
	Password string `validate:"required,min=8,regex=^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+$"`
}

func ValidateUser(user *User) error {
	validator := NewValidator()
	return validator.Validate(user)
}
```

#### 4. Testing Tag Parsing

```go
package tags_test

import (
	"reflect"
	"testing"
	"time"
	
	"yourapp/tags"
	"yourapp/config"
	"yourapp/validation"
)

func TestTagParsing(t *testing.T) {
	type TestStruct struct {
		Name     string `json:"name,omitempty" validate:"required,min=2" db:"user_name"`
		Email    string `json:"email" validate:"email" db:"email_address"`
		Age      int    `json:"age" validate:"min=0,max=120"`
		IsActive bool   `json:"is_active,omitempty" db:"active"`
	}
	
	parser := tags.NewTagParser()
	fields, err := parser.ParseStruct(reflect.TypeOf(TestStruct{}))
	if err != nil {
		t.Fatalf("Failed to parse struct: %v", err)
	}
	
	if len(fields) != 4 {
		t.Errorf("Expected 4 fields, got %d", len(fields))
	}
	
	// Test first field
	nameField := fields[0]
	if nameField.JSONName != "name" {
		t.Errorf("Expected JSON name 'name', got '%s'", nameField.JSONName)
	}
	
	if !nameField.JSONOmit {
		t.Error("Expected omitempty to be true")
	}
	
	if len(nameField.Validate) != 2 {
		t.Errorf("Expected 2 validation rules, got %d", len(nameField.Validate))
	}
}

func TestConfigParsing(t *testing.T) {
	type Config struct {
		Port    int           `env:"TEST_PORT" default:"8080"`
		Timeout time.Duration `env:"TEST_TIMEOUT" default:"30s"`
		Debug   bool          `env:"TEST_DEBUG" default:"false"`
	}
	
	parser := config.NewConfigParser()
	cfg := &Config{}
	
	err := parser.LoadConfig(cfg)
	if err != nil {
		t.Fatalf("Failed to load config: %v", err)
	}
	
	if cfg.Port != 8080 {
		t.Errorf("Expected port 8080, got %d", cfg.Port)
	}
	
	if cfg.Timeout != 30*time.Second {
		t.Errorf("Expected timeout 30s, got %v", cfg.Timeout)
	}
}

func TestValidation(t *testing.T) {
	type TestStruct struct {
		Name  string `validate:"required,min=2"`
		Email string `validate:"email"`
		Age   int    `validate:"min=0,max=120"`
	}
	
	validator := validation.NewValidator()
	
	// Test valid struct
	valid := TestStruct{
		Name:  "John",
		Email: "john@example.com",
		Age:   25,
	}
	
	if err := validator.Validate(valid); err != nil {
		t.Errorf("Expected no error for valid struct, got: %v", err)
	}
	
	// Test invalid struct
	invalid := TestStruct{
		Name:  "J", // Too short
		Email: "invalid-email",
		Age:   150, // Too old
	}
	
	err := validator.Validate(invalid)
	if err == nil {
		t.Error("Expected validation errors for invalid struct")
	}
	
	validationErrs, ok := err.(validation.ValidationErrors)
	if !ok {
		t.Errorf("Expected ValidationErrors, got %T", err)
	}
	
	if len(validationErrs) != 3 {
		t.Errorf("Expected 3 validation errors, got %d", len(validationErrs))
	}
}

func BenchmarkTagParsing(b *testing.B) {
	type BenchStruct struct {
		Field1 string `json:"field1" validate:"required"`
		Field2 int    `json:"field2" validate:"min=0"`
		Field3 bool   `json:"field3"`
	}
	
	parser := tags.NewTagParser()
	structType := reflect.TypeOf(BenchStruct{})
	
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		parser.ParseStruct(structType)
	}
}
```

## Consequences

### Positive

- **Robust Parsing**: Proper handling of malformed and edge case tags
- **Performance Optimization**: Caching reduces repeated reflection overhead
- **Clear Error Messages**: Helpful debugging information for tag issues
- **Consistent Patterns**: Standardized approach across different tag types
- **Extensibility**: Easy to add new tag types and validation rules
- **Type Safety**: Compile-time and runtime type checking

### Negative

- **Complexity**: More complex than simple string splitting approaches
- **Memory Overhead**: Caching consumes additional memory
- **Learning Curve**: Developers need to understand the tag parsing patterns
- **Performance Cost**: Still has reflection overhead, though minimized

### Trade-offs

- **Safety vs. Performance**: Prioritizes correctness over raw performance
- **Flexibility vs. Simplicity**: Provides extensive features at complexity cost
- **Consistency vs. Freedom**: Enforces patterns but may limit some use cases

## Best Practices

1. **Use Struct Tag Methods**: Leverage `reflect.StructTag.Get()` and `reflect.StructTag.Lookup()`
2. **Validate Tag Formats**: Check for malformed tags and provide clear errors
3. **Cache Reflection Results**: Avoid repeated reflection calls for the same types
4. **Handle Edge Cases**: Consider empty tags, whitespace, and special characters
5. **Provide Clear Documentation**: Document tag formats and expected values
6. **Test Thoroughly**: Include tests for valid and invalid tag combinations

## References

- [Go Struct Tags](https://golang.org/ref/spec#Struct_types)
- [Reflect Package](https://pkg.go.dev/reflect)
- [JSON Package](https://pkg.go.dev/encoding/json)
- [Validator Package](https://github.com/go-playground/validator)
