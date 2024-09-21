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

Additionally, since the evaluation is done every interval, we can batch the errors count in-memory and publish it periodically instead.

We can just use prometheus and also use gauge to indicate the circuit is broken. Everytime an error circuit unavailable due to circuit breaker error occur, we can just measure it.

### Leader style circuit breaker

Is there a need to complicate process and collect the aggregate counts to decide if a circuit breaker should be open?

Nope, if a system fails, the error counts will already accumulate on every instance. We don't need to wait for the aggregate result.

We can instead just gather the circuitbreaker data locally, but then set the state to redis. For example, the flow now becomes


1. check the local state, either open or closed. return if open and timeout haven't expire 
2. if expire, check redis store dor circuitbreaker state. It can be either open or nil, representing the close state after the timeout expires
3. if open, sync the state locally and set the timeout
4. in other words, if the state mismatch, update the local state to follow the remote state
5. if closed, just increment the counter
6. if threshold acquired, acquire a lock, e.g. setnx key that expires in the open period.
7. we can increment the counter in sliding log too, for every timeout we have. we can use this to exponentially increase the timeout

with this implementation, we dont care about the complicated state transition.


```
ttl = get ttl remote
if ttl > 0 then return err unavailable end


  err = work()
  if err then increment count end
  if count >= threshold and error rate > percentage then
    acquire lock
    setnx key random expiry
  end
```


## Sync nodes

When working with distributed circuit breaker, we don't need to sync the counts between each nodes. Instead, if one node fails, we can just publish the changes to all nodes.

When starting the circuit breakers, each node will subscribe to a channel. When one of the node fails, we just publish the state change.
Then each node will keep track and set the state to open, and handle recovery by itself.

This reduces number of execution drastically.


## Timeout and error weights

When calculating error rate, we usually treat each error as 1 count.

However, in practice, errors should be treated differently. E.g, a 5xx errors might indicate that the service is already down, and so we want the circuitbreaker to trip faster instead of waiting for it to reach the `failureThreshold`.

Another possible scenario is errors due to timeout. E.g. we might sample errors at per minute rate. If we have a service that responds with error after timeout of 30s, the circuitbreaker might already have reset before we hit the `failureThreshold`. Thus, the circuitbreaker will never open. Instead, we should assign more weight to timeout errors.

## Slow call 

Slow call are not timeout errors. Usually slow calls are an early indicator of services failing, so this should be penalize too. We can add the slow call score as part of the failure score, but with a different weight.

For example, we can set the score dynamically based on the duration:

```
every 5s score increases by 1
5s = 1 token
60s = 12 tokens
```

## Error budget

We follow the SRE guide and use error budgets instead of treating each failure or success as a count.

In other words, when defining thresholds, we use the term budget.

So for example the failure threhold has a budget of 100 per minute.

- a slow call consumes one token every 5s
- a normal error consumes one token (similar to count)
- an internal server error consumes 10 token (since its a known error)
- a timeout error consumes 10 token (the service is not responding anyway) plus the number of toekns from the slow call

If the tokens consumed exceeds the budget, the circuit becomes open.

```
tokens = errorToken(error) + durationToken(duration)
tokens <= budget
```

https://brooker.co.za/blog/2022/02/16/circuit-breakers.html
https://dl.acm.org/doi/pdf/10.1145/3542929.3563466

