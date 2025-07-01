# Text Length Constraints and Management

## Status
**Accepted**

## Context
Database text columns require careful length management to ensure data integrity, performance, and security. Different database systems handle text length constraints differently:

- **MySQL**: `VARCHAR(n)` enforces length limits; older versions silently truncated, newer versions throw errors
- **PostgreSQL**: `TEXT` has no inherent length limit; requires explicit constraints for validation
- **Performance Impact**: Uncontrolled text length affects index size, query performance, and storage costs
- **Security Concerns**: Unlimited text input can lead to DoS attacks and storage abuse
- **Data Quality**: Consistent length limits improve data predictability and application behavior

## Decision
We will implement comprehensive text length management using database constraints, application validation, and custom domain types to ensure predictable behavior and optimal performance.

## Implementation

### 1. Database Schema Design

#### MySQL Implementation
```sql
-- Basic length constraints
CREATE TABLE users (
    id INT PRIMARY KEY AUTO_INCREMENT,
    username VARCHAR(50) NOT NULL,
    email VARCHAR(254) NOT NULL,  -- RFC 5321 email length limit
    bio VARCHAR(500),
    settings JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- Additional constraints
    CONSTRAINT chk_username_length CHECK (CHAR_LENGTH(username) >= 3),
    CONSTRAINT chk_bio_length CHECK (CHAR_LENGTH(bio) <= 500),
    CONSTRAINT chk_email_format CHECK (email REGEXP '^[^@]+@[^@]+\.[^@]+$')
);

-- Content tables with appropriate limits
CREATE TABLE posts (
    id INT PRIMARY KEY AUTO_INCREMENT,
    title VARCHAR(200) NOT NULL,
    slug VARCHAR(100) NOT NULL UNIQUE,
    excerpt VARCHAR(500),
    content TEXT,  -- Actual content can be longer
    
    -- Enforce minimum title length
    CONSTRAINT chk_title_length CHECK (CHAR_LENGTH(title) >= 5 AND CHAR_LENGTH(title) <= 200),
    CONSTRAINT chk_slug_format CHECK (slug REGEXP '^[a-z0-9-]+$'),
    CONSTRAINT chk_content_length CHECK (CHAR_LENGTH(content) <= 65535)  -- 64KB limit
);

-- Comments with strict limits
CREATE TABLE comments (
    id INT PRIMARY KEY AUTO_INCREMENT,
    post_id INT NOT NULL,
    content VARCHAR(1000) NOT NULL,
    author_email VARCHAR(254) NOT NULL,
    
    CONSTRAINT chk_comment_length CHECK (CHAR_LENGTH(content) >= 1 AND CHAR_LENGTH(content) <= 1000),
    FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE
);
```

#### PostgreSQL Implementation with Custom Types
```sql
-- Custom domain types for consistent length management
CREATE DOMAIN short_text AS VARCHAR(255);
CREATE DOMAIN medium_text AS VARCHAR(1000);
CREATE DOMAIN long_text AS VARCHAR(5000);
CREATE DOMAIN email_text AS VARCHAR(254) CHECK (VALUE ~ '^[^@]+@[^@]+\.[^@]+$');
CREATE DOMAIN username_text AS VARCHAR(50) CHECK (char_length(VALUE) >= 3);

-- Enhanced domains with validation
CREATE DOMAIN slug_text AS VARCHAR(100) 
    CHECK (VALUE ~ '^[a-z0-9-]+$' AND char_length(VALUE) >= 3);

CREATE DOMAIN phone_text AS VARCHAR(20) 
    CHECK (VALUE ~ '^\+?[1-9]\d{1,14}$');

CREATE DOMAIN description_text AS VARCHAR(500) 
    CHECK (char_length(VALUE) >= 10);

-- Tables using custom types
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username username_text NOT NULL UNIQUE,
    email email_text NOT NULL UNIQUE,
    phone phone_text,
    bio description_text,
    settings JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE posts (
    id SERIAL PRIMARY KEY,
    title short_text NOT NULL,
    slug slug_text NOT NULL UNIQUE,
    excerpt description_text,
    content TEXT CHECK (char_length(content) <= 100000),  -- 100KB limit
    tags TEXT[] DEFAULT '{}',
    
    -- Additional text constraints
    CONSTRAINT chk_title_not_empty CHECK (trim(title) != ''),
    CONSTRAINT chk_content_not_empty CHECK (trim(content) != '')
);

-- Function to validate text length with custom message
CREATE OR REPLACE FUNCTION validate_text_length(
    text_value TEXT,
    min_length INTEGER DEFAULT 0,
    max_length INTEGER DEFAULT NULL,
    field_name TEXT DEFAULT 'field'
) RETURNS BOOLEAN AS $$
BEGIN
    IF text_value IS NULL THEN
        RAISE EXCEPTION '%s cannot be null', field_name;
    END IF;
    
    IF char_length(text_value) < min_length THEN
        RAISE EXCEPTION '%s must be at least %s characters long', field_name, min_length;
    END IF;
    
    IF max_length IS NOT NULL AND char_length(text_value) > max_length THEN
        RAISE EXCEPTION '%s cannot exceed %s characters', field_name, max_length;
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
```

