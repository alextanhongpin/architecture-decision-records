# Use Constants and Enums Effectively

## Status

`accepted`

## Context

Constants and enumerations are fundamental building blocks for maintainable Go code. Proper organization and usage of constants improves code readability, type safety, and maintainability while reducing magic numbers and strings throughout the codebase.

## Problem

Poor constant management leads to:
- **Magic numbers and strings** scattered throughout code
- **Inconsistent naming conventions** across packages
- **Difficult maintenance** when values need to change
- **Type safety issues** with string-based enumerations
- **Poor organization** with generic `const.go` files
- **Lack of validation** for enumeration values

## Solution

Implement a structured approach to constants and enumerations that emphasizes type safety, domain organization, and functional constructors over plain constant declarations.

## Go Constants Best Practices

### 1. Domain-Organized Constants

```go
// Bad: Generic constants file
// const.go
const (
    CodeNotFound = 404
    CodeSuccess  = 200
    StatusActive = "active"
    StatusInactive = "inactive"
    EmailDomainCompany = "@company.com"
    MaxRetries = 3
)

// Good: Domain-specific constants
// user/status.go
package user

type Status string

const (
    StatusActive   Status = "active"
    StatusInactive Status = "inactive"
    StatusPending  Status = "pending"
    StatusSuspended Status = "suspended"
)

// IsValid validates if the status is recognized
func (s Status) IsValid() bool {
    switch s {
    case StatusActive, StatusInactive, StatusPending, StatusSuspended:
        return true
    default:
        return false
    }
}

// String implements the Stringer interface
func (s Status) String() string {
    return string(s)
}

// http/status.go
package http

const (
    StatusOK       = 200
    StatusNotFound = 404
    StatusBadRequest = 400
    StatusInternalServerError = 500
)

// retry/config.go
package retry

const (
    DefaultMaxRetries = 3
    DefaultBackoffMs  = 100
    MaxBackoffMs      = 5000
)
```

### 2. Type-Safe Enumerations

```go
package order

import (
    "encoding/json"
    "fmt"
)

// OrderStatus represents the current state of an order
type OrderStatus int

const (
    OrderStatusPending OrderStatus = iota
    OrderStatusConfirmed
    OrderStatusProcessing
    OrderStatusShipped
    OrderStatusDelivered
    OrderStatusCancelled
    OrderStatusRefunded
)

// String provides string representation for OrderStatus
func (s OrderStatus) String() string {
    switch s {
    case OrderStatusPending:
        return "pending"
    case OrderStatusConfirmed:
        return "confirmed"
    case OrderStatusProcessing:
        return "processing"
    case OrderStatusShipped:
        return "shipped"
    case OrderStatusDelivered:
        return "delivered"
    case OrderStatusCancelled:
        return "cancelled"
    case OrderStatusRefunded:
        return "refunded"
    default:
        return "unknown"
    }
}

// MarshalJSON implements json.Marshaler
func (s OrderStatus) MarshalJSON() ([]byte, error) {
    return json.Marshal(s.String())
}

// UnmarshalJSON implements json.Unmarshaler
func (s *OrderStatus) UnmarshalJSON(data []byte) error {
    var str string
    if err := json.Unmarshal(data, &str); err != nil {
        return err
    }
    
    status, err := ParseOrderStatus(str)
    if err != nil {
        return err
    }
    
    *s = status
    return nil
}

// ParseOrderStatus converts string to OrderStatus
func ParseOrderStatus(s string) (OrderStatus, error) {
    switch s {
    case "pending":
        return OrderStatusPending, nil
    case "confirmed":
        return OrderStatusConfirmed, nil
    case "processing":
        return OrderStatusProcessing, nil
    case "shipped":
        return OrderStatusShipped, nil
    case "delivered":
        return OrderStatusDelivered, nil
    case "cancelled":
        return OrderStatusCancelled, nil
    case "refunded":
        return OrderStatusRefunded, nil
    default:
        return 0, fmt.Errorf("invalid order status: %s", s)
    }
}

// IsValid checks if the status is valid
func (s OrderStatus) IsValid() bool {
    return s >= OrderStatusPending && s <= OrderStatusRefunded
}

// CanTransitionTo checks if transition to another status is allowed
func (s OrderStatus) CanTransitionTo(target OrderStatus) bool {
    validTransitions := map[OrderStatus][]OrderStatus{
        OrderStatusPending:    {OrderStatusConfirmed, OrderStatusCancelled},
        OrderStatusConfirmed:  {OrderStatusProcessing, OrderStatusCancelled},
        OrderStatusProcessing: {OrderStatusShipped, OrderStatusCancelled},
        OrderStatusShipped:    {OrderStatusDelivered},
        OrderStatusDelivered:  {OrderStatusRefunded},
        OrderStatusCancelled:  {}, // Final state
        OrderStatusRefunded:   {}, // Final state
    }
    
    allowedTargets, exists := validTransitions[s]
    if !exists {
        return false
    }
    
    for _, allowed := range allowedTargets {
        if allowed == target {
            return true
        }
    }
    
    return false
}

// AllOrderStatuses returns all valid order statuses
func AllOrderStatuses() []OrderStatus {
    return []OrderStatus{
        OrderStatusPending,
        OrderStatusConfirmed,
        OrderStatusProcessing,
        OrderStatusShipped,
        OrderStatusDelivered,
        OrderStatusCancelled,
        OrderStatusRefunded,
    }
}
```

