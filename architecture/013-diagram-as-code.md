# Diagram as Code

## Status

`accepted`

## Context

We want to adopt diagram-as-code tools such as Mermaid.js to maintain architectural documentation that stays in sync with our codebase. Traditional diagramming tools create static artifacts that quickly become outdated and disconnected from the actual implementation.

Diagram-as-code provides version control, code review capabilities, and automatic rendering in documentation platforms. This approach enables living documentation that evolves with the system.

## Decision

Use Mermaid.js as the primary diagram-as-code tool for architectural documentation, with PlantUML as a secondary option for complex UML diagrams.

### Sequence Diagrams

Use sequence diagrams to document API interactions, system flows, and time-based processes:

```mermaid
sequenceDiagram
    participant Client
    participant API as API Gateway
    participant Auth as Auth Service
    participant DB as Database
    participant Cache as Redis Cache
    
    Client->>+API: POST /api/auth/login
    API->>+Auth: ValidateCredentials(email, password)
    Auth->>+DB: SELECT user WHERE email = ?
    DB-->>-Auth: User record
    Auth->>Auth: bcrypt.Compare(password, hash)
    Auth->>+Cache: SET session:uuid, user_id, TTL=24h
    Cache-->>-Auth: OK
    Auth-->>-API: LoginResponse{token, user}
    API-->>-Client: 200 OK {token, user}
    
    Note over Client,Cache: Successful authentication flow
```

### Cron Job Workflows

Document scheduled job execution patterns:

```mermaid
sequenceDiagram
    participant Scheduler
    participant Leader as Leader Election
    participant Job as Job Handler
    participant DB as Database
    participant Queue as Message Queue
    
    Note over Scheduler,Queue: Daily Leaderboard Update
    
    Scheduler->>+Leader: AcquireLock("leaderboard-update")
    Leader->>Leader: SET lock IF NOT EXISTS
    Leader-->>-Scheduler: Lock acquired
    
    Scheduler->>+Job: ExecuteLeaderboardUpdate()
    Job->>+DB: BEGIN TRANSACTION
    Job->>DB: UPDATE user_rankings SET rank = ...
    Job->>DB: UPDATE user_levels SET level = ...
    Job->>DB: INSERT INTO leaderboard_history
    Job->>DB: COMMIT TRANSACTION
    DB-->>-Job: Success
    
    Job->>+Queue: PublishEvent("leaderboard.updated")
    Queue-->>-Job: Event published
    Job-->>-Scheduler: Job completed
    
    Scheduler->>Leader: ReleaseLock("leaderboard-update")
```

### System Architecture Diagrams

Visualize high-level system components and their relationships:

```mermaid
graph TB
    subgraph "Client Layer"
        Web[Web App]
        Mobile[Mobile App]
        CLI[CLI Tool]
    end
    
    subgraph "API Gateway"
        Gateway[Kong/Nginx]
        LB[Load Balancer]
    end
    
    subgraph "Services"
        Auth[Auth Service]
        User[User Service]
        Order[Order Service]
        Payment[Payment Service]
        Notification[Notification Service]
    end
    
    subgraph "Data Layer"
        PG[(PostgreSQL)]
        Redis[(Redis)]
        S3[(S3 Storage)]
    end
    
    subgraph "Infrastructure"
        Queue[Message Queue]
        Monitor[Monitoring]
        Logger[Logging]
    end
    
    Web --> Gateway
    Mobile --> Gateway
    CLI --> Gateway
    
    Gateway --> Auth
    Gateway --> User
    Gateway --> Order
    Gateway --> Payment
    
    Auth --> PG
    User --> PG
    Order --> PG
    Payment --> PG
    
    Auth --> Redis
    User --> Redis
    
    Order --> Queue
    Payment --> Queue
    Queue --> Notification
    
    Notification --> S3
    
    Services --> Monitor
    Services --> Logger
```

### Use Case Flow Diagrams

Document complex business logic with decision points:

```mermaid
---
title: E-commerce Order Processing
---
%%{init: {'theme': 'default', 'themeVariables': {'darkMode': false}, "flowchart" : { "curve" : "stepAfter" } } }%%
flowchart TD
    Start([Order Request])
    ValidateCart{Valid Cart?}
    CheckInventory[Check Inventory]
    InStock{Items Available?}
    ReserveItems[Reserve Items]
    ProcessPayment[Process Payment]
    PaymentSuccess{Payment OK?}
    CreateOrder[Create Order]
    SendConfirmation[Send Confirmation]
    ReleaseReservation[Release Reservation]
    NotifyCustomer[Notify Customer]
    End([Order Complete])
    Error([Order Failed])
    
    Start --> ValidateCart
    ValidateCart -->|Yes| CheckInventory
    ValidateCart -->|No| Error
    
    CheckInventory --> InStock
    InStock -->|Yes| ReserveItems
    InStock -->|No| NotifyCustomer
    
    ReserveItems --> ProcessPayment
    ProcessPayment --> PaymentSuccess
    
    PaymentSuccess -->|Yes| CreateOrder
    PaymentSuccess -->|No| ReleaseReservation
    
    CreateOrder --> SendConfirmation
    SendConfirmation --> End
    
    ReleaseReservation --> NotifyCustomer
    NotifyCustomer --> Error
    
    style Start fill:#90EE90
    style End fill:#90EE90
    style Error fill:#FFB6C1
    style PaymentSuccess fill:#FFE4B5
    style InStock fill:#FFE4B5
```

