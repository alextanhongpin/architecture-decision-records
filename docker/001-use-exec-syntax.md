# Use EXEC Syntax in Docker

## Overview

Docker supports two different syntax forms for commands like `CMD`, `RUN`, and `ENTRYPOINT`: the shell form and the exec form. Understanding the difference is crucial for proper container behavior, especially for signal handling and graceful termination.

## Shell Form vs Exec Form

### Shell Form
The shell form runs commands through a shell (`/bin/sh -c` on Linux):

```dockerfile
# Shell form - runs as: /bin/sh -c "command"
CMD /go/bin/app
RUN echo "Hello World"
ENTRYPOINT /go/bin/app
```

### Exec Form  
The exec form runs the executable directly without a shell:

```dockerfile
# Exec form - runs the executable directly
CMD ["/go/bin/app"]
RUN ["echo", "Hello World"]
ENTRYPOINT ["/go/bin/app"]
```

## Key Differences

### Process ID (PID)
- **Shell form**: The command runs as a child process under the shell (PID 1 is the shell)
- **Exec form**: The command runs as PID 1 (the main process)

### Signal Handling
- **Shell form**: Signals are sent to the shell, which may not forward them to your application
- **Exec form**: Signals are sent directly to your application

### Variable Expansion
- **Shell form**: Environment variables are expanded by the shell
- **Exec form**: No variable expansion (variables must be expanded manually)

## Demonstration

Here's what you see when running containers with different forms:

```bash
# Shell form example
CMD /go/bin/app
# Container process: /bin/sh -c /go/bin/app

# Exec form example  
CMD ["/go/bin/app"]
# Container process: /go/bin/app
```

Docker PS output comparison:
```bash
$ docker ps -a
CONTAINER ID   IMAGE                      COMMAND                  CREATED              STATUS                          PORTS     NAMES
16554a390f0d   alextanhongpin/app:0.0.2   "/bin/sh -c /go/bin/…"   About a minute ago   Exited (0) 39 seconds ago                 competent_merkle
47facfd6c8ea   1a73a3d36064               "/go/bin/app"            2 minutes ago        Exited (0) About a minute ago             optimistic_newton
```

## Why Exec Form is Preferred

### 1. Graceful Termination
The most critical reason is proper signal handling. When Docker stops a container:

1. Docker sends `SIGTERM` to PID 1
2. **Shell form**: Shell receives the signal but may not forward it to your app
3. **Exec form**: Your application receives the signal directly

```dockerfile
# ❌ Shell form - application may not receive SIGTERM
CMD /go/bin/app

# ✅ Exec form - application receives SIGTERM directly  
CMD ["/go/bin/app"]
```

### 2. Resource Efficiency
With shell form, you have an extra shell process consuming memory and CPU:

```bash
# Shell form - two processes
PID 1: /bin/sh -c /go/bin/app
PID 8: /go/bin/app

# Exec form - one process
PID 1: /go/bin/app
```

### 3. Debugging and Monitoring
Process monitoring tools work better when your application is PID 1:

```bash
# Check process tree
$ docker exec container-id ps aux
# Shell form shows shell + app
# Exec form shows only app
```

## Practical Examples

### Basic Go Application

```dockerfile
FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -o /app/server ./cmd/server

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/

COPY --from=builder /app/server .

# ✅ Use exec form for proper signal handling
CMD ["./server"]
```

### With Environment Variables

When you need environment variable expansion with exec form:

```dockerfile
# ❌ This won't work with exec form
CMD ["/go/bin/app", "--port", "$PORT"]

# ✅ Use shell form if you need variable expansion
CMD ["/bin/sh", "-c", "/go/bin/app --port $PORT"]

# ✅ Or set environment variables in your application code
ENV PORT=8080
CMD ["/go/bin/app"]
```

### Complex Commands

For complex commands requiring shell features:

```dockerfile
# ❌ Shell form - signals not handled properly
CMD /go/bin/app > /var/log/app.log 2>&1

# ✅ Better: Use exec form with a wrapper script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
```

Example `entrypoint.sh`:
```bash
#!/bin/sh
# Redirect output and handle signals properly
exec /go/bin/app > /var/log/app.log 2>&1
```

## Testing Signal Handling

### Go Application with Graceful Shutdown

```go
package main

import (
    "context"
    "fmt"
    "net/http"
    "os"
    "os/signal"
    "syscall"
    "time"
)

func main() {
    server := &http.Server{
        Addr:    ":8080",
        Handler: http.HandlerFunc(handler),
    }

    // Start server in a goroutine
    go func() {
        fmt.Println("Server starting on :8080")
        if err := server.ListenAndServe(); err != http.ErrServerClosed {
            fmt.Printf("Server error: %v\n", err)
        }
    }()

    // Wait for interrupt signal
    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit

    fmt.Println("Server shutting down...")

    // Graceful shutdown with timeout
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()

    if err := server.Shutdown(ctx); err != nil {
        fmt.Printf("Server forced to shutdown: %v\n", err)
    }

    fmt.Println("Server exited")
}

func handler(w http.ResponseWriter, r *http.Request) {
    fmt.Fprintf(w, "Hello from Go server!")
}
```

### Test Signal Handling

```bash
# Build and run with exec form
$ docker build -t test-signals .
$ docker run -d --name test-app test-signals

# Test graceful shutdown
$ docker stop test-app

# Check logs to see if graceful shutdown occurred
$ docker logs test-app
```

## Best Practices

### 1. Always Use Exec Form for CMD and ENTRYPOINT
```dockerfile
# ✅ Recommended
CMD ["./app"]
ENTRYPOINT ["./app"]

# ❌ Avoid
CMD ./app
ENTRYPOINT ./app
```

### 2. Use Shell Form Only When Necessary
```dockerfile
# When you need shell features like pipes, redirects, etc.
RUN echo "Building application..." && \
    go build -o app . && \
    echo "Build complete"
```

### 3. Handle Complex Scenarios with Scripts
```dockerfile
# For complex startup logic
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["./app"]
```

### 4. Use `exec` in Shell Scripts
When writing shell scripts that start your application:

```bash
#!/bin/bash
# docker-entrypoint.sh

# Setup logic here
echo "Initializing application..."

# Use exec to replace shell with your application
exec "$@"
```

## Common Pitfalls

### 1. Variable Expansion in Exec Form
```dockerfile
# ❌ Variables not expanded
CMD ["echo", "$HOME"]

# ✅ Use shell form for variable expansion
CMD ["sh", "-c", "echo $HOME"]
```

### 2. Array vs String Confusion
```dockerfile
# ❌ This is shell form (despite brackets in comments)
CMD /go/bin/app --port 8080

# ✅ This is exec form (proper JSON array)
CMD ["/go/bin/app", "--port", "8080"]
```

### 3. Ignoring Signal Handling
Always test that your application receives and handles signals properly:

```bash
# Test graceful shutdown
$ timeout 10s docker run --rm your-image
# Should see graceful shutdown, not forced termination
```

## References

- [Dockerfile Best Practices](https://docs.docker.com/develop/dev-best-practices/dockerfile_best-practices/)
- [Docker CMD vs ENTRYPOINT](https://docs.docker.com/engine/reference/builder/#cmd)
- [Process Signal Handling in Containers](https://engineering.pipefy.com/2021/07/30/1-docker-bits-shell-vs-exec/)
