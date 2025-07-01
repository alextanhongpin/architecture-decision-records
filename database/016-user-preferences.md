# User Preferences

## Status

`accepted`

## Context

Modern applications require flexible user preference systems to enhance user experience through personalization. Users need control over various settings such as notification preferences, UI configurations, privacy settings, and behavioral customizations like "don't show this popup again" flags.

### Common User Preference Categories

| Category | Examples | Storage Strategy | Access Patterns |
|----------|----------|------------------|-----------------|
| **UI Settings** | Theme, language, layout | Key-value pairs | Frequent read, infrequent write |
| **Notifications** | Email, push, SMS preferences | Structured data | Medium read/write frequency |
| **Privacy** | Data sharing, visibility settings | Boolean flags | Infrequent access |
| **Behavioral** | Tutorial completion, popup dismissals | Event tracking | Write-heavy, occasional reads |
| **Feature Flags** | Beta features, experimental options | Boolean toggles | Read-heavy |

### Storage Challenges

- **Schema Evolution**: Preferences change as features evolve
- **Performance**: Fast retrieval for user experience
- **Scalability**: Efficient storage for millions of users
- **Flexibility**: Support for various data types and structures
- **Auditability**: Track preference changes over time
- **Defaults**: Handle missing preferences gracefully

### Design Approaches

1. **JSON Column Approach**: Store all preferences as JSON in users table
2. **Separate Table Approach**: Dedicated user_preferences table with key-value pairs
3. **Hybrid Approach**: Common preferences in users table, complex ones separately
4. **Redis Cache Approach**: Database + Redis for performance
5. **Event Sourcing**: Track preference changes as events

## Decision

Implement a **hybrid user preferences system** that combines:

1. **Core Preferences**: Stored as JSON column in users table for frequently accessed settings
2. **Complex Preferences**: Separate table for structured data and historical tracking
3. **Cache Layer**: Redis caching for high-performance access
4. **Event Tracking**: Audit log for preference changes
5. **Default Management**: Centralized default preference management

## Implementation

### Database Schema Design

```sql
-- Enhanced users table with preferences JSON column
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    username VARCHAR(100) UNIQUE NOT NULL,
    
    -- Core preferences stored as JSON for fast access
    preferences JSONB DEFAULT '{}' NOT NULL,
    
    -- Preference metadata
    preferences_version INTEGER DEFAULT 1,
    preferences_updated_at TIMESTAMP DEFAULT NOW(),
    
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Index on JSONB preferences for efficient queries
CREATE INDEX idx_users_preferences_gin ON users USING GIN (preferences);
CREATE INDEX idx_users_preferences_theme ON users ((preferences->>'theme'));
CREATE INDEX idx_users_preferences_language ON users ((preferences->>'language'));
CREATE INDEX idx_users_preferences_notifications ON users ((preferences->'notifications'));

-- Separate table for complex preferences and historical tracking
CREATE TABLE user_preferences (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Preference identification
    category VARCHAR(50) NOT NULL,  -- 'notification', 'privacy', 'ui', 'behavioral'
    preference_key VARCHAR(100) NOT NULL,
    
    -- Flexible value storage
    value_text TEXT,
    value_number DECIMAL(15,6),
    value_boolean BOOLEAN,
    value_json JSONB,
    value_timestamp TIMESTAMP,
    
    -- Metadata
    is_active BOOLEAN DEFAULT true,
    source VARCHAR(50) DEFAULT 'user',  -- 'user', 'admin', 'system', 'import'
    
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    
    CONSTRAINT unique_user_category_key UNIQUE (user_id, category, preference_key, is_active)
);

-- Indexes for efficient preference queries
CREATE INDEX idx_user_preferences_user_category ON user_preferences(user_id, category);
CREATE INDEX idx_user_preferences_key ON user_preferences(preference_key);
CREATE INDEX idx_user_preferences_active ON user_preferences(is_active) WHERE is_active = true;
CREATE INDEX idx_user_preferences_json ON user_preferences USING GIN (value_json);

-- Preference change audit log
CREATE TABLE user_preference_history (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL,
    category VARCHAR(50) NOT NULL,
    preference_key VARCHAR(100) NOT NULL,
    
    -- Change tracking
    old_value JSONB,
    new_value JSONB,
    change_type VARCHAR(20) NOT NULL, -- 'created', 'updated', 'deleted'
    change_reason VARCHAR(255),
    
    -- Change metadata
    changed_by_user_id BIGINT,
    changed_by_system VARCHAR(50),
    ip_address INET,
    user_agent TEXT,
    
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_user_preference_history_user ON user_preference_history(user_id, created_at DESC);
CREATE INDEX idx_user_preference_history_key ON user_preference_history(preference_key, created_at DESC);

-- Default preferences configuration
CREATE TABLE preference_defaults (
    id SERIAL PRIMARY KEY,
    category VARCHAR(50) NOT NULL,
    preference_key VARCHAR(100) NOT NULL,
    
    -- Default value (one of these will be set)
    default_text TEXT,
    default_number DECIMAL(15,6),
    default_boolean BOOLEAN,
    default_json JSONB,
    
    -- Configuration
    data_type VARCHAR(20) NOT NULL, -- 'text', 'number', 'boolean', 'json'
    is_required BOOLEAN DEFAULT false,
    description TEXT,
    
    -- Validation rules
    validation_rules JSONB, -- JSON schema for validation
    
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    
    CONSTRAINT unique_category_key UNIQUE (category, preference_key)
);

-- Seed default preferences
INSERT INTO preference_defaults (category, preference_key, default_boolean, data_type, description) VALUES
('ui', 'dark_theme', false, 'boolean', 'Enable dark theme'),
('ui', 'compact_layout', false, 'boolean', 'Use compact layout'),
('notifications', 'email_enabled', true, 'boolean', 'Enable email notifications'),
('notifications', 'push_enabled', true, 'boolean', 'Enable push notifications'),
('privacy', 'profile_public', false, 'boolean', 'Make profile publicly visible'),
('behavioral', 'tutorial_completed', false, 'boolean', 'User has completed tutorial'),
('behavioral', 'welcome_popup_dismissed', false, 'boolean', 'Welcome popup was dismissed');

INSERT INTO preference_defaults (category, preference_key, default_text, data_type, description) VALUES
('ui', 'language', 'en', 'text', 'User interface language'),
('ui', 'timezone', 'UTC', 'text', 'User timezone');

INSERT INTO preference_defaults (category, preference_key, default_json, data_type, description) VALUES
('notifications', 'email_frequency', '{"newsletters": "weekly", "updates": "daily", "marketing": "never"}', 'json', 'Email notification frequency settings'),
('ui', 'dashboard_layout', '{"widgets": ["recent", "stats", "activity"], "columns": 2}', 'json', 'Dashboard layout configuration');
```

