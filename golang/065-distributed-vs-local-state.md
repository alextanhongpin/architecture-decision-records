# Distributed vs local state

When designing package, we need to be aware of the state of the package.

It can be
- distributed, which means state are shared across different instances (or different initialization of the same package on the same instance)
- local, which means states are shared locally on the same instance

This is important mostly for coordination and consistency of data.

Some problems doesn't require distributed implementation (local ratelimit/circuit breaker), some requires both (lock) and some is okay with just local state (e.g. dataloader).

For some application you can design all three solutions. But understanding them allows you to create better packages.


## Examples

Let's take an example on how to build solutions for all three different scenario.

atomic counter
1. local, use atomic primitives
2. distributed, use redis inc

locking
- local, use mutex
- distributed, use redis lock
- both: combine both mutex and distributed lock

circuitbreaker
- local, track count and status change locally
- distributed, track count and status change on redis
- both: track count locally, publish state changes to other nodes 