### 2. Application Layer Validation

```go
// pkg/validation/text.go
package validation

import (
    "fmt"
    "regexp"
    "strings"
    "unicode/utf8"
)

// TextConstraints defines validation rules for text fields
type TextConstraints struct {
    MinLength   int
    MaxLength   int
    Required    bool
    AllowEmpty  bool
    Pattern     *regexp.Regexp
    Trim        bool
    Normalize   bool
}

// Common text validation patterns
var (
    UsernamePattern = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)
    SlugPattern     = regexp.MustCompile(`^[a-z0-9-]+$`)
    EmailPattern    = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)
    PhonePattern    = regexp.MustCompile(`^\+?[1-9]\d{1,14}$`)
)

// Predefined constraints for common fields
var (
    UsernameConstraints = TextConstraints{
        MinLength: 3,
        MaxLength: 50,
        Required:  true,
        Pattern:   UsernamePattern,
        Trim:      true,
        Normalize: true,
    }
    
    EmailConstraints = TextConstraints{
        MinLength: 5,
        MaxLength: 254,
        Required:  true,
        Pattern:   EmailPattern,
        Trim:      true,
        Normalize: true,
    }
    
    TitleConstraints = TextConstraints{
        MinLength: 5,
        MaxLength: 200,
        Required:  true,
        Trim:      true,
    }
    
    ContentConstraints = TextConstraints{
        MinLength: 10,
        MaxLength: 65535,
        Required:  true,
        Trim:      true,
    }
    
    CommentConstraints = TextConstraints{
        MinLength: 1,
        MaxLength: 1000,
        Required:  true,
        Trim:      true,
    }
)

// ValidateText validates text against constraints
func ValidateText(value string, constraints TextConstraints, fieldName string) error {
    original := value
    
    // Normalize text if required
    if constraints.Normalize {
        value = strings.ToLower(value)
    }
    
    // Trim whitespace if required
    if constraints.Trim {
        value = strings.TrimSpace(value)
    }
    
    // Check if required
    if constraints.Required && value == "" {
        return fmt.Errorf("%s is required", fieldName)
    }
    
    // Check if empty is allowed
    if !constraints.AllowEmpty && value == "" {
        return fmt.Errorf("%s cannot be empty", fieldName)
    }
    
    // Skip length checks for empty optional fields
    if value == "" {
        return nil
    }
    
    // Validate UTF-8 encoding
    if !utf8.ValidString(value) {
        return fmt.Errorf("%s contains invalid UTF-8 characters", fieldName)
    }
    
    // Check length constraints
    length := utf8.RuneCountInString(value)
    
    if length < constraints.MinLength {
        return fmt.Errorf("%s must be at least %d characters long", fieldName, constraints.MinLength)
    }
    
    if constraints.MaxLength > 0 && length > constraints.MaxLength {
        return fmt.Errorf("%s cannot exceed %d characters", fieldName, constraints.MaxLength)
    }
    
    // Check pattern if specified
    if constraints.Pattern != nil && !constraints.Pattern.MatchString(value) {
        return fmt.Errorf("%s format is invalid", fieldName)
    }
    
    return nil
}

// TextValidator provides validation for multiple text fields
type TextValidator struct {
    constraints map[string]TextConstraints
}

func NewTextValidator() *TextValidator {
    return &TextValidator{
        constraints: map[string]TextConstraints{
            "username": UsernameConstraints,
            "email":    EmailConstraints,
            "title":    TitleConstraints,
            "content":  ContentConstraints,
            "comment":  CommentConstraints,
        },
    }
}

func (tv *TextValidator) Validate(data map[string]string) map[string]error {
    errors := make(map[string]error)
    
    for field, value := range data {
        if constraint, exists := tv.constraints[field]; exists {
            if err := ValidateText(value, constraint, field); err != nil {
                errors[field] = err
            }
        }
    }
    
    return errors
}

func (tv *TextValidator) AddConstraint(field string, constraint TextConstraints) {
    tv.constraints[field] = constraint
}
```

