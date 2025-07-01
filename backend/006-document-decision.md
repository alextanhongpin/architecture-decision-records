# Document Decision

## Status

`accepted`

## Context

Technical decisions often don't translate directly to code and require explicit documentation to ensure team alignment and knowledge transfer. Many architectural decisions are based on abstractions rather than specific implementations, making them invisible in the codebase itself.

The challenge is to capture the reasoning, context, and trade-offs behind technical decisions in a way that:
- Survives code refactoring and language migrations
- Provides complete context beyond what code comments can offer
- Enables future teams to understand and challenge decisions
- Creates an audit trail for architectural evolution

## Decision

Implement Architecture Decision Records (ADRs) as the primary mechanism for documenting significant technical decisions. Documentation should be:
- **Version-controlled** alongside source code
- **Lightweight** and low-friction to maintain
- **Searchable** and discoverable
- **Language-agnostic** focusing on outcomes over implementation

## Implementation

### ADR Structure

Use a standardized format for all decision documents:

```markdown
# [Number]. [Title]

## Status
[Proposed | Accepted | Deprecated | Superseded]

## Context
[Problem statement and constraints]

## Decision
[What we decided and why]

## Consequences
[Positive and negative outcomes]

## Implementation
[How to implement the decision]

## Alternatives Considered
[Other options and why they were rejected]
```

### Documentation Types

**Architecture Decision Records (ADRs)**
- Major architectural choices
- Technology selection decisions
- Significant process changes
- Cross-cutting concerns

```markdown
# 001. Use Microservices Architecture

## Status
Accepted

## Context
Our monolithic application is becoming difficult to maintain and deploy...

## Decision
Adopt a microservices architecture using domain-driven design principles...
```

**Design Documents (RFCs)**
- Feature design specifications
- API design documents
- System integration plans

```markdown
# RFC-001: User Authentication System

## Summary
Design a centralized authentication system supporting multiple providers...

## Goals
- Single sign-on across all services
- Support for OAuth2 and SAML
- Scalable to 1M+ users
```

**Runbooks and Playbooks**
- Operational procedures
- Incident response guides
- Deployment instructions

```markdown
# Database Migration Playbook

## Pre-migration Checklist
- [ ] Backup database
- [ ] Test migration in staging
- [ ] Notify stakeholders
```

### File Organization

```
docs/
├── adr/                    # Architecture Decision Records
│   ├── 001-microservices.md
│   ├── 002-event-sourcing.md
│   └── README.md
├── rfc/                    # Request for Comments
│   ├── 001-auth-system.md
│   ├── 002-payment-flow.md
│   └── README.md
├── runbooks/              # Operational documentation
│   ├── deployment.md
│   ├── incident-response.md
│   └── monitoring.md
├── api/                   # API documentation
│   ├── openapi.yaml
│   └── authentication.md
└── diagrams/              # Architecture diagrams
    ├── system-overview.mmd
    └── data-flow.mmd
```

### Documentation Principles

#### 1. Co-locate with Code

Place documentation in the same repository as the source code to ensure it evolves together:

```
project-root/
├── src/
├── docs/
├── README.md
└── CHANGELOG.md
```

#### 2. Use Text-Based Formats

Prefer formats that work well with version control:

```yaml
# ✅ Good: Text-based diagram
graph TD
    A[User Request] --> B[API Gateway]
    B --> C[Auth Service]
    B --> D[Business Logic]
    
# ❌ Avoid: Binary image files
# architecture-diagram.png
```

#### 3. Immutable Decision Records

Once accepted, ADRs should not be modified. Instead:
- Mark as "Superseded" 
- Create new ADR that references the old one
- Maintain decision history

```markdown
# 001. Use REST APIs

## Status
Superseded by ADR-005

## Context
...original context...

## Decision
...original decision...

---

# 005. Adopt GraphQL APIs

## Status
Accepted

## Context
REST APIs (ADR-001) have limitations for our mobile clients...
```

### Decision Criteria Framework

#### Decision Impact Classification

**High Impact**: Affects multiple teams, hard to reverse
- Technology stack choices
- Database architecture
- Communication patterns
- Security frameworks

**Medium Impact**: Affects single team, moderate reversal cost
- Library selections
- Code organization patterns
- Testing strategies

**Low Impact**: Team-internal, easy to reverse
- Code formatting rules
- Local development tools
- Naming conventions

#### Documentation Requirements by Impact

