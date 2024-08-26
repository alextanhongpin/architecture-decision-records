# Pipeline

Concurrent pipeline for handling streaming data


- handling timeout
- handling context
- running n workers
- scale up workers adaptive
- circuit breaker
- retry
- handling error
- inflight request
- rate limit
- throttle
- showing progress
- heartbeat
- debounce
- idempotent
- deduplicate
- branch


```
generator | fork(10) | task1 | task2 | branch | error:retry success:print
```


## Usecases

- I want to run at most n request in flight concurrently 
- I want to run at most n request per second (no burst/burst)
- I want to pause the job on error, and retry after sleep. This requires pausing the generator (iterators, maybe?). When streaming result from sql, we can for example batch in small requests through cursor pagination, and store the last cursor for resuming. This prevents loading everything into memory
- For a step, I want to run multiple other requests concurrently. This should be done using errgroup for example, the pipeline doesnt handle this.
- for a step, I want to batch and debounce requests. For example, I might pass the ids of the users into another pipeline, deduplicate it and do a batch fetch from cache or in db etc. This cuts down the number of operations dramatically.
- waiting for multiple results. One object can wait for results from multiple pipeline. We can store it in a global map and do a sweep every interval to check for completion. This requires global state.

## Optimization

- batching with buffered channels. When streaming from generator, sometimes the pipeline will get stuck, blocking the channels and might impact the generator, e,g streaming from db. We need a way to signal generator from providing us the next batch, e,g by tracking progress rate and batch completion, batch of 1000, 50% completion in 10s. Of course the easiest way is to always just wait for one batch to complete, then restart with the next batch.
- stopping generator until retries sleep timeout completes
- dataloader for caching similar resources, just be aware of storage



## Design

generator
- batch
- stream
- cursor
- pause
- resume
- stop
- next
- ratelimt
- inflight
- buffer
- idempotent
- context, timeout etc
- pipe

fanout
- inflight
- retry
- ratelimit
- idempotent
- context

Some other utilities
- passthrough
- progress

context can be supplied through another channel?



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
	start := time.Now()
	ch := Generator(10)
	ch = FanOutFunc(5, ch, func(i int) int {
		time.Sleep(100 * time.Millisecond)
		return i * 10
	})
	ch = RateLimit(10, time.Second, ch)
	for v := range ch {
		fmt.Println(v)
	}
	fmt.Println(time.Since(start))
}

func Generator(n int) chan int {
	ch := make(chan int)

	go func() {
		defer close(ch)

		for i := range n {
			ch <- i
		}
	}()

	return ch
}

func FanOutFunc[K, V any](n int, in chan K, fn func(K) V) chan V {
	ch := make(chan V)

	var wg sync.WaitGroup
	wg.Add(n)

	for range n {
		go func() {
			defer wg.Done()

			for k := range in {
				ch <- fn(k)
			}
		}()
	}

	go func() {
		wg.Wait()
		close(ch)
	}()

	return ch
}

func RateLimit[T any](request int, period time.Duration, in chan T) chan T {
	ch := make(chan T)
	t := time.NewTicker(period / time.Duration(request))

	go func() {
		defer t.Stop()
		defer close(ch)
		for v := range in {
			select {
			case <-t.C:
				ch <- v
			}
		}
	}()

	return ch
}

func InFlightRequest[T any](n int, in chan T) chan T {
	ch := make(chan T)

	bf := make(chan struct{}, n)
	for range n {
		bf <- struct{}{}
	}

	go func() {
		defer close(ch)
		defer close(bf)

		for v := range in {
			select {
			case <-bf:
				select {
				case ch <- v:
					bf <- struct{}{}
				}
			}
		}
	}()

	return ch
}
```

Batcher:
```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"context"
	"fmt"
	"sync"
	"time"
)

func main() {
	ch := make(chan int)
	go func() {
		defer close(ch)
		for i := range 20 {
			ch <- i % 10
		}
	}()
	b := BatchFunc(3, time.Second, ch, func(vs []int) {
		fmt.Println(vs)
	})
	time.Sleep(1 * time.Second)
	b.Stop()
	fmt.Println("Hello, 世界")
}

type BatchStopperCloser interface {
	Stop()
	Flush()
}

type batchFunc[T comparable] struct {
	limit  int
	period time.Duration
	fn     func([]T)
	in     chan T
	cancel func()
	wg     sync.WaitGroup
	flush  chan struct{}
}

func newBatchFunc[T comparable](limit int, period time.Duration, in chan T, fn func([]T)) *batchFunc[T] {
	return &batchFunc[T]{
		flush:  make(chan struct{}),
		limit:  limit,
		period: period,
		fn:     fn,
		in:     in,
	}
}

func (b *batchFunc[T]) init() {
	cache := make(map[T]struct{})
	t := time.NewTicker(b.period)
	defer t.Stop()

	flush := func() {
		keys := make([]T, 0, len(cache))
		for k := range cache {
			keys = append(keys, k)
		}
		clear(cache)

		if len(keys) == 0 {
			return
		}

		b.fn(keys)
	}
	defer flush()

	ctx, cancel := context.WithCancel(context.Background())
	b.cancel = cancel

	var wg sync.WaitGroup
	wg.Add(1)

	go func() {
		defer wg.Done()

		for {
			select {
			case <-ctx.Done():
				return
			case k, open := <-b.in:
				if !open {
					return
				}

				_, ok := cache[k]
				if ok {
					continue
				}
				cache[k] = struct{}{}
				t.Reset(b.period)

				if len(cache) >= b.limit {
					flush()
				}
			case <-b.flush:
				t.Reset(b.period)
				flush()
			case <-t.C:
				flush()
			}
		}
	}()
}

func (b *batchFunc[T]) Stop() {
	b.cancel()
	b.wg.Wait()
}
func (b *batchFunc[T]) Flush() {
	b.flush <- struct{}{}
}

func BatchFunc[T comparable](n int, period time.Duration, in chan T, fn func([]T)) BatchStopperCloser {
	b := newBatchFunc[T](n, period, in, fn)
	b.init()
	return b
}
```

### Context

For cancellation, we don't really need to pass context or a done channel as the first argument for every stage function. As long as one of the channel is closed, all subsequent ones will be closed too.

We just need the first stage to be cancellable.

However, we can still make a stage with context using the approach below.

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"context"
	"fmt"
)

func main() {
	fmt.Println("Hello, 世界")
}

func Context(ctx context.Context, in chan any) chan any {
	out := make(chan any)

	go func() {
		defer close(out)

		for {
			select {
			case <-ctx.Done():
				return
			case v, ok := <-in:
				if !ok {
					return
				}
				out <- v
			}
		}
	}()

	return out
}
```
