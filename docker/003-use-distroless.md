
# Use Distroless Images

## Overview

Distroless images contain only your application and its runtime dependencies. They do not contain package managers, shells, or any other programs you would expect to find in a standard Linux distribution. This makes them an excellent choice for production deployments where security and minimal attack surface are priorities.

## What are Distroless Images?

Distroless images are Google's approach to creating minimal container images that contain:
- Only your application binary
- Essential runtime dependencies (like libc, SSL certificates, timezone data)
- Minimal filesystem structure
- No shell, package manager, or debugging tools

## Benefits

### Security
- **Minimal attack surface**: No unnecessary binaries that could be exploited
- **No shell access**: Attackers cannot exec into the container
- **No package manager**: Cannot install additional software at runtime
- **Regular updates**: Google maintains base images with security patches

### Size
- **Smaller than Alpine**: Typically 2-5MB vs Alpine's ~5MB
- **Larger than scratch**: But includes essential dependencies
- **Optimized layers**: Minimal layer count for faster pulls

### Compliance
- **FIPS compliance**: Available variants for regulated environments
- **Reproducible builds**: Consistent image builds
- **Vulnerability scanning**: Minimal components to scan

## Available Distroless Images

### Base Images
- `gcr.io/distroless/static-debian11` - For static binaries (like Go)
- `gcr.io/distroless/base-debian11` - For applications needing glibc
- `gcr.io/distroless/cc-debian11` - For applications needing libgcc
- `gcr.io/distroless/java17` - For Java applications
- `gcr.io/distroless/nodejs` - For Node.js applications
- `gcr.io/distroless/python3` - For Python applications

### Debug Variants
- `gcr.io/distroless/static-debian11:debug` - Includes busybox shell
- `gcr.io/distroless/base-debian11:debug` - Includes busybox shell

## Multi-stage Build Example

```dockerfile
# Build stage
FROM golang:1.21-alpine AS builder

# Install dependencies for building
RUN apk update && apk add --no-cache git ca-certificates tzdata && update-ca-certificates

# Create non-root user for runtime
ENV USER=appuser
ENV UID=10001

# Create user (note: this is for the builder stage)
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

# Set working directory
WORKDIR /go/src/app

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download
RUN go mod verify

# Copy source code
COPY . .

# Build static binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags='-w -s -extldflags "-static"' \
    -a -installsuffix cgo \
    -o /go/bin/app \
    ./cmd/app

# Runtime stage using distroless
FROM gcr.io/distroless/static-debian11

# Copy timezone data
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# Copy SSL certificates
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy passwd file for user information
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

# Copy the binary
COPY --from=builder /go/bin/app /go/bin/app

# Use non-root user
USER appuser:appuser

# Expose port (optional, for documentation)
EXPOSE 8080

# Use exec form for proper signal handling
ENTRYPOINT ["/go/bin/app"]
```

## Choosing the Right Distroless Image

### For Go Applications
```dockerfile
# Static binary (no CGO)
FROM gcr.io/distroless/static-debian11

# With CGO dependencies
FROM gcr.io/distroless/base-debian11
```

### For Java Applications
```dockerfile
# Java 17 runtime
FROM gcr.io/distroless/java17

# Java 11 runtime
FROM gcr.io/distroless/java11

# Copy your JAR
COPY --from=builder /app/app.jar /app.jar

ENTRYPOINT ["java", "-jar", "/app.jar"]
```

### For Node.js Applications
```dockerfile
# Node.js runtime
FROM gcr.io/distroless/nodejs

# Copy your application
COPY --from=builder /app /app

WORKDIR /app

ENTRYPOINT ["node", "index.js"]
```

### For Python Applications
```dockerfile
# Python 3 runtime
FROM gcr.io/distroless/python3

# Copy your application
COPY --from=builder /app /app

WORKDIR /app

ENTRYPOINT ["python", "main.py"]
```

## Advanced Configuration

### Health Checks with Distroless
Since distroless images don't have curl or wget, implement health checks in your application:

```dockerfile
FROM gcr.io/distroless/static-debian11

COPY --from=builder /go/bin/app /app

# Health check using the application itself
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/app", "--health-check"]

ENTRYPOINT ["/app"]
```

