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

## Implementation 

- by frequency
- by duration
- by error rate
- by throttle
- combination

- wait: cron style, waits for the next execution. can just use for loop?
- nowait: immediately fails. this should be default implementation...


### Example: Fixed Window

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
	rl := New(10, time.Second)
	for i := range 100 {
		time.Sleep(50 * time.Millisecond)
		fmt.Println(i, rl.Remaining(), rl.Allow(), rl.Remaining(), rl.RetryAt(), time.Now())
	}
	fmt.Println("Hello, 世界")
}

func New(limit int, period time.Duration) *RateLimiter {
	return &RateLimiter{
		limit:  limit,
		period: period.Nanoseconds(),
		Now:    time.Now,
	}
}

type RateLimiter struct {
	// Config
	limit  int
	period int64
	Now    func() time.Time

	// State
	mu    sync.RWMutex
	count int
	last  int64
}

func (r *RateLimiter) Allow() bool {
	return r.AllowN(1)
}

func (r *RateLimiter) AllowN(n int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.remaining()-n >= 0 {
		r.count += n
		return true
	}
	return false
}

func (r *RateLimiter) Remaining() int {
	r.mu.RLock()
	n := r.remaining()
	r.mu.RUnlock()
	return n
}

func (r *RateLimiter) remaining() int {
	now := r.Now().UnixNano()
	if r.last+r.period <= now {
		r.last = now
		r.count = 0
	}
	return r.limit - r.count
}

func (r *RateLimiter) RetryAt() time.Time {
	if r.Remaining() > 0 {
		return r.Now()
	}

	r.mu.RLock()
	last, period := r.last, r.period
	r.mu.RUnlock()
	return time.Unix(0, last+period)
}
```

### Example: Fixed window key 

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
	k := "key"
	rl := New(10, time.Second)
	stop := rl.Clear()
	defer stop()
	for i := range 100 {
		time.Sleep(50 * time.Millisecond)
		fmt.Println(i, rl.Remaining(k), rl.Allow(k), rl.Remaining(k), rl.RetryAt(k))
	}
	k = "val"
	for i := range 11 {
		fmt.Println(i, rl.Remaining(k), rl.Allow(k), rl.Remaining(k), rl.RetryAt(k))
	}
	fmt.Println("Hello, 世界", rl)
	time.Sleep(2 * time.Second)
	fmt.Println("Hello, 世界", rl)
	time.Sleep(time.Second)
}

func New(limit int, period time.Duration) *RateLimiter {
	return &RateLimiter{
		limit:  limit,
		period: period.Nanoseconds(),
		Now:    time.Now,
		vals:   make(map[string]*State),
	}
}

type RateLimiter struct {
	// Config
	limit  int
	period int64
	Now    func() time.Time

	// State
	mu   sync.RWMutex
	vals map[string]*State
}

type State struct {
	count int
	last  int64
}

func (r *RateLimiter) Allow(key string) bool {
	return r.AllowN(key, 1)
}

func (r *RateLimiter) AllowN(key string, n int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.vals[key]; !ok {
		r.vals[key] = new(State)
	}
	if r.remaining(key)-n >= 0 {
		r.vals[key].count += n
		return true
	}
	return false
}

func (r *RateLimiter) Remaining(key string) int {
	r.mu.RLock()
	n := r.remaining(key)
	r.mu.RUnlock()
	return n
}

func (r *RateLimiter) remaining(key string) int {
	v, ok := r.vals[key]
	if !ok {
		return r.limit
	}

	now := r.Now().UnixNano()
	if v.last+r.period <= now {
		v.last = now
		v.count = 0
	}

	return r.limit - v.count
}

func (r *RateLimiter) RetryAt(key string) time.Time {
	if r.Remaining(key) > 0 {
		return r.Now()
	}

	r.mu.RLock()
	v, ok := r.vals[key]
	if !ok {
		r.mu.RUnlock()
		return r.Now()
	}
	last, period := v.last, r.period
	r.mu.RUnlock()
	return time.Unix(0, last+period)
}

func (r *RateLimiter) Clear() func() {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)

	go func() {
		defer wg.Done()

		t := time.NewTicker(time.Duration(r.period))
		defer t.Stop()

		for {
			select {
			case <-done:
				return
			case ts := <-t.C:
				now := ts.UnixNano()
				r.mu.Lock()
				for k, v := range r.vals {
					if v.last+r.period <= now {
						delete(r.vals, k)
					}
				}
				r.mu.Unlock()
			}
		}
	}()

	return sync.OnceFunc(func() {
		close(done)
		wg.Wait()
	})
}
```

## Example: Sliding window key

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"math"
	"sync"
	"time"
)