### 3. Configuration Constants with Constructors

```go
package config

import (
    "time"
)

// Campaign configuration
type CampaignConfig struct {
    StartDate  time.Time
    EndDate    time.Time
    MaxUsers   int
    DiscountPct float64
}

// BlackFridayCampaign returns configuration for Black Friday campaign
func BlackFridayCampaign() CampaignConfig {
    return CampaignConfig{
        StartDate:   time.Date(2024, time.November, 29, 0, 0, 0, 0, time.UTC),
        EndDate:     time.Date(2024, time.December, 2, 23, 59, 59, 0, time.UTC),
        MaxUsers:    10000,
        DiscountPct: 25.0,
    }
}

// IsActive checks if the campaign is currently active
func (c CampaignConfig) IsActive(now time.Time) bool {
    return now.After(c.StartDate) && now.Before(c.EndDate)
}

// DaysUntilStart returns days until campaign starts
func (c CampaignConfig) DaysUntilStart(now time.Time) int {
    if now.After(c.StartDate) {
        return 0
    }
    return int(c.StartDate.Sub(now).Hours() / 24)
}

// DaysRemaining returns days remaining in campaign
func (c CampaignConfig) DaysRemaining(now time.Time) int {
    if now.After(c.EndDate) {
        return 0
    }
    if now.Before(c.StartDate) {
        return int(c.EndDate.Sub(c.StartDate).Hours() / 24)
    }
    return int(c.EndDate.Sub(now).Hours() / 24)
}

// Database configuration constants
type DatabaseConfig struct {
    MaxOpenConns    int
    MaxIdleConns    int
    ConnMaxLifetime time.Duration
    ConnMaxIdleTime time.Duration
}

// ProductionDBConfig returns production database configuration
func ProductionDBConfig() DatabaseConfig {
    return DatabaseConfig{
        MaxOpenConns:    25,
        MaxIdleConns:    5,
        ConnMaxLifetime: 5 * time.Minute,
        ConnMaxIdleTime: 5 * time.Minute,
    }
}

// DevelopmentDBConfig returns development database configuration
func DevelopmentDBConfig() DatabaseConfig {
    return DatabaseConfig{
        MaxOpenConns:    10,
        MaxIdleConns:    2,
        ConnMaxLifetime: 1 * time.Minute,
        ConnMaxIdleTime: 1 * time.Minute,
    }
}

// TestDBConfig returns test database configuration
func TestDBConfig() DatabaseConfig {
    return DatabaseConfig{
        MaxOpenConns:    5,
        MaxIdleConns:    1,
        ConnMaxLifetime: 30 * time.Second,
        ConnMaxIdleTime: 30 * time.Second,
    }
}
```

### 4. API and Error Constants