```go
type DecisionImpact int

const (
    HighImpact DecisionImpact = iota
    MediumImpact
    LowImpact
)

type DocumentationRequirement struct {
    Impact       DecisionImpact
    RequiresADR  bool
    ReviewLevel  string
    Stakeholders []string
}

var requirements = map[DecisionImpact]DocumentationRequirement{
    HighImpact: {
        RequiresADR:  true,
        ReviewLevel:  "Architecture Review Board",
        Stakeholders: []string{"tech-leads", "architects", "product"},
    },
    MediumImpact: {
        RequiresADR:  true,
        ReviewLevel:  "Team Lead Review",
        Stakeholders: []string{"team-lead", "senior-devs"},
    },
    LowImpact: {
        RequiresADR:  false,
        ReviewLevel:  "Peer Review",
        Stakeholders: []string{"team-members"},
    },
}
```

### Templates and Examples

#### ADR Template

```markdown
# [Number]. [Descriptive Title]

## Status
[Proposed | Accepted | Deprecated | Superseded by ADR-XXX]

## Context
What is the issue that we're seeing that is motivating this decision or change?

## Decision
What is the change that we're proposing or have agreed to implement?

## Consequences
What becomes easier or more difficult to do and any risks introduced by this change?

### Positive
- Benefit 1
- Benefit 2

### Negative  
- Cost 1
- Risk 1

### Mitigation
- How we'll address negative consequences

## Implementation
Specific steps or guidelines for implementing this decision.

## Alternatives Considered
What other options did we consider and why were they not chosen?

## References
- Links to related discussions
- External documentation
- Related ADRs
```

#### Decision Log Example

```go
// decisions/log.go
package decisions

import "time"

type Decision struct {
    ID          string    `json:"id"`
    Title       string    `json:"title"`
    Status      string    `json:"status"`
    Date        time.Time `json:"date"`
    Owner       string    `json:"owner"`
    Stakeholders []string `json:"stakeholders"`
    Context     string    `json:"context"`
    Decision    string    `json:"decision"`
    Consequences string   `json:"consequences"`
    Tags        []string  `json:"tags"`
}

// Example decisions
var TechnologyDecisions = []Decision{
    {
        ID:     "ADR-001",
        Title:  "Use PostgreSQL as Primary Database",
        Status: "Accepted",
        Date:   time.Date(2024, 1, 15, 0, 0, 0, 0, time.UTC),
        Owner:  "architecture-team",
        Stakeholders: []string{"backend-team", "data-team"},
        Context: "Need reliable ACID transactions and complex queries",
        Decision: "PostgreSQL for transactional data, Redis for caching",
        Tags: []string{"database", "storage", "architecture"},
    },
}
```

### Automation and Tooling

#### ADR Generation Tool

```bash
#!/bin/bash
# scripts/new-adr.sh

ADR_DIR="docs/adr"
NEXT_NUM=$(ls ${ADR_DIR}/*.md 2>/dev/null | wc -l | xargs expr 1 +)
PADDED_NUM=$(printf "%03d" ${NEXT_NUM})

if [ -z "$1" ]; then
    echo "Usage: $0 <title>"
    echo "Example: $0 'Use Redis for Caching'"
    exit 1
fi

TITLE="$1"
FILENAME="${ADR_DIR}/${PADDED_NUM}-$(echo ${TITLE} | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g').md"

cat > "${FILENAME}" << EOF
# ${PADDED_NUM}. ${TITLE}

## Status

Proposed

## Context

[Describe the problem or opportunity]

## Decision

[Describe the decision and rationale]

## Consequences

### Positive
- 

### Negative
- 

## Implementation

[Implementation details]

## Alternatives Considered

[Alternative options]
EOF

echo "Created ${FILENAME}"
```

#### Documentation Validation

```yaml
# .github/workflows/docs-validation.yml
name: Documentation Validation

on:
  pull_request:
    paths:
      - 'docs/**'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Validate ADR Format
        run: |
          for file in docs/adr/*.md; do
            echo "Validating $file"
            
            # Check required sections exist
            if ! grep -q "## Status" "$file"; then
              echo "Missing Status section in $file"
              exit 1
            fi
            
            if ! grep -q "## Context" "$file"; then
              echo "Missing Context section in $file"
              exit 1
            fi
            
            if ! grep -q "## Decision" "$file"; then
              echo "Missing Decision section in $file"
              exit 1
            fi
          done
      
      - name: Check for Broken Links
        run: |
          # Check internal links in documentation
          find docs -name "*.md" -exec markdown-link-check {} \;
      
      - name: Validate Mermaid Diagrams
        run: |
          # Validate Mermaid syntax
          npx @mermaid-js/mermaid-cli --version
          find docs -name "*.mmd" -exec mmdc -i {} -o /tmp/output.png \;
```

### Review Process

