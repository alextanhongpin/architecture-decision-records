
# Nested Router

## Status
Accepted

## Context
As applications grow in complexity, organizing HTTP routes in a hierarchical manner becomes essential for maintainability and code organization. Nested routers allow grouping related endpoints under common prefixes, enabling better separation of concerns and modular architecture.

## Decision
We will implement nested routing patterns using Go's standard `http.ServeMux` and custom router implementations to organize endpoints hierarchically, enabling better modularity and separation of concerns.

## Rationale

### Benefits
- **Modular Organization**: Group related endpoints under common prefixes
- **Middleware Composition**: Apply middleware at different nesting levels
- **Code Reusability**: Reuse handler groups across different applications
- **Separation of Concerns**: Keep different features isolated
- **Scalable Architecture**: Easy to add new routes and modify existing ones

### Use Cases
- API versioning (`/api/v1/`, `/api/v2/`)
- Feature grouping (`/users/`, `/orders/`, `/products/`)
- Administrative interfaces (`/admin/users/`, `/admin/reports/`)
- Multi-tenant applications (`/tenant/{id}/resources/`)

## Implementation

### Basic Nested Router with Standard Library

```go
package main

import (
	"fmt"
	"net/http"
)

func main() {
	mux := http.NewServeMux()
	
	// Mount nested routers with proper path handling
	mux.Handle("GET /api/v1/", http.StripPrefix("/api/v1", apiV1Router()))
	mux.Handle("GET /api/v2/", http.StripPrefix("/api/v2", apiV2Router()))
	mux.Handle("GET /admin/", http.StripPrefix("/admin", adminRouter()))
	
	// Direct routes
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("GET /", indexHandler)

	fmt.Println("Server listening on :8080")
	http.ListenAndServe(":8080", mux)
}

func apiV1Router() http.Handler {
	mux := http.NewServeMux()
	
	// User routes
	mux.Handle("GET /users/", http.StripPrefix("/users", userRouter()))
	mux.Handle("GET /orders/", http.StripPrefix("/orders", orderRouter()))
	
	// Direct API v1 routes
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("API v1"))
	})
	
	return mux
}

func apiV2Router() http.Handler {
	mux := http.NewServeMux()
	
	// Enhanced routes with new features
	mux.Handle("GET /users/", http.StripPrefix("/users", userV2Router()))
	mux.Handle("GET /orders/", http.StripPrefix("/orders", orderV2Router()))
	
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("API v2"))
	})
	
	return mux
}

func userRouter() http.Handler {
	mux := http.NewServeMux()
	
	mux.HandleFunc("GET /", listUsers)
	mux.HandleFunc("POST /", createUser)
	mux.HandleFunc("GET /{id}", getUser)
	mux.HandleFunc("PUT /{id}", updateUser)
	mux.HandleFunc("DELETE /{id}", deleteUser)
	
	return mux
}

func orderRouter() http.Handler {
	mux := http.NewServeMux()
	
	mux.HandleFunc("GET /", listOrders)
	mux.HandleFunc("POST /", createOrder)
	mux.HandleFunc("GET /{id}", getOrder)
	mux.HandleFunc("PUT /{id}", updateOrder)
	mux.HandleFunc("DELETE /{id}", deleteOrder)
	
	return mux
}

func adminRouter() http.Handler {
	mux := http.NewServeMux()
	
	// Admin-specific middleware would be applied here
	mux.Handle("GET /users/", http.StripPrefix("/users", adminUserRouter()))
	mux.Handle("GET /reports/", http.StripPrefix("/reports", adminReportRouter()))
	
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("Admin Panel"))
	})
	
	return mux
}

// Placeholder handlers
func listUsers(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("List users"))
}

func createUser(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("Create user"))
}

func getUser(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	w.Write([]byte(fmt.Sprintf("Get user %s", id)))
}

func updateUser(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	w.Write([]byte(fmt.Sprintf("Update user %s", id)))
}

func deleteUser(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	w.Write([]byte(fmt.Sprintf("Delete user %s", id)))
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("OK"))
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("Welcome"))
}

// Additional placeholder functions...
func listOrders(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func createOrder(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func getOrder(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func updateOrder(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func deleteOrder(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func userV2Router() http.Handler { return http.NewServeMux() }
func orderV2Router() http.Handler { return http.NewServeMux() }
func adminUserRouter() http.Handler { return http.NewServeMux() }
func adminReportRouter() http.Handler { return http.NewServeMux() }
```

