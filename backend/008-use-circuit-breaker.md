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
