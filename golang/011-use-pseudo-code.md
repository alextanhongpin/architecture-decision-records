# Use Pseudo Code for Business Logic

## Status

`accepted`

## Context

When writing application service layers (use case layer), the main business logic should be expressed as clear, step-by-step pseudo code before diving into implementation details. This approach improves code readability, maintainability, and enables better business logic understanding.

## Problem

Many developers write use case methods that immediately dive into implementation details, making it difficult to:
- **Understand business workflow** at a glance
- **Identify missing steps** in the business process
- **Review business logic** separately from technical implementation
- **Maintain and modify** complex business workflows
- **Test business logic** independently from infrastructure concerns
- **Communicate with stakeholders** about business processes

## Solution

Structure use case methods with a clear pseudo code approach:
1. **Main method** contains step-by-step business logic in pseudo code format
2. **Private helper methods** implement the technical details
3. **Clear separation** between business workflow and implementation
4. **Consistent naming** that reflects business terminology

## Go Pseudo Code Implementation

### Basic Pseudo Code Pattern

```go
package usecase

import (
    "context"
    "fmt"
    "myapp/domain"
)

// UserRegistrationUseCase handles user registration business logic
type UserRegistrationUseCase struct {
    userRepo     domain.UserRepository
    emailService domain.EmailService
    auditService domain.AuditService
    validator    domain.UserValidator
}

// RegisterUser demonstrates pseudo code approach for business logic
func (uc *UserRegistrationUseCase) RegisterUser(ctx context.Context, req RegisterUserRequest) (*domain.User, error) {
    // Step 1: Validate user registration data
    if err := uc.validateRegistrationData(ctx, req); err != nil {
        return nil, err
    }
    
    // Step 2: Check if user already exists
    if err := uc.ensureUserDoesNotExist(ctx, req.Email); err != nil {
        return nil, err
    }
    
    // Step 3: Create user account
    user, err := uc.createUserAccount(ctx, req)
    if err != nil {
        return nil, err
    }
    
    // Step 4: Send welcome email
    if err := uc.sendWelcomeEmail(ctx, user); err != nil {
        // Log error but don't fail registration
        uc.logEmailFailure(ctx, user.ID, err)
    }
    
    // Step 5: Record registration event
    if err := uc.recordRegistrationEvent(ctx, user); err != nil {
        // Log error but don't fail registration
        uc.logAuditFailure(ctx, user.ID, err)
    }
    
    return user, nil
}

// validateRegistrationData implements Step 1
func (uc *UserRegistrationUseCase) validateRegistrationData(ctx context.Context, req RegisterUserRequest) error {
    if req.Email == "" {
        return domain.ErrInvalidEmail
    }
    
    if req.Password == "" || len(req.Password) < 8 {
        return domain.ErrInvalidPassword
    }
    
    return uc.validator.ValidateUser(ctx, domain.User{
        Email: req.Email,
        Name:  req.Name,
    })
}

// ensureUserDoesNotExist implements Step 2
func (uc *UserRegistrationUseCase) ensureUserDoesNotExist(ctx context.Context, email string) error {
    _, err := uc.userRepo.GetByEmail(ctx, email)
    if err == nil {
        return domain.ErrUserAlreadyExists
    }
    
    if err != domain.ErrUserNotFound {
        return fmt.Errorf("failed to check user existence: %w", err)
    }
    
    return nil
}

// createUserAccount implements Step 3
func (uc *UserRegistrationUseCase) createUserAccount(ctx context.Context, req RegisterUserRequest) (*domain.User, error) {
    hashedPassword, err := uc.hashPassword(req.Password)
    if err != nil {
        return nil, fmt.Errorf("failed to hash password: %w", err)
    }
    
    user := &domain.User{
        ID:       uc.generateUserID(),
        Email:    req.Email,
        Name:     req.Name,
        Password: hashedPassword,
        Status:   domain.UserStatusActive,
    }
    
    if err := uc.userRepo.Create(ctx, user); err != nil {
        return nil, fmt.Errorf("failed to create user: %w", err)
    }
    
    return user, nil
}

// sendWelcomeEmail implements Step 4
func (uc *UserRegistrationUseCase) sendWelcomeEmail(ctx context.Context, user *domain.User) error {
    emailData := domain.WelcomeEmailData{
        UserName: user.Name,
        Email:    user.Email,
    }
    
    return uc.emailService.SendWelcomeEmail(ctx, emailData)
}

// recordRegistrationEvent implements Step 5
func (uc *UserRegistrationUseCase) recordRegistrationEvent(ctx context.Context, user *domain.User) error {
    event := domain.AuditEvent{
        Type:   "user_registered",
        UserID: user.ID,
        Data: map[string]interface{}{
            "email": user.Email,
            "name":  user.Name,
        },
    }
    
    return uc.auditService.RecordEvent(ctx, event)
}

// Helper methods for technical implementation details
func (uc *UserRegistrationUseCase) hashPassword(password string) (string, error) {
    // Implementation details...
}

func (uc *UserRegistrationUseCase) generateUserID() string {
    // Implementation details...
}

func (uc *UserRegistrationUseCase) logEmailFailure(ctx context.Context, userID string, err error) {
    // Implementation details...
}

func (uc *UserRegistrationUseCase) logAuditFailure(ctx context.Context, userID string, err error) {
    // Implementation details...
}
```

