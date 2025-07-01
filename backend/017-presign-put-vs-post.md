# Presigned URLs: PUT vs POST for S3 Uploads

## Status

`accepted`

## Context

When implementing file uploads to AWS S3, we need to decide between using presigned PUT URLs or presigned POST URLs. Both approaches allow direct client-to-S3 uploads without proxying files through our backend servers, but they have different characteristics, security implications, and use cases.

The choice between PUT and POST presigned URLs affects upload flexibility, security controls, metadata handling, and client implementation complexity.

## Decision

We will use **presigned PUT URLs** for single file uploads with known filenames and **presigned POST URLs** for scenarios requiring complex upload policies, form-based uploads, or dynamic metadata.

### PUT vs POST Comparison

| Aspect | Presigned PUT | Presigned POST |
|--------|---------------|----------------|
| **HTTP Method** | PUT | POST |
| **File Size Limit** | 5GB (single part) | 5GB (single part) |
| **Content-Type** | Must be specified | Can be dynamic |
| **Filename** | Fixed in URL | Can be dynamic |
| **Metadata** | Limited control | Full control |
| **Browser Support** | Full (via fetch/XHR) | Full (via forms) |
| **Policy Complexity** | Simple | Complex |
| **Security Controls** | Basic | Advanced |
| **Use Case** | Known files | Dynamic uploads |

## Implementation

### Presigned PUT URLs

```go
package upload

import (
    "context"
    "fmt"
    "net/url"
    "time"

    "github.com/aws/aws-sdk-go-v2/aws"
    "github.com/aws/aws-sdk-go-v2/service/s3"
    "github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// PutPresigner handles presigned PUT URL generation
type PutPresigner struct {
    client *s3.Client
    bucket string
}

// NewPutPresigner creates a new PUT presigner
func NewPutPresigner(client *s3.Client, bucket string) *PutPresigner {
    return &PutPresigner{
        client: client,
        bucket: bucket,
    }
}

// PutURLRequest represents a PUT URL request
type PutURLRequest struct {
    Key         string
    ContentType string
    Expires     time.Duration
    Metadata    map[string]string
}

// PutURLResponse represents a PUT URL response
type PutURLResponse struct {
    URL     string            `json:"url"`
    Key     string            `json:"key"`
    Headers map[string]string `json:"headers"`
    Expires time.Time         `json:"expires"`
}

// GeneratePutURL generates a presigned PUT URL
func (p *PutPresigner) GeneratePutURL(ctx context.Context, req PutURLRequest) (*PutURLResponse, error) {
    // Validate request
    if req.Key == "" {
        return nil, fmt.Errorf("key is required")
    }
    if req.ContentType == "" {
        req.ContentType = "application/octet-stream"
    }
    if req.Expires == 0 {
        req.Expires = 15 * time.Minute
    }

    // Build put object input
    putObjectInput := &s3.PutObjectInput{
        Bucket:      aws.String(p.bucket),
        Key:         aws.String(req.Key),
        ContentType: aws.String(req.ContentType),
    }

    // Add metadata
    if len(req.Metadata) > 0 {
        putObjectInput.Metadata = req.Metadata
    }

    // Create presigner
    presigner := s3.NewPresignClient(p.client)

    // Generate presigned URL
    presignedReq, err := presigner.PresignPutObject(ctx, putObjectInput, func(opts *s3.PresignOptions) {
        opts.Expires = req.Expires
    })
    if err != nil {
        return nil, fmt.Errorf("failed to generate presigned URL: %w", err)
    }

    // Extract headers that must be included in the request
    headers := make(map[string]string)
    if req.ContentType != "" {
        headers["Content-Type"] = req.ContentType
    }

    return &PutURLResponse{
        URL:     presignedReq.URL,
        Key:     req.Key,
        Headers: headers,
        Expires: time.Now().Add(req.Expires),
    }, nil
}

// Example usage
func ExamplePutUpload() error {
    ctx := context.Background()
    
    // Initialize S3 client (configuration omitted for brevity)
    var s3Client *s3.Client
    
    presigner := NewPutPresigner(s3Client, "my-upload-bucket")
    
    // Generate presigned URL
    response, err := presigner.GeneratePutURL(ctx, PutURLRequest{
        Key:         "uploads/user-123/document.pdf",
        ContentType: "application/pdf",
        Expires:     30 * time.Minute,
        Metadata: map[string]string{
            "user-id":    "123",
            "upload-type": "document",
        },
    })
    if err != nil {
        return err
    }
    
    fmt.Printf("Upload URL: %s\n", response.URL)
    return nil
}
```