func main() {
	k := "key"
	rl := New(10, time.Second)
	stop := rl.Clear()
	defer stop()
	for i := range 50 {
		time.Sleep(50 * time.Millisecond)
		fmt.Println(i, rl.Remaining(k), rl.Allow(k), rl.Remaining(k), rl.RetryAt(k))
	}
	k = "val"
	for i := range 11 {
		fmt.Println(i, rl.Remaining(k), rl.Allow(k), rl.Remaining(k), rl.RetryAt(k))
	}
	fmt.Println("Hello, 世界", rl)
	time.Sleep(2 * time.Second)
	fmt.Println("Hello, 世界", rl)
	time.Sleep(time.Second)
}

func New(limit int, period time.Duration) *RateLimiter {
	return &RateLimiter{
		limit:  limit,
		period: period.Nanoseconds(),
		Now:    time.Now,
		vals:   make(map[string]*State),
	}
}

type RateLimiter struct {
	// Config
	limit  int
	period int64
	Now    func() time.Time

	// State
	mu   sync.RWMutex
	vals map[string]*State
}

type State struct {
	prev int
	curr int
	last int64
}

func (r *RateLimiter) Allow(key string) bool {
	return r.AllowN(key, 1)
}

func (r *RateLimiter) AllowN(key string, n int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.vals[key]; !ok {
		r.vals[key] = new(State)
	}
	if r.remaining(key)-n >= 0 {
		r.vals[key].curr += n
		return true
	}
	return false
}

func (r *RateLimiter) Remaining(key string) int {
	r.mu.RLock()
	n := r.remaining(key)
	r.mu.RUnlock()
	return n
}

func (r *RateLimiter) remaining(key string) int {
	v, ok := r.vals[key]
	if !ok {
		return r.limit
	}

	now := r.Now().UnixNano()
	curr := now - now%r.period
	prev := curr - r.period
	if v.last == prev {
		v.prev = v.curr
		v.curr = 0
		v.last = curr
	} else if v.last != curr {
		v.prev = 0
		v.curr = 0
		v.last = curr
	}

	ratio := 1.0 - float64(now%r.period)/float64(r.period)
	count := int(math.Floor(float64(v.prev)*ratio + float64(v.curr)))
	return r.limit - count
}

func (r *RateLimiter) RetryAt(key string) time.Time {
	if r.Remaining(key) > 0 {
		return r.Now()
	}

	r.mu.RLock()
	v, ok := r.vals[key]
	if !ok {
		r.mu.RUnlock()
		return r.Now()
	}
	last, period := v.last, r.period
	r.mu.RUnlock()
	return time.Unix(0, last+period)
}

func (r *RateLimiter) Clear() func() {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)

	go func() {
		defer wg.Done()

		t := time.NewTicker(time.Duration(r.period))
		defer t.Stop()

		for {
			select {
			case <-done:
				return
			case <-t.C:
				r.mu.Lock()
				now := r.Now().UnixNano()
				for k, v := range r.vals {
					if v.last+r.period <= now {
						delete(r.vals, k)
					}
				}
				r.mu.Unlock()
			}
		}
	}()

	return sync.OnceFunc(func() {
		close(done)
		wg.Wait()
	})
}

```


## GCRA Keys

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
	k := "key"
	rl := New(10, time.Second, 3)
	stop := rl.Clear()
	defer stop()
	for i := range 50 {
		time.Sleep(10 * time.Millisecond)
		fmt.Println(i, rl.Allow(k))
	}
	k = "val"
	for i := range 11 {
		fmt.Println(i, rl.Allow(k))
	}
	fmt.Println("Hello, 世界", rl)
	time.Sleep(2 * time.Second)
	fmt.Println("Hello, 世界", rl)
	time.Sleep(time.Second)
}

func New(limit int, period time.Duration, burst int) *RateLimiter {
	return &RateLimiter{
		burst:    int64(burst),
		limit:    limit,
		period:   period.Nanoseconds(),
		interval: period.Nanoseconds() / int64(limit),
		Now:      time.Now,
		vals:     make(map[string]int64),
	}
}

type RateLimiter struct {
	// Config
	burst    int64
	limit    int
	period   int64
	interval int64
	Now      func() time.Time

	// State
	mu   sync.RWMutex
	vals map[string]int64
}

func (r *RateLimiter) Allow(key string) bool {
	return r.AllowN(key, 1)
}

func (r *RateLimiter) AllowN(key string, n int64) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := r.Now().UnixNano()
	t := max(r.vals[key], now)
	if t-r.burst*r.interval <= now {
		r.vals[key] = t + n*r.interval
		return true
	}

	return false
}

func (r *RateLimiter) Clear() func() {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)

	go func() {
		defer wg.Done()

		t := time.NewTicker(time.Duration(r.period))
		defer t.Stop()

		for {
			select {
			case <-done:
				return
			case <-t.C:
				r.mu.Lock()
				now := r.Now().UnixNano()
				for k, v := range r.vals {
					if v+r.period <= now {
						delete(r.vals, k)
					}
				}
				r.mu.Unlock()
			}
		}
	}()

	return sync.OnceFunc(func() {
		close(done)
		wg.Wait()
	})
}
```

## Consequences

Rate limiting protects your server from DDOS.


