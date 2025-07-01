# Feature-Driven Architecture

## Status

`accepted`

## Context

One of the main issues when working on large legacy projects is architectural complexity that hinders development velocity and code comprehension:

- **Too many layers**: Logic is scattered across multiple abstraction layers (controllers, services, repositories, models)
- **Distributed logic**: Business logic is fragmented across different layers and files
- **Cognitive overhead**: Too many file jumps required to understand a complete feature workflow
- **Debugging complexity**: Tracing execution paths requires navigating multiple files and layers

Feature-Driven Architecture (FDA) addresses these issues by co-locating all logic related to a specific feature in a single, cohesive unit. This approach prioritizes feature completeness over layer separation.

## Decision

Adopt Feature-Driven Architecture where each feature encapsulates all necessary logic in a self-contained module, reducing cognitive load and improving development velocity.

### Core Principles

1. **Feature Completeness**: All code needed for a feature lives in one place
2. **Minimal File Jumping**: Developers can understand and modify features without extensive navigation
3. **Self-Contained Logic**: Features have minimal dependencies on other features
4. **Vertical Slicing**: Features are sliced vertically through all application layers

### Directory Structure

Organize code by features rather than technical layers:

```
domain/
├── user/
│   ├── types.go              # Domain types and interfaces
│   ├── errors.go             # Feature-specific errors
│   └── usecase/
│       ├── register.go       # Complete registration feature
│       ├── login.go          # Complete authentication feature
│       ├── profile.go        # Complete profile management
│       └── password_reset.go # Complete password reset flow
├── order/
│   ├── types.go
│   ├── errors.go
│   └── usecase/
│       ├── create.go         # Complete order creation
│       ├── fulfill.go        # Complete order fulfillment
│       ├── cancel.go         # Complete order cancellation
│       └── refund.go         # Complete refund process
└── payment/
    ├── types.go
    ├── errors.go
    └── usecase/
        ├── process.go        # Complete payment processing
        ├── webhook.go        # Complete webhook handling
        └── reconcile.go      # Complete payment reconciliation
```

### Feature Implementation

Each feature file contains all necessary components:

