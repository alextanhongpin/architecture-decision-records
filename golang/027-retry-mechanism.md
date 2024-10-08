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


### Retry Options

A retry can have the following options:
- max attempt: the number of attempts allowed
- max delay: the max delay per attempt
- max duration: the max total duration for retry

```markdown
Scenario: Set max attempt
Given that I set a max attempt of 5,
When the retry keeps failing,
Then it retry 5 times,
Before ending with error max attempt.
```

```markdown
Scenario: Set max delay
Given that I set a max delay of 1s,
When a new delay is generated,
Then the delay is at most 1s.
```

### Skipping retry

Not all operations needs to be retried. For example, when the request or operation is cancelled by user (`context.Cancelled`).

### Policy

What makes a good retry? A simple and clear policy.

The retry library should be simple, with minimum the list of delays for each retry. Why is this better than generating it on the fly? 
- more performant (reduce loop cycle, as no generation needed)
- predictable delays between each retries (before jitter of course)
- configurable - you might want a policy that not necessarily be exponential, e.g. exponential in the beginning, then capped in the end

Options:
- list of delays
- max wait timeout (if you have an SLA and does not want to exceed the duration, especially when the retry includes jitter) actually just allow user to use context for this 
- use jitter: encouraged, default to normal jitter function with the delay + random(delay/2), but customisable

Hooks
- retry event, recording start, retry at time, delay and current iteration

Methods
- set jitter function: allow user to override jitter function 

constructor

- `retry = new Retry([5, 10, 15, 20, ...])`
- `retry.do(cb)`

## Retry with iterator

the retry logic is dead simple

- retry n times
- each time, the duration is exponential
- if the error is nil, return
- if the error is abortable, abort, e.g 429 too many requests
- otherwise loop until max attemptsreached


what to measure
- number of retries
- duration taken
- errors kind
What to mnimize
- number of retries should be short, butthe duration between each retries should be long

## Retry complexity

https://brooker.co.za/blog/2022/02/28/retries.html

### Retry Throttler


Read the RFC here:
https://github.com/grpc/proposal/blob/master/A6-client-retries.md

And the implementation here: 
https://github.com/grpc/grpc-go/blob/f8d98a477c22a51320d5aee8ec156cbfa60d4436/clientconn.go#L1589

Implementation by Finagle:
https://github.com/twitter/finagle/blob/develop/finagle-core/src/main/scala/com/twitter/finagle/service/RetryBudget.scala
https://finagle.github.io/blog/2016/02/08/retry-budgets/

## Consequences


The retry timeout becomes more predictable.

## Other implementation 

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"errors"
	"fmt"
	"iter"
	"time"
)

func main() {
	retry := &Retry{MaxRetries: 3}
	for i, err := range retry.Try() {
		fmt.Println("Hello, 世界", i, err)
	}
}

type Retry struct {
	MaxRetries int
	Backoff    func(int) time.Duration
}

func (r *Retry) Try() iter.Seq2[int, error] {
	return func(yield func(int, error) bool) {
		var err error
		for i := range r.MaxRetries {
			if i == r.MaxRetries-1 {
				err = errors.New("limit exceeded")
			}
			// TODO: Add throttle
			if !yield(i, err) {
				break
			}
			time.Sleep(time.Second)
		}
	}
}
```

Improved with context cancellation and custom retries

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"context"
	"errors"
	"fmt"
	"iter"
	"time"
)

func main() {
	retry := &Retry{}
	for i, err := range retry.Try(context.Background(), 3) {
		fmt.Println("Hello, 世界", i, err)
	}
}

type Retry struct {
	Backoff func(int) time.Duration
}

func (r *Retry) Try(ctx context.Context, limit int) iter.Seq2[int, error] {
	return func(yield func(int, error) bool) {
		for i := range limit + 1 {
			if i == limit {
				err := errors.New("limit exceeded")
				yield(i, err)
				return
			}

			// TODO: Add throttle
			if !yield(i, nil) {
				break
			}

			select {
			case <-time.After(time.Second):
			case <-ctx.Done():
			}
		}
	}
}
```

## Headers

```go
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/alextanhongpin/core/sync/ratelimit"
)

func main() {
	rl := ratelimit.NewTokenBucket(5, time.Minute, 3)
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		res := rl.Allow()

		reset := int(time.Now().Sub(res.ResetAt).Seconds())
		if reset < 0 {
			reset = 0
		}
		fmt.Printf("%+v\n", res)

		if !res.Allow {
			w.Header().Set("X-RateLimit-Limit", fmt.Sprintf("%d", res.Limit))
			w.Header().Set("X-RateLimit-Remaining", fmt.Sprintf("%d", res.Remaining))
			w.Header().Set("X-RateLimit-Reset", fmt.Sprintf("%d", reset))

			w.WriteHeader(http.StatusTooManyRequests)
		}

		now := time.Now()
		json.NewEncoder(w).Encode(map[string]any{
			"allow":     res.Allow,
			"t0":        now.Truncate(time.Minute),
			"ti":        now,
			"tn":        now.Truncate(time.Minute).Add(time.Minute),
			"percent":   float64(now.Sub(now.Truncate(time.Minute))) / float64(time.Minute),
			"limit":     res.Limit,
			"remaining": res.Remaining,
			"resetIn":   res.ResetAt.Sub(time.Now()).String(),
			"retryAt":   res.RetryAt.Sub(time.Now()).String(),
		})
	})

	fmt.Println("listening on :8080. press ctrl+c to cancel.")
	http.ListenAndServe(":8080", mux)
}
```

A simpler alternative is to just return the `Retry-After` header, which is in seconds.

## References

- How AWS approach this https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
