# Event-Driven Architecture

## Status 

`draft`

## Context

Event-driven architecture is a way to design loosely coupled systems.

In this ADR, we take a look at approaches on how to turn a request/reply-based system into an event-driven architecture.

We will also explore the use cases and when to choose this over request/reply systems.

The choice is not exclusive, as both architectures can coexist.

## Decisions

### Event Patterns

Event-driven systems can be implemented using several patterns, each with its own trade-offs and use cases.

### Batch Events

Batch events allow processing multiple events together, which can improve throughput and reduce the overhead of individual event processing.

**Use cases:**
- Data synchronization between systems
- Bulk operations that can be optimized
- Reducing API call frequency

**Example:**
```go
type BatchEvent struct {
    Events    []Event   `json:"events"`
    BatchID   string    `json:"batch_id"`
    Timestamp time.Time `json:"timestamp"`
}

func ProcessBatchEvents(events []Event) error {
    // Process multiple events in a single transaction
    return db.Transaction(func(tx *sql.Tx) error {
        for _, event := range events {
            if err := processEvent(tx, event); err != nil {
                return err
            }
        }
        return nil
    })
}
```

### Outbox Pattern

The outbox pattern ensures reliable event publishing by storing events in the same database transaction as the business data, then publishing them asynchronously.

**Benefits:**
- Guarantees event publication
- Maintains data consistency
- Handles system failures gracefully

**Implementation:**
```go
type OutboxEvent struct {
    ID        string    `json:"id"`
    EventType string    `json:"event_type"`
    Payload   []byte    `json:"payload"`
    CreatedAt time.Time `json:"created_at"`
    Published bool      `json:"published"`
}

func CreateOrderWithEvent(order Order) error {
    return db.Transaction(func(tx *sql.Tx) error {
        // Save business data
        if err := saveOrder(tx, order); err != nil {
            return err
        }
        
        // Save event to outbox
        event := OutboxEvent{
            ID:        uuid.New().String(),
            EventType: "order.created",
            Payload:   json.Marshal(order),
            CreatedAt: time.Now(),
        }
        return saveOutboxEvent(tx, event)
    })
}
```

### Event Notification

Instead of passing a heavy payload, send small payloads that can be serialized as the first MVP. They should contain mostly reference IDs and possibly the URLs for the consumer to call.

As the name suggests, it is meant for notifying the consumer that an event occurred, without assuming that the consumer will take action.

**Example:**
```json
{
  "event_type": "order.created",
  "order_id": "12345",
  "customer_id": "67890", 
  "timestamp": "2025-01-01T10:00:00Z",
  "api_url": "https://api.example.com/orders/12345"
}
```

### Event-Carried State Transfer

Event-carried state transfer contains a larger payload. However, passing states can have unexpected consequences, especially if the state is prone to change.

Take an order created notification, for example. We pass a payload that contains the details of the order notification. However, there could be delays in processing and publishing, and hence the status of the order could be cancelled. When that happens, there is no reason to actually send the event anymore.

For most cases, it is also better for the consumer to decide when to call the API to fetch the latest data from the publisher, instead of relying on the stale data that was sent.

**When to use:**
- When consumers need immediate access to data
- When network latency is a concern
- When the consumer system is read-heavy

**Example:**
```json
{
  "event_type": "order.created",
  "order": {
    "id": "12345",
    "customer_id": "67890",
    "items": [...],
    "total": 99.99,
    "status": "pending",
    "created_at": "2025-01-01T10:00:00Z"
  }
}
```

### CQRS (Command Query Responsibility Segregation)

CQRS separates read and write operations, allowing for different models optimized for each operation type.

**Benefits:**
- Optimized read and write models
- Better scalability
- Flexibility in data storage

**Implementation patterns:**
- Separate databases for reads and writes
- Event sourcing for writes, projections for reads
- Different APIs for commands and queries

### Event Sourcing

Event sourcing stores the state of a business entity as a sequence of state-changing events.

**Benefits:**
- Complete audit trail
- Ability to replay events
- Time-travel debugging
- Natural fit for event-driven architectures

**Challenges:**
- Complexity in event schema evolution
- Storage overhead
- Query complexity for current state

### CloudEvents

CloudEvents is a specification for describing event data in a common way, promoting interoperability between different systems.

**Standard format:**
```json
{
  "specversion": "1.0",
  "type": "com.example.order.created",
  "source": "orders-service",
  "id": "12345",
  "time": "2025-01-01T10:00:00Z",
  "datacontenttype": "application/json",
  "data": {
    "order_id": "12345",
    "customer_id": "67890"
  }
}
```

### Consumer vs Background Tasks

For most scenarios, we don't need to publish the message externally. Events can be published and consumed within the system.

**Internal events:**
- Faster processing
- Simpler infrastructure
- Better consistency guarantees

**External events:**
- Better decoupling
- Scalability across services
- Fault isolation

## Implementation Considerations

### Message Ordering

Ensure events are processed in the correct order when order matters:

```go
// Use partition keys for ordered processing
func PublishEvent(event Event) error {
    partitionKey := event.EntityID // Events for same entity go to same partition
    return messageQueue.Publish(event, partitionKey)
}
```

### Idempotency

Ensure event handlers can be safely retried:

```go
func HandleOrderCreated(event OrderCreatedEvent) error {
    // Check if already processed
    if isProcessed(event.ID) {
        return nil // Already handled, skip
    }
    
    // Process event
    if err := processOrder(event.Order); err != nil {
        return err
    }
    
    // Mark as processed
    return markProcessed(event.ID)
}
```

### Error Handling

Implement robust error handling with dead letter queues:

```go
func ProcessEvent(event Event) error {
    maxRetries := 3
    for i := 0; i < maxRetries; i++ {
        if err := handleEvent(event); err != nil {
            if i == maxRetries-1 {
                // Send to dead letter queue
                return sendToDeadLetterQueue(event, err)
            }
            // Exponential backoff
            time.Sleep(time.Duration(math.Pow(2, float64(i))) * time.Second)
            continue
        }
        return nil
    }
    return nil
}
```

## Consequences

### Benefits
- **Loose coupling**: Services can evolve independently
- **Scalability**: Events can be processed asynchronously
- **Resilience**: System continues working even if some consumers are down
- **Flexibility**: Easy to add new consumers without changing producers

### Challenges
- **Complexity**: More moving parts to manage and monitor
- **Debugging**: Harder to trace event flows across services
- **Eventual consistency**: Data may not be immediately consistent across services
- **Event schema evolution**: Changes to events can break consumers

### Anti-patterns to Avoid
- **Event as RPC**: Using events for synchronous request-response patterns
- **Event notification with large payloads**: Mixing notification and state transfer patterns
- **Shared event schemas**: Tight coupling through shared event definitions
- **Missing event versioning**: Not planning for schema evolution

### References
https://www.ben-morris.com/event-driven-architecture-and-message-design-anti-patterns-and-pitfalls/