### Database Entity Relationships

Document data models with entity relationship diagrams:

```mermaid
erDiagram
    User {
        uuid id PK
        string email UK
        string password_hash
        string first_name
        string last_name
        timestamp created_at
        timestamp updated_at
    }
    
    Order {
        uuid id PK
        uuid user_id FK
        string status
        decimal total_amount
        timestamp created_at
        timestamp updated_at
    }
    
    OrderItem {
        uuid id PK
        uuid order_id FK
        uuid product_id FK
        int quantity
        decimal unit_price
        decimal total_price
    }
    
    Product {
        uuid id PK
        string name
        string description
        decimal price
        int stock_quantity
        timestamp created_at
        timestamp updated_at
    }
    
    User ||--o{ Order : "places"
    Order ||--o{ OrderItem : "contains"
    Product ||--o{ OrderItem : "ordered as"
```

### State Machine Diagrams

Visualize entity state transitions:

```mermaid
stateDiagram-v2
    [*] --> Pending : Create Order
    
    Pending --> Confirmed : Payment Success
    Pending --> Cancelled : Payment Failed
    Pending --> Cancelled : User Cancellation
    
    Confirmed --> Processing : Start Fulfillment
    Confirmed --> Cancelled : Inventory Unavailable
    
    Processing --> Shipped : Items Dispatched
    Processing --> Cancelled : Fulfillment Failed
    
    Shipped --> Delivered : Customer Received
    Shipped --> Returned : Return Initiated
    
    Delivered --> Returned : Return Requested
    Delivered --> [*] : Order Complete
    
    Cancelled --> [*] : Refund Processed
    Returned --> [*] : Return Processed
    
    note right of Pending : Payment validation\nInventory check
    note right of Processing : Pick, pack, ship
    note right of Delivered : Customer satisfaction
```

### Documentation Integration

Embed diagrams in documentation with automated generation:

```yaml
# .github/workflows/docs.yml
name: Generate Documentation
on:
  push:
    branches: [main]
    paths: ['docs/**/*.md']

jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18'
          
      - name: Install Mermaid CLI
        run: npm install -g @mermaid-js/mermaid-cli
        
      - name: Generate diagrams
        run: |
          find docs -name "*.md" -exec grep -l "```mermaid" {} \; | \
          xargs mmdc --input {} --output diagrams/
          
      - name: Deploy to GitHub Pages
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs
```

### Best Practices

#### Naming Conventions

Use consistent naming for diagram elements:

```mermaid
graph LR
    %% Services: PascalCase
    UserService[User Service]
    OrderService[Order Service]
    
    %% Databases: ALL_CAPS with icon
    USER_DB[(User Database)]
    ORDER_DB[(Order Database)]
    
    %% External systems: Prefix with "Ext"
    ExtPayment[Ext: Payment Gateway]
    ExtEmail[Ext: Email Service]
    
    %% Actors: Title Case
    Customer[Customer]
    Admin[Admin User]
```

#### Color Coding

Apply consistent colors for different component types:

```mermaid
graph TB
    Client[Client App]
    API[API Gateway]
    Service[Microservice]
    DB[(Database)]
    Queue[Message Queue]
    Cache[Cache]
    
    %% Color definitions
    classDef client fill:#e1f5fe
    classDef api fill:#f3e5f5
    classDef service fill:#e8f5e8
    classDef database fill:#fff3e0
    classDef queue fill:#fce4ec
    classDef cache fill:#f1f8e9
    
    class Client client
    class API api
    class Service service
    class DB database
    class Queue queue
    class Cache cache
```

#### Version Control

Track diagram changes with meaningful commit messages:

```bash
# Good commit messages for diagram changes
git commit -m "docs: add user registration sequence diagram"
git commit -m "arch: update microservices architecture diagram with new payment service"
git commit -m "flow: revise order processing flowchart based on new requirements"
```

## Consequences

### Positive

- **Version Control**: Diagrams are versioned alongside code changes
- **Code Review**: Architectural changes can be reviewed through pull requests
- **Living Documentation**: Diagrams stay current with system evolution
- **Consistency**: Standardized notation and styling across all diagrams
- **Automation**: Diagrams can be automatically generated and validated
- **Accessibility**: Text-based diagrams are searchable and accessible

### Negative

- **Learning Curve**: Team members need to learn diagram syntax
- **Tool Limitations**: Some complex diagrams may require specialized tools
- **Rendering Dependencies**: Requires proper tooling for diagram visualization
- **Syntax Errors**: Malformed diagram syntax can break documentation builds

## Anti-patterns

- **Overly Complex Diagrams**: Trying to show too much detail in a single diagram
- **Inconsistent Styling**: Using different colors, shapes, or naming conventions
- **Outdated Diagrams**: Not updating diagrams when system changes
- **No Context**: Diagrams without explanatory text or decision rationale
- **Wrong Diagram Type**: Using sequence diagrams for static relationships