```go
package api

// API Version constants
const (
    APIVersionV1 = "v1"
    APIVersionV2 = "v2"
    APIVersionV3 = "v3"
)

// Header constants
const (
    HeaderContentType   = "Content-Type"
    HeaderAuthorization = "Authorization"
    HeaderUserAgent     = "User-Agent"
    HeaderRequestID     = "X-Request-ID"
    HeaderAPIVersion    = "X-API-Version"
)

// Content type constants
const (
    ContentTypeJSON = "application/json"
    ContentTypeXML  = "application/xml"
    ContentTypeForm = "application/x-www-form-urlencoded"
)

// Rate limiting constants
const (
    RateLimitHeaderLimit     = "X-RateLimit-Limit"
    RateLimitHeaderRemaining = "X-RateLimit-Remaining"
    RateLimitHeaderReset     = "X-RateLimit-Reset"
)

// Default limits
const (
    DefaultRateLimit = 1000  // requests per hour
    DefaultPageSize  = 20    // items per page
    MaxPageSize      = 100   // maximum items per page
)

// Timeout constants
const (
    DefaultRequestTimeout = 30 * time.Second
    DefaultReadTimeout    = 15 * time.Second
    DefaultWriteTimeout   = 15 * time.Second
)

package errors

// Error codes as typed constants
type ErrorCode string

const (
    ErrorCodeValidation    ErrorCode = "VALIDATION_ERROR"
    ErrorCodeNotFound      ErrorCode = "NOT_FOUND"
    ErrorCodeUnauthorized  ErrorCode = "UNAUTHORIZED"
    ErrorCodeForbidden     ErrorCode = "FORBIDDEN"
    ErrorCodeConflict      ErrorCode = "CONFLICT"
    ErrorCodeRateLimit     ErrorCode = "RATE_LIMIT"
    ErrorCodeInternalError ErrorCode = "INTERNAL_ERROR"
)

// String implements the Stringer interface
func (e ErrorCode) String() string {
    return string(e)
}

// HTTPStatus returns the appropriate HTTP status code
func (e ErrorCode) HTTPStatus() int {
    switch e {
    case ErrorCodeValidation:
        return 400
    case ErrorCodeNotFound:
        return 404
    case ErrorCodeUnauthorized:
        return 401
    case ErrorCodeForbidden:
        return 403
    case ErrorCodeConflict:
        return 409
    case ErrorCodeRateLimit:
        return 429
    case ErrorCodeInternalError:
        return 500
    default:
        return 500
    }
}

// IsClientError returns true if this is a client error (4xx)
func (e ErrorCode) IsClientError() bool {
    status := e.HTTPStatus()
    return status >= 400 && status < 500
}

// IsServerError returns true if this is a server error (5xx)
func (e ErrorCode) IsServerError() bool {
    status := e.HTTPStatus()
    return status >= 500
}
```

### 5. Business Domain Constants