### Complex Business Process Example

```go
package usecase

// OrderProcessingUseCase demonstrates complex business workflow
type OrderProcessingUseCase struct {
    orderRepo     domain.OrderRepository
    productRepo   domain.ProductRepository
    paymentSvc    domain.PaymentService
    inventorySvc  domain.InventoryService
    shippingSvc   domain.ShippingService
    notificationSvc domain.NotificationService
}

// ProcessOrder orchestrates the complete order processing workflow
func (uc *OrderProcessingUseCase) ProcessOrder(ctx context.Context, req ProcessOrderRequest) (*domain.Order, error) {
    // Step 1: Validate order request
    if err := uc.validateOrderRequest(ctx, req); err != nil {
        return nil, err
    }
    
    // Step 2: Check product availability
    if err := uc.verifyProductAvailability(ctx, req.Items); err != nil {
        return nil, err
    }
    
    // Step 3: Calculate order total
    orderTotal, err := uc.calculateOrderTotal(ctx, req.Items)
    if err != nil {
        return nil, err
    }
    
    // Step 4: Reserve inventory
    reservation, err := uc.reserveInventory(ctx, req.Items)
    if err != nil {
        return nil, err
    }
    defer uc.handleInventoryReservationCleanup(ctx, reservation)
    
    // Step 5: Process payment
    payment, err := uc.processPayment(ctx, req.PaymentMethod, orderTotal)
    if err != nil {
        return nil, err
    }
    
    // Step 6: Create order record
    order, err := uc.createOrderRecord(ctx, req, orderTotal, payment.ID)
    if err != nil {
        // Refund payment if order creation fails
        uc.refundPayment(ctx, payment.ID)
        return nil, err
    }
    
    // Step 7: Confirm inventory reservation
    if err := uc.confirmInventoryReservation(ctx, reservation); err != nil {
        // Handle inventory confirmation failure
        uc.handleInventoryConfirmationFailure(ctx, order, payment.ID)
        return nil, err
    }
    
    // Step 8: Schedule shipping
    if err := uc.scheduleShipping(ctx, order); err != nil {
        // Log error but don't fail order
        uc.logShippingScheduleFailure(ctx, order.ID, err)
    }
    
    // Step 9: Send order confirmation
    if err := uc.sendOrderConfirmation(ctx, order); err != nil {
        // Log error but don't fail order
        uc.logNotificationFailure(ctx, order.ID, err)
    }
    
    return order, nil
}

// validateOrderRequest implements Step 1
func (uc *OrderProcessingUseCase) validateOrderRequest(ctx context.Context, req ProcessOrderRequest) error {
    // Business rules validation
    if len(req.Items) == 0 {
        return domain.ErrEmptyOrder
    }
    
    if req.CustomerID == "" {
        return domain.ErrInvalidCustomer
    }
    
    for _, item := range req.Items {
        if item.Quantity <= 0 {
            return domain.ErrInvalidQuantity
        }
        if item.ProductID == "" {
            return domain.ErrInvalidProduct
        }
    }
    
    return nil
}

// verifyProductAvailability implements Step 2
func (uc *OrderProcessingUseCase) verifyProductAvailability(ctx context.Context, items []OrderItem) error {
    for _, item := range items {
        product, err := uc.productRepo.GetByID(ctx, item.ProductID)
        if err != nil {
            return fmt.Errorf("product %s not found: %w", item.ProductID, err)
        }
        
        if !product.IsAvailable {
            return domain.ErrProductNotAvailable
        }
        
        available, err := uc.inventorySvc.CheckAvailability(ctx, item.ProductID, item.Quantity)
        if err != nil {
            return fmt.Errorf("failed to check inventory: %w", err)
        }
        
        if !available {
            return domain.ErrInsufficientInventory
        }
    }
    
    return nil
}

// calculateOrderTotal implements Step 3
func (uc *OrderProcessingUseCase) calculateOrderTotal(ctx context.Context, items []OrderItem) (domain.Money, error) {
    var total domain.Money
    
    for _, item := range items {
        product, err := uc.productRepo.GetByID(ctx, item.ProductID)
        if err != nil {
            return total, err
        }
        
        itemTotal := product.Price.Multiply(item.Quantity)
        total = total.Add(itemTotal)
    }
    
    // Apply discounts, taxes, shipping costs
    total = uc.applyDiscounts(ctx, total)
    total = uc.calculateTaxes(ctx, total)
    total = uc.addShippingCosts(ctx, total)
    
    return total, nil
}

// reserveInventory implements Step 4
func (uc *OrderProcessingUseCase) reserveInventory(ctx context.Context, items []OrderItem) (*domain.InventoryReservation, error) {
    reservationReq := domain.InventoryReservationRequest{
        Items:     items,
        ExpiresAt: time.Now().Add(15 * time.Minute),
    }
    
    return uc.inventorySvc.Reserve(ctx, reservationReq)
}

// processPayment implements Step 5
func (uc *OrderProcessingUseCase) processPayment(ctx context.Context, paymentMethod domain.PaymentMethod, amount domain.Money) (*domain.Payment, error) {
    paymentReq := domain.PaymentRequest{
        Method: paymentMethod,
        Amount: amount,
    }
    
    return uc.paymentSvc.ProcessPayment(ctx, paymentReq)
}

// createOrderRecord implements Step 6
func (uc *OrderProcessingUseCase) createOrderRecord(ctx context.Context, req ProcessOrderRequest, total domain.Money, paymentID string) (*domain.Order, error) {
    order := &domain.Order{
        ID:         uc.generateOrderID(),
        CustomerID: req.CustomerID,
        Items:      req.Items,
        Total:      total,
        PaymentID:  paymentID,
        Status:     domain.OrderStatusPending,
        CreatedAt:  time.Now(),
    }
    
    if err := uc.orderRepo.Create(ctx, order); err != nil {
        return nil, fmt.Errorf("failed to create order: %w", err)
    }
    
    return order, nil
}

// confirmInventoryReservation implements Step 7
func (uc *OrderProcessingUseCase) confirmInventoryReservation(ctx context.Context, reservation *domain.InventoryReservation) error {
    return uc.inventorySvc.ConfirmReservation(ctx, reservation.ID)
}

// scheduleShipping implements Step 8
func (uc *OrderProcessingUseCase) scheduleShipping(ctx context.Context, order *domain.Order) error {
    shippingReq := domain.ShippingRequest{
        OrderID: order.ID,
        Items:   order.Items,
        Address: order.ShippingAddress,
    }
    
    return uc.shippingSvc.ScheduleShipping(ctx, shippingReq)
}

// sendOrderConfirmation implements Step 9
func (uc *OrderProcessingUseCase) sendOrderConfirmation(ctx context.Context, order *domain.Order) error {
    notification := domain.Notification{
        Type:       "order_confirmation",
        CustomerID: order.CustomerID,
        OrderID:    order.ID,
        Data: map[string]interface{}{
            "order_total": order.Total,
            "items":       order.Items,
        },
    }
    
    return uc.notificationSvc.Send(ctx, notification)
}

// Cleanup and error handling methods
func (uc *OrderProcessingUseCase) handleInventoryReservationCleanup(ctx context.Context, reservation *domain.InventoryReservation) {
    if reservation != nil && reservation.Status == domain.ReservationStatusPending {
        if err := uc.inventorySvc.ReleaseReservation(ctx, reservation.ID); err != nil {
            uc.logInventoryCleanupFailure(ctx, reservation.ID, err)
        }
    }
}

func (uc *OrderProcessingUseCase) refundPayment(ctx context.Context, paymentID string) {
    if err := uc.paymentSvc.RefundPayment(ctx, paymentID); err != nil {
        uc.logRefundFailure(ctx, paymentID, err)
    }
}

func (uc *OrderProcessingUseCase) handleInventoryConfirmationFailure(ctx context.Context, order *domain.Order, paymentID string) {
    // Mark order as failed
    order.Status = domain.OrderStatusFailed
    uc.orderRepo.Update(ctx, order)
    
    // Refund payment
    uc.refundPayment(ctx, paymentID)
}
```

