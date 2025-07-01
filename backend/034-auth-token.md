# Auth Token

## Status
Accepted

## Context
Authentication tokens are critical components for securing API access and maintaining user sessions across different platforms and devices. The design must balance security requirements with usability while supporting multiple authentication providers and platforms.

## Decision
We will implement a comprehensive authentication token system using JWTs with secure metadata, provider tracking, device identification, and platform-specific security measures including secure cookie handling for web applications.

## Rationale

### Benefits
- **Platform Flexibility**: Supports web, mobile, and API clients
- **Provider Agnostic**: Works with multiple authentication providers
- **Security**: Implements industry best practices for token security
- **Auditability**: Tracks device and provider information
- **Scalability**: Stateless token validation with optional state tracking

### Security Considerations
- **Token Expiration**: Short-lived access tokens with refresh mechanisms
- **Secure Storage**: Platform-appropriate storage (cookies for web, secure storage for mobile)
- **Revocation**: Ability to invalidate tokens when needed
- **Validation**: Strong signature verification and claims validation

## Implementation

### Token Structure and Claims

```go
package auth

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// TokenClaims represents the structure of JWT claims
type TokenClaims struct {
	// Standard JWT claims
	jwt.RegisteredClaims
	
	// Custom claims
	UserID     string            `json:"user_id"`
	Email      string            `json:"email,omitempty"`
	Provider   string            `json:"provider"`           // email, google, facebook, etc.
	Device     DeviceInfo        `json:"device"`
	Roles      []string          `json:"roles,omitempty"`
	Scopes     []string          `json:"scopes,omitempty"`
	SessionID  string            `json:"session_id"`
	TokenType  string            `json:"token_type"`         // access, refresh
	Metadata   map[string]string `json:"metadata,omitempty"`
}

// DeviceInfo contains device-specific information
type DeviceInfo struct {
	ID       string `json:"id"`                 // unique device identifier
	Type     string `json:"type"`               // web, ios, android
	Platform string `json:"platform,omitempty"` // browser type, mobile device model
	IP       string `json:"ip,omitempty"`
	UserAgent string `json:"user_agent,omitempty"`
}

// TokenPair represents access and refresh tokens
type TokenPair struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	TokenType    string    `json:"token_type"`
	ExpiresIn    int       `json:"expires_in"`
	ExpiresAt    time.Time `json:"expires_at"`
	Scope        string    `json:"scope,omitempty"`
}

// TokenService handles JWT operations
type TokenService struct {
	accessSecret     []byte
	refreshSecret    []byte
	accessDuration   time.Duration
	refreshDuration  time.Duration
	issuer           string
	sessionStore     SessionStore
}

// SessionStore interface for managing active sessions
type SessionStore interface {
	StoreSession(sessionID string, userID string, deviceID string, expiresAt time.Time) error
	ValidateSession(sessionID string) (bool, error)
	RevokeSession(sessionID string) error
	RevokeUserSessions(userID string) error
	RevokeDeviceSessions(userID string, deviceID string) error
	GetUserSessions(userID string) ([]Session, error)
}

// Session represents an active user session
type Session struct {
	ID        string    `json:"id"`
	UserID    string    `json:"user_id"`
	DeviceID  string    `json:"device_id"`
	Provider  string    `json:"provider"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
	LastUsed  time.Time `json:"last_used"`
	Active    bool      `json:"active"`
}

func NewTokenService(accessSecret, refreshSecret []byte, issuer string, sessionStore SessionStore) *TokenService {
	return &TokenService{
		accessSecret:     accessSecret,
		refreshSecret:    refreshSecret,
		accessDuration:   15 * time.Minute,  // Short-lived access token
		refreshDuration:  7 * 24 * time.Hour, // 7 days refresh token
		issuer:           issuer,
		sessionStore:     sessionStore,
	}
}

