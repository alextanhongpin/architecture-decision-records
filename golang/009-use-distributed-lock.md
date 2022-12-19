# Use distributed lock

There are many approaches to locking, and some can be local (`singleflight`) or distributed (requires the usage of redis, or postgres's advisory lock).


The actual implementation depends on the usecase, but the goal is mostly to prevent concurrent action on a given operation (similar to golang's mutex).



In order to perform locking, the operation must be uniquely identified across different processes. The steps to locking may look like this:

1) Lock a unique identifier
2) Perform the operation
1) Release the lock

The operations is ideally idempotent.
