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

