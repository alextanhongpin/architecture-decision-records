# JSON UI

## Status
Accepted

## Context
Creating custom user interfaces for administrative tasks, debugging, and data visualization can be time-consuming and resource-intensive. For internal tools, development environments, and debugging scenarios, a JSON-based UI approach can provide immediate value while maintaining flexibility and reducing development overhead.

## Decision
We will use JSON-based UIs for internal tooling, debugging interfaces, and administrative panels. This approach prioritizes rapid development and flexibility over polished user experience for internal-facing applications.

## Rationale

### Benefits
- **Rapid Development**: No need to design, implement, and maintain complex UI components
- **Flexibility**: Easy to modify and extend as data structures evolve
- **Debugging-Friendly**: Raw data visibility helps with troubleshooting
- **Universal**: Works across different platforms and clients
- **Searchable**: JSON content can be easily searched and filtered
- **API-First**: Encourages thinking in terms of data structures and APIs

### Use Cases
- Administrative panels
- Development and debugging tools
- API documentation and testing
- Configuration management interfaces
- Data exploration and analysis tools
- Internal dashboards and reports

## Implementation

### Basic JSON Renderer

```go
package jsonui

import (
	"encoding/json"
	"fmt"
	"html/template"
	"net/http"
	"strings"
)

// JSONUIHandler renders JSON data with a simple HTML wrapper
type JSONUIHandler struct {
	title string
}

func NewJSONUIHandler(title string) *JSONUIHandler {
	return &JSONUIHandler{title: title}
}

func (h *JSONUIHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Get data source (this would be customized based on your needs)
	data, err := h.getData(r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Check if client wants raw JSON
	if r.Header.Get("Accept") == "application/json" {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(data)
		return
	}

	// Render HTML with embedded JSON
	h.renderHTML(w, data)
}

func (h *JSONUIHandler) renderHTML(w http.ResponseWriter, data interface{}) {
	jsonData, _ := json.MarshalIndent(data, "", "  ")
	
	tmpl := `
<!DOCTYPE html>
<html>
<head>
    <title>{{.Title}}</title>
    <style>
        body { font-family: monospace; margin: 20px; }
        .json-container { 
            background: #f5f5f5; 
            padding: 20px; 
            border-radius: 5px; 
            overflow-x: auto;
        }
        pre { margin: 0; }
        .search-box { 
            margin-bottom: 20px; 
            padding: 10px; 
            width: 100%; 
            font-size: 16px;
        }
        .controls { margin-bottom: 20px; }
        button { 
            padding: 8px 16px; 
            margin-right: 10px; 
            cursor: pointer;
        }
    </style>
</head>
<body>
    <h1>{{.Title}}</h1>
    <div class="controls">
        <button onclick="expandAll()">Expand All</button>
        <button onclick="collapseAll()">Collapse All</button>
        <button onclick="copyToClipboard()">Copy JSON</button>
    </div>
    <input type="text" class="search-box" placeholder="Search JSON..." onkeyup="searchJSON(this.value)">
    <div class="json-container">
        <pre id="json-content">{{.JSON}}</pre>
    </div>
    
    <script>
        function searchJSON(query) {
            const content = document.getElementById('json-content');
            const originalText = content.textContent;
            
            if (!query) {
                content.innerHTML = originalText;
                return;
            }
            
            const regex = new RegExp(query, 'gi');
            const highlighted = originalText.replace(regex, '<mark>$&</mark>');
            content.innerHTML = highlighted;
        }
        
        function expandAll() {
            // Implementation for expanding nested JSON
            console.log('Expand all');
        }
        
        function collapseAll() {
            // Implementation for collapsing nested JSON
            console.log('Collapse all');
        }
        
        function copyToClipboard() {
            const text = document.getElementById('json-content').textContent;
            navigator.clipboard.writeText(text);
            alert('JSON copied to clipboard!');
        }
    </script>