### Go Preference Management Framework

```go
package preferences

import (
    "context"
    "database/sql"
    "encoding/json"
    "fmt"
    "time"
    
    "github.com/redis/go-redis/v9"
    "go.uber.org/zap"
)

// PreferenceManager handles all user preference operations
type PreferenceManager struct {
    db            *sql.DB
    cache         *redis.Client
    logger        *zap.Logger
    defaultsCache map[string]*DefaultPreference
}

// UserPreferences represents a user's complete preference set
type UserPreferences struct {
    UserID             int64                  `json:"user_id"`
    CorePreferences    map[string]interface{} `json:"core_preferences"`
    ComplexPreferences map[string]*Preference `json:"complex_preferences"`
    Version            int                    `json:"version"`
    UpdatedAt          time.Time             `json:"updated_at"`
}

// Preference represents a single preference setting
type Preference struct {
    ID            int64       `json:"id"`
    UserID        int64       `json:"user_id"`
    Category      string      `json:"category"`
    Key           string      `json:"key"`
    Value         interface{} `json:"value"`
    DataType      string      `json:"data_type"`
    Source        string      `json:"source"`
    IsActive      bool        `json:"is_active"`
    CreatedAt     time.Time   `json:"created_at"`
    UpdatedAt     time.Time   `json:"updated_at"`
}

// DefaultPreference represents default preference configuration
type DefaultPreference struct {
    Category        string      `json:"category"`
    Key             string      `json:"key"`
    DefaultValue    interface{} `json:"default_value"`
    DataType        string      `json:"data_type"`
    IsRequired      bool        `json:"is_required"`
    Description     string      `json:"description"`
    ValidationRules string      `json:"validation_rules,omitempty"`
}

// PreferenceChange represents a preference change event
type PreferenceChange struct {
    UserID        int64       `json:"user_id"`
    Category      string      `json:"category"`
    Key           string      `json:"key"`
    OldValue      interface{} `json:"old_value"`
    NewValue      interface{} `json:"new_value"`
    ChangeType    string      `json:"change_type"`
    ChangeReason  string      `json:"change_reason,omitempty"`
    ChangedBy     int64       `json:"changed_by,omitempty"`
    IPAddress     string      `json:"ip_address,omitempty"`
    UserAgent     string      `json:"user_agent,omitempty"`
}

func NewPreferenceManager(db *sql.DB, cache *redis.Client, logger *zap.Logger) *PreferenceManager {
    pm := &PreferenceManager{
        db:            db,
        cache:         cache,
        logger:        logger,
        defaultsCache: make(map[string]*DefaultPreference),
    }
    
    // Load default preferences into cache
    pm.loadDefaults()
    
    return pm
}

// GetUserPreferences retrieves all preferences for a user
func (pm *PreferenceManager) GetUserPreferences(ctx context.Context, userID int64) (*UserPreferences, error) {
    // Try cache first
    if cached := pm.getCachedPreferences(ctx, userID); cached != nil {
        return cached, nil
    }
    
    preferences := &UserPreferences{
        UserID:             userID,
        CorePreferences:    make(map[string]interface{}),
        ComplexPreferences: make(map[string]*Preference),
    }
    
    // Get core preferences from users table
    coreQuery := `
        SELECT preferences, preferences_version, preferences_updated_at
        FROM users
        WHERE id = $1
    `
    
    var corePrefsJSON []byte
    err := pm.db.QueryRowContext(ctx, coreQuery, userID).Scan(
        &corePrefsJSON,
        &preferences.Version,
        &preferences.UpdatedAt,
    )
    
    if err != nil && err != sql.ErrNoRows {
        return nil, fmt.Errorf("failed to get core preferences: %w", err)
    }
    
    if len(corePrefsJSON) > 0 {
        if err := json.Unmarshal(corePrefsJSON, &preferences.CorePreferences); err != nil {
            pm.logger.Error("Failed to unmarshal core preferences", 
                zap.Int64("user_id", userID), 
                zap.Error(err))
        }
    }
    
    // Get complex preferences from user_preferences table
    complexQuery := `
        SELECT id, category, preference_key, 
               value_text, value_number, value_boolean, value_json, value_timestamp,
               source, created_at, updated_at
        FROM user_preferences
        WHERE user_id = $1 AND is_active = true
        ORDER BY category, preference_key
    `
    
    rows, err := pm.db.QueryContext(ctx, complexQuery, userID)
    if err != nil {
        return nil, fmt.Errorf("failed to get complex preferences: %w", err)
    }
    defer rows.Close()
    
    for rows.Next() {
        pref := &Preference{
            UserID:   userID,
            IsActive: true,
        }
        
        var valueText sql.NullString
        var valueNumber sql.NullFloat64
        var valueBool sql.NullBool
        var valueJSON []byte
        var valueTimestamp sql.NullTime
        
        err := rows.Scan(
            &pref.ID,
            &pref.Category,
            &pref.Key,
            &valueText,
            &valueNumber,
            &valueBool,
            &valueJSON,
            &valueTimestamp,
            &pref.Source,
            &pref.CreatedAt,
            &pref.UpdatedAt,
        )
        
        if err != nil {
            continue
        }
        
        // Determine value and data type
        pref.Value, pref.DataType = pm.extractPreferenceValue(
            valueText, valueNumber, valueBool, valueJSON, valueTimestamp)
        
        key := fmt.Sprintf("%s.%s", pref.Category, pref.Key)
        preferences.ComplexPreferences[key] = pref
    }
    
    // Fill in defaults for missing preferences
    pm.applyDefaults(preferences)
    
    // Cache the result
    pm.cachePreferences(ctx, preferences)
    
    return preferences, nil
}

// SetPreference sets a single preference value
func (pm *PreferenceManager) SetPreference(ctx context.Context, userID int64, 
    category, key string, value interface{}, options ...SetOption) error {
    
    config := &setConfig{
        source:       "user",
        changeReason: "user_update",
    }
    
    for _, opt := range options {
        opt(config)
    }
    
    // Get current value for audit
    current, _ := pm.GetPreference(ctx, userID, category, key)
    
    // Validate the preference
    if err := pm.validatePreference(category, key, value); err != nil {
        return fmt.Errorf("preference validation failed: %w", err)
    }
    
    // Determine storage strategy based on category and complexity
    if pm.shouldStoreAsCore(category, key) {
        return pm.setCorePreference(ctx, userID, key, value, config)
    }
    
    return pm.setComplexPreference(ctx, userID, category, key, value, current, config)
}

// GetPreference retrieves a single preference value
func (pm *PreferenceManager) GetPreference(ctx context.Context, userID int64, 
    category, key string) (interface{}, error) {
    
    preferences, err := pm.GetUserPreferences(ctx, userID)
    if err != nil {
        return nil, err
    }
    
    // Check core preferences first
    if pm.shouldStoreAsCore(category, key) {
        if value, exists := preferences.CorePreferences[key]; exists {
            return value, nil
        }
    }
    
    // Check complex preferences
    complexKey := fmt.Sprintf("%s.%s", category, key)
    if pref, exists := preferences.ComplexPreferences[complexKey]; exists {
        return pref.Value, nil
    }
    
    // Return default value
    if defaultPref := pm.getDefault(category, key); defaultPref != nil {
        return defaultPref.DefaultValue, nil
    }
    
    return nil, fmt.Errorf("preference not found: %s.%s", category, key)
}

// setCorePreference updates a preference in the users table JSON column
func (pm *PreferenceManager) setCorePreference(ctx context.Context, userID int64, 
    key string, value interface{}, config *setConfig) error {
    
    // Update JSON column using PostgreSQL JSON operations
    query := `
        UPDATE users 
        SET 
            preferences = preferences || jsonb_build_object($2, $3),
            preferences_version = preferences_version + 1,
            preferences_updated_at = NOW()
        WHERE id = $1
    `
    
    valueJSON, err := json.Marshal(value)
    if err != nil {
        return fmt.Errorf("failed to marshal preference value: %w", err)
    }
    
    _, err = pm.db.ExecContext(ctx, query, userID, key, string(valueJSON))
    if err != nil {
        return fmt.Errorf("failed to update core preference: %w", err)
    }
    
    // Invalidate cache
    pm.invalidateUserCache(ctx, userID)
    
    pm.logger.Info("Core preference updated",
        zap.Int64("user_id", userID),
        zap.String("key", key),
        zap.String("source", config.source),
    )
    
    return nil
}

// setComplexPreference updates a preference in the user_preferences table
func (pm *PreferenceManager) setComplexPreference(ctx context.Context, userID int64,
    category, key string, value interface{}, currentValue interface{}, config *setConfig) error {
    
    // Start transaction for atomic update
    tx, err := pm.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    // Deactivate existing preference
    _, err = tx.ExecContext(ctx, `
        UPDATE user_preferences 
        SET is_active = false, updated_at = NOW()
        WHERE user_id = $1 AND category = $2 AND preference_key = $3 AND is_active = true
    `, userID, category, key)
    
    if err != nil {
        return fmt.Errorf("failed to deactivate old preference: %w", err)
    }
    
    // Insert new preference
    insertQuery := `
        INSERT INTO user_preferences 
        (user_id, category, preference_key, value_text, value_number, value_boolean, 
         value_json, value_timestamp, source, is_active)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, true)
        RETURNING id
    `
    
    var valueText sql.NullString
    var valueNumber sql.NullFloat64
    var valueBool sql.NullBool
    var valueJSON []byte
    var valueTimestamp sql.NullTime
    
    // Convert value to appropriate SQL type
    pm.preparePreferenceValue(value, &valueText, &valueNumber, &valueBool, &valueJSON, &valueTimestamp)
    
    var prefID int64
    err = tx.QueryRowContext(ctx, insertQuery,
        userID, category, key,
        valueText, valueNumber, valueBool, valueJSON, valueTimestamp,
        config.source,
    ).Scan(&prefID)
    
    if err != nil {
        return fmt.Errorf("failed to insert new preference: %w", err)
    }
    
    // Record change in audit log
    err = pm.recordPreferenceChange(ctx, tx, &PreferenceChange{
        UserID:       userID,
        Category:     category,
        Key:          key,
        OldValue:     currentValue,
        NewValue:     value,
        ChangeType:   "updated",
        ChangeReason: config.changeReason,
        ChangedBy:    config.changedBy,
        IPAddress:    config.ipAddress,
        UserAgent:    config.userAgent,
    })
    
    if err != nil {
        return fmt.Errorf("failed to record preference change: %w", err)
    }
    
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("failed to commit preference change: %w", err)
    }
    
    // Invalidate cache
    pm.invalidateUserCache(ctx, userID)
    
    pm.logger.Info("Complex preference updated",
        zap.Int64("user_id", userID),
        zap.String("category", category),
        zap.String("key", key),
        zap.Int64("preference_id", prefID),
        zap.String("source", config.source),
    )
    
    return nil
}

// BulkSetPreferences sets multiple preferences atomically
func (pm *PreferenceManager) BulkSetPreferences(ctx context.Context, userID int64,
    preferences map[string]interface{}, options ...SetOption) error {
    
    config := &setConfig{
        source:       "user",
        changeReason: "bulk_update",
    }
    
    for _, opt := range options {
        opt(config)
    }
    
    tx, err := pm.db.BeginTx(ctx, nil)
    if err != nil {
        return err
    }
    defer tx.Rollback()
    
    coreUpdates := make(map[string]interface{})
    var complexUpdates []complexUpdate
    
    // Separate core and complex preferences
    for fullKey, value := range preferences {
        category, key := pm.parsePreferenceKey(fullKey)
        
        if pm.shouldStoreAsCore(category, key) {
            coreUpdates[key] = value
        } else {
            complexUpdates = append(complexUpdates, complexUpdate{
                category: category,
                key:      key,
                value:    value,
            })
        }
    }
    
    // Update core preferences
    if len(coreUpdates) > 0 {
        coreJSON, err := json.Marshal(coreUpdates)
        if err != nil {
            return fmt.Errorf("failed to marshal core preferences: %w", err)
        }
        
        _, err = tx.ExecContext(ctx, `
            UPDATE users 
            SET 
                preferences = preferences || $2::jsonb,
                preferences_version = preferences_version + 1,
                preferences_updated_at = NOW()
            WHERE id = $1
        `, userID, string(coreJSON))
        
        if err != nil {
            return fmt.Errorf("failed to update core preferences: %w", err)
        }
    }
    
    // Update complex preferences
    for _, update := range complexUpdates {
        // Get current value for audit
        currentValue, _ := pm.GetPreference(ctx, userID, update.category, update.key)
        
        // Deactivate existing
        _, err = tx.ExecContext(ctx, `
            UPDATE user_preferences 
            SET is_active = false, updated_at = NOW()
            WHERE user_id = $1 AND category = $2 AND preference_key = $3 AND is_active = true
        `, userID, update.category, update.key)
        
        if err != nil {
            return fmt.Errorf("failed to deactivate preference %s.%s: %w", 
                update.category, update.key, err)
        }
        
        // Insert new preference
        var valueText sql.NullString
        var valueNumber sql.NullFloat64
        var valueBool sql.NullBool
        var valueJSON []byte
        var valueTimestamp sql.NullTime
        
        pm.preparePreferenceValue(update.value, &valueText, &valueNumber, &valueBool, &valueJSON, &valueTimestamp)
        
        _, err = tx.ExecContext(ctx, `
            INSERT INTO user_preferences 
            (user_id, category, preference_key, value_text, value_number, value_boolean, 
             value_json, value_timestamp, source, is_active)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, true)
        `, userID, update.category, update.key,
           valueText, valueNumber, valueBool, valueJSON, valueTimestamp,
           config.source)
        
        if err != nil {
            return fmt.Errorf("failed to insert preference %s.%s: %w", 
                update.category, update.key, err)
        }
        
        // Record change
        pm.recordPreferenceChange(ctx, tx, &PreferenceChange{
            UserID:       userID,
            Category:     update.category,
            Key:          update.key,
            OldValue:     currentValue,
            NewValue:     update.value,
            ChangeType:   "updated",
            ChangeReason: config.changeReason,
            ChangedBy:    config.changedBy,
            IPAddress:    config.ipAddress,
            UserAgent:    config.userAgent,
        })
    }
    
    if err := tx.Commit(); err != nil {
        return fmt.Errorf("failed to commit bulk preference update: %w", err)
    }
    
    // Invalidate cache
    pm.invalidateUserCache(ctx, userID)
    
    pm.logger.Info("Bulk preferences updated",
        zap.Int64("user_id", userID),
        zap.Int("core_count", len(coreUpdates)),
        zap.Int("complex_count", len(complexUpdates)),
        zap.String("source", config.source),
    )
    
    return nil
}

type complexUpdate struct {
    category string
    key      string
    value    interface{}
}

type setConfig struct {
    source       string
    changeReason string
    changedBy    int64
    ipAddress    string
    userAgent    string
}

type SetOption func(*setConfig)

func WithSource(source string) SetOption {
    return func(c *setConfig) { c.source = source }
}

func WithChangeReason(reason string) SetOption {
    return func(c *setConfig) { c.changeReason = reason }
}

func WithChangedBy(userID int64) SetOption {
    return func(c *setConfig) { c.changedBy = userID }
}

func WithIPAddress(ip string) SetOption {
    return func(c *setConfig) { c.ipAddress = ip }
}

func WithUserAgent(ua string) SetOption {
    return func(c *setConfig) { c.userAgent = ua }
}
```