### Advanced Nested Router with Middleware

```go
package router

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

// Router represents a nested router with middleware support
type Router struct {
	mux         *http.ServeMux
	middlewares []Middleware
	prefix      string
}

// Middleware represents a middleware function
type Middleware func(http.Handler) http.Handler

// NewRouter creates a new router instance
func NewRouter() *Router {
	return &Router{
		mux:         http.NewServeMux(),
		middlewares: make([]Middleware, 0),
	}
}

// Use adds middleware to the router
func (r *Router) Use(middleware ...Middleware) {
	r.middlewares = append(r.middlewares, middleware...)
}

// Group creates a new router group with a common prefix
func (r *Router) Group(prefix string) *Router {
	return &Router{
		mux:         http.NewServeMux(),
		middlewares: make([]Middleware, 0),
		prefix:      strings.TrimSuffix(r.prefix+prefix, "/"),
	}
}

// Mount mounts a sub-router at the given path
func (r *Router) Mount(path string, handler http.Handler) {
	fullPath := r.prefix + path
	if !strings.HasSuffix(fullPath, "/") {
		fullPath += "/"
	}
	
	r.mux.Handle(fullPath, http.StripPrefix(strings.TrimSuffix(fullPath, "/"), handler))
}

// Handle registers a handler for the given pattern
func (r *Router) Handle(pattern string, handler http.Handler) {
	fullPattern := r.prefix + pattern
	r.mux.Handle(fullPattern, r.applyMiddleware(handler))
}

// HandleFunc registers a handler function for the given pattern
func (r *Router) HandleFunc(pattern string, handler http.HandlerFunc) {
	r.Handle(pattern, handler)
}

// ServeHTTP implements the http.Handler interface
func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	r.mux.ServeHTTP(w, req)
}

// applyMiddleware applies all middleware to the handler
func (r *Router) applyMiddleware(handler http.Handler) http.Handler {
	for i := len(r.middlewares) - 1; i >= 0; i-- {
		handler = r.middlewares[i](handler)
	}
	return handler
}

// Common middleware implementations
func LoggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %v", r.Method, r.URL.Path, time.Since(start))
	})
}

func AuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("Authorization")
		if token == "" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		
		// Validate token and add user context
		ctx := context.WithValue(r.Context(), "user", "authenticated_user")
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func CORSMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		
		next.ServeHTTP(w, r)
	})
}

func RateLimitMiddleware(next http.Handler) http.Handler {
	// Simple in-memory rate limiter (use Redis in production)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Rate limiting logic here
		next.ServeHTTP(w, r)
	})
}
```

### Usage Example with Advanced Router

