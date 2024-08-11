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