### Preference Utilities and Helpers

```go
// Helper functions for preference management

// shouldStoreAsCore determines if a preference should be stored in the JSON column
func (pm *PreferenceManager) shouldStoreAsCore(category, key string) bool {
    corePreferences := map[string]map[string]bool{
        "ui": {
            "theme":          true,
            "language":       true,
            "timezone":       true,
            "compact_layout": true,
        },
        "behavioral": {
            "tutorial_completed":       true,
            "welcome_popup_dismissed":  true,
        },
    }
    
    if categoryMap, exists := corePreferences[category]; exists {
        return categoryMap[key]
    }
    
    return false
}

// parsePreferenceKey splits a full preference key into category and key
func (pm *PreferenceManager) parsePreferenceKey(fullKey string) (category, key string) {
    parts := strings.SplitN(fullKey, ".", 2)
    if len(parts) == 2 {
        return parts[0], parts[1]
    }
    return "ui", fullKey // Default to ui category
}

// validatePreference validates a preference value against rules
func (pm *PreferenceManager) validatePreference(category, key string, value interface{}) error {
    defaultPref := pm.getDefault(category, key)
    if defaultPref == nil {
        return nil // No validation rules defined
    }
    
    // Type validation
    switch defaultPref.DataType {
    case "boolean":
        if _, ok := value.(bool); !ok {
            return fmt.Errorf("expected boolean value for %s.%s", category, key)
        }
    case "number":
        switch value.(type) {
        case int, int64, float64:
            // Valid numeric types
        default:
            return fmt.Errorf("expected numeric value for %s.%s", category, key)
        }
    case "text":
        if _, ok := value.(string); !ok {
            return fmt.Errorf("expected string value for %s.%s", category, key)
        }
    }
    
    // Additional validation rules can be implemented here
    // using JSON schema validation if validation_rules is set
    
    return nil
}

// preparePreferenceValue converts Go value to SQL nullable types
func (pm *PreferenceManager) preparePreferenceValue(value interface{},
    valueText *sql.NullString, valueNumber *sql.NullFloat64, valueBool *sql.NullBool,
    valueJSON *[]byte, valueTimestamp *sql.NullTime) {
    
    switch v := value.(type) {
    case string:
        *valueText = sql.NullString{String: v, Valid: true}
    case bool:
        *valueBool = sql.NullBool{Bool: v, Valid: true}
    case int:
        *valueNumber = sql.NullFloat64{Float64: float64(v), Valid: true}
    case int64:
        *valueNumber = sql.NullFloat64{Float64: float64(v), Valid: true}
    case float64:
        *valueNumber = sql.NullFloat64{Float64: v, Valid: true}
    case time.Time:
        *valueTimestamp = sql.NullTime{Time: v, Valid: true}
    default:
        // Store complex types as JSON
        if jsonBytes, err := json.Marshal(v); err == nil {
            *valueJSON = jsonBytes
        }
    }
}

// extractPreferenceValue converts SQL types back to Go values
func (pm *PreferenceManager) extractPreferenceValue(valueText sql.NullString,
    valueNumber sql.NullFloat64, valueBool sql.NullBool, valueJSON []byte,
    valueTimestamp sql.NullTime) (interface{}, string) {
    
    if valueText.Valid {
        return valueText.String, "text"
    }
    if valueNumber.Valid {
        return valueNumber.Float64, "number"
    }
    if valueBool.Valid {
        return valueBool.Bool, "boolean"
    }
    if valueTimestamp.Valid {
        return valueTimestamp.Time, "timestamp"
    }
    if len(valueJSON) > 0 {
        var value interface{}
        if err := json.Unmarshal(valueJSON, &value); err == nil {
            return value, "json"
        }
    }
    
    return nil, "unknown"
}

// getDefault retrieves default preference configuration
func (pm *PreferenceManager) getDefault(category, key string) *DefaultPreference {
    cacheKey := fmt.Sprintf("%s.%s", category, key)
    return pm.defaultsCache[cacheKey]
}

// loadDefaults loads default preferences into memory cache
func (pm *PreferenceManager) loadDefaults() {
    ctx := context.Background()
    query := `
        SELECT category, preference_key, default_text, default_number, 
               default_boolean, default_json, data_type, is_required, description,
               validation_rules
        FROM preference_defaults
        ORDER BY category, preference_key
    `
    
    rows, err := pm.db.QueryContext(ctx, query)
    if err != nil {
        pm.logger.Error("Failed to load preference defaults", zap.Error(err))
        return
    }
    defer rows.Close()
    
    for rows.Next() {
        var def DefaultPreference
        var defaultText sql.NullString
        var defaultNumber sql.NullFloat64
        var defaultBool sql.NullBool
        var defaultJSON []byte
        var validationRules sql.NullString
        
        err := rows.Scan(
            &def.Category,
            &def.Key,
            &defaultText,
            &defaultNumber,
            &defaultBool,
            &defaultJSON,
            &def.DataType,
            &def.IsRequired,
            &def.Description,
            &validationRules,
        )
        
        if err != nil {
            continue
        }
        
        // Extract default value based on type
        switch def.DataType {
        case "text":
            if defaultText.Valid {
                def.DefaultValue = defaultText.String
            }
        case "number":
            if defaultNumber.Valid {
                def.DefaultValue = defaultNumber.Float64
            }
        case "boolean":
            if defaultBool.Valid {
                def.DefaultValue = defaultBool.Bool
            }
        case "json":
            if len(defaultJSON) > 0 {
                var value interface{}
                if err := json.Unmarshal(defaultJSON, &value); err == nil {
                    def.DefaultValue = value
                }
            }
        }
        
        if validationRules.Valid {
            def.ValidationRules = validationRules.String
        }
        
        cacheKey := fmt.Sprintf("%s.%s", def.Category, def.Key)
        pm.defaultsCache[cacheKey] = &def
    }
    
    pm.logger.Info("Loaded preference defaults", 
        zap.Int("count", len(pm.defaultsCache)))
}

// applyDefaults fills in missing preferences with default values
func (pm *PreferenceManager) applyDefaults(preferences *UserPreferences) {
    for cacheKey, defaultPref := range pm.defaultsCache {
        // Check if preference exists
        if pm.shouldStoreAsCore(defaultPref.Category, defaultPref.Key) {
            if _, exists := preferences.CorePreferences[defaultPref.Key]; !exists {
                preferences.CorePreferences[defaultPref.Key] = defaultPref.DefaultValue
            }
        } else {
            if _, exists := preferences.ComplexPreferences[cacheKey]; !exists {
                preferences.ComplexPreferences[cacheKey] = &Preference{
                    UserID:    preferences.UserID,
                    Category:  defaultPref.Category,
                    Key:       defaultPref.Key,
                    Value:     defaultPref.DefaultValue,
                    DataType:  defaultPref.DataType,
                    Source:    "default",
                    IsActive:  true,
                    CreatedAt: time.Now(),
                    UpdatedAt: time.Now(),
                }
            }
        }
    }
}

// recordPreferenceChange records a change in the audit log
func (pm *PreferenceManager) recordPreferenceChange(ctx context.Context, tx *sql.Tx, 
    change *PreferenceChange) error {
    
    oldValueJSON, _ := json.Marshal(change.OldValue)
    newValueJSON, _ := json.Marshal(change.NewValue)
    
    query := `
        INSERT INTO user_preference_history 
        (user_id, category, preference_key, old_value, new_value, change_type,
         change_reason, changed_by_user_id, ip_address, user_agent)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
    `
    
    var changedBy sql.NullInt64
    if change.ChangedBy > 0 {
        changedBy = sql.NullInt64{Int64: change.ChangedBy, Valid: true}
    }
    
    _, err := tx.ExecContext(ctx, query,
        change.UserID,
        change.Category,
        change.Key,
        string(oldValueJSON),
        string(newValueJSON),
        change.ChangeType,
        change.ChangeReason,
        changedBy,
        change.IPAddress,
        change.UserAgent,
    )
    
    return err
}
```

