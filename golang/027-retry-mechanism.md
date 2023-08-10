# Retry Mechanism

## Status


`draft`

## Context


Failures happens, and that could be due to intermittent errors which could be resolved by simply retrying the request at a later time.

Implementing retry mechanism is fairly simple. We can just run a for loop and sleep for a given interval before retrying a request. A jitter is usually added to sleep duration for randomness, and to ensure that the requests does not bombard the server at the same time.

However, care needs to be taken to ensure that retry process does not block other processes, especially when it needs to sleep for a longer period of time.

This ADR proposes several approach to optimizing the retry time, especially when adding jitter which could cause the total duration to be unpredictable.

## Decision



Our retry policy consists of two basic things:
- the number of retries
- the duration for each retry


For the latter, we can opt for linear retry or exponential. In linear retry, we just sleep for the same amount of time before retrying. In exponential, we double the sleep duration every time the request fails. To prevent requests hitting the servers at the same time (aka thundering herd), we add an element of randomness through jitter.


However, this leads to a very unpredictable retry total duration. If each requests is independent of each other (non-blocking, e.g. a http request that spans a new goroutine), then it should not matter. If the request is sequential, then one failed request that is retrying will block other requests, especially if the retry never succeeds due to the server being in irrecoverable state.


To fix that, we need to introduce another new variables, the `max retry timeout`.

For non-linear retry especially, the max retry timeout is unpredictable when we add in jitter. Take for example, a retry configured with the following policy:

- 5 retries max
- 100ms, 200ms, 400ms, 800ms, 1600ms

The total timeout (assuming the request fails at the end) is 3.1s without jitter.


Assuming we include jitter now, where the amount is a random amount of half the retry period. In short, if the retry period is 100ms, then the jitter amount could be anywhere from 0-50ms. If the retry period is 200ms, the jitter period can be anywhere from 0-100ms.


Consider this example where the `max retry timeout` is 1s:

- 150ms, 300ms, 500ms

Here, the total is only 950ms, which is less than the max. For this scenario, we can choose to leave it this way, or we can add the 50ms to the last request to make it exactly 1s.

What if the max is exceeded?

- 150ms, 300ms, 600ms

The same example, but totalling up to 1050ms. For this, we can simply truncate the last duration so that the max is 1s. Or, we can be less strict about it and just allow the additional 50ms.


This decision can be included by splitting the `max retry timeout` into soft and hard limit.

The `soft limit` indicates that we should stop the subsequent retry if it exceeds the 1s threshold, but still allow the timeout to overflow.

The `hard limit` restricts the total max duration.


- 150ms, 300ms, 500ms, 1150ms (total: 2100ms)

Say we have a soft limit of 1s, but hard limit of 2s. The first 3 requests only took 950ms, which means we can potentially try the last request. However, the last request violates the hard limit, so we will not include that.



## Consequences


The retry timeout becomes more predictable.