// GenerateTokenPair creates a new access and refresh token pair
func (ts *TokenService) GenerateTokenPair(userID, email, provider string, device DeviceInfo, roles, scopes []string) (*TokenPair, error) {
	sessionID, err := generateSecureID()
	if err != nil {
		return nil, fmt.Errorf("failed to generate session ID: %w", err)
	}

	now := time.Now()
	accessExpiry := now.Add(ts.accessDuration)
	refreshExpiry := now.Add(ts.refreshDuration)

	// Create access token
	accessToken, err := ts.createToken(TokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    ts.issuer,
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(accessExpiry),
			NotBefore: jwt.NewNumericDate(now),
			ID:        sessionID,
		},
		UserID:    userID,
		Email:     email,
		Provider:  provider,
		Device:    device,
		Roles:     roles,
		Scopes:    scopes,
		SessionID: sessionID,
		TokenType: "access",
	}, ts.accessSecret)

	if err != nil {
		return nil, fmt.Errorf("failed to create access token: %w", err)
	}

	// Create refresh token
	refreshToken, err := ts.createToken(TokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    ts.issuer,
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(refreshExpiry),
			NotBefore: jwt.NewNumericDate(now),
			ID:        sessionID,
		},
		UserID:    userID,
		Provider:  provider,
		Device:    device,
		SessionID: sessionID,
		TokenType: "refresh",
	}, ts.refreshSecret)

	if err != nil {
		return nil, fmt.Errorf("failed to create refresh token: %w", err)
	}

	// Store session
	if err := ts.sessionStore.StoreSession(sessionID, userID, device.ID, refreshExpiry); err != nil {
		return nil, fmt.Errorf("failed to store session: %w", err)
	}

	return &TokenPair{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		TokenType:    "Bearer",
		ExpiresIn:    int(ts.accessDuration.Seconds()),
		ExpiresAt:    accessExpiry,
	}, nil
}

// ValidateAccessToken validates and parses an access token
func (ts *TokenService) ValidateAccessToken(tokenString string) (*TokenClaims, error) {
	claims, err := ts.parseToken(tokenString, ts.accessSecret)
	if err != nil {
		return nil, err
	}

	if claims.TokenType != "access" {
		return nil, errors.New("invalid token type")
	}

	// Check session validity
	valid, err := ts.sessionStore.ValidateSession(claims.SessionID)
	if err != nil {
		return nil, fmt.Errorf("session validation error: %w", err)
	}
	if !valid {
		return nil, errors.New("session invalid or expired")
	}

	return claims, nil
}

// RefreshToken creates new tokens using a refresh token
func (ts *TokenService) RefreshToken(refreshTokenString string) (*TokenPair, error) {
	claims, err := ts.parseToken(refreshTokenString, ts.refreshSecret)
	if err != nil {
		return nil, err
	}

	if claims.TokenType != "refresh" {
		return nil, errors.New("invalid token type")
	}

	// Validate session
	valid, err := ts.sessionStore.ValidateSession(claims.SessionID)
	if err != nil || !valid {
		return nil, errors.New("session invalid or expired")
	}

	// Generate new token pair
	return ts.GenerateTokenPair(
		claims.UserID,
		claims.Email,
		claims.Provider,
		claims.Device,
		claims.Roles,
		claims.Scopes,
	)
}

// RevokeToken revokes a specific session
func (ts *TokenService) RevokeToken(sessionID string) error {
	return ts.sessionStore.RevokeSession(sessionID)
}

// RevokeUserTokens revokes all tokens for a user
func (ts *TokenService) RevokeUserTokens(userID string) error {
	return ts.sessionStore.RevokeUserSessions(userID)
}

// RevokeDeviceTokens revokes all tokens for a specific device
func (ts *TokenService) RevokeDeviceTokens(userID, deviceID string) error {
	return ts.sessionStore.RevokeDeviceSessions(userID, deviceID)
}

// createToken creates a signed JWT token
func (ts *TokenService) createToken(claims TokenClaims, secret []byte) (string, error) {
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(secret)
}

// parseToken parses and validates a JWT token
func (ts *TokenService) parseToken(tokenString string, secret []byte) (*TokenClaims, error) {
	token, err := jwt.ParseWithClaims(tokenString, &TokenClaims{}, func(token *jwt.Token) (interface{}, error) {
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return secret, nil
	})

	if err != nil {
		return nil, err
	}

	if claims, ok := token.Claims.(*TokenClaims); ok && token.Valid {
		return claims, nil
	}

	return nil, errors.New("invalid token")
}

