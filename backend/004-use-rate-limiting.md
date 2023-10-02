# Use rate limiting 


## Statue

`draft`

## Context

Rate limiting is part of the resiliency toolkit. Without rate limiting, clients can make unlimited requests, causing a DDOS attack and bringing down the server.

However, rate limiting is not only applicable to throttling requests. We can also use it to limit any kinds of units such as GMV, no of transaction, weight, size in bytes, duration.


Not all rate limiting are counter based. Some are more rate based, that is they allow operations to be done with specific interval. Leaky bucket is an example of such rate limit algorithm.

### Min interval between request

If we make 5 requests per second, we can keep the rate constant by calling each request with 200ms interval. Instead of 200ms, we can also make it 100ms min interval. So it is possible to finish an operation earlier, while not burdening the system.

We can also use jitter.

### Controlled vs uncontrolled

For some operations, we have full control over the requests. For example, if you are building an app that makes API calls to Github using a token that is rate limited.
It is possible to keep the request rate constant.

However, API calls rate are not constant. For such scenario, we can just specify the min gap between requests.
## Decisions


## Consequences