#### Pull Request Template

```markdown
## Documentation Checklist

For changes that require documentation:

- [ ] **High Impact**: ADR created and reviewed by Architecture Review Board
- [ ] **Medium Impact**: Decision documented and reviewed by team lead  
- [ ] **API Changes**: API documentation updated
- [ ] **Process Changes**: Runbooks updated
- [ ] **Diagrams**: Updated with text-based tools (Mermaid, PlantUML)
- [ ] **Links**: All internal links verified

## Decision Impact

- [ ] High (affects multiple teams, hard to reverse)
- [ ] Medium (affects single team, moderate cost to reverse)
- [ ] Low (team-internal, easy to reverse)

## Documentation Updated

- [ ] ADR
- [ ] API docs
- [ ] Runbooks
- [ ] Architecture diagrams
- [ ] README files
```

### Migration Strategy

#### Existing Decisions Audit

```go
// tools/decision-audit/main.go
package main

import (
    "fmt"
    "os"
    "path/filepath"
    "regexp"
    "strings"
)

func main() {
    // Find potential undocumented decisions in code
    err := filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
        if err != nil {
            return err
        }
        
        if strings.HasSuffix(path, ".go") {
            content, err := os.ReadFile(path)
            if err != nil {
                return err
            }
            
            // Look for decision markers in comments
            decisionMarkers := []string{
                "TODO: Document decision",
                "FIXME: Need ADR",
                "XXX: Architecture decision",
                "DECISION:",
                "RATIONALE:",
            }
            
            for _, marker := range decisionMarkers {
                if strings.Contains(string(content), marker) {
                    fmt.Printf("Potential undocumented decision in %s\n", path)
                }
            }
        }
        
        return nil
    })
    
    if err != nil {
        fmt.Printf("Error: %v\n", err)
    }
}
```

### Knowledge Management

#### Decision Search Interface

```go
// api/decisions/handler.go
package decisions

import (
    "encoding/json"
    "net/http"
    "strings"
)

type SearchRequest struct {
    Query  string   `json:"query"`
    Tags   []string `json:"tags"`
    Status string   `json:"status"`
}

func (h *Handler) SearchDecisions(w http.ResponseWriter, r *http.Request) {
    var req SearchRequest
    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    decisions := h.repo.SearchDecisions(req.Query, req.Tags, req.Status)
    
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(decisions)
}

func (repo *Repository) SearchDecisions(query string, tags []string, status string) []Decision {
    var results []Decision
    
    for _, decision := range repo.decisions {
        // Filter by status
        if status != "" && decision.Status != status {
            continue
        }
        
        // Filter by tags
        if len(tags) > 0 && !hasAnyTag(decision.Tags, tags) {
            continue
        }
        
        // Filter by query in title or content
        if query != "" {
            searchText := strings.ToLower(decision.Title + " " + decision.Context + " " + decision.Decision)
            if !strings.Contains(searchText, strings.ToLower(query)) {
                continue
            }
        }
        
        results = append(results, decision)
    }
    
    return results
}
```

## Best Practices

### Writing Effective ADRs

1. **Start with Context**: Clearly explain the problem and constraints
2. **Be Specific**: Include concrete examples and measurements
3. **Consider Alternatives**: Document why other options were rejected
4. **Think Long-term**: Consider how the decision will age
5. **Include Stakeholders**: Identify who is affected by the decision

### Maintenance Guidelines

1. **Regular Reviews**: Quarterly review of active ADRs
2. **Decision Lifecycle**: Track from proposed → accepted → superseded
3. **Link to Implementation**: Connect decisions to actual code
4. **Update Status**: Mark outdated decisions as superseded
5. **Archive Obsolete**: Move old decisions to archive folder

## Consequences

### Positive

- **Knowledge Preservation**: Decisions survive team changes and time
- **Faster Onboarding**: New team members understand architectural choices
- **Better Decisions**: Forces thorough consideration of alternatives
- **Audit Trail**: Clear history of architectural evolution
- **Reduced Debates**: Settled decisions don't get relitigated

### Negative

- **Documentation Overhead**: Time spent writing and maintaining docs
- **Process Burden**: May slow down decision-making initially
- **Maintenance Cost**: Keeping documentation current requires discipline
- **Tool Dependencies**: Relies on team adoption and tooling

### Mitigation Strategies

- **Start Small**: Begin with high-impact decisions only
- **Provide Templates**: Reduce friction with standardized formats
- **Automate Validation**: Use CI/CD to enforce documentation standards
- **Regular Training**: Ensure team understands ADR value and process
- **Lead by Example**: Senior engineers model good documentation practices