func generateSecureID() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}
```

### Authentication Middleware

```go
package middleware

import (
	"context"
	"net/http"
	"strings"
	"your-app/auth"
)

// AuthMiddleware handles JWT authentication
type AuthMiddleware struct {
	tokenService *auth.TokenService
	optional     bool
}

func NewAuthMiddleware(tokenService *auth.TokenService, optional bool) *AuthMiddleware {
	return &AuthMiddleware{
		tokenService: tokenService,
		optional:     optional,
	}
}

func (am *AuthMiddleware) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := am.extractToken(r)
		
		if token == "" {
			if !am.optional {
				http.Error(w, "Authorization token required", http.StatusUnauthorized)
				return
			}
			next.ServeHTTP(w, r)
			return
		}

		claims, err := am.tokenService.ValidateAccessToken(token)
		if err != nil {
			if !am.optional {
				http.Error(w, "Invalid token", http.StatusUnauthorized)
				return
			}
			next.ServeHTTP(w, r)
			return
		}

		// Add claims to request context
		ctx := context.WithValue(r.Context(), "auth_claims", claims)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (am *AuthMiddleware) extractToken(r *http.Request) string {
	// Check Authorization header
	authHeader := r.Header.Get("Authorization")
	if authHeader != "" && strings.HasPrefix(authHeader, "Bearer ") {
		return strings.TrimPrefix(authHeader, "Bearer ")
	}

	// Check cookie for web clients
	if cookie, err := r.Cookie("access_token"); err == nil {
		return cookie.Value
	}

	return ""
}

// RequireRoles middleware to check for specific roles
func RequireRoles(roles ...string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := r.Context().Value("auth_claims").(*auth.TokenClaims)
			if !ok {
				http.Error(w, "Authentication required", http.StatusUnauthorized)
				return
			}

			// Check if user has any of the required roles
			hasRole := false
			for _, requiredRole := range roles {
				for _, userRole := range claims.Roles {
					if userRole == requiredRole {
						hasRole = true
						break
					}
				}
				if hasRole {
					break
				}
			}

			if !hasRole {
				http.Error(w, "Insufficient permissions", http.StatusForbidden)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// RequireScopes middleware to check for specific scopes
func RequireScopes(scopes ...string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := r.Context().Value("auth_claims").(*auth.TokenClaims)
			if !ok {
				http.Error(w, "Authentication required", http.StatusUnauthorized)
				return
			}

			// Check if token has all required scopes
			for _, requiredScope := range scopes {
				hasScope := false
				for _, tokenScope := range claims.Scopes {
					if tokenScope == requiredScope {
						hasScope = true
						break
					}
				}
				if !hasScope {
					http.Error(w, "Insufficient scopes", http.StatusForbidden)
					return
				}
			}

			next.ServeHTTP(w, r)
		})
	}
}
```

### Platform-Specific Token Handling

```go
package handlers

import (
	"encoding/json"
	"net/http"
	"time"
	"your-app/auth"
)

// AuthHandler handles authentication endpoints
type AuthHandler struct {
	tokenService *auth.TokenService
}

func NewAuthHandler(tokenService *auth.TokenService) *AuthHandler {
	return &AuthHandler{tokenService: tokenService}
}

