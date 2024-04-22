# Use Locking

## Status

`draft`

## Context

In distributed systems, race conditions can occur when multiple processes or threads try to access the same resource at the same time. This can lead to unexpected side effects, such as:

* Duplicate calls (e.g., registering a user twice)
* Non-linear executions (e.g., calling step two before step one is completed)
* Access to modify a resource at the same time (e.g., two calls modifying a Post with different results)

To prevent race conditions, we can use locking mechanisms to ensure that only one process or thread can access a resource at a time.

We can apply locking mechanisms locally, which only work on a single server, or we can use distributed locking mechanisms, which work across multiple servers.

Local locking mechanisms include using mutexes or channels as a means of synchronization.

Distributed locking mechanisms typically use a central locking service, such as Redis, Consul, or Postgres/MySQL.

Each locking mechanism has its own tradeoffs, so it is important to choose the right one for your needs.

If the process can be asynchronous, we can also use Kafka and send all the message to the same partition by key. This allows processing the message by the consumer serially for a given partition key, e.g. when updating transaction state, we use transaction id as the partition key.

## Decision

We will use Redis for distributed locking in our system. Redis is a fast, in-memory key-value store that is well-suited for locking applications. It provides a simple and efficient locking API that is easy to use.

## Consequences

Using Redis for distributed locking will have the following consequences:

* It will improve the consistency of our system by preventing race conditions.
* It will reduce the risk of data corruption.
* It will make our system more scalable by allowing us to handle more concurrent requests.

## Next Steps

We will need to implement the Redis locking mechanism in our system. We will also need to test the mechanism to ensure that it is working correctly.


### Methods

- `lock.lock(ctx, key, lock duration)` returns a new lock instance that can be terminated early as well as extended
- lock.do, similar to above but accepts a callback and holds the lock until the callback completes
- any attempt to extend/release the lock when it expires will return ErrLockReleased

behaviour
- by default, lock will wait until the lock is acquired. to prevent it from waiting indefinitely, set a context cancellation or NOWAIT option

### Design 

How do we design a distributed lock? The example below assumes the implementation using a **single** redis node. For multiple nodes implementation, check out redlock algorithm. The difference is that in single node implementation, we can guarantee the lock will only be held by a single client.

Let's start with a naive implementation. Below is the pseudo code:


```
lock(key)
work()
unlock(key)
```

Quite simple, except there is a few issue. If the server crash before the unlock is called, the key is locked forever.

We can fix it by adding ttl to the key:

```
lock(key, ttl)
work()
unlock(key)
```

However, now we introduced a bug. The work may take longer than the ttl, causing the key to expire, and another thread may acquire the lock.

We need to periodically refresh the lock:

```
lock(key, ttl)
refresh(key, every)
work()
extend(key, every)
unlock(key)
```

We now have three failure points
- the refresh failed for some reason, we need to cancel the work done if it is still in progress
- the work fails, we need to cancel the refresh
- the work completes, close to the time the key is expiring. We try adding an extend after the work completes, but the lock may expired already

the first two just requires concurrency synchronization. for the last one, we need to add a timeout for the work to ensure it completes before the end of the refresh duration


```
lock(key, ttl)
refresh(key, every, timeout)
work(timeout-buffer)
extend(key, every)
unlock(key)
```