```go
// domain/user/usecase/register.go
package usecase

import (
    "context"
    "database/sql"
    "fmt"
    "time"
    
    "golang.org/x/crypto/bcrypt"
)

// Domain types specific to registration
type RegisterRequest struct {
    Email     string `json:"email" validate:"required,email"`
    Password  string `json:"password" validate:"required,min=8"`
    FirstName string `json:"first_name" validate:"required"`
    LastName  string `json:"last_name" validate:"required"`
}

type RegisterResponse struct {
    UserID    string    `json:"user_id"`
    Email     string    `json:"email"`
    CreatedAt time.Time `json:"created_at"`
    Token     string    `json:"token"`
}

// Feature-specific errors
var (
    ErrEmailAlreadyExists = fmt.Errorf("email already registered")
    ErrWeakPassword      = fmt.Errorf("password does not meet requirements")
    ErrInvalidEmail      = fmt.Errorf("invalid email format")
)

// Complete registration feature
type RegisterUseCase struct {
    db          *sql.DB
    emailSender EmailSender
    tokenGen    TokenGenerator
    validator   Validator
    logger      Logger
}

func NewRegisterUseCase(
    db *sql.DB,
    emailSender EmailSender,
    tokenGen TokenGenerator,
    validator Validator,
    logger Logger,
) *RegisterUseCase {
    return &RegisterUseCase{
        db:          db,
        emailSender: emailSender,
        tokenGen:    tokenGen,
        validator:   validator,
        logger:      logger,
    }
}

func (uc *RegisterUseCase) Execute(ctx context.Context, req RegisterRequest) (*RegisterResponse, error) {
    // Input validation
    if err := uc.validator.Validate(req); err != nil {
        return nil, fmt.Errorf("validation failed: %w", err)
    }
    
    // Business logic validation
    if err := uc.validatePasswordStrength(req.Password); err != nil {
        return nil, err
    }
    
    // Start database transaction
    tx, err := uc.db.BeginTx(ctx, nil)
    if err != nil {
        return nil, fmt.Errorf("failed to start transaction: %w", err)
    }
    defer tx.Rollback()
    
    // Check if email already exists
    exists, err := uc.emailExists(ctx, tx, req.Email)
    if err != nil {
        return nil, fmt.Errorf("failed to check email existence: %w", err)
    }
    if exists {
        return nil, ErrEmailAlreadyExists
    }
    
    // Hash password
    hashedPassword, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
    if err != nil {
        return nil, fmt.Errorf("failed to hash password: %w", err)
    }
    
    // Create user record
    userID := generateUUID()
    user := &User{
        ID:           userID,
        Email:        req.Email,
        PasswordHash: string(hashedPassword),
        FirstName:    req.FirstName,
        LastName:     req.LastName,
        CreatedAt:    time.Now(),
        Status:       "pending_verification",
    }
    
    if err := uc.insertUser(ctx, tx, user); err != nil {
        return nil, fmt.Errorf("failed to create user: %w", err)
    }
    
    // Create verification token
    token, err := uc.tokenGen.GenerateVerificationToken(userID)
    if err != nil {
        return nil, fmt.Errorf("failed to generate token: %w", err)
    }
    
    if err := uc.insertVerificationToken(ctx, tx, userID, token); err != nil {
        return nil, fmt.Errorf("failed to store verification token: %w", err)
    }
    
    // Commit transaction
    if err := tx.Commit(); err != nil {
        return nil, fmt.Errorf("failed to commit transaction: %w", err)
    }
    
    // Send verification email (async, non-blocking)
    go func() {
        if err := uc.sendVerificationEmail(user.Email, token); err != nil {
            uc.logger.Error("failed to send verification email", 
                "user_id", userID, 
                "email", user.Email, 
                "error", err)
        }
    }()
    
    // Generate auth token for immediate login
    authToken, err := uc.tokenGen.GenerateAuthToken(userID)
    if err != nil {
        return nil, fmt.Errorf("failed to generate auth token: %w", err)
    }
    
    uc.logger.Info("user registered successfully", 
        "user_id", userID, 
        "email", user.Email)
    
    return &RegisterResponse{
        UserID:    userID,
        Email:     user.Email,
        CreatedAt: user.CreatedAt,
        Token:     authToken,
    }, nil
}

// Helper methods - all contained within the same feature file
func (uc *RegisterUseCase) validatePasswordStrength(password string) error {
    if len(password) < 8 {
        return ErrWeakPassword
    }
    
    hasUpper := false
    hasLower := false
    hasDigit := false
    hasSpecial := false
    
    for _, char := range password {
        switch {
        case 'A' <= char && char <= 'Z':
            hasUpper = true
        case 'a' <= char && char <= 'z':
            hasLower = true
        case '0' <= char && char <= '9':
            hasDigit = true
        default:
            hasSpecial = true
        }
    }
    
    if !hasUpper || !hasLower || !hasDigit || !hasSpecial {
        return ErrWeakPassword
    }
    
    return nil
}

func (uc *RegisterUseCase) emailExists(ctx context.Context, tx *sql.Tx, email string) (bool, error) {
    var count int
    query := `SELECT COUNT(*) FROM users WHERE email = $1`
    err := tx.QueryRowContext(ctx, query, email).Scan(&count)
    return count > 0, err
}

func (uc *RegisterUseCase) insertUser(ctx context.Context, tx *sql.Tx, user *User) error {
    query := `
        INSERT INTO users (id, email, password_hash, first_name, last_name, created_at, status)
        VALUES ($1, $2, $3, $4, $5, $6, $7)`
    
    _, err := tx.ExecContext(ctx, query,
        user.ID, user.Email, user.PasswordHash,
        user.FirstName, user.LastName, user.CreatedAt, user.Status)
    
    return err
}

func (uc *RegisterUseCase) insertVerificationToken(ctx context.Context, tx *sql.Tx, userID, token string) error {
    query := `
        INSERT INTO verification_tokens (user_id, token, expires_at, created_at)
        VALUES ($1, $2, $3, $4)`
    
    expiresAt := time.Now().Add(24 * time.Hour)
    _, err := tx.ExecContext(ctx, query, userID, token, expiresAt, time.Now())
    
    return err
}

func (uc *RegisterUseCase) sendVerificationEmail(email, token string) error {
    verificationURL := fmt.Sprintf("https://app.example.com/verify?token=%s", token)
    
    emailContent := EmailContent{
        To:      email,
        Subject: "Verify your account",
        Template: "verification",
        Data: map[string]interface{}{
            "verification_url": verificationURL,
        },
    }
    
    return uc.emailSender.Send(emailContent)
}
```

### HTTP Transport Integration

Transport layer delegates directly to features:

```go
// transport/http/user.go
package http

type UserHandler struct {
    registerUC *usecase.RegisterUseCase
    loginUC    *usecase.LoginUseCase
    profileUC  *usecase.ProfileUseCase
}

func (h *UserHandler) Register(w http.ResponseWriter, r *http.Request) {
    var req usecase.RegisterRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "invalid request body", http.StatusBadRequest)
        return
    }
    
    resp, err := h.registerUC.Execute(r.Context(), req)
    if err != nil {
        h.handleError(w, err)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusCreated)
    json.NewEncoder(w).Encode(resp)
}

func (h *UserHandler) handleError(w http.ResponseWriter, err error) {
    switch {
    case errors.Is(err, usecase.ErrEmailAlreadyExists):
        http.Error(w, "email already registered", http.StatusConflict)
    case errors.Is(err, usecase.ErrWeakPassword):
        http.Error(w, "password does not meet requirements", http.StatusBadRequest)
    default:
        http.Error(w, "internal server error", http.StatusInternalServerError)
    }
}
```

### Testing Strategy

Test complete features in isolation:

