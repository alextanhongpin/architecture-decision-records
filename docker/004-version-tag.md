# Docker Image Version Tagging Strategies

## Overview

Choosing the right Docker image tagging strategy is crucial for deployment reliability, rollback capabilities, and efficient CI/CD pipelines. This document explores various tagging approaches and their trade-offs to help you select the best strategy for your use case.

## Common Tagging Strategies

### 1. Semantic Versioning (SemVer)
Use semantic versioning for release-based deployments:

```bash
# Examples
myapp:1.0.0
myapp:1.2.3
myapp:2.0.0-beta.1
myapp:1.0.0-rc.1
```

**Pros:**
- Clear version progression
- Industry standard
- Easy to understand
- Good for public libraries/applications

**Cons:**
- Requires manual version management
- Not suitable for continuous deployment
- Can lead to version conflicts

### 2. Git Commit Hash
Use the Git commit SHA for exact source traceability:

```bash
# Full SHA
myapp:a1b2c3d4e5f6789012345678901234567890abcd

# Short SHA (recommended)
myapp:a1b2c3d
myapp:$(git rev-parse --short HEAD)
```

**Pros:**
- Exact source code traceability
- Automatic generation
- Unique for every commit
- Good for development/staging

**Cons:**
- Not human-readable
- No indication of compatibility
- Requires rebuild for every commit
- Storage intensive

### 3. Dependency-Based Hashing
Hash based on dependencies and Dockerfile (recommended for efficiency):

```bash
# Create hash from dependencies
HASH=$(cat go.mod go.sum Dockerfile | md5sum | cut -d' ' -f1)
myapp:deps-${HASH:0:8}
```

**Pros:**
- Only rebuild when dependencies change
- Efficient storage usage
- Automatic cache optimization
- Good for CI/CD pipelines

**Cons:**
- Requires scripting
- Hash collisions (rare)
- Source code changes don't trigger rebuild

### 4. Timestamp-Based
Use timestamps for continuous deployment:

```bash
# ISO format
myapp:2024-01-15T10-30-45Z

# Unix timestamp
myapp:$(date +%s)

# Date with build number
myapp:2024-01-15-build-123
```

**Pros:**
- Chronological ordering
- Easy to generate
- Good for continuous deployment

**Cons:**
- No source traceability
- Multiple builds per day
- Time zone issues

### 5. Branch-Based
Tag images based on Git branches:

```bash
# Branch name
myapp:main
myapp:feature-auth
myapp:release-1.2

# Branch with commit
myapp:main-a1b2c3d
myapp:develop-$(git rev-parse --short HEAD)
```

**Pros:**
- Clear environment mapping
- Easy branch-specific deployments
- Good for GitFlow workflows

**Cons:**
- Overwrites previous versions
- Not suitable for production
- Can cause deployment issues

## Recommended Multi-Tag Strategy

Use multiple tags to combine benefits of different strategies:

```dockerfile
# Dockerfile
FROM golang:1.21-alpine AS builder
# ... build steps ...

FROM gcr.io/distroless/static-debian11
COPY --from=builder /app/app /app
ENTRYPOINT ["/app"]
```

```bash
#!/bin/bash
# build-and-tag.sh

set -e

# Get version information
GIT_COMMIT=$(git rev-parse --short HEAD)
GIT_BRANCH=$(git branch --show-current)
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
VERSION=$(cat VERSION 2>/dev/null || echo "0.0.0")

# Create dependency hash
DEPS_HASH=$(cat go.mod go.sum Dockerfile | sha256sum | cut -d' ' -f1 | head -c8)

# Image name
IMAGE_NAME="myapp"

# Build image
docker build -t ${IMAGE_NAME}:build .

# Tag with multiple strategies
docker tag ${IMAGE_NAME}:build ${IMAGE_NAME}:${VERSION}
docker tag ${IMAGE_NAME}:build ${IMAGE_NAME}:${GIT_COMMIT}
docker tag ${IMAGE_NAME}:build ${IMAGE_NAME}:deps-${DEPS_HASH}
docker tag ${IMAGE_NAME}:build ${IMAGE_NAME}:${GIT_BRANCH}-${GIT_COMMIT}

# Production-specific tags
if [ "$GIT_BRANCH" = "main" ]; then
    docker tag ${IMAGE_NAME}:build ${IMAGE_NAME}:latest
    docker tag ${IMAGE_NAME}:build ${IMAGE_NAME}:stable
fi

# Add build metadata labels
docker build \
    --label "org.opencontainers.image.version=${VERSION}" \
    --label "org.opencontainers.image.revision=${GIT_COMMIT}" \
    --label "org.opencontainers.image.created=${BUILD_DATE}" \
    --label "org.opencontainers.image.source=https://github.com/user/repo" \
    --label "custom.deps-hash=${DEPS_HASH}" \
    -t ${IMAGE_NAME}:${VERSION} .

echo "Built and tagged image: ${IMAGE_NAME}:${VERSION}"
```