```go
package payment

import (
    "fmt"
    "strings"
)

// PaymentMethod represents supported payment methods
type PaymentMethod string

const (
    PaymentMethodCreditCard PaymentMethod = "credit_card"
    PaymentMethodDebitCard  PaymentMethod = "debit_card"
    PaymentMethodPayPal     PaymentMethod = "paypal"
    PaymentMethodBankTransfer PaymentMethod = "bank_transfer"
    PaymentMethodCrypto     PaymentMethod = "crypto"
    PaymentMethodApplePay   PaymentMethod = "apple_pay"
    PaymentMethodGooglePay  PaymentMethod = "google_pay"
)

// IsValid validates the payment method
func (pm PaymentMethod) IsValid() bool {
    switch pm {
    case PaymentMethodCreditCard, PaymentMethodDebitCard, PaymentMethodPayPal,
         PaymentMethodBankTransfer, PaymentMethodCrypto, PaymentMethodApplePay,
         PaymentMethodGooglePay:
        return true
    default:
        return false
    }
}

// RequiresVerification returns true if payment method requires additional verification
func (pm PaymentMethod) RequiresVerification() bool {
    switch pm {
    case PaymentMethodBankTransfer, PaymentMethodCrypto:
        return true
    default:
        return false
    }
}

// IsInstant returns true if payment is processed instantly
func (pm PaymentMethod) IsInstant() bool {
    switch pm {
    case PaymentMethodCreditCard, PaymentMethodDebitCard, PaymentMethodApplePay, PaymentMethodGooglePay:
        return true
    default:
        return false
    }
}

// DisplayName returns a user-friendly display name
func (pm PaymentMethod) DisplayName() string {
    switch pm {
    case PaymentMethodCreditCard:
        return "Credit Card"
    case PaymentMethodDebitCard:
        return "Debit Card"
    case PaymentMethodPayPal:
        return "PayPal"
    case PaymentMethodBankTransfer:
        return "Bank Transfer"
    case PaymentMethodCrypto:
        return "Cryptocurrency"
    case PaymentMethodApplePay:
        return "Apple Pay"
    case PaymentMethodGooglePay:
        return "Google Pay"
    default:
        return "Unknown"
    }
}

// ParsePaymentMethod converts string to PaymentMethod
func ParsePaymentMethod(s string) (PaymentMethod, error) {
    method := PaymentMethod(strings.ToLower(s))
    if !method.IsValid() {
        return "", fmt.Errorf("invalid payment method: %s", s)
    }
    return method, nil
}

// Currency represents supported currencies
type Currency string

const (
    CurrencyUSD Currency = "USD"
    CurrencyEUR Currency = "EUR"
    CurrencyGBP Currency = "GBP"
    CurrencyJPY Currency = "JPY"
    CurrencyCAD Currency = "CAD"
    CurrencyAUD Currency = "AUD"
)

// Symbol returns the currency symbol
func (c Currency) Symbol() string {
    switch c {
    case CurrencyUSD, CurrencyCAD, CurrencyAUD:
        return "$"
    case CurrencyEUR:
        return "€"
    case CurrencyGBP:
        return "£"
    case CurrencyJPY:
        return "¥"
    default:
        return string(c)
    }
}

// DecimalPlaces returns the number of decimal places for the currency
func (c Currency) DecimalPlaces() int {
    switch c {
    case CurrencyJPY:
        return 0
    default:
        return 2
    }
}

// IsValid validates the currency
func (c Currency) IsValid() bool {
    switch c {
    case CurrencyUSD, CurrencyEUR, CurrencyGBP, CurrencyJPY, CurrencyCAD, CurrencyAUD:
        return true
    default:
        return false
    }
}
```

### 6. Feature Flags and Environment Constants

```go
package feature

// FeatureFlag represents a feature flag
type FeatureFlag string

const (
    FeatureFlagNewCheckout     FeatureFlag = "new_checkout"
    FeatureFlagBetaFeatures    FeatureFlag = "beta_features"
    FeatureFlagAdvancedSearch  FeatureFlag = "advanced_search"
    FeatureFlagMLRecommendations FeatureFlag = "ml_recommendations"
    FeatureFlagDarkMode        FeatureFlag = "dark_mode"
)

// DefaultState returns the default state for the feature flag
func (f FeatureFlag) DefaultState() bool {
    switch f {
    case FeatureFlagDarkMode:
        return true // Dark mode enabled by default
    default:
        return false
    }
}

// IsValid validates the feature flag
func (f FeatureFlag) IsValid() bool {
    switch f {
    case FeatureFlagNewCheckout, FeatureFlagBetaFeatures, FeatureFlagAdvancedSearch,
         FeatureFlagMLRecommendations, FeatureFlagDarkMode:
        return true
    default:
        return false
    }
}

// Environment represents deployment environments
type Environment string

const (
    EnvironmentDevelopment Environment = "development"
    EnvironmentStaging     Environment = "staging"
    EnvironmentProduction  Environment = "production"
    EnvironmentTest        Environment = "test"
)

// IsProduction returns true if this is production environment
func (e Environment) IsProduction() bool {
    return e == EnvironmentProduction
}

// IsDevelopment returns true if this is development environment
func (e Environment) IsDevelopment() bool {
    return e == EnvironmentDevelopment
}

// AllowsDebugFeatures returns true if debug features are allowed
func (e Environment) AllowsDebugFeatures() bool {
    return e == EnvironmentDevelopment || e == EnvironmentTest
}

// RequiresSecureConfig returns true if secure configuration is required
func (e Environment) RequiresSecureConfig() bool {
    return e == EnvironmentProduction || e == EnvironmentStaging
}
```

### 7. Validation and Limits