```go
package main

import (
	"encoding/json"
	"net/http"
	"your-app/router"
)

func main() {
	r := router.NewRouter()
	
	// Global middleware
	r.Use(router.LoggingMiddleware)
	r.Use(router.CORSMiddleware)
	
	// API v1 group
	v1 := r.Group("/api/v1")
	v1.Use(router.RateLimitMiddleware)
	
	// Public API routes
	v1.HandleFunc("GET /health", healthHandler)
	v1.HandleFunc("GET /version", versionHandler)
	
	// Protected API routes
	protected := v1.Group("")
	protected.Use(router.AuthMiddleware)
	
	// Mount resource routers
	userRouter := NewUserRouter()
	protected.Mount("/users", userRouter)
	
	orderRouter := NewOrderRouter()
	protected.Mount("/orders", orderRouter)
	
	// API v2 group with different middleware
	v2 := r.Group("/api/v2")
	v2.Use(router.LoggingMiddleware)
	v2.Use(router.AuthMiddleware)
	
	// Enhanced user router for v2
	userV2Router := NewUserV2Router()
	v2.Mount("/users", userV2Router)
	
	// Admin group with additional authentication
	admin := r.Group("/admin")
	admin.Use(router.AuthMiddleware)
	admin.Use(adminAuthMiddleware)
	
	adminUserRouter := NewAdminUserRouter()
	admin.Mount("/users", adminUserRouter)
	
	http.ListenAndServe(":8080", r)
}

// Resource-specific routers
func NewUserRouter() http.Handler {
	r := router.NewRouter()
	
	r.HandleFunc("GET /", listUsersHandler)
	r.HandleFunc("POST /", createUserHandler)
	r.HandleFunc("GET /{id}", getUserHandler)
	r.HandleFunc("PUT /{id}", updateUserHandler)
	r.HandleFunc("DELETE /{id}", deleteUserHandler)
	
	return r
}

func NewOrderRouter() http.Handler {
	r := router.NewRouter()
	
	r.HandleFunc("GET /", listOrdersHandler)
	r.HandleFunc("POST /", createOrderHandler)
	r.HandleFunc("GET /{id}", getOrderHandler)
	r.HandleFunc("PUT /{id}", updateOrderHandler)
	r.HandleFunc("DELETE /{id}", deleteOrderHandler)
	
	// Nested routes for order items
	r.Mount("/{id}/items", NewOrderItemRouter())
	
	return r
}

func NewOrderItemRouter() http.Handler {
	r := router.NewRouter()
	
	r.HandleFunc("GET /", listOrderItemsHandler)
	r.HandleFunc("POST /", addOrderItemHandler)
	r.HandleFunc("DELETE /{itemId}", removeOrderItemHandler)
	
	return r
}

// Middleware for admin routes
func adminAuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Additional admin authentication logic
		user := r.Context().Value("user")
		if user != "admin_user" {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Handler implementations
func healthHandler(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func versionHandler(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(map[string]string{"version": "1.0.0"})
}

func listUsersHandler(w http.ResponseWriter, r *http.Request) {
	// Implementation
}

func createUserHandler(w http.ResponseWriter, r *http.Request) {
	// Implementation
}

func getUserHandler(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	// Get user by ID
	json.NewEncoder(w).Encode(map[string]string{"id": id})
}

// Additional handler implementations...
func updateUserHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func deleteUserHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func listOrdersHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func createOrderHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func getOrderHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func updateOrderHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func deleteOrderHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func listOrderItemsHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func addOrderItemHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func removeOrderItemHandler(w http.ResponseWriter, r *http.Request) { /* implementation */ }
func NewUserV2Router() http.Handler { return router.NewRouter() }
func NewAdminUserRouter() http.Handler { return router.NewRouter() }
```

### Controller Pattern Implementation

```go
package controllers

import (
	"encoding/json"
	"net/http"
	"strconv"
)

// BaseController provides common functionality for all controllers
type BaseController struct{}

func (bc *BaseController) WriteJSON(w http.ResponseWriter, data interface{}) error {
	w.Header().Set("Content-Type", "application/json")
	return json.NewEncoder(w).Encode(data)
}

func (bc *BaseController) WriteError(w http.ResponseWriter, message string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": message})
}

// UserController handles user-related operations
type UserController struct {
	BaseController
	userService UserService
}

func NewUserController(userService UserService) *UserController {
	return &UserController{
		userService: userService,
	}
}

func (uc *UserController) Router() http.Handler {
	r := router.NewRouter()
	
	r.HandleFunc("GET /", uc.List)
	r.HandleFunc("POST /", uc.Create)
	r.HandleFunc("GET /{id}", uc.Get)
	r.HandleFunc("PUT /{id}", uc.Update)
	r.HandleFunc("DELETE /{id}", uc.Delete)
	
	return r
}

func (uc *UserController) List(w http.ResponseWriter, r *http.Request) {
	users, err := uc.userService.GetAll()
	if err != nil {
		uc.WriteError(w, "Failed to fetch users", http.StatusInternalServerError)
		return
	}
	
	uc.WriteJSON(w, users)
}

func (uc *UserController) Create(w http.ResponseWriter, r *http.Request) {
	var user User
	if err := json.NewDecoder(r.Body).Decode(&user); err != nil {
		uc.WriteError(w, "Invalid request body", http.StatusBadRequest)
		return
	}
	
	createdUser, err := uc.userService.Create(user)
	if err != nil {
		uc.WriteError(w, "Failed to create user", http.StatusInternalServerError)
		return
	}
	
	w.WriteHeader(http.StatusCreated)
	uc.WriteJSON(w, createdUser)
}

func (uc *UserController) Get(w http.ResponseWriter, r *http.Request) {
	idStr := r.PathValue("id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		uc.WriteError(w, "Invalid user ID", http.StatusBadRequest)
		return
	}
	
	user, err := uc.userService.GetByID(id)
	if err != nil {
		uc.WriteError(w, "User not found", http.StatusNotFound)
		return
	}
	
	uc.WriteJSON(w, user)
}

func (uc *UserController) Update(w http.ResponseWriter, r *http.Request) {
	idStr := r.PathValue("id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		uc.WriteError(w, "Invalid user ID", http.StatusBadRequest)
		return
	}
	
	var user User
	if err := json.NewDecoder(r.Body).Decode(&user); err != nil {
		uc.WriteError(w, "Invalid request body", http.StatusBadRequest)
		return
	}
	
	user.ID = id
	updatedUser, err := uc.userService.Update(user)
	if err != nil {
		uc.WriteError(w, "Failed to update user", http.StatusInternalServerError)
		return
	}
	
	uc.WriteJSON(w, updatedUser)
}

func (uc *UserController) Delete(w http.ResponseWriter, r *http.Request) {
	idStr := r.PathValue("id")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		uc.WriteError(w, "Invalid user ID", http.StatusBadRequest)
		return
	}
	
	if err := uc.userService.Delete(id); err != nil {
		uc.WriteError(w, "Failed to delete user", http.StatusInternalServerError)
		return
	}
	
	w.WriteHeader(http.StatusNoContent)
}

// Service interfaces and models
type UserService interface {
	GetAll() ([]User, error)
	GetByID(id int) (User, error)
	Create(user User) (User, error)
	Update(user User) (User, error)
	Delete(id int) error
}

type User struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
}
```

