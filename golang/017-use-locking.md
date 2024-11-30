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

There is still an potential error. When the redis instamce failed, the token might not be refreshed and expires. 

Instead of expiring the token, we persist it indefinitely, but check if the last refreshed at is within a certain interval, e.g 5 mins. Then we run a cron to extend it periodically. This is safer sibce the data will never be deleted during the process.

### Alternative

How to handle locking between different client?

Let's say we have `Foo` that obtains a lock. Another client `Bar` attempts to acquire the lock too. We have several possible alternative for `Bar`.

1. fail fast, `Bar` cannot obtain the lock. Let the client decide whether to retry or not
2. retry every interval until it can obtain
3. retry every interval until timeout
4. retry every interval until context canceled
5. retry n times until it can obtain, fail otherwise

### Timeouts

When locking, there are several timeouts involved

- normal context timeout/cancellation
- initial lock timeout
- refresh lock timeout, e.g. 0.9 times the lock timeout
- client wait timeout

For example, when the client first request a lock, it is locked for 10s. Then every 7.5s, the lock will be extended for another 10s. The reason to keep the lock short is if the process fails, then another process should be able to take over the operation.

The refresh lock is necessary to avoid the lock from expiring before the process completes. The refresh needs to be canceled but without errors once the process that holds the lock completes. If the refresh fails, the process should also terminate and the lock released.

The client that waits for the lock needs to periodically try to obtain the lock.

The incorrect way is to just assume the lock is acquired, and the process completes within the lock period:

```
lock(1m)
process() // what if the process took 2m to complete? another process calling can acquire the lock
```

### Waiting to acquire a lock

A client can keep polling to acquire the lock. However, this naive implementation will not work:

```go
// resetAfter retrieves the remaining time before the key expires.
func (l *Locker) resetAfter(ctx context.Context, key string) (time.Duration, error) {
	duration, err := l.client.PTTL(ctx, key).Result()
	// The key may be deleted already, so we return 0 to allow retry immediately.
	if errors.Is(err, redis.Nil) {
		return 0, nil
	}

	return duration, err
}
```

```go
func (l *Locker) TryLock(ctx context.Context, key string, ttl, wait time.Duration) (string, error) {
	nowait := wait <= 0
	if nowait {
		return l.Lock(ctx, key, ttl)
	}

	// Create a context with a timeout for the wait duration.
	ctx, cancel := context.WithTimeoutCause(ctx, wait, ErrLockWaitTimeout)
	defer cancel()

	for {
		// Check the remaining time before the key expires.
		sleep, err := l.resetAfter(ctx, key)
		if err != nil {
			return "", fmt.Errorf("try lock: %w", err)
		}

		// Sleep for the remaining time before the key expires.
		select {
		case <-ctx.Done():
			return "", context.Cause(ctx)
		case <-time.After(sleep):
			token, err := l.Lock(ctx, key, ttl)
			if errors.Is(err, ErrLocked) {
				continue
			}

			return token, err
		}
	}
}
```

Above, we try to check the previous expiry of the lock duration that is held by another process. This doesn't work because there is simply too much waiting time. If the lock is released early, we will end up waiting a long time.

### Metrics

- lock hit: number of successful locks acquired
- lock miss: the number of errors in conflicting lock

What can we get from this?

- zero lock hit: obviously very bad
- zero lock miss: is the lock even needed
- low lock miss, a good number of concurrency issue avoided
- high lock miss: super concurrent, are there any ways to synchronize this

the lock hit ratio is lock hit divided by sum of lock hit and lock miss.

The more interesting question would be, are there any concurrent operations after implementing the lock?

How can we test it?

We can generate n number of concurrent actions, and fire it at the same time. The action will require sending the timestamps. We can measure the timestamps and see if the gap is consistent with the refresh lock time. If not, it means there is a possibility of a race condition.