// Login handles user authentication
func (ah *AuthHandler) Login(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email      string `json:"email"`
		Password   string `json:"password"`
		Provider   string `json:"provider"`
		DeviceInfo struct {
			Type      string `json:"type"`
			Platform  string `json:"platform"`
			UserAgent string `json:"user_agent"`
		} `json:"device_info"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	// Validate credentials (implementation depends on your auth system)
	user, err := ah.validateCredentials(req.Email, req.Password, req.Provider)
	if err != nil {
		http.Error(w, "Invalid credentials", http.StatusUnauthorized)
		return
	}

	// Create device info
	deviceInfo := auth.DeviceInfo{
		ID:        generateDeviceID(req.DeviceInfo.Type, r.RemoteAddr),
		Type:      req.DeviceInfo.Type,
		Platform:  req.DeviceInfo.Platform,
		IP:        r.RemoteAddr,
		UserAgent: req.DeviceInfo.UserAgent,
	}

	// Generate tokens
	tokenPair, err := ah.tokenService.GenerateTokenPair(
		user.ID,
		user.Email,
		req.Provider,
		deviceInfo,
		user.Roles,
		user.Scopes,
	)
	if err != nil {
		http.Error(w, "Failed to generate tokens", http.StatusInternalServerError)
		return
	}

	// Handle platform-specific token delivery
	ah.handleTokenResponse(w, r, tokenPair, deviceInfo.Type)
}

// handleTokenResponse handles platform-specific token delivery
func (ah *AuthHandler) handleTokenResponse(w http.ResponseWriter, r *http.Request, tokenPair *auth.TokenPair, deviceType string) {
	switch deviceType {
	case "web":
		// Set secure HTTP-only cookie for web clients
		http.SetCookie(w, &http.Cookie{
			Name:     "access_token",
			Value:    tokenPair.AccessToken,
			Path:     "/",
			Expires:  tokenPair.ExpiresAt,
			HttpOnly: true,
			Secure:   true, // HTTPS only
			SameSite: http.SameSiteStrictMode,
		})

		http.SetCookie(w, &http.Cookie{
			Name:     "refresh_token",
			Value:    tokenPair.RefreshToken,
			Path:     "/auth/refresh",
			Expires:  time.Now().Add(7 * 24 * time.Hour),
			HttpOnly: true,
			Secure:   true,
			SameSite: http.SameSiteStrictMode,
		})

		// Return minimal response for web
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"success":    true,
			"token_type": tokenPair.TokenType,
			"expires_in": tokenPair.ExpiresIn,
		})

	case "ios", "android":
		// Return tokens in response body for mobile clients
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(tokenPair)

	default:
		// API clients get tokens in response body
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(tokenPair)
	}
}

// Refresh handles token refresh
func (ah *AuthHandler) Refresh(w http.ResponseWriter, r *http.Request) {
	var refreshToken string

	// Extract refresh token based on client type
	if cookie, err := r.Cookie("refresh_token"); err == nil {
		refreshToken = cookie.Value
	} else {
		var req struct {
			RefreshToken string `json:"refresh_token"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "Invalid request", http.StatusBadRequest)
			return
		}
		refreshToken = req.RefreshToken
	}

	if refreshToken == "" {
		http.Error(w, "Refresh token required", http.StatusBadRequest)
		return
	}

	// Refresh tokens
	newTokenPair, err := ah.tokenService.RefreshToken(refreshToken)
	if err != nil {
		http.Error(w, "Invalid refresh token", http.StatusUnauthorized)
		return
	}

	// Determine client type from original token or request headers
	deviceType := "api" // default
	if r.Header.Get("User-Agent") != "" {
		// Simple device type detection logic
		userAgent := r.Header.Get("User-Agent")
		if strings.Contains(userAgent, "Mozilla") {
			deviceType = "web"
		}
	}

	ah.handleTokenResponse(w, r, newTokenPair, deviceType)
}

// Logout handles user logout
func (ah *AuthHandler) Logout(w http.ResponseWriter, r *http.Request) {
	claims, ok := r.Context().Value("auth_claims").(*auth.TokenClaims)
	if !ok {
		http.Error(w, "Authentication required", http.StatusUnauthorized)
		return
	}

	// Revoke session
	if err := ah.tokenService.RevokeToken(claims.SessionID); err != nil {
		http.Error(w, "Failed to logout", http.StatusInternalServerError)
		return
	}

	// Clear cookies for web clients
	http.SetCookie(w, &http.Cookie{
		Name:     "access_token",
		Value:    "",
		Path:     "/",
		Expires:  time.Unix(0, 0),
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
	})

	http.SetCookie(w, &http.Cookie{
		Name:     "refresh_token",
		Value:    "",
		Path:     "/auth/refresh",
		Expires:  time.Unix(0, 0),
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
	})

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"message": "Logged out successfully"})
}

