# Error Tags

You can add additional context by wrapping errors in golang, e.g 

```go
fmt.Errorf("register failed: %w", err)
```

However, the error becomes unstructured and harder to grep in logs.

We can provide tags instead, and declare them for each usecase. Tags can extend an error..

```go
package user

var ErrNotFound = causes.New(...)


package register

var RegisterUserNotFound = user.ErrNotFound.Tag("register")

```