</body>
</html>`

	t := template.Must(template.New("json-ui").Parse(tmpl))
	t.Execute(w, map[string]interface{}{
		"Title": h.title,
		"JSON":  string(jsonData),
	})
}

func (h *JSONUIHandler) getData(r *http.Request) (interface{}, error) {
	// This would be implemented based on your specific data source
	return map[string]interface{}{
		"message": "Implement getData method for your specific use case",
		"example": map[string]interface{}{
			"users": []map[string]interface{}{
				{"id": 1, "name": "Alice", "email": "alice@example.com"},
				{"id": 2, "name": "Bob", "email": "bob@example.com"},
			},
			"config": map[string]interface{}{
				"debug":   true,
				"timeout": 30,
			},
		},
	}, nil
}
```

### Table Converter Utility

```go
package jsonui

import (
	"encoding/json"
	"fmt"
	"html/template"
	"reflect"
	"strings"
)

// TableConverter converts JSON data to HTML tables
type TableConverter struct{}

func NewTableConverter() *TableConverter {
	return &TableConverter{}
}

// ConvertToTable converts JSON data to an HTML table
func (tc *TableConverter) ConvertToTable(data interface{}) (string, error) {
	v := reflect.ValueOf(data)
	
	switch v.Kind() {
	case reflect.Slice:
		return tc.convertSliceToTable(v)
	case reflect.Map:
		return tc.convertMapToTable(v)
	default:
		return tc.convertSingleValueToTable(data)
	}
}

func (tc *TableConverter) convertSliceToTable(v reflect.Value) (string, error) {
	if v.Len() == 0 {
		return "<p>No data available</p>", nil
	}
	
	var headers []string
	var rows []map[string]interface{}
	
	// Extract headers from first element
	first := v.Index(0).Interface()
	if firstMap, ok := first.(map[string]interface{}); ok {
		for key := range firstMap {
			headers = append(headers, key)
		}
		
		// Convert all elements to rows
		for i := 0; i < v.Len(); i++ {
			if rowMap, ok := v.Index(i).Interface().(map[string]interface{}); ok {
				rows = append(rows, rowMap)
			}
		}
	}
	
	return tc.renderTable(headers, rows), nil
}

func (tc *TableConverter) convertMapToTable(v reflect.Value) (string, error) {
	headers := []string{"Key", "Value"}
	var rows []map[string]interface{}
	
	for _, key := range v.MapKeys() {
		value := v.MapIndex(key)
		rows = append(rows, map[string]interface{}{
			"Key":   key.Interface(),
			"Value": value.Interface(),
		})
	}
	
	return tc.renderTable(headers, rows), nil
}

func (tc *TableConverter) convertSingleValueToTable(data interface{}) (string, error) {
	jsonData, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return "", err
	}
	
	return fmt.Sprintf("<pre>%s</pre>", string(jsonData)), nil
}

func (tc *TableConverter) renderTable(headers []string, rows []map[string]interface{}) string {
	var html strings.Builder
	
	html.WriteString(`<table style="border-collapse: collapse; width: 100%;">`)
	
	// Headers
	html.WriteString("<thead><tr>")
	for _, header := range headers {
		html.WriteString(fmt.Sprintf(`<th style="border: 1px solid #ddd; padding: 8px; background-color: #f2f2f2;">%s</th>`, header))
	}
	html.WriteString("</tr></thead>")
	
	// Rows
	html.WriteString("<tbody>")
	for _, row := range rows {
		html.WriteString("<tr>")
		for _, header := range headers {
			value := row[header]
			html.WriteString(fmt.Sprintf(`<td style="border: 1px solid #ddd; padding: 8px;">%v</td>`, value))
		}
		html.WriteString("</tr>")
	}
	html.WriteString("</tbody>")
	
	html.WriteString("</table>")
	return html.String()
}
```

### Advanced JSON UI with Filtering