### 3. Model Integration

```go
// pkg/models/user.go
package models

import (
    "database/sql/driver"
    "fmt"
    "strings"
    "unicode/utf8"
)

// Username custom type with validation
type Username string

func NewUsername(value string) (Username, error) {
    value = strings.TrimSpace(value)
    
    if utf8.RuneCountInString(value) < 3 {
        return "", fmt.Errorf("username must be at least 3 characters long")
    }
    
    if utf8.RuneCountInString(value) > 50 {
        return "", fmt.Errorf("username cannot exceed 50 characters")
    }
    
    if !UsernamePattern.MatchString(value) {
        return "", fmt.Errorf("username can only contain letters, numbers, underscores, and hyphens")
    }
    
    return Username(value), nil
}

func (u Username) String() string {
    return string(u)
}

func (u Username) Value() (driver.Value, error) {
    return string(u), nil
}

func (u *Username) Scan(value interface{}) error {
    if value == nil {
        *u = ""
        return nil
    }
    
    switch v := value.(type) {
    case string:
        username, err := NewUsername(v)
        if err != nil {
            return err
        }
        *u = username
        return nil
    case []byte:
        username, err := NewUsername(string(v))
        if err != nil {
            return err
        }
        *u = username
        return nil
    default:
        return fmt.Errorf("cannot scan %T into Username", value)
    }
}

// Email custom type
type Email string

func NewEmail(value string) (Email, error) {
    value = strings.TrimSpace(strings.ToLower(value))
    
    if utf8.RuneCountInString(value) > 254 {
        return "", fmt.Errorf("email cannot exceed 254 characters")
    }
    
    if !EmailPattern.MatchString(value) {
        return "", fmt.Errorf("invalid email format")
    }
    
    return Email(value), nil
}

func (e Email) String() string {
    return string(e)
}

func (e Email) Value() (driver.Value, error) {
    return string(e), nil
}

func (e *Email) Scan(value interface{}) error {
    if value == nil {
        *e = ""
        return nil
    }
    
    switch v := value.(type) {
    case string:
        email, err := NewEmail(v)
        if err != nil {
            return err
        }
        *e = email
        return nil
    case []byte:
        email, err := NewEmail(string(v))
        if err != nil {
            return err
        }
        *e = email
        return nil
    default:
        return fmt.Errorf("cannot scan %T into Email", value)
    }
}

// User model with text constraints
type User struct {
    ID       int      `json:"id" db:"id"`
    Username Username `json:"username" db:"username"`
    Email    Email    `json:"email" db:"email"`
    Bio      *string  `json:"bio,omitempty" db:"bio"`
    Settings string   `json:"settings,omitempty" db:"settings"`
}

func (u *User) Validate() error {
    // Username validation is built into the type
    
    // Bio validation
    if u.Bio != nil {
        bio := strings.TrimSpace(*u.Bio)
        if utf8.RuneCountInString(bio) > 500 {
            return fmt.Errorf("bio cannot exceed 500 characters")
        }
        if bio != "" && utf8.RuneCountInString(bio) < 10 {
            return fmt.Errorf("bio must be at least 10 characters long when provided")
        }
    }
    
    return nil
}
```

### 4. Database Migration for Existing Data

