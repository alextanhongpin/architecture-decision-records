# Todos

healthcheck 
- for internal deps
- for external deps (microservices etc), lazily evaluated

Resiliency
- idempotency
- rate limiting
- circuit breaker
- resource allocations (by cpu/memory)
- backpressure
- throttle

Observability
- logging
  - dynamic log levels with ring buffer
- tracing
- metrics

Flow
- orchestration
- choreography
- saga
- background

API Design
- camelCase response body
- query string, params, json, csv, html encoder/decoder
- middleware
  - auth
  - request id
  - cors
  - logger
- routes
- graceful shutdown
- timeouts
- default context
- error handling with status code

