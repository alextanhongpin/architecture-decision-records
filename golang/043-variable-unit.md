# Variable unit

## Status


`draft`

## Context

Most of the time, we use a single unit of count for most incrementing operations.

This includes, but not limited to:
- semaphore
- goroutines pool
- rate limit
- circuit breaker
- background job priority

When we start using a unit greater than 1, it adds weight to the context.

For example, when performing rate limit, instead of incrementing by one for all resources, we can increment by 10 to quickly exhaust the rate limit.

Different resources may also consume the limit at different rates. For example, every POST method may increnent the rate limit more than then GET requests 