Go application with health check support:
```go
package main

import (
    "context"
    "flag"
    "fmt"
    "log"
    "net/http"
    "os"
    "os/signal"
    "syscall"
    "time"
)

func main() {
    var (
        addr        = flag.String("addr", ":8080", "HTTP address")
        healthCheck = flag.Bool("health-check", false, "Run health check")
    )
    flag.Parse()

    // Handle health check mode
    if *healthCheck {
        if err := runHealthCheck(*addr); err != nil {
            log.Printf("Health check failed: %v", err)
            os.Exit(1)
        }
        os.Exit(0)
    }

    // Start HTTP server
    mux := http.NewServeMux()
    mux.HandleFunc("/health", handleHealth)
    mux.HandleFunc("/", handleRoot)

    server := &http.Server{
        Addr:    *addr,
        Handler: mux,
    }

    // Start server in goroutine
    go func() {
        log.Printf("Server starting on %s", *addr)
        if err := server.ListenAndServe(); err != http.ErrServerClosed {
            log.Printf("Server error: %v", err)
        }
    }()

    // Wait for interrupt signal
    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit

    log.Println("Server shutting down...")

    // Graceful shutdown
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()

    if err := server.Shutdown(ctx); err != nil {
        log.Printf("Server forced to shutdown: %v", err)
    }

    log.Println("Server exited")
}

func runHealthCheck(addr string) error {
    client := &http.Client{Timeout: 3 * time.Second}
    resp, err := client.Get(fmt.Sprintf("http://localhost%s/health", addr))
    if err != nil {
        return err
    }
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        return fmt.Errorf("health check failed with status %d", resp.StatusCode)
    }

    return nil
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    fmt.Fprintf(w, "OK")
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
    fmt.Fprintf(w, "Hello from distroless container!")
}
```

### Security Best Practices

#### Non-root User
```dockerfile
FROM gcr.io/distroless/static-debian11

# Copy passwd file with non-root user
COPY --from=builder /etc/passwd /etc/passwd

# Copy application with proper ownership
COPY --from=builder --chown=65534:65534 /go/bin/app /app

# Run as nobody user
USER 65534:65534

ENTRYPOINT ["/app"]
```

#### Read-only Filesystem
```dockerfile
FROM gcr.io/distroless/static-debian11

COPY --from=builder /go/bin/app /app

# Make filesystem read-only (configure via Docker run)
# docker run --read-only --tmpfs /tmp myapp

ENTRYPOINT ["/app"]
```

## Debugging Distroless Images

### Using Debug Variants
```dockerfile
# Development/debug version
FROM gcr.io/distroless/static-debian11:debug AS debug

COPY --from=builder /go/bin/app /app

# Includes busybox shell for debugging
ENTRYPOINT ["/app"]

# Production version
FROM gcr.io/distroless/static-debian11 AS production

COPY --from=builder /go/bin/app /app

ENTRYPOINT ["/app"]
```

Build different variants:
```bash
# Production build
docker build --target production -t myapp:prod .

# Debug build
docker build --target debug -t myapp:debug .

# Debug the debug version
docker run -it myapp:debug sh
```

### Debugging Techniques

#### Using Debug Images
```bash
# Run debug version
docker run -it myapp:debug sh

# Inside container, you can:
ps aux              # Check processes
ls -la /            # Explore filesystem
cat /etc/passwd     # Check users
netstat -tulpn      # Check network connections
```

#### Copying Files from Running Containers
```bash
# Copy files from running container
docker cp container-id:/go/bin/app ./app-debug

# Analyze the binary
file ./app-debug
ldd ./app-debug
```

#### Using Docker Exec with Debug Images
```bash
# Start container
docker run -d --name myapp-debug myapp:debug

# Exec into container
docker exec -it myapp-debug sh

# Debug your application
strace -p 1  # Trace system calls of PID 1
```

## Comparison with Other Base Images

### Size Comparison
```bash
# Build all variants
docker build --target scratch -t myapp:scratch .
docker build --target alpine -t myapp:alpine .
docker build --target distroless -t myapp:distroless .

# Compare sizes
docker images | grep myapp
# myapp   distroless   latest   8.2MB
# myapp   alpine       latest   12.1MB
# myapp   scratch      latest   5.2MB
```