### Caching Layer

```go
package preferences

import (
    "context"
    "encoding/json"
    "fmt"
    "time"
)

// getCachedPreferences retrieves preferences from Redis cache
func (pm *PreferenceManager) getCachedPreferences(ctx context.Context, userID int64) *UserPreferences {
    cacheKey := fmt.Sprintf("user_preferences:%d", userID)
    
    data, err := pm.cache.Get(ctx, cacheKey).Result()
    if err != nil {
        return nil
    }
    
    var preferences UserPreferences
    if err := json.Unmarshal([]byte(data), &preferences); err != nil {
        pm.logger.Warn("Failed to unmarshal cached preferences",
            zap.Int64("user_id", userID),
            zap.Error(err),
        )
        return nil
    }
    
    return &preferences
}

// cachePreferences stores preferences in Redis cache
func (pm *PreferenceManager) cachePreferences(ctx context.Context, preferences *UserPreferences) {
    cacheKey := fmt.Sprintf("user_preferences:%d", preferences.UserID)
    
    data, err := json.Marshal(preferences)
    if err != nil {
        pm.logger.Error("Failed to marshal preferences for caching",
            zap.Int64("user_id", preferences.UserID),
            zap.Error(err),
        )
        return
    }
    
    // Cache for 1 hour
    pm.cache.Set(ctx, cacheKey, data, time.Hour)
}

// invalidateUserCache removes user preferences from cache
func (pm *PreferenceManager) invalidateUserCache(ctx context.Context, userID int64) {
    cacheKey := fmt.Sprintf("user_preferences:%d", userID)
    pm.cache.Del(ctx, cacheKey)
}

// PreferenceService provides high-level preference operations
type PreferenceService struct {
    manager *PreferenceManager
    logger  *zap.Logger
}

func NewPreferenceService(manager *PreferenceManager, logger *zap.Logger) *PreferenceService {
    return &PreferenceService{
        manager: manager,
        logger:  logger,
    }
}

// Common preference operations

// MarkPopupDismissed marks a popup as dismissed by the user
func (ps *PreferenceService) MarkPopupDismissed(ctx context.Context, userID int64, 
    popupType string) error {
    
    key := fmt.Sprintf("%s_dismissed", popupType)
    return ps.manager.SetPreference(ctx, userID, "behavioral", key, true,
        WithChangeReason("popup_dismissed"))
}

// IsPopupDismissed checks if a popup has been dismissed
func (ps *PreferenceService) IsPopupDismissed(ctx context.Context, userID int64, 
    popupType string) (bool, error) {
    
    key := fmt.Sprintf("%s_dismissed", popupType)
    value, err := ps.manager.GetPreference(ctx, userID, "behavioral", key)
    if err != nil {
        return false, nil // Default to not dismissed
    }
    
    if dismissed, ok := value.(bool); ok {
        return dismissed, nil
    }
    
    return false, nil
}

// UpdateNotificationSettings updates user notification preferences
func (ps *PreferenceService) UpdateNotificationSettings(ctx context.Context, userID int64,
    settings map[string]interface{}) error {
    
    preferences := make(map[string]interface{})
    for key, value := range settings {
        fullKey := fmt.Sprintf("notifications.%s", key)
        preferences[fullKey] = value
    }
    
    return ps.manager.BulkSetPreferences(ctx, userID, preferences,
        WithChangeReason("notification_settings_update"))
}

// GetThemePreference gets user's theme preference
func (ps *PreferenceService) GetThemePreference(ctx context.Context, userID int64) (string, error) {
    value, err := ps.manager.GetPreference(ctx, userID, "ui", "theme")
    if err != nil {
        return "light", nil // Default theme
    }
    
    if theme, ok := value.(string); ok {
        return theme, nil
    }
    
    if darkTheme, ok := value.(bool); ok {
        if darkTheme {
            return "dark", nil
        }
        return "light", nil
    }
    
    return "light", nil
}

// SetLanguagePreference sets user's language preference
func (ps *PreferenceService) SetLanguagePreference(ctx context.Context, userID int64, 
    language string) error {
    
    return ps.manager.SetPreference(ctx, userID, "ui", "language", language,
        WithChangeReason("language_change"))
}
```

