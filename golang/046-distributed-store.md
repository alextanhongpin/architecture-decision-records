# Distributed Store

## Status 

`draft`


## Context

Most distributed applications will have shared state.

A few examples includes circuit breaker, rate limit, cache, idempotency.


## Decisions

For packages that requires such states to be shared and synchronized, they can be placed in the `dsync` package.

A similar local implementation could be stored in `sync` package.

Since most distributed solutions required a data store (e.g. redis, postgres, consul, etcd), the implementation will be tied to those stores.

We can for example prefix them with the store names, e.g. `pglock` or `rlock`.