## Advanced Tagging Patterns

### Environment-Specific Tags
```bash
# Development
myapp:dev-${GIT_COMMIT}

# Staging  
myapp:staging-${VERSION}

# Production
myapp:prod-${VERSION}
myapp:prod-stable
```

### Feature Branch Strategy
```bash
# Feature branches
myapp:feat-auth-${GIT_COMMIT}
myapp:feat-payments-${GIT_COMMIT}

# Pull request builds
myapp:pr-123-${GIT_COMMIT}
```

### Release Candidate Strategy
```bash
# Release candidates
myapp:1.2.0-rc.1
myapp:1.2.0-rc.2

# Final release
myapp:1.2.0
myapp:1.2
myapp:1
myapp:latest
```

## CI/CD Integration

### GitHub Actions Example
```yaml
name: Build and Push Docker Image

on:
  push:
    branches: [main, develop]
    tags: ['v*']
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to Container Registry
      uses: docker/login-action@v3
      with:
        registry: ${{ env.REGISTRY }}
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - name: Generate tags and labels
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
        tags: |
          # Git commit SHA
          type=sha,prefix={{branch}}-
          
          # Branch name
          type=ref,event=branch
          
          # Semver tags
          type=semver,pattern={{version}}
          type=semver,pattern={{major}}.{{minor}}
          type=semver,pattern={{major}}
          
          # Latest tag for main branch
          type=raw,value=latest,enable={{is_default_branch}}
          
          # PR number for pull requests
          type=ref,event=pr,prefix=pr-

    - name: Generate dependency hash
      id: deps
      run: |
        DEPS_HASH=$(cat go.mod go.sum Dockerfile | sha256sum | cut -d' ' -f1 | head -c8)
        echo "hash=$DEPS_HASH" >> $GITHUB_OUTPUT

    - name: Build and push Docker image
      uses: docker/build-push-action@v5
      with:
        context: .
        push: true
        tags: |
          ${{ steps.meta.outputs.tags }}
          ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:deps-${{ steps.deps.outputs.hash }}
        labels: ${{ steps.meta.outputs.labels }}
        cache-from: type=gha
        cache-to: type=gha,mode=max
```

### GitLab CI Example
```yaml
variables:
  DOCKER_REGISTRY: "registry.gitlab.com"
  IMAGE_NAME: "$CI_PROJECT_PATH"

stages:
  - build
  - test
  - deploy

build:
  stage: build
  image: docker:24.0.5
  services:
    - docker:24.0.5-dind
  before_script:
    - echo $CI_REGISTRY_PASSWORD | docker login -u $CI_REGISTRY_USER --password-stdin $CI_REGISTRY
  script:
    # Generate dependency hash
    - DEPS_HASH=$(cat go.mod go.sum Dockerfile | sha256sum | cut -d' ' -f1 | head -c8)
    
    # Build image
    - docker build -t temp-image .
    
    # Tag with multiple strategies
    - docker tag temp-image $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
    - docker tag temp-image $CI_REGISTRY_IMAGE:$CI_COMMIT_REF_SLUG-$CI_COMMIT_SHORT_SHA
    - docker tag temp-image $CI_REGISTRY_IMAGE:deps-$DEPS_HASH
    
    # Tag latest for main branch
    - |
      if [ "$CI_COMMIT_REF_NAME" = "main" ]; then
        docker tag temp-image $CI_REGISTRY_IMAGE:latest
      fi
    
    # Push all tags
    - docker push --all-tags $CI_REGISTRY_IMAGE
  rules:
    - if: $CI_COMMIT_BRANCH
    - if: $CI_COMMIT_TAG
```

## Image Scanning and Security

### Vulnerability Scanning
```bash
#!/bin/bash
# scan-image.sh

IMAGE_TAG=$1

# Scan with Trivy
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    aquasec/trivy image $IMAGE_TAG

# Scan with Grype
grype $IMAGE_TAG

# Docker Scout (if available)
docker scout cves $IMAGE_TAG
```

### Image Signing with Cosign
```bash
#!/bin/bash
# sign-image.sh

IMAGE_TAG=$1

# Sign the image
cosign sign --key cosign.key $IMAGE_TAG

# Verify signature
cosign verify --key cosign.pub $IMAGE_TAG
```

## Tag Cleanup and Retention