```go
package limits

import (
    "time"
)

// User limits
const (
    MaxUsernameLength = 50
    MinUsernameLength = 3
    MaxEmailLength    = 255
    MinPasswordLength = 8
    MaxPasswordLength = 128
    MaxProfilePicSize = 5 * 1024 * 1024 // 5MB
)

// Content limits
const (
    MaxPostLength     = 280
    MaxCommentLength  = 500
    MaxHashtags       = 10
    MaxMentions       = 20
    MaxFileUploadSize = 100 * 1024 * 1024 // 100MB
)

// API limits
const (
    MaxRequestsPerMinute = 60
    MaxRequestsPerHour   = 1000
    MaxRequestsPerDay    = 10000
    MaxConcurrentRequests = 10
)

// Time limits
const (
    SessionTimeout      = 24 * time.Hour
    TokenExpiry         = 1 * time.Hour
    RefreshTokenExpiry  = 30 * 24 * time.Hour
    PasswordResetExpiry = 1 * time.Hour
    EmailVerifyExpiry   = 24 * time.Hour
)

// Validation functions
func IsValidUsernameLength(username string) bool {
    length := len(username)
    return length >= MinUsernameLength && length <= MaxUsernameLength
}

func IsValidEmailLength(email string) bool {
    return len(email) <= MaxEmailLength
}

func IsValidPasswordLength(password string) bool {
    length := len(password)
    return length >= MinPasswordLength && length <= MaxPasswordLength
}

func IsValidPostLength(content string) bool {
    return len(content) <= MaxPostLength
}

func IsValidFileSize(size int64, maxSize int64) bool {
    return size <= maxSize
}
```

### 8. Testing Constants

```go
package testdata

import (
    "time"
)

// Test user data
const (
    TestUserEmail    = "test@example.com"
    TestUserName     = "Test User"
    TestUserPassword = "testpassword123"
    TestUserID       = "test-user-id"
)

// Test timestamps
var (
    TestTimeNow     = time.Date(2024, 1, 15, 12, 0, 0, 0, time.UTC)
    TestTimePast    = TestTimeNow.Add(-24 * time.Hour)
    TestTimeFuture  = TestTimeNow.Add(24 * time.Hour)
)

// Test configurations
func TestDatabaseConfig() DatabaseConfig {
    return DatabaseConfig{
        MaxOpenConns:    2,
        MaxIdleConns:    1,
        ConnMaxLifetime: 10 * time.Second,
        ConnMaxIdleTime: 5 * time.Second,
    }
}

// Test campaign that's always active
func TestActiveCampaign() CampaignConfig {
    return CampaignConfig{
        StartDate:   TestTimePast,
        EndDate:     TestTimeFuture,
        MaxUsers:    100,
        DiscountPct: 10.0,
    }
}

// Test campaign that's expired
func TestExpiredCampaign() CampaignConfig {
    return CampaignConfig{
        StartDate:   TestTimePast.Add(-48 * time.Hour),
        EndDate:     TestTimePast,
        MaxUsers:    100,
        DiscountPct: 15.0,
    }
}
```

### 9. Usage Examples

```go
package main

import (
    "fmt"
    "log"
    "time"
    
    "myapp/config"
    "myapp/order"
    "myapp/payment"
)

func main() {
    // Using configuration constructors
    campaign := config.BlackFridayCampaign()
    now := time.Now()
    
    if campaign.IsActive(now) {
        fmt.Printf("Black Friday sale is active! %v%% off\n", campaign.DiscountPct)
    } else {
        days := campaign.DaysUntilStart(now)
        if days > 0 {
            fmt.Printf("Black Friday sale starts in %d days\n", days)
        }
    }
    
    // Using typed enumerations
    status := order.OrderStatusPending
    fmt.Printf("Order status: %s\n", status.String())
    
    if status.CanTransitionTo(order.OrderStatusConfirmed) {
        fmt.Println("Order can be confirmed")
    }
    
    // Using payment methods
    method, err := payment.ParsePaymentMethod("credit_card")
    if err != nil {
        log.Fatal(err)
    }
    
    fmt.Printf("Payment method: %s\n", method.DisplayName())
    fmt.Printf("Is instant: %v\n", method.IsInstant())
    fmt.Printf("Requires verification: %v\n", method.RequiresVerification())
    
    // Currency handling
    currency := payment.CurrencyUSD
    fmt.Printf("Currency: %s %s\n", currency, currency.Symbol())
    fmt.Printf("Decimal places: %d\n", currency.DecimalPlaces())
}

// Business logic using constants
func ProcessOrder(orderStatus order.OrderStatus, paymentMethod payment.PaymentMethod) error {
    // Validate order status
    if !orderStatus.IsValid() {
        return fmt.Errorf("invalid order status")
    }
    
    // Check if order can be processed
    if orderStatus != order.OrderStatusConfirmed {
        return fmt.Errorf("order must be confirmed before processing")
    }
    
    // Validate payment method
    if !paymentMethod.IsValid() {
        return fmt.Errorf("invalid payment method")
    }
    
    // Check if additional verification is needed
    if paymentMethod.RequiresVerification() {
        fmt.Println("Additional verification required")
        // Handle verification logic
    }
    
    // Process the order
    fmt.Printf("Processing order with %s payment\n", paymentMethod.DisplayName())
    return nil
}
```

