# Distributed Store

## Status 

`draft`


## Context

Most distributed applications will have shared state.

A few examples includes circuit breaker, rate limit, cache, idempotency.


## Decisions

For packages that requires such states to be shared and synchronized, they can be placed in the `dsync` package.

A similar local implementation could be stored in `sync` package.