### Presigned POST URLs

```go
// PostPresigner handles presigned POST URL generation
type PostPresigner struct {
    client *s3.Client
    bucket string
}

// NewPostPresigner creates a new POST presigner
func NewPostPresigner(client *s3.Client, bucket string) *PostPresigner {
    return &PostPresigner{
        client: client,
        bucket: bucket,
    }
}

// PostURLRequest represents a POST URL request
type PostURLRequest struct {
    KeyPrefix      string
    ContentType    string
    MinSize        int64
    MaxSize        int64
    Expires        time.Duration
    AllowedTypes   []string
    Metadata       map[string]string
    SuccessRedirect string
}

// PostURLResponse represents a POST URL response
type PostURLResponse struct {
    URL    string            `json:"url"`
    Fields map[string]string `json:"fields"`
    Expires time.Time        `json:"expires"`
}

// GeneratePostURL generates a presigned POST URL with policy
func (p *PostPresigner) GeneratePostURL(ctx context.Context, req PostURLRequest) (*PostURLResponse, error) {
    if req.KeyPrefix == "" {
        return nil, fmt.Errorf("key prefix is required")
    }
    if req.Expires == 0 {
        req.Expires = 15 * time.Minute
    }
    if req.MaxSize == 0 {
        req.MaxSize = 10 * 1024 * 1024 // 10MB default
    }

    // Create presigner
    presigner := s3.NewPresignClient(p.client)

    // Build post object input
    postObjectInput := &s3.PutObjectInput{
        Bucket: aws.String(p.bucket),
        Key:    aws.String(req.KeyPrefix + "${filename}"), // Dynamic filename
    }

    // Create conditions for the policy
    conditions := []interface{}{
        map[string]string{"bucket": p.bucket},
        []interface{}{"starts-with", "$key", req.KeyPrefix},
        []interface{}{"content-length-range", req.MinSize, req.MaxSize},
    }

    // Add content type restrictions
    if len(req.AllowedTypes) > 0 {
        for _, contentType := range req.AllowedTypes {
            conditions = append(conditions, []interface{}{"starts-with", "$Content-Type", contentType})
        }
    }

    // Add metadata conditions
    for key, value := range req.Metadata {
        conditions = append(conditions, map[string]string{
            fmt.Sprintf("x-amz-meta-%s", key): value,
        })
    }

    // Generate presigned POST
    presignedPost, err := presigner.PresignPostObject(ctx, postObjectInput, func(opts *s3.PresignPostOptions) {
        opts.Expires = req.Expires
        // Note: Actual policy implementation would be more complex
    })
    if err != nil {
        return nil, fmt.Errorf("failed to generate presigned POST: %w", err)
    }

    return &PostURLResponse{
        URL:     presignedPost.URL,
        Fields:  presignedPost.Values,
        Expires: time.Now().Add(req.Expires),
    }, nil
}
```

### Client-Side Implementation

#### JavaScript with PUT

```javascript
// Upload using presigned PUT URL
async function uploadFilePut(file, presignedData) {
    const { url, headers } = presignedData;
    
    try {
        const response = await fetch(url, {
            method: 'PUT',
            headers: {
                'Content-Type': headers['Content-Type'] || file.type,
                ...headers
            },
            body: file
        });
        
        if (!response.ok) {
            throw new Error(`Upload failed: ${response.statusText}`);
        }
        
        return {
            success: true,
            location: response.headers.get('Location') || url.split('?')[0]
        };
    } catch (error) {
        return {
            success: false,
            error: error.message
        };
    }
}

// Usage
const fileInput = document.getElementById('file');
const file = fileInput.files[0];

// Get presigned URL from backend
const presignedResponse = await fetch('/api/upload/presign-put', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        filename: file.name,
        contentType: file.type,
        size: file.size
    })
});

const presignedData = await presignedResponse.json();
const result = await uploadFilePut(file, presignedData);
```

