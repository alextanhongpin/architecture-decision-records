# Streaming System

## Status

`draft`

## Context

Implement a streaming system for real-time data processing and distribution.

Streaming systems are essential for:
- Real-time data processing
- Event-driven architectures
- Live data feeds
- Real-time analytics and monitoring
- Chat applications and notifications
- IoT data processing

We'll explore different approaches including Redis Streams, message queues, and WebSocket implementations.

## Decisions

### Redis Streams Implementation

Redis Streams provide a powerful abstraction for building streaming applications:

```go
type StreamProcessor struct {
    client      redis.Client
    streamName  string
    consumerGroup string
    consumerName  string
}

func NewStreamProcessor(client redis.Client, stream, group, consumer string) *StreamProcessor {
    return &StreamProcessor{
        client:       client,
        streamName:   stream,
        consumerGroup: group,
        consumerName:  consumer,
    }
}

// Producer: Add messages to stream
func (sp *StreamProcessor) Produce(ctx context.Context, data map[string]interface{}) error {
    return sp.client.XAdd(ctx, &redis.XAddArgs{
        Stream: sp.streamName,
        Values: data,
    }).Err()
}

// Consumer: Read messages from stream
func (sp *StreamProcessor) Consume(ctx context.Context) error {
    // Create consumer group if it doesn't exist
    sp.client.XGroupCreate(ctx, sp.streamName, sp.consumerGroup, "0")
    
    for {
        streams, err := sp.client.XReadGroup(ctx, &redis.XReadGroupArgs{
            Group:    sp.consumerGroup,
            Consumer: sp.consumerName,
            Streams:  []string{sp.streamName, ">"},
            Count:    10,
            Block:    time.Second,
        }).Result()
        
        if err != nil {
            if err == redis.Nil {
                continue // No messages, continue polling
            }
            return err
        }
        
        for _, stream := range streams {
            for _, message := range stream.Messages {
                if err := sp.processMessage(ctx, message); err != nil {
                    log.Printf("Error processing message %s: %v", message.ID, err)
                    continue
                }
                
                // Acknowledge message
                sp.client.XAck(ctx, sp.streamName, sp.consumerGroup, message.ID)
            }
        }
    }
}

func (sp *StreamProcessor) processMessage(ctx context.Context, msg redis.XMessage) error {
    // Process the message based on its type
    messageType, ok := msg.Values["type"].(string)
    if !ok {
        return fmt.Errorf("message missing type field")
    }
    
    switch messageType {
    case "user_action":
        return sp.handleUserAction(ctx, msg.Values)
    case "system_event":
        return sp.handleSystemEvent(ctx, msg.Values)
    default:
        return fmt.Errorf("unknown message type: %s", messageType)
    }
}
```

### WebSocket Streaming

For real-time client communication:

```go
type StreamingServer struct {
    upgrader websocket.Upgrader
    clients  map[*websocket.Conn]bool
    mutex    sync.RWMutex
    
    // Channels for different message types
    broadcast   chan []byte
    register    chan *websocket.Conn
    unregister  chan *websocket.Conn
}

func NewStreamingServer() *StreamingServer {
    return &StreamingServer{
        upgrader: websocket.Upgrader{
            CheckOrigin: func(r *http.Request) bool {
                return true // Configure properly for production
            },
        },
        clients:     make(map[*websocket.Conn]bool),
        broadcast:   make(chan []byte),
        register:    make(chan *websocket.Conn),
        unregister:  make(chan *websocket.Conn),
    }
}

func (s *StreamingServer) Run() {
    for {
        select {
        case client := <-s.register:
            s.mutex.Lock()
            s.clients[client] = true
            s.mutex.Unlock()
            log.Printf("Client connected. Total: %d", len(s.clients))
            
        case client := <-s.unregister:
            s.mutex.Lock()
            if _, ok := s.clients[client]; ok {
                delete(s.clients, client)
                client.Close()
            }
            s.mutex.Unlock()
            log.Printf("Client disconnected. Total: %d", len(s.clients))
            
        case message := <-s.broadcast:
            s.mutex.RLock()
            for client := range s.clients {
                select {
                case client.WriteMessage(websocket.TextMessage, message):
                default:
                    close(client)
                    delete(s.clients, client)
                }
            }
            s.mutex.RUnlock()
        }
    }
}

func (s *StreamingServer) HandleWebSocket(w http.ResponseWriter, r *http.Request) {
    conn, err := s.upgrader.Upgrade(w, r, nil)
    if err != nil {
        log.Printf("WebSocket upgrade failed: %v", err)
        return
    }
    
    s.register <- conn
    
    // Handle incoming messages
    go func() {
        defer func() {
            s.unregister <- conn
        }()
        
        for {
            _, message, err := conn.ReadMessage()
            if err != nil {
                break
            }
            
            // Process incoming message
            s.handleClientMessage(conn, message)
        }
    }()
}

func (s *StreamingServer) BroadcastToAll(message []byte) {
    select {
    case s.broadcast <- message:
    default:
        log.Println("Broadcast channel full, dropping message")
    }
}
```

### Event Stream Processing

Process events in real-time with windowing and aggregation:

