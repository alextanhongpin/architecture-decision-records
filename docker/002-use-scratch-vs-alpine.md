# Using Scratch vs Alpine Base Images

## Overview

Choosing the right base image is crucial for container security, size, and debugging capabilities. This document compares `scratch`, `alpine`, and `distroless` images to help you make informed decisions based on your specific requirements.

## Base Image Comparison

| Feature | Scratch | Alpine | Distroless | Ubuntu/Debian |
|---------|---------|--------|------------|---------------|
| Size | ~0 bytes | ~5MB | ~2MB | ~100MB+ |
| Security | Minimal attack surface | Small attack surface | Minimal attack surface | Large attack surface |
| Debugging | No tools | Full shell + tools | No shell/tools | Full toolset |
| Use Case | Static binaries | Development/Debug | Production security | Development |

## Scratch Images

`FROM scratch` is literally an empty, zero-byte image/filesystem where you add everything yourself.

### Pros
- **Minimal size**: No base layer, only your application
- **Maximum security**: No additional software or attack surface
- **Fastest startup**: No base image initialization

### Cons
- **No debugging tools**: Cannot exec into container for troubleshooting
- **No shell**: Cannot run shell commands or scripts
- **No CA certificates**: Must copy SSL certificates manually
- **No timezone data**: Must copy timezone information manually

### Example: Go Application with Scratch

```dockerfile
# Multi-stage build
FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# Build static binary (important for scratch)
RUN CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-extldflags "-static"' -o app .

# Scratch runtime
FROM scratch

# Copy CA certificates for HTTPS requests
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy timezone data if needed
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# Copy the binary
COPY --from=builder /app/app /app

# Use exec form for proper signal handling
ENTRYPOINT ["/app"]
```

## Alpine Images

Alpine Linux is a security-oriented, lightweight Linux distribution based on musl libc and busybox.

### Pros
- **Small size**: ~5MB base image
- **Package manager**: apk for installing additional tools
- **Shell access**: Full shell environment for debugging
- **Active maintenance**: Regular security updates

### Cons
- **musl libc differences**: Some applications compiled for glibc may not work
- **Limited package ecosystem**: Fewer packages compared to Ubuntu/Debian
- **DNS resolution issues**: Historical issues with musl DNS resolver

### Example: Go Application with Alpine

```dockerfile
FROM golang:1.21-alpine AS builder

# Install git and ca-certificates (often needed for go modules)
RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -o app .

# Alpine runtime
FROM alpine:latest

# Install ca-certificates and timezone data
RUN apk --no-cache add ca-certificates tzdata

# Optional: Add bash for better shell experience
RUN apk add --no-cache bash

# Create non-root user
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

WORKDIR /home/appuser

# Copy binary
COPY --from=builder /app/app .

# Change ownership
RUN chown -R appuser:appgroup /home/appuser

USER appuser

ENTRYPOINT ["./app"]
```

## Debugging Capabilities

### Scratch - No Debugging
```bash
# This will fail with scratch images
$ docker exec -it $(docker ps -q) ps -ef
# Error: OCI runtime exec failed: exec failed: unable to start container process: 
# exec: "ps": executable file not found in $PATH: unknown

$ docker exec -it $(docker ps -q) sh
# Error: exec: "sh": executable file not found in $PATH: unknown
```

### Alpine - Full Debugging
```bash
# These work with Alpine
$ docker exec -it $(docker ps -q) ps aux
$ docker exec -it $(docker ps -q) sh
$ docker exec -it $(docker ps -q) netstat -tulpn
$ docker exec -it $(docker ps -q) top
```

## Production vs Development Considerations

### Development Environment
Use Alpine for development to enable debugging:

```dockerfile
FROM alpine:latest

# Install debugging tools
RUN apk add --no-cache \
    bash \
    curl \
    htop \
    strace \
    tcpdump \
    netcat-openbsd

COPY --from=builder /app/app .

# Enable shell access
ENTRYPOINT ["./app"]
```

### Production Environment
Use scratch or distroless for maximum security:

```dockerfile
FROM scratch

# Only essential files
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /app/app /app

USER 65534:65534  # nobody user

ENTRYPOINT ["/app"]
```

## Advanced Techniques

### Debug Mode Toggle
Create different targets for development and production:

