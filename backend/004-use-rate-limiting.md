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

### Capacity and refill rate

Another concept is that capacity and refill rate does not have to be equal. For example, if the capacity is 5 request, then the refill rate does not have to be 5req/s, or 200ms each request. It can be lower, e.g. 100ms per request as long as it doesn't hit the limit.

### Time window

A naive way to define the time window is to just divide them evenly. In reality, this will always lead to burst at the start or end of the time window.

Take for example 5 request per second. If the operation is controlled, we can just fire the request at the end of the interval, every 200ms.

However, if the operation is uncontrolled, it is possible for user to make request at the end of the first interval, and at the start of the next interval, leading to sudden burst.

A better approach is to divide the period over twice the requests, and check if the operation is done at even boundaries. For some use cases, it might not make sense, so setting a min interval between requests is simpler.

## Decisions

Implementing the right rate limit requires understanding the usecase.

The most naive implementation will just require:

- limit: the number of max request
- period: the time window where the limit is applied too

For more advance usecase, we can also configure the following:

- min interval: the minimum interval before each request. The maximum can be calculated using period/limit. Setting this to 0 is not recommended for high traffic application
- quota: can replace limit
- burst: allow burst request


## Rate Limit Header

https://datatracker.ietf.org/doc/html/rfc6585#section-4

We should only return Retry-After. We don't need to expose internal rate limiting policy to client. However, if we are serving the clients, we can return additional headers.

Most rate limit algo like leaky bucket doesnt gave a concept of remaining, it just aims to keep the flow constant.

## Rate limit rollout

Hash based, percentage rollout.

## Rate Limit Config

https://www.slashid.dev/blog/id-based-rate-limiting/

## Separate Threshold

Use a rate limit with separate rate and separate limit, e.g. 10 per second, but limit to 5 per second.

## Consequences

Rate limiting protects your server from DDOS.