// LogoutAll revokes all user sessions
func (ah *AuthHandler) LogoutAll(w http.ResponseWriter, r *http.Request) {
	claims, ok := r.Context().Value("auth_claims").(*auth.TokenClaims)
	if !ok {
		http.Error(w, "Authentication required", http.StatusUnauthorized)
		return
	}

	if err := ah.tokenService.RevokeUserTokens(claims.UserID); err != nil {
		http.Error(w, "Failed to logout from all devices", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"message": "Logged out from all devices"})
}

// GetSessions returns active sessions for the user
func (ah *AuthHandler) GetSessions(w http.ResponseWriter, r *http.Request) {
	claims, ok := r.Context().Value("auth_claims").(*auth.TokenClaims)
	if !ok {
		http.Error(w, "Authentication required", http.StatusUnauthorized)
		return
	}

	sessions, err := ah.tokenService.SessionStore.GetUserSessions(claims.UserID)
	if err != nil {
		http.Error(w, "Failed to get sessions", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"sessions": sessions,
		"current":  claims.SessionID,
	})
}

// Helper functions
func (ah *AuthHandler) validateCredentials(email, password, provider string) (*User, error) {
	// Implementation depends on your authentication system
	// This could validate against database, LDAP, OAuth provider, etc.
	return nil, nil
}

func generateDeviceID(deviceType, ip string) string {
	// Generate unique device ID based on device type and IP
	// In production, you might want to use more sophisticated device fingerprinting
	return fmt.Sprintf("%s_%s_%d", deviceType, strings.ReplaceAll(ip, ":", "_"), time.Now().Unix())
}

type User struct {
	ID     string   `json:"id"`
	Email  string   `json:"email"`
	Roles  []string `json:"roles"`
	Scopes []string `json:"scopes"`
}
```

### Enhanced Security Features

```go
package security

import (
	"context"
	"crypto/subtle"
	"fmt"
	"net/http"
	"strings"
	"time"
	"your-app/auth"
)

// SecurityMiddleware provides additional security checks
type SecurityMiddleware struct {
	tokenService *auth.TokenService
}

func NewSecurityMiddleware(tokenService *auth.TokenService) *SecurityMiddleware {
	return &SecurityMiddleware{tokenService: tokenService}
}

// RequireRecentAuth requires recent authentication for sensitive operations
func (sm *SecurityMiddleware) RequireRecentAuth(maxAge time.Duration) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := r.Context().Value("auth_claims").(*auth.TokenClaims)
			if !ok {
				http.Error(w, "Authentication required", http.StatusUnauthorized)
				return
			}

			// Check if token was issued recently enough
			tokenAge := time.Since(claims.IssuedAt.Time)
			if tokenAge > maxAge {
				http.Error(w, "Recent authentication required", http.StatusForbidden)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// ValidateDeviceFingerprint ensures the request comes from the same device
func (sm *SecurityMiddleware) ValidateDeviceFingerprint() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := r.Context().Value("auth_claims").(*auth.TokenClaims)
			if !ok {
				next.ServeHTTP(w, r)
				return
			}

			// Compare request fingerprint with token device info
			currentUA := r.Header.Get("User-Agent")
			currentIP := r.RemoteAddr

			// Allow some flexibility for IP changes (mobile networks, etc.)
			if claims.Device.UserAgent != "" && 
			   subtle.ConstantTimeCompare([]byte(claims.Device.UserAgent), []byte(currentUA)) != 1 {
				// Log suspicious activity
				fmt.Printf("User-Agent mismatch for user %s: expected %s, got %s\n", 
					claims.UserID, claims.Device.UserAgent, currentUA)
			}

			next.ServeHTTP(w, r)
		})
	}
}