```go
// cmd/migrate-text-constraints/main.go
package main

import (
    "database/sql"
    "fmt"
    "log"
    "strings"
    "unicode/utf8"
)

func migrateTextConstraints(db *sql.DB) error {
    // 1. Identify and fix existing data that violates new constraints
    if err := fixExistingData(db); err != nil {
        return fmt.Errorf("failed to fix existing data: %w", err)
    }
    
    // 2. Add new constraints
    constraints := []string{
        "ALTER TABLE users ADD CONSTRAINT chk_username_length CHECK (CHAR_LENGTH(username) BETWEEN 3 AND 50)",
        "ALTER TABLE users ADD CONSTRAINT chk_email_length CHECK (CHAR_LENGTH(email) <= 254)",
        "ALTER TABLE users ADD CONSTRAINT chk_bio_length CHECK (bio IS NULL OR CHAR_LENGTH(bio) <= 500)",
        "ALTER TABLE posts ADD CONSTRAINT chk_title_length CHECK (CHAR_LENGTH(title) BETWEEN 5 AND 200)",
        "ALTER TABLE posts ADD CONSTRAINT chk_content_length CHECK (CHAR_LENGTH(content) <= 65535)",
    }
    
    for _, constraint := range constraints {
        if _, err := db.Exec(constraint); err != nil {
            return fmt.Errorf("failed to add constraint: %w", err)
        }
    }
    
    return nil
}

func fixExistingData(db *sql.DB) error {
    // Fix usernames that are too short or too long
    rows, err := db.Query(`
        SELECT id, username FROM users 
        WHERE CHAR_LENGTH(username) < 3 OR CHAR_LENGTH(username) > 50
    `)
    if err != nil {
        return err
    }
    defer rows.Close()
    
    for rows.Next() {
        var id int
        var username string
        if err := rows.Scan(&id, &username); err != nil {
            continue
        }
        
        // Truncate or pad username
        newUsername := fixUsername(username)
        _, err := db.Exec("UPDATE users SET username = ? WHERE id = ?", newUsername, id)
        if err != nil {
            log.Printf("Failed to fix username for user %d: %v", id, err)
        }
    }
    
    // Fix bio fields that are too long
    _, err = db.Exec(`
        UPDATE users 
        SET bio = SUBSTRING(bio, 1, 500) 
        WHERE CHAR_LENGTH(bio) > 500
    `)
    if err != nil {
        return err
    }
    
    // Fix titles that are too short or too long
    _, err = db.Exec(`
        UPDATE posts 
        SET title = CASE 
            WHEN CHAR_LENGTH(title) < 5 THEN CONCAT(title, ' - Post')
            WHEN CHAR_LENGTH(title) > 200 THEN SUBSTRING(title, 1, 197) + '...'
            ELSE title
        END
        WHERE CHAR_LENGTH(title) < 5 OR CHAR_LENGTH(title) > 200
    `)
    
    return err
}

func fixUsername(username string) string {
    // Clean username
    username = strings.TrimSpace(username)
    username = strings.ReplaceAll(username, " ", "_")
    
    // Ensure minimum length
    if utf8.RuneCountInString(username) < 3 {
        username = username + "_user"
    }
    
    // Ensure maximum length
    if utf8.RuneCountInString(username) > 50 {
        runes := []rune(username)
        username = string(runes[:50])
    }
    
    return username
}
```

### 5. Performance Optimization

```sql
-- Index optimization for text fields
-- Use prefix indexes for long text fields
CREATE INDEX idx_posts_title ON posts(title(50));
CREATE INDEX idx_posts_content_prefix ON posts(content(100));

-- Full-text search indexes
CREATE FULLTEXT INDEX idx_posts_fulltext ON posts(title, content);
CREATE FULLTEXT INDEX idx_comments_fulltext ON comments(content);

-- Covering indexes for common queries
CREATE INDEX idx_users_username_email ON users(username, email);
CREATE INDEX idx_posts_title_created ON posts(title, created_at);

-- Analyze index usage
EXPLAIN SELECT * FROM users WHERE username LIKE 'john%';
SHOW INDEX FROM posts;
```

### 6. Monitoring and Alerting

```go
// pkg/monitoring/text_metrics.go
package monitoring

import (
    "database/sql"
    "log"
    "time"
)

type TextMetrics struct {
    db *sql.DB
}

func NewTextMetrics(db *sql.DB) *TextMetrics {
    return &TextMetrics{db: db}
}

func (tm *TextMetrics) CollectMetrics() {
    ticker := time.NewTicker(1 * time.Hour)
    defer ticker.Stop()
    
    for range ticker.C {
        tm.collectLengthDistribution()
        tm.detectAnomalies()
    }
}

func (tm *TextMetrics) collectLengthDistribution() {
    // Collect username length distribution
    rows, err := tm.db.Query(`
        SELECT 
            CASE 
                WHEN CHAR_LENGTH(username) < 10 THEN 'short'
                WHEN CHAR_LENGTH(username) < 20 THEN 'medium'
                ELSE 'long'
            END AS category,
            COUNT(*) as count
        FROM users 
        GROUP BY category
    `)
    if err != nil {
        log.Printf("Failed to collect username metrics: %v", err)
        return
    }
    defer rows.Close()
    
    for rows.Next() {
        var category string
        var count int
        if err := rows.Scan(&category, &count); err == nil {
            log.Printf("Username length distribution - %s: %d", category, count)
        }
    }
}

func (tm *TextMetrics) detectAnomalies() {
    // Detect posts with unusually long content
    var longContentCount int
    err := tm.db.QueryRow(`
        SELECT COUNT(*) 
        FROM posts 
        WHERE CHAR_LENGTH(content) > 50000
    `).Scan(&longContentCount)
    
    if err == nil && longContentCount > 0 {
        log.Printf("Alert: %d posts with content longer than 50KB detected", longContentCount)
    }
    
    // Detect potential spam (very short comments)
    var shortCommentCount int
    err = tm.db.QueryRow(`
        SELECT COUNT(*) 
        FROM comments 
        WHERE CHAR_LENGTH(content) < 5 
        AND created_at > NOW() - INTERVAL 1 HOUR
    `).Scan(&shortCommentCount)
    
    if err == nil && shortCommentCount > 100 {
        log.Printf("Alert: %d very short comments in the last hour - potential spam", shortCommentCount)
    }
}
```

