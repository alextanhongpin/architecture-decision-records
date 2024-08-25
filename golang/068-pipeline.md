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
- showing progress


```
gen | fork(10) | task1 | task2 | branch | error:retry success:print
```