```go
// domain/user/usecase/register_test.go
func TestRegisterUseCase_Execute(t *testing.T) {
    tests := []struct {
        name        string
        request     RegisterRequest
        setupMocks  func(*mocks.MockDB, *mocks.MockEmailSender, *mocks.MockTokenGen)
        expectedErr error
    }{
        {
            name: "successful registration",
            request: RegisterRequest{
                Email:     "test@example.com",
                Password:  "StrongPass123!",
                FirstName: "John",
                LastName:  "Doe",
            },
            setupMocks: func(db *mocks.MockDB, email *mocks.MockEmailSender, token *mocks.MockTokenGen) {
                db.On("BeginTx", mock.Anything, mock.Anything).Return(&sql.Tx{}, nil)
                db.On("QueryRowContext", mock.Anything, mock.Anything, mock.Anything).Return(&sql.Row{})
                db.On("ExecContext", mock.Anything, mock.Anything, mock.Anything).Return(sql.Result{}, nil)
                token.On("GenerateVerificationToken", mock.Anything).Return("token123", nil)
                token.On("GenerateAuthToken", mock.Anything).Return("auth_token", nil)
                email.On("Send", mock.Anything).Return(nil)
            },
            expectedErr: nil,
        },
        {
            name: "email already exists",
            request: RegisterRequest{
                Email:     "existing@example.com",
                Password:  "StrongPass123!",
                FirstName: "Jane",
                LastName:  "Doe",
            },
            setupMocks: func(db *mocks.MockDB, email *mocks.MockEmailSender, token *mocks.MockTokenGen) {
                db.On("BeginTx", mock.Anything, mock.Anything).Return(&sql.Tx{}, nil)
                // Mock existing email
                db.On("QueryRowContext", mock.Anything, mock.Anything, "existing@example.com").
                    Return(mockRow(1)) // Count = 1, email exists
            },
            expectedErr: ErrEmailAlreadyExists,
        },
    }
    
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // Setup
            mockDB := &mocks.MockDB{}
            mockEmail := &mocks.MockEmailSender{}
            mockToken := &mocks.MockTokenGen{}
            mockValidator := &mocks.MockValidator{}
            mockLogger := &mocks.MockLogger{}
            
            tt.setupMocks(mockDB, mockEmail, mockToken)
            
            uc := NewRegisterUseCase(mockDB, mockEmail, mockToken, mockValidator, mockLogger)
            
            // Execute
            resp, err := uc.Execute(context.Background(), tt.request)
            
            // Assert
            if tt.expectedErr != nil {
                assert.Error(t, err)
                assert.True(t, errors.Is(err, tt.expectedErr))
                assert.Nil(t, resp)
            } else {
                assert.NoError(t, err)
                assert.NotNil(t, resp)
                assert.Equal(t, tt.request.Email, resp.Email)
            }
            
            mockDB.AssertExpectations(t)
            mockEmail.AssertExpectations(t)
            mockToken.AssertExpectations(t)
        })
    }
}
```

### Cross-Feature Communication

Features communicate through well-defined interfaces and events:

```go
// domain/order/usecase/create.go
type CreateOrderUseCase struct {
    db          *sql.DB
    userService UserService // Interface to user domain
    eventBus    EventBus
}

func (uc *CreateOrderUseCase) Execute(ctx context.Context, req CreateOrderRequest) (*CreateOrderResponse, error) {
    // Validate user exists (cross-domain call)
    user, err := uc.userService.GetByID(ctx, req.UserID)
    if err != nil {
        return nil, fmt.Errorf("invalid user: %w", err)
    }
    
    // Create order logic...
    order := &Order{
        ID:     generateUUID(),
        UserID: user.ID,
        // ... other fields
    }
    
    if err := uc.insertOrder(ctx, order); err != nil {
        return nil, err
    }
    
    // Publish domain event
    event := OrderCreatedEvent{
        OrderID:   order.ID,
        UserID:    order.UserID,
        Amount:    order.TotalAmount,
        CreatedAt: order.CreatedAt,
    }
    
    uc.eventBus.Publish(event)
    
    return &CreateOrderResponse{Order: order}, nil
}
```

## Consequences

### Positive

- **Reduced Cognitive Load**: Complete feature understanding in one file
- **Faster Development**: Less time spent navigating between files
- **Easier Debugging**: Single location for feature-related issues
- **Independent Testing**: Features can be tested in isolation
- **Clear Ownership**: Each feature has a clear responsible developer/team
- **Simpler Onboarding**: New developers can understand features quickly

### Negative

- **Code Duplication**: Some logic may be duplicated across features
- **Large Files**: Feature files can become substantial as complexity grows
- **Harder Refactoring**: Cross-cutting concerns require touching multiple features
- **Less Reusability**: Shared logic is harder to extract and reuse

### Trade-offs

- **Coupling vs Cohesion**: Prioritizes feature cohesion over layer separation
- **DRY vs Locality**: Accepts some duplication for improved code locality
- **Flexibility vs Simplicity**: Less flexible but significantly simpler mental model

## Anti-patterns

- **Feature Sprawl**: Single features that handle too many responsibilities
- **Hidden Dependencies**: Features with undeclared dependencies on other features
- **Shared State**: Features modifying shared global state without coordination
- **Leaky Abstractions**: Feature internals exposed to transport or other layers
- **God Features**: Single features that become too large and complex
