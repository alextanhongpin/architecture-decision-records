# Thundering Herd

How to deal with thundering herd?

Does request-coalescing help?

Not really.

Load shedding

## Thundering Herd

Thundering herd is a problem that occurs when a large number of clients are waiting for a resource to become available. When the resource becomes available, all the clients are notified at the same time. This causes a spike in the load on the server.

The problem is that only one client can acquire the resource. The rest of the clients will have to wait. This causes a lot of contention and can lead to performance degradation.

## Request Coalescing

Request coalescing is a technique that can help reduce the impact of thundering herd. The idea is to combine multiple requests into a single request. This reduces the number of requests that the server has to process.

For example, if multiple clients are waiting for the same resource, the server can combine all the requests into a single request. This reduces the contention on the server and can improve performance.

However, request coalescing is not a silver bullet. It can help reduce the impact of thundering herd, but it is not a complete solution. There are other techniques that can be used to deal with thundering herd.


## Load Shedding

The naive way is to just use redis publish-subscribe to update the percentage of requests to drop. This have to be executed manually.


A more advanced way is to assign a priority to each request. The priority is based on the time the request was received. The request with the highest priority will be dropped first.

We can use the approach used by netflix to implement this. Netflix uses a cubic curve to determine with priority to drop.


Below is the cubic function:
$$fn(x) = -\frac{1}{10000}x^{3\ }+\ 100$$

Where $x$ is the load percentage. The output is the priority to drop.

It starts from 0 (highest priority) to 100 (lowest priority). When the load is 0, the priority is 100. When the load is 100%, the priority is 0 (all requests).

## Select Traffic

We can also selectively allow only a subset of users to make requests when the load is too high.

For example, we can hash the id of the users and get the modulo of 100. Then we can target the percentage of users to rollout to.

We can gradually increase the load from 0 to 100% this way. This can be done in a gradual way, e,g ramping up traffic over 30s, similar like nginx slow start module https://docs.nginx.com/nginx/admin-guide/load-balancer/http-load-balancer/#:~:text=The%20server%20slow%E2%80%91start%20feature,be%20marked%20as%20failed%20again.&text=The%20time%20value%20(here%2C%2030,server%20to%20the%20full%20value.

Other way of segmenting includes allowing only paid users to make requests first, but this depends heavily on the domain (e.g. if all users must be paid, then it is pointless).

## Stateful client

If thundering herd is caused by retries, we can signal the client never to retry again. This however is not easy to implement or is failure prone. 

For exapmple, we can signal only certain status code to be retryable:

- 408 Request Timeout
- 425 Too Early
- 429 Too Many Requests (don't retry)
- 500 Internal Server Error (don't retry too?...)
- 502 Bad Gateway
- 503 Service Unavailable
- 504 Gateway Timeout

When the server is down, we may signal the status 429 to selected clients upon restarting to terminate the retries permanently.

## Rate Limiting 

Rate limit is one of the easiest way to regulate flow.


## Throttling

You can also throttle the request

## Active queue management 

CoDel (Controlled Delay) can be used for load shedding.

## Metrics

Some useful metrics 
- in flight request count
- latency
- inflow rate
- outflow rate
- pending queue rate

How can we balance the input and output tatr