#### JavaScript with POST

```javascript
// Upload using presigned POST URL
async function uploadFilePost(file, presignedData) {
    const { url, fields } = presignedData;
    
    const formData = new FormData();
    
    // Add all the fields from the presigned POST
    Object.entries(fields).forEach(([key, value]) => {
        formData.append(key, value);
    });
    
    // Add the file (must be last)
    formData.append('file', file);
    
    try {
        const response = await fetch(url, {
            method: 'POST',
            body: formData
        });
        
        if (!response.ok) {
            throw new Error(`Upload failed: ${response.statusText}`);
        }
        
        return {
            success: true,
            location: response.headers.get('Location')
        };
    } catch (error) {
        return {
            success: false,
            error: error.message
        };
    }
}

// Usage with progress tracking
async function uploadWithProgress(file, presignedData, onProgress) {
    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        const formData = new FormData();
        
        // Add fields
        Object.entries(presignedData.fields).forEach(([key, value]) => {
            formData.append(key, value);
        });
        formData.append('file', file);
        
        xhr.upload.addEventListener('progress', (event) => {
            if (event.lengthComputable) {
                const percentComplete = (event.loaded / event.total) * 100;
                onProgress(percentComplete);
            }
        });
        
        xhr.addEventListener('load', () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                resolve({ success: true, response: xhr.response });
            } else {
                reject(new Error(`Upload failed: ${xhr.statusText}`));
            }
        });
        
        xhr.addEventListener('error', () => {
            reject(new Error('Upload failed'));
        });
        
        xhr.open('POST', presignedData.url);
        xhr.send(formData);
    });
}
```

### REST API Endpoints

```go
// UploadHandler handles upload-related requests
type UploadHandler struct {
    putPresigner  *PutPresigner
    postPresigner *PostPresigner
}

// GetPresignedPutURL handles PUT URL generation
func (h *UploadHandler) GetPresignedPutURL(w http.ResponseWriter, r *http.Request) {
    var req struct {
        Filename    string            `json:"filename"`
        ContentType string            `json:"contentType"`
        Size        int64             `json:"size"`
        Metadata    map[string]string `json:"metadata"`
    }
    
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "Invalid request", http.StatusBadRequest)
        return
    }
    
    // Validate file
    if err := h.validateUpload(req.Filename, req.ContentType, req.Size); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    // Generate unique key
    userID := getUserID(r) // Extract from JWT/session
    key := fmt.Sprintf("uploads/%s/%s/%s", userID, time.Now().Format("2006/01/02"), req.Filename)
    
    response, err := h.putPresigner.GeneratePutURL(r.Context(), PutURLRequest{
        Key:         key,
        ContentType: req.ContentType,
        Expires:     15 * time.Minute,
        Metadata:    req.Metadata,
    })
    if err != nil {
        http.Error(w, "Failed to generate upload URL", http.StatusInternalServerError)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(response)
}

// GetPresignedPostURL handles POST URL generation
func (h *UploadHandler) GetPresignedPostURL(w http.ResponseWriter, r *http.Request) {
    var req struct {
        MaxSize      int64    `json:"maxSize"`
        AllowedTypes []string `json:"allowedTypes"`
    }
    
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, "Invalid request", http.StatusBadRequest)
        return
    }
    
    userID := getUserID(r)
    keyPrefix := fmt.Sprintf("uploads/%s/%s/", userID, time.Now().Format("2006/01/02"))
    
    response, err := h.postPresigner.GeneratePostURL(r.Context(), PostURLRequest{
        KeyPrefix:    keyPrefix,
        MaxSize:      req.MaxSize,
        AllowedTypes: req.AllowedTypes,
        Expires:      15 * time.Minute,
    })
    if err != nil {
        http.Error(w, "Failed to generate upload URL", http.StatusInternalServerError)
        return
    }
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(response)
}

func (h *UploadHandler) validateUpload(filename, contentType string, size int64) error {
    // Check file size
    if size > 100*1024*1024 { // 100MB
        return fmt.Errorf("file too large")
    }
    
    // Check content type
    allowedTypes := []string{
        "image/jpeg", "image/png", "image/gif",
        "application/pdf", "text/plain",
    }
    
    valid := false
    for _, allowed := range allowedTypes {
        if contentType == allowed {
            valid = true
            break
        }
    }
    
    if !valid {
        return fmt.Errorf("unsupported file type: %s", contentType)
    }
    
    return nil
}

func getUserID(r *http.Request) string {
    // Extract user ID from JWT token or session
    return "user-123" // Simplified
}
```