### Conditional Business Logic

```go
package usecase

// LoanApprovalUseCase demonstrates conditional business logic
type LoanApprovalUseCase struct {
    applicantRepo   domain.ApplicantRepository
    creditSvc       domain.CreditCheckService
    riskSvc         domain.RiskAssessmentService
    approvalSvc     domain.ApprovalService
    notificationSvc domain.NotificationService
}

// ProcessLoanApplication handles loan application with conditional logic
func (uc *LoanApprovalUseCase) ProcessLoanApplication(ctx context.Context, req LoanApplicationRequest) (*domain.LoanApplication, error) {
    // Step 1: Validate application data
    if err := uc.validateApplicationData(ctx, req); err != nil {
        return nil, err
    }
    
    // Step 2: Get applicant information
    applicant, err := uc.getApplicantInformation(ctx, req.ApplicantID)
    if err != nil {
        return nil, err
    }
    
    // Step 3: Perform credit check
    creditReport, err := uc.performCreditCheck(ctx, applicant)
    if err != nil {
        return nil, err
    }
    
    // Step 4: Assess risk based on credit report
    riskAssessment, err := uc.assessRisk(ctx, applicant, creditReport, req.LoanAmount)
    if err != nil {
        return nil, err
    }
    
    // Step 5: Make approval decision based on risk
    decision := uc.makeApprovalDecision(ctx, riskAssessment, req.LoanAmount)
    
    // Step 6: Create loan application record
    application, err := uc.createLoanApplication(ctx, req, creditReport, riskAssessment, decision)
    if err != nil {
        return nil, err
    }
    
    // Step 7: Handle decision-specific actions
    if err := uc.handleDecisionActions(ctx, application, decision); err != nil {
        return nil, err
    }
    
    // Step 8: Send notification to applicant
    if err := uc.sendApplicationNotification(ctx, application); err != nil {
        uc.logNotificationFailure(ctx, application.ID, err)
    }
    
    return application, nil
}

// makeApprovalDecision implements Step 5 with business rules
func (uc *LoanApprovalUseCase) makeApprovalDecision(ctx context.Context, risk *domain.RiskAssessment, loanAmount domain.Money) domain.ApprovalDecision {
    // High-level business logic in pseudo code format
    
    // Rule 1: Auto-reject if high risk
    if risk.Level == domain.RiskLevelHigh {
        return domain.ApprovalDecision{
            Status: domain.DecisionStatusRejected,
            Reason: "High risk assessment",
        }
    }
    
    // Rule 2: Auto-approve if low risk and small amount
    if risk.Level == domain.RiskLevelLow && loanAmount.LessThan(domain.NewMoney(10000)) {
        return domain.ApprovalDecision{
            Status: domain.DecisionStatusApproved,
            Reason: "Low risk, small amount",
        }
    }
    
    // Rule 3: Require manual review for medium risk or large amounts
    if risk.Level == domain.RiskLevelMedium || loanAmount.GreaterThanOrEqual(domain.NewMoney(10000)) {
        return domain.ApprovalDecision{
            Status: domain.DecisionStatusPendingReview,
            Reason: "Requires manual review",
        }
    }
    
    // Rule 4: Default approval for low risk
    return domain.ApprovalDecision{
        Status: domain.DecisionStatusApproved,
        Reason: "Standard approval criteria met",
    }
}

// handleDecisionActions implements Step 7 with conditional logic
func (uc *LoanApprovalUseCase) handleDecisionActions(ctx context.Context, application *domain.LoanApplication, decision domain.ApprovalDecision) error {
    switch decision.Status {
    case domain.DecisionStatusApproved:
        return uc.handleApprovedApplication(ctx, application)
        
    case domain.DecisionStatusRejected:
        return uc.handleRejectedApplication(ctx, application)
        
    case domain.DecisionStatusPendingReview:
        return uc.handlePendingReviewApplication(ctx, application)
        
    default:
        return fmt.Errorf("unknown decision status: %s", decision.Status)
    }
}

func (uc *LoanApprovalUseCase) handleApprovedApplication(ctx context.Context, application *domain.LoanApplication) error {
    // Generate loan documents
    if err := uc.generateLoanDocuments(ctx, application); err != nil {
        return err
    }
    
    // Schedule fund disbursement
    return uc.scheduleFundDisbursement(ctx, application)
}

func (uc *LoanApprovalUseCase) handleRejectedApplication(ctx context.Context, application *domain.LoanApplication) error {
    // Generate rejection letter
    return uc.generateRejectionLetter(ctx, application)
}

func (uc *LoanApprovalUseCase) handlePendingReviewApplication(ctx context.Context, application *domain.LoanApplication) error {
    // Assign to underwriter
    return uc.assignToUnderwriter(ctx, application)
}
```