### HTTP API Integration

```go
package api

import (
    "encoding/json"
    "net/http"
    "strconv"
    
    "github.com/gorilla/mux"
    "go.uber.org/zap"
)

// PreferenceHandler handles HTTP requests for user preferences
type PreferenceHandler struct {
    service *preferences.PreferenceService
    logger  *zap.Logger
}

func NewPreferenceHandler(service *preferences.PreferenceService, logger *zap.Logger) *PreferenceHandler {
    return &PreferenceHandler{
        service: service,
        logger:  logger,
    }
}

// GetPreferences returns all user preferences
func (ph *PreferenceHandler) GetPreferences(w http.ResponseWriter, r *http.Request) {
    userID := getUserIDFromContext(r.Context())
    
    preferences, err := ph.service.manager.GetUserPreferences(r.Context(), userID)
    if err != nil {
        http.Error(w, "Failed to get preferences", http.StatusInternalServerError)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(preferences)
}

// UpdatePreferences updates multiple user preferences
func (ph *PreferenceHandler) UpdatePreferences(w http.ResponseWriter, r *http.Request) {
    userID := getUserIDFromContext(r.Context())
    
    var request map[string]interface{}
    if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
        http.Error(w, "Invalid request body", http.StatusBadRequest)
        return
    }
    
    err := ph.service.manager.BulkSetPreferences(r.Context(), userID, request,
        preferences.WithIPAddress(getClientIP(r)),
        preferences.WithUserAgent(r.UserAgent()),
        preferences.WithChangeReason("api_update"))
    
    if err != nil {
        ph.logger.Error("Failed to update preferences",
            zap.Int64("user_id", userID),
            zap.Error(err),
        )
        http.Error(w, "Failed to update preferences", http.StatusInternalServerError)
        return
    }
    
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]string{"status": "success"})
}

// DismissPopup marks a popup as dismissed
func (ph *PreferenceHandler) DismissPopup(w http.ResponseWriter, r *http.Request) {
    userID := getUserIDFromContext(r.Context())
    vars := mux.Vars(r)
    popupType := vars["popup_type"]
    
    if popupType == "" {
        http.Error(w, "popup_type is required", http.StatusBadRequest)
        return
    }
    
    err := ph.service.MarkPopupDismissed(r.Context(), userID, popupType)
    if err != nil {
        http.Error(w, "Failed to dismiss popup", http.StatusInternalServerError)
        return
    }
    
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]string{"status": "dismissed"})
}

func getUserIDFromContext(ctx context.Context) int64 {
    // Extract user ID from context (implementation depends on auth system)
    if userID, ok := ctx.Value("user_id").(int64); ok {
        return userID
    }
    return 0
}

func getClientIP(r *http.Request) string {
    // Get client IP from request headers
    if ip := r.Header.Get("X-Forwarded-For"); ip != "" {
        return ip
    }
    if ip := r.Header.Get("X-Real-IP"); ip != "" {
        return ip
    }
    return r.RemoteAddr
}
```

## Consequences

### Positive

- **Performance**: Core preferences cached in JSON column for fast access
- **Flexibility**: Complex preferences support various data types
- **Auditability**: Complete change history for compliance and debugging
- **Scalability**: Redis caching reduces database load
- **User Experience**: Fast preference retrieval enhances application responsiveness
- **Maintainability**: Centralized preference management with defaults

### Negative

- **Complexity**: Multiple storage strategies increase system complexity
- **Storage Overhead**: Preference history and caching consume additional storage
- **Cache Consistency**: Potential inconsistency between cache and database
- **Migration Effort**: Existing preference systems require migration

### Mitigations

- **Documentation**: Clear guidelines for when to use each storage strategy
- **Monitoring**: Track preference access patterns and cache performance
- **Testing**: Comprehensive tests for preference operations and cache consistency
- **Gradual Migration**: Phased approach to migrate existing preferences

## Related Patterns

- **[Redis Convention](012-redis-convention.md)**: Redis usage patterns for caching
- **[Application Version](014-version.md)**: Versioning preference schema changes
- **[Logging](013-logging.md)**: Audit logging for preference changes
- **[Independent Schema](022-independent-schema.md)**: Preference schema evolution 