// RateLimitByUser implements per-user rate limiting
func (sm *SecurityMiddleware) RateLimitByUser(limiter UserRateLimiter) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := r.Context().Value("auth_claims").(*auth.TokenClaims)
			if !ok {
				next.ServeHTTP(w, r)
				return
			}

			if !limiter.Allow(claims.UserID) {
				http.Error(w, "Rate limit exceeded", http.StatusTooManyRequests)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// UserRateLimiter interface for per-user rate limiting
type UserRateLimiter interface {
	Allow(userID string) bool
}
```

## Best Practices

### 1. Token Security
- Use strong, random secrets for signing
- Implement proper token expiration policies
- Support token revocation and blacklisting
- Validate all token claims thoroughly
- Use secure token storage on client side

### 2. Platform-Specific Considerations
- **Web**: Use secure HTTP-only cookies
- **Mobile**: Store tokens in secure storage (Keychain/KeyStore)
- **API**: Support Authorization header with Bearer tokens
- **SPA**: Consider token handling with XSS protection

### 3. Session Management
- Track active sessions with metadata
- Provide session management interfaces
- Support device-specific logout
- Implement session timeout policies
- Monitor for suspicious session activity

### 4. Provider Integration
- Support multiple authentication providers
- Track primary vs. linked providers
- Handle provider-specific claims
- Implement provider account linking
- Support provider-specific token refresh

### 5. Security Monitoring
- Log authentication events
- Monitor for unusual access patterns
- Implement device fingerprinting
- Track token usage and abuse
- Set up alerts for security events

## Common Patterns

### Token Refresh Flow
```go
// Automatic token refresh in client
func (c *APIClient) makeAuthenticatedRequest(req *http.Request) (*http.Response, error) {
	// Add current access token
	req.Header.Set("Authorization", "Bearer "+c.accessToken)
	
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	
	// If token expired, refresh and retry
	if resp.StatusCode == 401 {
		if err := c.refreshToken(); err != nil {
			return nil, err
		}
		
		// Retry with new token
		req.Header.Set("Authorization", "Bearer "+c.accessToken)
		return c.httpClient.Do(req)
	}
	
	return resp, nil
}
```

### Multi-Provider Support
```go
// Provider-specific token handling
func (ah *AuthHandler) handleProviderAuth(provider string, providerToken string) (*User, error) {
	switch provider {
	case "google":
		return ah.validateGoogleToken(providerToken)
	case "facebook":
		return ah.validateFacebookToken(providerToken)
	case "email":
		return ah.validateEmailPassword(providerToken)
	default:
		return nil, errors.New("unsupported provider")
	}
}
```

### Device Management
```go
// Device-specific operations
func (ts *TokenService) GetUserDevices(userID string) ([]DeviceInfo, error) {
	sessions, err := ts.sessionStore.GetUserSessions(userID)
	if err != nil {
		return nil, err
	}
	
	var devices []DeviceInfo
	for _, session := range sessions {
		// Extract device info from session
		devices = append(devices, session.DeviceInfo)
	}
	
	return devices, nil
}
```

## Consequences

### Positive
- **Security**: Strong authentication and authorization mechanisms
- **Flexibility**: Supports multiple platforms and providers
- **Auditability**: Comprehensive tracking of authentication events
- **Scalability**: Stateless token validation with optional session tracking
- **User Experience**: Platform-appropriate token handling

### Negative
- **Complexity**: Multiple token types and platform-specific handling
- **Storage Requirements**: Session and device tracking data
- **Performance**: Token validation and signature verification overhead
- **Key Management**: Secure key rotation and distribution challenges

### Mitigation
- **Documentation**: Provide clear integration guides for each platform
- **Monitoring**: Implement comprehensive security monitoring
- **Testing**: Thorough testing across all supported platforms
- **Automation**: Automated key rotation and security updates
- **Fallbacks**: Graceful handling of token validation failures

## Related Patterns
- [008-use-circuit-breaker.md](008-use-circuit-breaker.md) - Circuit breaker for auth service dependencies
- [004-use-rate-limiting.md](004-use-rate-limiting.md) - Rate limiting authentication endpoints
- [013-logging.md](013-logging.md) - Security event logging
- [032-nested-router.md](032-nested-router.md) - Authentication middleware in nested routers