```dockerfile
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o app .

# Development target with debugging tools
FROM alpine:latest AS development
RUN apk --no-cache add ca-certificates bash curl htop strace
WORKDIR /root/
COPY --from=builder /app/app .
CMD ["./app"]

# Production target with minimal surface
FROM scratch AS production
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /app/app /app
ENTRYPOINT ["/app"]
```

Build different variants:
```bash
# Development image
docker build --target development -t myapp:dev .

# Production image  
docker build --target production -t myapp:prod .
```

### Adding Debugging to Scratch
If you must use scratch but need occasional debugging:

```dockerfile
FROM scratch AS base
COPY --from=builder /app/app /app
ENTRYPOINT ["/app"]

# Debug variant that adds busybox
FROM busybox:glibc AS debug
COPY --from=builder /app/app /app
# busybox provides basic shell and utilities
ENTRYPOINT ["/app"]
```

## Health Checks and Monitoring

### With Alpine (Easy)
```dockerfile
FROM alpine:latest
RUN apk add --no-cache curl
COPY --from=builder /app/app .

# Health check using curl
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["./app"]
```

### With Scratch (Requires Built-in Health Endpoint)
```dockerfile
FROM scratch
COPY --from=builder /app/app /app

# Health check must use the application binary itself
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/app", "--health-check"]

ENTRYPOINT ["/app"]
```

Your Go application needs to support health check mode:
```go
package main

import (
    "flag"
    "fmt"
    "net/http"
    "os"
)

func main() {
    healthCheck := flag.Bool("health-check", false, "Run health check")
    flag.Parse()

    if *healthCheck {
        resp, err := http.Get("http://localhost:8080/health")
        if err != nil || resp.StatusCode != 200 {
            os.Exit(1)
        }
        os.Exit(0)
    }

    // Normal application startup
    startServer()
}
```

## Security Considerations

### User Management
Always avoid running as root:

```dockerfile
# Alpine - create user
FROM alpine:latest
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup
USER appuser

# Scratch - use existing nobody user
FROM scratch
USER 65534:65534
```

### File Permissions
```dockerfile
# Set proper permissions
COPY --from=builder --chown=65534:65534 /app/app /app
```

## Performance Comparison

### Image Size Comparison
```bash
# Build different variants
docker build -f Dockerfile.scratch -t app:scratch .
docker build -f Dockerfile.alpine -t app:alpine .
docker build -f Dockerfile.ubuntu -t app:ubuntu .

# Compare sizes
docker images | grep app
# app    scratch    latest    5.2MB     
# app    alpine     latest    12.1MB    
# app    ubuntu     latest    156MB     
```

### Startup Time
```bash
# Measure container startup time
time docker run --rm app:scratch
time docker run --rm app:alpine
time docker run --rm app:ubuntu
```

## Best Practices

### 1. Choose Based on Environment
- **Development**: Alpine (debugging capabilities)
- **Staging**: Alpine or Distroless (balance of debugging and security)
- **Production**: Scratch or Distroless (maximum security)

### 2. Static Binary Requirements
For scratch images, ensure your binary is truly static:
```bash
# Check binary dependencies
ldd /path/to/binary
# Should output: "not a dynamic executable" for scratch compatibility
```

### 3. Multi-stage Optimization
```dockerfile
# Use larger image for building
FROM golang:1.21 AS builder
# Use minimal image for runtime
FROM scratch AS runtime
```

### 4. Security Scanning
```bash
# Scan images for vulnerabilities
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    -v $HOME/Library/Caches:/root/.cache/ \
    aquasec/trivy image app:alpine
```

## Troubleshooting

### Common Issues with Scratch
1. **Missing CA certificates**: Copy from builder stage
2. **Timezone issues**: Copy zoneinfo data
3. **DNS resolution**: Ensure static linking
4. **File not found**: Check binary architecture matches

### Debugging Scratch Images
```bash
# Debug by temporarily switching to alpine
sed 's/FROM scratch/FROM alpine:latest/' Dockerfile > Dockerfile.debug
docker build -f Dockerfile.debug -t app:debug .
docker run -it app:debug sh
```

## Conclusion

- **Use Scratch** when you need maximum security and minimal size, and you have static binaries
- **Use Alpine** when you need debugging capabilities and can accept slightly larger size
- **Use Distroless** when you want security of scratch with some basic runtime dependencies
- **Always test** your choice in your specific environment with your specific application

The key is balancing security, size, and operational requirements based on your deployment environment and debugging needs.