## Use Cases

### When to Use PUT

1. **Single File Uploads**: Uploading one file at a time with known metadata
2. **Replace Existing Files**: Updating existing files with new versions
3. **Simple Scenarios**: Basic upload requirements without complex policies
4. **Mobile Apps**: Simpler implementation for mobile applications
5. **Direct Replacements**: When you need to replace a file at a specific key

### When to Use POST

1. **Form-Based Uploads**: HTML form uploads from web browsers
2. **Dynamic Filenames**: When filenames are generated client-side
3. **Complex Policies**: Advanced upload restrictions and validations
4. **Multiple Files**: Uploading multiple files with different constraints
5. **File Processing**: When you need to trigger processing after upload
6. **Browser Compatibility**: Better support for older browsers

## Security Considerations

### PUT Security

```go
// Secure PUT URL generation
func (p *PutPresigner) SecureGeneratePutURL(ctx context.Context, userID, filename string) (*PutURLResponse, error) {
    // Validate user permissions
    if !p.canUserUpload(userID) {
        return nil, fmt.Errorf("user not authorized to upload")
    }
    
    // Sanitize filename
    sanitizedFilename := sanitizeFilename(filename)
    
    // Generate secure key with user isolation
    key := fmt.Sprintf("users/%s/uploads/%s/%s", 
        userID, 
        time.Now().Format("2006/01/02"), 
        sanitizedFilename)
    
    return p.GeneratePutURL(ctx, PutURLRequest{
        Key:         key,
        ContentType: detectContentType(filename),
        Expires:     5 * time.Minute, // Short expiry
    })
}

func sanitizeFilename(filename string) string {
    // Remove path traversal attempts
    filename = filepath.Base(filename)
    // Remove dangerous characters
    re := regexp.MustCompile(`[^a-zA-Z0-9\-_\.]`)
    return re.ReplaceAllString(filename, "_")
}
```

### POST Security

```go
// Secure POST URL with comprehensive policy
func (p *PostPresigner) SecureGeneratePostURL(ctx context.Context, userID string, req PostURLRequest) (*PostURLResponse, error) {
    // Enhanced security policy
    conditions := []interface{}{
        // Bucket restriction
        map[string]string{"bucket": p.bucket},
        
        // Key prefix restriction (user isolation)
        []interface{}{"starts-with", "$key", fmt.Sprintf("users/%s/", userID)},
        
        // Size restrictions
        []interface{}{"content-length-range", 1, req.MaxSize},
        
        // Content type restrictions
        []interface{}{"starts-with", "$Content-Type", "image/"},
        
        // Prevent malicious redirects
        []interface{}{"eq", "$success_action_status", "201"},
        
        // Time-based restrictions
        map[string]string{"x-amz-date": time.Now().Format("20060102T150405Z")},
    }
    
    // Generate with conditions
    return p.generateWithConditions(ctx, conditions, req)
}
```

## Monitoring and Analytics