### Testing Pseudo Code Structure

```go
package usecase_test

import (
    "context"
    "testing"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/mock"
    "github.com/stretchr/testify/require"
    "myapp/domain"
    "myapp/usecase"
)

func TestUserRegistrationUseCase_RegisterUser(t *testing.T) {
    // Setup mocks
    userRepo := &MockUserRepository{}
    emailService := &MockEmailService{}
    auditService := &MockAuditService{}
    validator := &MockUserValidator{}
    
    uc := usecase.NewUserRegistrationUseCase(userRepo, emailService, auditService, validator)
    ctx := context.Background()
    
    t.Run("Successful Registration", func(t *testing.T) {
        req := usecase.RegisterUserRequest{
            Email:    "test@example.com",
            Name:     "Test User",
            Password: "validpassword",
        }
        
        // Step 1: Validation should pass
        validator.On("ValidateUser", mock.Anything, mock.Anything).Return(nil)
        
        // Step 2: User should not exist
        userRepo.On("GetByEmail", mock.Anything, req.Email).Return(nil, domain.ErrUserNotFound)
        
        // Step 3: User creation should succeed
        userRepo.On("Create", mock.Anything, mock.AnythingOfType("*domain.User")).Return(nil)
        
        // Step 4: Email sending should succeed
        emailService.On("SendWelcomeEmail", mock.Anything, mock.Anything).Return(nil)
        
        // Step 5: Audit recording should succeed
        auditService.On("RecordEvent", mock.Anything, mock.Anything).Return(nil)
        
        user, err := uc.RegisterUser(ctx, req)
        
        require.NoError(t, err)
        assert.Equal(t, req.Email, user.Email)
        assert.Equal(t, req.Name, user.Name)
        
        // Verify all steps were executed
        validator.AssertExpectations(t)
        userRepo.AssertExpectations(t)
        emailService.AssertExpectations(t)
        auditService.AssertExpectations(t)
    })
    
    t.Run("Validation Failure - Step 1", func(t *testing.T) {
        req := usecase.RegisterUserRequest{
            Email:    "", // Invalid email
            Name:     "Test User",
            Password: "validpassword",
        }
        
        _, err := uc.RegisterUser(ctx, req)
        
        assert.Equal(t, domain.ErrInvalidEmail, err)
        
        // Should not proceed to other steps
        userRepo.AssertNotCalled(t, "GetByEmail")
        userRepo.AssertNotCalled(t, "Create")
    })
    
    t.Run("User Already Exists - Step 2", func(t *testing.T) {
        req := usecase.RegisterUserRequest{
            Email:    "existing@example.com",
            Name:     "Test User",
            Password: "validpassword",
        }
        
        // Step 1: Validation should pass
        validator.On("ValidateUser", mock.Anything, mock.Anything).Return(nil)
        
        // Step 2: User already exists
        existingUser := &domain.User{Email: req.Email}
        userRepo.On("GetByEmail", mock.Anything, req.Email).Return(existingUser, nil)
        
        _, err := uc.RegisterUser(ctx, req)
        
        assert.Equal(t, domain.ErrUserAlreadyExists, err)
        
        // Should not proceed to user creation
        userRepo.AssertNotCalled(t, "Create")
    })
    
    t.Run("Email Failure Does Not Fail Registration - Step 4", func(t *testing.T) {
        req := usecase.RegisterUserRequest{
            Email:    "test@example.com",
            Name:     "Test User",
            Password: "validpassword",
        }
        
        // Steps 1-3 succeed
        validator.On("ValidateUser", mock.Anything, mock.Anything).Return(nil)
        userRepo.On("GetByEmail", mock.Anything, req.Email).Return(nil, domain.ErrUserNotFound)
        userRepo.On("Create", mock.Anything, mock.AnythingOfType("*domain.User")).Return(nil)
        
        // Step 4: Email fails
        emailService.On("SendWelcomeEmail", mock.Anything, mock.Anything).Return(fmt.Errorf("email service error"))
        
        // Step 5: Audit should still proceed
        auditService.On("RecordEvent", mock.Anything, mock.Anything).Return(nil)
        
        user, err := uc.RegisterUser(ctx, req)
        
        // Registration should still succeed despite email failure
        require.NoError(t, err)
        assert.Equal(t, req.Email, user.Email)
        
        // All steps should have been attempted
        emailService.AssertExpectations(t)
        auditService.AssertExpectations(t)
    })
}

// Mock implementations
type MockUserRepository struct {
    mock.Mock
}

func (m *MockUserRepository) Create(ctx context.Context, user *domain.User) error {
    args := m.Called(ctx, user)
    return args.Error(0)
}

func (m *MockUserRepository) GetByEmail(ctx context.Context, email string) (*domain.User, error) {
    args := m.Called(ctx, email)
    return args.Get(0).(*domain.User), args.Error(1)
}

type MockEmailService struct {
    mock.Mock
}

func (m *MockEmailService) SendWelcomeEmail(ctx context.Context, data domain.WelcomeEmailData) error {
    args := m.Called(ctx, data)
    return args.Error(0)
}

type MockAuditService struct {
    mock.Mock
}

func (m *MockAuditService) RecordEvent(ctx context.Context, event domain.AuditEvent) error {
    args := m.Called(ctx, event)
    return args.Error(0)
}

type MockUserValidator struct {
    mock.Mock
}

func (m *MockUserValidator) ValidateUser(ctx context.Context, user domain.User) error {
    args := m.Called(ctx, user)
    return args.Error(0)
}
```