## Anti-patterns to Avoid

### 1. Magic Numbers and Strings

```go
// Bad: Magic numbers and strings
func ProcessPayment(amount float64, method string) error {
    if amount > 10000.0 { // What does 10000 represent?
        return errors.New("amount too large")
    }
    
    if method == "cc" || method == "dc" { // Unclear abbreviations
        // Process card payment
    }
    
    time.Sleep(30 * time.Second) // Why 30 seconds?
    return nil
}

// Good: Named constants
const (
    MaxPaymentAmount = 10000.0
    CardProcessingTimeout = 30 * time.Second
)

func ProcessPayment(amount float64, method PaymentMethod) error {
    if amount > MaxPaymentAmount {
        return errors.New("amount exceeds maximum allowed")
    }
    
    if method == PaymentMethodCreditCard || method == PaymentMethodDebitCard {
        // Process card payment
    }
    
    time.Sleep(CardProcessingTimeout)
    return nil
}
```

### 2. Untyped String Constants

```go
// Bad: Untyped string constants
const (
    StatusActive = "active"
    StatusInactive = "inactive"
)

func UpdateUserStatus(userID string, status string) error {
    // No type safety - any string can be passed
    if status != StatusActive && status != StatusInactive {
        return errors.New("invalid status")
    }
    // ... implementation
}

// Good: Typed constants
type UserStatus string

const (
    UserStatusActive   UserStatus = "active"
    UserStatusInactive UserStatus = "inactive"
)

func (s UserStatus) IsValid() bool {
    return s == UserStatusActive || s == UserStatusInactive
}

func UpdateUserStatus(userID string, status UserStatus) error {
    // Type safety enforced at compile time
    if !status.IsValid() {
        return errors.New("invalid status")
    }
    // ... implementation
}
```

### 3. Generic Constants Files

```go
// Bad: Generic constants file
// constants.go
const (
    MaxUsers = 1000
    MaxRetries = 3
    DefaultTimeout = 30
    StatusOK = 200
    StatusNotFound = 404
    EmailSuffix = "@company.com"
    CachePrefix = "user:"
)

// Good: Domain-organized constants
// user/limits.go
const MaxUsers = 1000

// retry/config.go 
const MaxRetries = 3

// http/status.go
const (
    StatusOK = 200
    StatusNotFound = 404
)

// email/config.go
const CompanyEmailSuffix = "@company.com"

// cache/keys.go
const UserCachePrefix = "user:"
```

## Decision

1. **Organize constants by domain** rather than in generic files
2. **Use typed constants** for enumerations and business values
3. **Provide validation methods** for enumeration types
4. **Implement constructor functions** for complex configurations
5. **Include JSON marshaling/unmarshaling** for API types
6. **Add business logic methods** to typed constants
7. **Use iota for integer enumerations** when order matters
8. **Avoid uppercase constants** except for exported constants

## Consequences

### Positive
- **Type safety**: Compile-time validation of enumeration values
- **Better organization**: Domain-specific constant organization
- **Enhanced readability**: Clear business intent and meaning
- **Easier maintenance**: Centralized configuration management
- **Improved testing**: Reusable test constants and configurations

### Negative
- **More verbose**: Additional type definitions and methods
- **Learning curve**: Team needs to understand typing patterns
- **Potential over-engineering**: Simple values might become complex

### Trade-offs
- **Type safety vs Simplicity**: More complex types but better validation
- **Code organization vs Convenience**: More files but better structure
- **Compile-time safety vs Runtime flexibility**: Stricter types but less dynamic behavior
