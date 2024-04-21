# Use Circuit Breaker


## Status

`draft`


## Context

Calls to external resources may fail. When that happens, we want to avoid stomping the server with more request (aka thundering herd).

When that happens, there are few ways to address the issue.

We can simply return an error `503 Service Unavailable` to the caller and allow them to retry later.
Alternatively, we can implement an auto-switch mechanism to switch to a different provider (e.g. when Stripe fails, switch to Paypal).


## Decisions

We decided to fail fast using a circuit breaker.


### Metrics

We need to measure how frequent did the circuit breaker opened.

Another important metric is when the circuit breaker transitioned from half-open to opened. This indicates that the service fails to recover.
When this occur over a certain threshold, we can fallback to other providers.


### Scalability

Figuring out the right threshold can be hard. It can be a fixed value or percentage based.

### Granularity


The granularity can be at service level, which means an entire endpoint. Whether to implement it at path level, it depends on the application.

### Threshold


Ideally the circuit breaker should only be opened if the service fails 100%. To guarantee that, we need to sample data in the past time window.


The classical circuit breaker only checks the threshold of error. However, there are some issues with that.


## Performance 

A circuitbreaker has 3 states, open , closed and half-open. The last state could be ignored actually, by just checking if **one** request after the timeout fails, revert it to `open` status immediately. Otherwise, just convert it to `closed` state.


A circuitbreaker function usually does three things when a requests enters:

1. evaluate: can the state move to the next one?
2. entry: if yes, init the new state
3. process: record the success and failure

and it will repeat indefinitely.

We are dealing with read and writes here, which is bad because of the fact that the read and write are separate processes and there may be a drift in the state. Take for example two requests that enters at the same time, and both reads the sane state. However, when the first request completes, the state already changed. But the second doesn't know because it reads the same value. However, the second write may end up overwriting the state of the first write.

The process above is active, since it involves both read and write. The read/write process can be bursty and we cannot limit it.

We can instead handle it passively.

Instead of checking the state for every request, we spin a separate thread to evaluate the state. This happens at every interval, e.g. 1 minute. This is similar to leaky bucket rate limiting, except we have a more consistent write.

When writing, we can also lock the process so only one write happens at the time. The only thing we write now is the change in the state. The reader also does not need to evaluate the state on the fly, but just read the final status.


Another alternative is to use alertmanager from prometheus, and sends a webhook after the query condition is hit, e.g. failure rate exceeds 90% for 1 minute. We can also increment the sleep exponentially for every webhook we received, which will expire after a while. When it recovers, then the state can be reset.
