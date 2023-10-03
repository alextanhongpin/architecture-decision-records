# Use rate limiting 


## Statue

`draft`

## Context

Rate limiting is part of the microservice resiliency toolkit. Without rate limiting, clients can make potentially unlimited requests, causing a DDOS attack and bringing down the server.

However, rate limiting is not only applicable to throttling requests. We can also use it to limit any kinds of units such as GMV, no of transaction, weight, size in bytes, duration.


Not all rate limiting are counter based. Some are rate based, that is they allow operations to be done with specific interval. Leaky bucket is an example of such rate limit algorithm.


### Min interval between request

If we make 5 requests per second, we can keep the rate constant by calling each request with 200ms interval. Instead of 200ms, we can also make it 100ms min interval. So it is possible to finish an operation earlier, while not burdening the system.

We can also use jitter.

### Controlled vs uncontrolled

Rate limiting operations can be divided into two types, controlled and uncontrolled.

Controlled means you have control over the rate at which a task is done, e.g. running a loop to fetch users using Github API.

Uncontrolled is the opposite. For example, you are serving an API to end users, and users can make requests anytime.

For controlled operations, we want to _delay_ the call until the next allow at. For uncontrolled, we want to _prevent_ the call if it is before the next allow at. 

The process of delaying the call is closer to load leveling than rate limiting. 

### Load Leveling

Load leveling smoothen load by processing requests at a constant rate. Leaky bucket is one such algorithm.

One naive implementation is to just sleep before the next call:

```python
for req in requests:
  do(req)
  sleep(1)
```

### Burst

Burst allows successive requests to be made, bypassing the load-leveling mechanism.

### Throttle

For some operations, we just care about not hitting the limit, rather than processing it at a constant rate.

One such example is fraud monitoring. We want to limit the amount of daily transaction to a value imposed by the user. The transactions can be done at any time.

### Quota vs limit

Most rate limiter defines a limit, the maximum amount of calls that can be made. However, they suffer from one issue. Imagine a rate limiter that allows 5 request per second.

If a user make requests continuously at 0.9s, we will have a spike at the end of the time window.

Quota defines the number of available requests that can be made and decreases over time at the end of the time window.

At time 0.2s, user will have 4 requests remaining. At 0.8s, user will have 1 request remaining.

## Decisions

Implementing the right rate limit requires understanding the usecase.

The most naive implementation will just require:

- limit: the number of max request
- period: the time window where the limit is applied too

For more advance usecase, we can also configure the following:

- min interval: the minimum interval before each request. The maximum can be calculated using period/limit. Setting this to 0 is not recommended for high traffic application
- quota: can replace limit
- burst: allow burst request



## Consequences

Rate limiting protects your server from DDOS.