```go
// UploadMetrics tracks upload performance
type UploadMetrics struct {
    logger     *log.Logger
    prometheus *prometheus.Registry
}

func (m *UploadMetrics) TrackUpload(method, userID, contentType string, size int64, duration time.Duration) {
    // Log upload event
    m.logger.Info("file upload completed",
        "method", method,
        "user_id", userID,
        "content_type", contentType,
        "size_bytes", size,
        "duration_ms", duration.Milliseconds(),
    )
    
    // Update Prometheus metrics
    uploadCounter.WithLabelValues(method, contentType).Inc()
    uploadSizeHistogram.WithLabelValues(method).Observe(float64(size))
    uploadDurationHistogram.WithLabelValues(method).Observe(duration.Seconds())
}

// CloudWatch custom metrics
func (m *UploadMetrics) PublishCloudWatchMetrics(method string, size int64, success bool) {
    // Publish to CloudWatch for S3 upload analytics
    dimensions := []types.Dimension{
        {Name: aws.String("Method"), Value: aws.String(method)},
        {Name: aws.String("Success"), Value: aws.String(fmt.Sprintf("%t", success))},
    }
    
    // Publish metrics to CloudWatch
    // Implementation depends on AWS SDK setup
}
```

## Testing

```go
func TestPresignedURLs(t *testing.T) {
    // Mock S3 client for testing
    mockS3 := &mockS3Client{}
    
    t.Run("PUT URL Generation", func(t *testing.T) {
        presigner := NewPutPresigner(mockS3, "test-bucket")
        
        response, err := presigner.GeneratePutURL(context.Background(), PutURLRequest{
            Key:         "test/file.jpg",
            ContentType: "image/jpeg",
            Expires:     5 * time.Minute,
        })
        
        assert.NoError(t, err)
        assert.NotEmpty(t, response.URL)
        assert.Equal(t, "test/file.jpg", response.Key)
    })
    
    t.Run("POST URL Generation", func(t *testing.T) {
        presigner := NewPostPresigner(mockS3, "test-bucket")
        
        response, err := presigner.GeneratePostURL(context.Background(), PostURLRequest{
            KeyPrefix: "test/",
            MaxSize:   1024 * 1024,
            Expires:   5 * time.Minute,
        })
        
        assert.NoError(t, err)
        assert.NotEmpty(t, response.URL)
        assert.NotEmpty(t, response.Fields)
    })
}
```

## Benefits

1. **Direct Upload**: Files upload directly to S3, reducing server load
2. **Scalability**: No bandwidth limitations on application servers
3. **Security**: Time-limited, scoped access to S3
4. **Cost Efficiency**: Reduced data transfer costs
5. **Performance**: Faster uploads with S3's global infrastructure
6. **Flexibility**: Choose appropriate method based on use case

## Consequences

### Positive

- **Reduced Server Load**: Files don't pass through application servers
- **Better Performance**: Direct uploads to S3 are typically faster
- **Cost Savings**: Reduced bandwidth and compute costs
- **Scalability**: Can handle high upload volumes
- **Security**: Time-limited and scoped access

### Negative

- **Complexity**: More complex client-side implementation
- **Error Handling**: Need to handle S3 errors on client side
- **Validation**: Server-side validation happens after upload
- **Debugging**: More difficult to debug upload issues
- **Dependencies**: Client applications depend on S3 availability

## Best Practices

1. **Short Expiry Times**: Use minimal expiry times for security
2. **User Isolation**: Include user ID in object keys
3. **Content Validation**: Validate file types and sizes
4. **Progress Tracking**: Implement upload progress indicators
5. **Error Handling**: Provide clear error messages
6. **Monitoring**: Track upload success rates and performance
7. **Cleanup**: Implement cleanup for failed/abandoned uploads
8. **CORS Configuration**: Properly configure S3 CORS for web uploads

## References

- [AWS S3 Presigned URLs Documentation](https://docs.aws.amazon.com/AmazonS3/latest/dev/PresignedUrlUploadObject.html)
- [Differences between PUT and POST S3 signed URLs](https://advancedweb.hu/differences-between-put-and-post-s3-signed-urls/)
- [AWS S3 POST Policy Documentation](https://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectPOST.html)