```go
package jsonui

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// AdvancedJSONUIHandler provides filtering, pagination, and sorting
type AdvancedJSONUIHandler struct {
	dataSource DataSource
	title      string
}

type DataSource interface {
	GetData(filters map[string]string, offset, limit int) (interface{}, error)
	GetTotal(filters map[string]string) (int, error)
}

type FilterConfig struct {
	Page     int
	PageSize int
	Filters  map[string]string
	Sort     string
	Order    string
}

func NewAdvancedJSONUIHandler(title string, dataSource DataSource) *AdvancedJSONUIHandler {
	return &AdvancedJSONUIHandler{
		title:      title,
		dataSource: dataSource,
	}
}

func (h *AdvancedJSONUIHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	config := h.parseFilters(r.URL.Query())
	
	data, err := h.dataSource.GetData(config.Filters, config.Page*config.PageSize, config.PageSize)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	
	total, err := h.dataSource.GetTotal(config.Filters)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	
	response := map[string]interface{}{
		"data":       data,
		"pagination": map[string]interface{}{
			"page":      config.Page,
			"page_size": config.PageSize,
			"total":     total,
			"pages":     (total + config.PageSize - 1) / config.PageSize,
		},
		"filters": config.Filters,
	}
	
	if r.Header.Get("Accept") == "application/json" {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
		return
	}
	
	h.renderAdvancedHTML(w, response, config)
}

func (h *AdvancedJSONUIHandler) parseFilters(values url.Values) FilterConfig {
	config := FilterConfig{
		Page:     0,
		PageSize: 50,
		Filters:  make(map[string]string),
		Sort:     "id",
		Order:    "asc",
	}
	
	if page := values.Get("page"); page != "" {
		if p, err := strconv.Atoi(page); err == nil && p >= 0 {
			config.Page = p
		}
	}
	
	if pageSize := values.Get("page_size"); pageSize != "" {
		if ps, err := strconv.Atoi(pageSize); err == nil && ps > 0 && ps <= 1000 {
			config.PageSize = ps
		}
	}
	
	// Extract filter parameters
	for key, vals := range values {
		if len(vals) > 0 && !strings.HasPrefix(key, "_") && 
		   key != "page" && key != "page_size" && key != "sort" && key != "order" {
			config.Filters[key] = vals[0]
		}
	}
	
	if sort := values.Get("sort"); sort != "" {
		config.Sort = sort
	}
	
	if order := values.Get("order"); order == "desc" {
		config.Order = order
	}
	
	return config
}

func (h *AdvancedJSONUIHandler) renderAdvancedHTML(w http.ResponseWriter, data interface{}, config FilterConfig) {
	jsonData, _ := json.MarshalIndent(data, "", "  ")
	
	// Implementation would include a more sophisticated HTML template
	// with filter forms, pagination controls, and sorting options
	w.Header().Set("Content-Type", "text/html")
	w.Write([]byte(fmt.Sprintf(`