### Cleanup Script
```bash
#!/bin/bash
# cleanup-tags.sh

REGISTRY="myregistry.com"
REPOSITORY="myapp"
KEEP_TAGS=10  # Keep latest 10 tags

# Get all tags
TAGS=$(docker images --format "table {{.Tag}}" ${REPOSITORY} | tail -n +2 | sort -V)

# Count tags
TAG_COUNT=$(echo "$TAGS" | wc -l)

if [ $TAG_COUNT -gt $KEEP_TAGS ]; then
    # Calculate how many to delete
    DELETE_COUNT=$((TAG_COUNT - KEEP_TAGS))
    
    # Get tags to delete (oldest first)
    TAGS_TO_DELETE=$(echo "$TAGS" | head -n $DELETE_COUNT)
    
    # Delete old tags
    for tag in $TAGS_TO_DELETE; do
        echo "Deleting ${REPOSITORY}:${tag}"
        docker rmi ${REPOSITORY}:${tag} || true
    done
fi
```

### Registry Cleanup Policies
```yaml
# Harbor cleanup policy
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-cleanup-policy
data:
  policy.yaml: |
    rules:
      - id: 1
        priority: 1
        disabled: false
        action: retain
        template: latestPushedK
        params:
          latestPushedK: 10
        tag_selectors:
          - kind: doublestar
            decoration: matches
            pattern: "**"
        scope_selectors:
          - repository:
              kind: doublestar
              decoration: repoMatches
              pattern: "**"
```

## Best Practices

### 1. Use Meaningful Tags
```bash
# ✅ Good: Descriptive and traceable
myapp:v1.2.3
myapp:main-a1b2c3d
myapp:deps-abc12345

# ❌ Bad: Vague or non-descriptive  
myapp:latest
myapp:temp
myapp:test
```

### 2. Implement Immutable Tags
```bash
# Never overwrite existing tags
# Instead of:
docker tag myapp:build myapp:v1.0.0  # Overwrites existing v1.0.0

# Use:
docker tag myapp:build myapp:v1.0.1  # New version
```

### 3. Include Metadata
```dockerfile
# Add labels for metadata
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.revision="a1b2c3d"
LABEL org.opencontainers.image.created="2024-01-15T10:30:45Z"
LABEL org.opencontainers.image.source="https://github.com/user/repo"
LABEL org.opencontainers.image.documentation="https://docs.example.com"
LABEL custom.deps-hash="abc12345"
```

### 4. Environment-Specific Strategies
```bash
# Development: Use commit hash for traceability
dev-a1b2c3d

# Staging: Use semantic version or branch
staging-v1.2.0-rc.1

# Production: Use semantic version only
v1.2.0
```

### 5. Automation and Consistency
- Automate tagging in CI/CD pipelines
- Use consistent naming conventions
- Document your tagging strategy
- Implement tag validation

## Troubleshooting

### Common Issues

#### Tag Conflicts
```bash
# Error: tag already exists
# Solution: Use unique tags or implement versioning
myapp:v1.0.0-build-${BUILD_NUMBER}
```

#### Storage Bloat
```bash
# Too many images consuming storage
# Solution: Implement cleanup policies
docker image prune -f
docker system prune -f
```

#### Deployment Confusion
```bash
# Can't determine which version is deployed
# Solution: Use descriptive tags and maintain deployment logs
kubectl get pods -o jsonpath='{.items[*].spec.containers[*].image}'
```

## Migration Strategy

### From Manual to Automated Tagging
1. **Assessment**: Audit current tagging practices
2. **Strategy Design**: Choose appropriate tagging strategy
3. **Implementation**: Update CI/CD pipelines
4. **Testing**: Validate in staging environment
5. **Rollout**: Gradual production deployment
6. **Monitoring**: Track deployment success rates

### Example Migration Script
```bash
#!/bin/bash
# migrate-tags.sh

OLD_TAG_PATTERN="myapp:latest"
NEW_TAG_PATTERN="myapp:v*"

# List current deployments
kubectl get deployments -o jsonpath='{.items[*].spec.template.spec.containers[*].image}' | \
grep $OLD_TAG_PATTERN

# Update deployment with new tag
kubectl set image deployment/myapp container=myapp:v1.0.0

# Verify deployment
kubectl rollout status deployment/myapp
```

## Conclusion

The recommended approach combines multiple tagging strategies:

1. **Development**: Use commit hash for exact traceability
2. **Dependencies**: Use hash of go.mod + go.sum + Dockerfile for efficient caching
3. **Production**: Use semantic versioning for clear release management
4. **Automation**: Implement in CI/CD for consistency

Choose your strategy based on:
- **Deployment frequency**: Continuous vs. release-based
- **Team size**: Small teams can use simpler strategies
- **Compliance requirements**: Some industries require exact traceability
- **Storage constraints**: Consider cleanup and retention policies

Remember: The best tagging strategy is one that your entire team understands and consistently applies.