## Best Practices

### 1. Length Limit Guidelines

| Field Type | Recommended Length | Rationale |
|------------|-------------------|-----------|
| Username | 3-50 characters | Readable yet concise |
| Email | 5-254 characters | RFC 5321 specification |
| Title | 5-200 characters | SEO and readability |
| Short Description | 10-500 characters | Preview text |
| Content/Body | 10-65,535 characters | MySQL TEXT limit |
| Comment | 1-1,000 characters | Encourages concise feedback |
| URL Slug | 3-100 characters | SEO-friendly URLs |
| Phone | 7-20 characters | International format support |

### 2. Database-Specific Considerations

#### MySQL
```sql
-- Use appropriate column types
VARCHAR(255)    -- For most text fields
TEXT            -- For content up to 65KB
MEDIUMTEXT      -- For content up to 16MB
LONGTEXT        -- For content up to 4GB

-- Enable strict mode for data validation
SET sql_mode = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
```

#### PostgreSQL
```sql
-- Use domain types for consistency
CREATE DOMAIN text_short AS VARCHAR(255);
CREATE DOMAIN text_medium AS VARCHAR(1000);
CREATE DOMAIN text_long AS TEXT CHECK (char_length(VALUE) <= 65535);

-- Use CHECK constraints for validation
ALTER TABLE users ADD CONSTRAINT check_bio_length 
CHECK (bio IS NULL OR char_length(bio) BETWEEN 10 AND 500);
```

### 3. Application Layer Best Practices

```go
// Implement consistent validation across the application
type ValidationRule struct {
    Field       string
    MinLength   int
    MaxLength   int
    Required    bool
    Pattern     *regexp.Regexp
    Sanitizer   func(string) string
}

// Use middleware for automatic validation
func TextValidationMiddleware(rules []ValidationRule) gin.HandlerFunc {
    return func(c *gin.Context) {
        var data map[string]string
        if err := c.ShouldBindJSON(&data); err != nil {
            c.JSON(400, gin.H{"error": "Invalid JSON"})
            c.Abort()
            return
        }
        
        for _, rule := range rules {
            if value, exists := data[rule.Field]; exists {
                if err := ValidateText(value, TextConstraints{
                    MinLength: rule.MinLength,
                    MaxLength: rule.MaxLength,
                    Required:  rule.Required,
                    Pattern:   rule.Pattern,
                }, rule.Field); err != nil {
                    c.JSON(400, gin.H{"error": err.Error()})
                    c.Abort()
                    return
                }
            }
        }
        
        c.Next()
    }
}
```

## Consequences

### Positive
- **Data Integrity**: Consistent text length limits prevent data corruption and truncation
- **Performance**: Controlled field sizes optimize index performance and storage
- **Security**: Input length limits prevent DoS attacks and storage abuse
- **Predictability**: Consistent constraints enable reliable application behavior
- **User Experience**: Clear validation messages guide users to proper input format

### Negative
- **Complexity**: Additional validation logic in both database and application layers
- **Maintenance**: Field length requirements may change, requiring schema migrations
- **User Frustration**: Strict limits may prevent legitimate use cases
- **Development Overhead**: More extensive testing required for edge cases

## Related Patterns
- [Migration Files](002-migration-files.md) - Managing schema changes for text constraints
- [Database Design Record](009-database-design-record.md) - Documenting text field decisions
- [Validation Patterns](../backend/021-validator.md) - Application-level text validation
- [Performance Optimization](020-storage.md) - Text field storage optimization