## Best Practices

### 1. Main Method as Business Process

```go
// Good: Clear business process flow
func (uc *OrderUseCase) PlaceOrder(ctx context.Context, req PlaceOrderRequest) (*Order, error) {
    // Step 1: Validate order
    if err := uc.validateOrder(ctx, req); err != nil {
        return nil, err
    }
    
    // Step 2: Check inventory
    if err := uc.checkInventory(ctx, req.Items); err != nil {
        return nil, err
    }
    
    // Step 3: Calculate pricing
    pricing, err := uc.calculatePricing(ctx, req)
    if err != nil {
        return nil, err
    }
    
    // Step 4: Process payment
    payment, err := uc.processPayment(ctx, pricing.Total, req.PaymentMethod)
    if err != nil {
        return nil, err
    }
    
    // Step 5: Create order
    return uc.createOrder(ctx, req, pricing, payment)
}

// Bad: Implementation details mixed with business logic
func (uc *OrderUseCase) PlaceOrderBad(ctx context.Context, req PlaceOrderRequest) (*Order, error) {
    // Validation mixed with database calls
    if req.CustomerID == "" {
        return nil, errors.New("invalid customer")
    }
    
    customer, err := uc.customerRepo.GetByID(ctx, req.CustomerID)
    if err != nil {
        return nil, err
    }
    
    var totalPrice decimal.Decimal
    for _, item := range req.Items {
        product, err := uc.productRepo.GetByID(ctx, item.ProductID)
        if err != nil {
            return nil, err
        }
        
        if product.Stock < item.Quantity {
            return nil, errors.New("insufficient stock")
        }
        
        itemPrice := product.Price.Mul(decimal.NewFromInt(int64(item.Quantity)))
        totalPrice = totalPrice.Add(itemPrice)
    }
    
    // Business logic gets lost in implementation details...
}
```