## Best Practices

### 1. Path Prefix Management
- Always use trailing slashes for mount points
- Use `http.StripPrefix` for proper path handling
- Be consistent with path naming conventions
- Avoid conflicts between nested and direct routes

### 2. Middleware Organization
- Apply middleware at appropriate nesting levels
- Use global middleware for cross-cutting concerns
- Apply specific middleware to resource groups
- Consider middleware order and dependencies

### 3. Resource Organization
- Group related endpoints under common prefixes
- Use RESTful conventions for resource endpoints
- Separate public and protected routes
- Implement consistent error handling

### 4. Performance Considerations
- Cache route lookups where possible
- Minimize middleware overhead
- Use efficient path matching algorithms
- Consider route compilation for high-traffic applications

### 5. Testing Strategy
- Test each router level independently
- Verify middleware application at different levels
- Test route resolution and parameter extraction
- Implement integration tests for complete request flows

## Common Patterns

### API Versioning
```go
// Version-specific routers
v1 := r.Group("/api/v1")
v2 := r.Group("/api/v2")

// Different middleware for different versions
v1.Use(legacyAuthMiddleware)
v2.Use(modernAuthMiddleware)
```

### Feature Modules
```go
// Feature-based organization
userModule := r.Group("/users")
orderModule := r.Group("/orders")
paymentModule := r.Group("/payments")

// Each module can have its own middleware
userModule.Use(userSpecificMiddleware)
```

### Multi-tenancy
```go
// Tenant-specific routes
tenant := r.Group("/tenant/{tenantId}")
tenant.Use(tenantAuthMiddleware)
tenant.Mount("/users", userRouter)
tenant.Mount("/orders", orderRouter)
```

## Consequences

### Positive
- Better code organization and modularity
- Easier maintenance and testing
- Flexible middleware composition
- Scalable routing architecture
- Clear separation of concerns

### Negative
- Increased complexity in simple applications
- Potential performance overhead from nested lookups
- More complex debugging and troubleshooting
- Learning curve for developers unfamiliar with the pattern

### Mitigation
- Start simple and add nesting as needed
- Document routing structure clearly
- Implement comprehensive logging and monitoring
- Provide clear examples and documentation
- Use consistent patterns across the application

## Related Patterns
- [025-json-response.md](025-json-response.md) - Standardized response handling
- [013-logging.md](013-logging.md) - Request logging in middleware
- [004-use-rate-limiting.md](004-use-rate-limiting.md) - Rate limiting middleware
- [034-auth-token.md](034-auth-token.md) - Authentication middleware