<!DOCTYPE html>
<html>
<head>
    <title>%s</title>
    <style>
        /* Advanced styling for filters, pagination, etc. */
        body { font-family: Arial, sans-serif; margin: 20px; }
        .filters { margin-bottom: 20px; padding: 15px; background: #f8f9fa; border-radius: 5px; }
        .filter-input { margin: 5px; padding: 5px; }
        .pagination { margin: 20px 0; }
        .pagination a { margin: 0 5px; padding: 5px 10px; text-decoration: none; border: 1px solid #ddd; }
        .pagination .current { background: #007bff; color: white; }
        .json-container { background: #f5f5f5; padding: 20px; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>%s</h1>
    
    <div class="filters">
        <h3>Filters</h3>
        <form method="GET">
            <!-- Filter inputs would be generated based on available fields -->
            <input type="text" name="search" placeholder="Search..." class="filter-input">
            <button type="submit">Apply Filters</button>
            <a href="?">Clear Filters</a>
        </form>
    </div>
    
    <div class="json-container">
        <pre>%s</pre>
    </div>
    
    <div class="pagination">
        <!-- Pagination links would be generated based on current page and total pages -->
    </div>
</body>
</html>`, h.title, h.title, string(jsonData))))
}
```

### Usage Examples

```go
package main

import (
	"net/http"
	"log"
)

func main() {
	// Basic JSON UI
	http.Handle("/admin/users", NewJSONUIHandler("User Management"))
	
	// Table converter example
	http.HandleFunc("/admin/users/table", func(w http.ResponseWriter, r *http.Request) {
		users := []map[string]interface{}{
			{"id": 1, "name": "Alice", "email": "alice@example.com", "active": true},
			{"id": 2, "name": "Bob", "email": "bob@example.com", "active": false},
		}
		
		converter := NewTableConverter()
		table, err := converter.ConvertToTable(users)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(table))
	})
	
	// Advanced JSON UI with filtering
	// http.Handle("/admin/advanced", NewAdvancedJSONUIHandler("Advanced Data", myDataSource))
	
	log.Println("Server starting on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
```

## Best Practices

### 1. Progressive Enhancement
- Start with basic JSON rendering
- Add search and filtering capabilities
- Implement table views for structured data
- Provide export functionality

### 2. Performance Considerations
- Implement pagination for large datasets
- Use server-side filtering and sorting
- Consider caching for frequently accessed data
- Lazy load nested objects

### 3. User Experience
- Provide both JSON and table views
- Include search functionality
- Add keyboard shortcuts for common actions
- Implement responsive design for mobile access

### 4. Security
- Sanitize all displayed data
- Implement proper authentication and authorization
- Filter sensitive information in production environments
- Use HTTPS for all administrative interfaces

### 5. Development Workflow
- Use JSON UI for rapid prototyping
- Generate OpenAPI documentation from JSON schemas
- Implement automated testing with JSON responses
- Version your JSON schemas for backward compatibility

## Tools and Libraries

### Go Libraries
- `encoding/json` - Standard JSON handling
- `html/template` - HTML template rendering
- `github.com/gorilla/mux` - HTTP routing
- `github.com/rs/cors` - CORS handling

### Frontend Libraries
- JSONViewer.js - Interactive JSON viewer
- DataTables - Advanced table functionality
- Prism.js - Syntax highlighting
- Chart.js - Data visualization

### Browser Extensions
- JSON Formatter - Chrome/Firefox extension
- JSONView - Safari extension
- Postman - API testing and visualization

## Migration Strategy

### From Custom UI to JSON UI
1. **Audit Current UI**: Identify components that can be simplified
2. **Create JSON Endpoints**: Expose data through clean JSON APIs
3. **Implement Basic Renderers**: Start with simple JSON display
4. **Add Progressive Features**: Implement search, filtering, and tables
5. **Gather Feedback**: Collect user feedback and iterate
6. **Optimize Performance**: Add caching and pagination as needed

### Gradual Enhancement
- Begin with read-only JSON displays
- Add basic filtering and search
- Implement CRUD operations through forms
- Integrate with existing authentication systems
- Add advanced features based on user needs

## Consequences

### Positive
- Faster development and iteration cycles
- Reduced maintenance overhead
- Better debugging and troubleshooting capabilities
- Improved API-first thinking
- Universal accessibility across platforms

### Negative
- Less polished user experience for non-technical users
- Limited UI customization options
- May not be suitable for complex workflows
- Requires technical knowledge to interpret raw data

### Mitigation
- Use JSON UI primarily for internal tools and debugging
- Provide training for non-technical users
- Implement progressive enhancement for better UX
- Consider hybrid approaches for complex use cases

## Related Patterns
- [025-json-response.md](025-json-response.md) - Standardized JSON response format
- [027-checklist.md](027-checklist.md) - Development checklist including UI considerations
- [012-use-metrics.md](012-use-metrics.md) - Monitoring and observability through JSON interfaces