### 2. Error Handling Strategy

```go
// Good: Clear error handling strategy per step
func (uc *PaymentUseCase) ProcessPayment(ctx context.Context, req PaymentRequest) (*Payment, error) {
    // Step 1: Validate payment data (fail fast)
    if err := uc.validatePaymentData(ctx, req); err != nil {
        return nil, err
    }
    
    // Step 2: Check payment method (fail fast)
    if err := uc.validatePaymentMethod(ctx, req.PaymentMethod); err != nil {
        return nil, err
    }
    
    // Step 3: Process payment (critical - must succeed)
    payment, err := uc.chargePayment(ctx, req)
    if err != nil {
        return nil, err
    }
    
    // Step 4: Send receipt (non-critical - log but don't fail)
    if err := uc.sendReceipt(ctx, payment); err != nil {
        uc.logReceiptFailure(ctx, payment.ID, err)
    }
    
    // Step 5: Update analytics (non-critical - log but don't fail)
    if err := uc.updateAnalytics(ctx, payment); err != nil {
        uc.logAnalyticsFailure(ctx, payment.ID, err)
    }
    
    return payment, nil
}
```

### 3. Consistent Step Naming

```go
// Good: Consistent step naming convention
func (uc *SubscriptionUseCase) CreateSubscription(ctx context.Context, req CreateSubscriptionRequest) (*Subscription, error) {
    // Step 1: Validate subscription request
    if err := uc.validateSubscriptionRequest(ctx, req); err != nil {
        return nil, err
    }
    
    // Step 2: Check user eligibility
    if err := uc.checkUserEligibility(ctx, req.UserID); err != nil {
        return nil, err
    }
    
    // Step 3: Calculate subscription pricing
    pricing, err := uc.calculateSubscriptionPricing(ctx, req.PlanID)
    if err != nil {
        return nil, err
    }
    
    // Step 4: Setup recurring payment
    paymentSetup, err := uc.setupRecurringPayment(ctx, req.PaymentMethod, pricing)
    if err != nil {
        return nil, err
    }
    
    // Step 5: Create subscription record
    subscription, err := uc.createSubscriptionRecord(ctx, req, pricing, paymentSetup)
    if err != nil {
        uc.cancelRecurringPayment(ctx, paymentSetup.ID)
        return nil, err
    }
    
    // Step 6: Send welcome notification
    if err := uc.sendWelcomeNotification(ctx, subscription); err != nil {
        uc.logNotificationFailure(ctx, subscription.ID, err)
    }
    
    return subscription, nil
}

// Bad: Inconsistent naming
func (uc *SubscriptionUseCase) CreateSubscriptionBad(ctx context.Context, req CreateSubscriptionRequest) (*Subscription, error) {
    // Mixed naming conventions and unclear step boundaries
    if err := uc.validate(ctx, req); err != nil {
        return nil, err
    }
    
    if err := uc.isEligible(ctx, req.UserID); err != nil {
        return nil, err
    }
    
    pricing := uc.getPricing(ctx, req.PlanID)
    payment := uc.doPayment(ctx, req.PaymentMethod, pricing)
    sub := uc.makeSub(ctx, req, pricing, payment)
    
    uc.notify(ctx, sub)
    
    return sub, nil
}
```

## Decision

1. **Structure main methods** as step-by-step business processes
2. **Use descriptive step comments** that explain business intent
3. **Implement steps as private methods** with clear names
4. **Separate critical from non-critical steps** in error handling
5. **Follow consistent naming conventions** for step methods
6. **Keep implementation details** in helper methods
7. **Write tests** that verify each step in isolation

## Consequences

### Positive
- **Improved readability**: Business logic is immediately clear
- **Better maintainability**: Easy to modify individual steps
- **Enhanced testability**: Each step can be tested independently
- **Clearer communication**: Business stakeholders can understand the flow
- **Easier debugging**: Problems can be traced to specific steps

### Negative
- **More verbose code**: Additional method calls and structure
- **Potential over-abstraction**: Simple operations might become complex
- **Learning curve**: Team needs to adopt consistent approach

### Trade-offs
- **Code length vs Clarity**: More lines but clearer intent
- **Performance vs Maintainability**: Slight overhead from method calls
- **Flexibility vs Structure**: More rigid patterns but better organization 