### Security Comparison
| Feature | Scratch | Alpine | Distroless |
|---------|---------|--------|------------|
| Attack Surface | Minimal | Small | Minimal |
| Shell Access | None | Yes | None |
| Package Manager | None | Yes | None |
| SSL Certificates | Manual | Included | Included |
| Timezone Data | Manual | Included | Included |
| User Management | Manual | Full | Basic |

### Debugging Comparison
| Feature | Scratch | Alpine | Distroless |
|---------|---------|--------|------------|
| Shell Access | None | Yes | Debug variant only |
| System Tools | None | Full | Debug variant only |
| Package Installation | None | Yes | None |
| File Exploration | None | Yes | Debug variant only |

## Production Considerations

### CI/CD Pipeline
```yaml
# .github/workflows/docker.yml
name: Docker Build

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    
    - name: Build production image
      run: |
        docker build --target production -t myapp:${{ github.sha }} .
        
    - name: Build debug image (for testing)
      run: |
        docker build --target debug -t myapp:${{ github.sha }}-debug .
        
    - name: Test application
      run: |
        # Test with debug image for easier debugging
        docker run -d --name test-app myapp:${{ github.sha }}-debug
        sleep 5
        docker exec test-app /app --health-check
        docker logs test-app
        docker stop test-app
        
    - name: Security scan
      run: |
        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
          aquasec/trivy image myapp:${{ github.sha }}
```

### Monitoring and Logging
```dockerfile
FROM gcr.io/distroless/static-debian11

COPY --from=builder /go/bin/app /app

# Labels for monitoring
LABEL maintainer="your-team@company.com"
LABEL version="1.0.0"
LABEL description="My application running on distroless"

# Environment variables for configuration
ENV LOG_LEVEL=info
ENV METRICS_PORT=9090

ENTRYPOINT ["/app"]
```

## Migration from Other Base Images

### From Alpine
```dockerfile
# Before: Alpine
FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY app /app
ENTRYPOINT ["/app"]

# After: Distroless
FROM gcr.io/distroless/static-debian11
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /app /app
ENTRYPOINT ["/app"]
```

### From Scratch
```dockerfile
# Before: Scratch (manual setup)
FROM scratch
COPY ca-certificates.crt /etc/ssl/certs/
COPY app /app
ENTRYPOINT ["/app"]

# After: Distroless (certificates included)
FROM gcr.io/distroless/static-debian11
COPY --from=builder /app /app
ENTRYPOINT ["/app"]
```

## Best Practices

### 1. Choose the Right Base Image
- **static-debian11**: For Go applications without CGO
- **base-debian11**: For applications needing glibc
- **cc-debian11**: For applications needing libgcc

### 2. Use Multi-stage Builds
```dockerfile
# Build in full environment
FROM golang:1.21 AS builder
# Deploy to minimal environment
FROM gcr.io/distroless/static-debian11
```

### 3. Handle Debugging Needs
- Use debug variants for development
- Use production variants for deployment
- Implement health checks in your application

### 4. Security Considerations
- Always use non-root users
- Copy only necessary files
- Implement proper health checks
- Regular security scanning

### 5. Testing Strategy
- Test with debug images during development
- Deploy production images to staging
- Monitor for runtime issues

## Troubleshooting

### Common Issues

#### Binary Not Found
```bash
# Error: container_linux.go:349: starting container process caused "exec: \"/app\": 
# no such file or directory"

# Solution: Check binary architecture
file /path/to/binary
# Should match container architecture (usually linux/amd64)
```

#### Missing Dependencies
```bash
# Error: error while loading shared libraries: libc.so.6: cannot open shared object file

# Solution: Use base-debian11 instead of static-debian11
FROM gcr.io/distroless/base-debian11
```

#### Timezone Issues
```dockerfile
# Copy timezone data
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
ENV TZ=UTC
```

#### SSL Certificate Issues
```dockerfile
# Ensure certificates are copied
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
```

## Conclusion

Distroless images provide an excellent balance between security, size, and functionality. They're ideal for production deployments where you need:

- **Security**: Minimal attack surface without unnecessary tools
- **Size**: Smaller than traditional Linux distributions
- **Maintenance**: Google-maintained base images with security updates
- **Standards**: Essential runtime dependencies included

Use distroless images when you want the security benefits of scratch images but need the convenience of included runtime dependencies like SSL certificates and timezone data.
```


[^1]: https://github.com/GoogleContainerTools/distroless