```go
type EventProcessor struct {
    windowSize time.Duration
    events     chan Event
    windows    map[string]*Window
    mutex      sync.RWMutex
}

type Event struct {
    ID        string                 `json:"id"`
    Type      string                 `json:"type"`
    Timestamp time.Time              `json:"timestamp"`
    Data      map[string]interface{} `json:"data"`
}

type Window struct {
    Start  time.Time
    End    time.Time
    Events []Event
    Count  int
}

func NewEventProcessor(windowSize time.Duration) *EventProcessor {
    return &EventProcessor{
        windowSize: windowSize,
        events:     make(chan Event, 1000),
        windows:    make(map[string]*Window),
    }
}

func (ep *EventProcessor) ProcessEvents() {
    ticker := time.NewTicker(ep.windowSize)
    defer ticker.Stop()
    
    for {
        select {
        case event := <-ep.events:
            ep.addEventToWindow(event)
            
        case <-ticker.C:
            ep.processWindows()
        }
    }
}

func (ep *EventProcessor) addEventToWindow(event Event) {
    ep.mutex.Lock()
    defer ep.mutex.Unlock()
    
    windowKey := ep.getWindowKey(event.Timestamp)
    
    if window, exists := ep.windows[windowKey]; exists {
        window.Events = append(window.Events, event)
        window.Count++
    } else {
        start := event.Timestamp.Truncate(ep.windowSize)
        ep.windows[windowKey] = &Window{
            Start:  start,
            End:    start.Add(ep.windowSize),
            Events: []Event{event},
            Count:  1,
        }
    }
}

func (ep *EventProcessor) processWindows() {
    ep.mutex.Lock()
    defer ep.mutex.Unlock()
    
    now := time.Now()
    for key, window := range ep.windows {
        if window.End.Before(now) {
            // Process completed window
            ep.processCompletedWindow(window)
            delete(ep.windows, key)
        }
    }
}

func (ep *EventProcessor) processCompletedWindow(window *Window) {
    // Aggregate events in the window
    aggregated := make(map[string]int)
    for _, event := range window.Events {
        aggregated[event.Type]++
    }
    
    // Emit aggregated results
    result := map[string]interface{}{
        "window_start": window.Start,
        "window_end":   window.End,
        "total_events": window.Count,
        "event_types":  aggregated,
    }
    
    log.Printf("Window processed: %+v", result)
    // Send to downstream systems
}

func (ep *EventProcessor) getWindowKey(timestamp time.Time) string {
    return timestamp.Truncate(ep.windowSize).Format(time.RFC3339)
}
```

### Stream Partitioning

For horizontal scaling across multiple processors:

```go
type PartitionedStream struct {
    partitions     int
    processors     []*StreamProcessor
    partitionFunc  func(key string) int
}

func NewPartitionedStream(partitions int) *PartitionedStream {
    processors := make([]*StreamProcessor, partitions)
    for i := 0; i < partitions; i++ {
        processors[i] = NewStreamProcessor(
            redis.NewClient(&redis.Options{Addr: "localhost:6379"}),
            fmt.Sprintf("stream:%d", i),
            "consumer-group",
            fmt.Sprintf("consumer-%d", i),
        )
    }
    
    return &PartitionedStream{
        partitions: partitions,
        processors: processors,
        partitionFunc: func(key string) int {
            hash := fnv.New32a()
            hash.Write([]byte(key))
            return int(hash.Sum32()) % partitions
        },
    }
}

func (ps *PartitionedStream) Produce(ctx context.Context, key string, data map[string]interface{}) error {
    partition := ps.partitionFunc(key)
    return ps.processors[partition].Produce(ctx, data)
}

func (ps *PartitionedStream) StartConsumers(ctx context.Context) {
    for i, processor := range ps.processors {
        go func(id int, p *StreamProcessor) {
            log.Printf("Starting consumer for partition %d", id)
            if err := p.Consume(ctx); err != nil {
                log.Printf("Consumer %d error: %v", id, err)
            }
        }(i, processor)
    }
}
```

### Backpressure Handling

Manage flow control when consumers can't keep up:

```go
type BackpressureHandler struct {
    buffer     chan Event
    maxBuffer  int
    dropPolicy DropPolicy
    metrics    *Metrics
}

type DropPolicy int

const (
    DropOldest DropPolicy = iota
    DropNewest
    Block
)

func (bh *BackpressureHandler) HandleEvent(event Event) error {
    select {
    case bh.buffer <- event:
        return nil
    default:
        // Buffer is full, apply drop policy
        switch bh.dropPolicy {
        case DropOldest:
            // Remove oldest event and add new one
            select {
            case <-bh.buffer:
                bh.metrics.EventsDropped++
            default:
            }
            bh.buffer <- event
            return nil
            
        case DropNewest:
            bh.metrics.EventsDropped++
            return fmt.Errorf("event dropped due to backpressure")
            
        case Block:
            // Block until buffer has space
            bh.buffer <- event
            return nil
        }
    }
    return nil
}
```

## Consequences

### Benefits
- **Real-time processing**: Immediate handling of data as it arrives
- **Scalability**: Can handle high-throughput data streams
- **Fault tolerance**: Built-in retry and acknowledgment mechanisms
- **Flexibility**: Support for different consumption patterns

### Challenges
- **Complexity**: More sophisticated error handling and monitoring required
- **Resource management**: Memory usage can grow with unprocessed messages
- **Ordering guarantees**: Ensuring message order across partitions
- **Exactly-once processing**: Avoiding duplicate processing

### Best Practices
- Implement proper error handling and retry logic
- Monitor consumer lag and processing rates
- Use partitioning for scalability
- Implement circuit breakers for downstream dependencies
- Plan for schema evolution in stream data
- Set appropriate buffer sizes and timeout values

### Monitoring
- Consumer lag metrics
- Processing throughput
- Error rates
- Memory usage
- Connection counts 
