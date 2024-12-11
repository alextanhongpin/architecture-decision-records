# Singleflight

How is this different than distributed lock?

In distributed lock, only one client can hold the key. Some work is performed, and thr lock is released. 

Another special form is idempotency. We utilize the locking property for similar reason, but returns the same response for the same request. 

The difference is duration. Singleflight only shares the same response for the given "session". 

A "session" is where multiple client calls the same key concurrently.

However, only one will execute and and return the valid payload.

This is suitable to combat thundering cache, for example when renewing cache.

We can employ several strategy here.


```
v, loaded, err := singleflight.do(key, func() (T, err) {
  return res, nil
})
```


```
ok = setnx(key + ":fetch", token, ttl)
if !ok {
  lock_ttl = ttl(key + ":fetch")
  wait_ttl = min(wait_ttl, lock_ttl)
  sub = subscribe(key)
  for {
     select(sub, wait_ttl, ping)
     value = get(key)
     return value, true, nik
  }
  return getter()
}
go refresh()
value = getter()
publish(key, value)
return value, false, nil
```

There are two main actor
- executor - executes the job. only one caller can acquire the lock and execute the job
- waiter - waits for the lock to expire, indicating the task is done

## Setting a lock

Setting a lock with a lease ensures no duplicate jobs are made (assuming we have a single redis instance, not a cluster).

We set a unique token, so that only the setter can modify the key value pair.

A lock ttl is set, so thst further caller can grab the lock. However, while the current lock is held, it will be renewed periodically.

## Notifying done

Once the task is completed, we can just publish a message to the waiter.

## Waiting for result

The waiter waits for the result of the execution. Since we don't know when the lock will expire (it can be renewed), we just periodically ping if the lock is still held.

We also subscribe to the channel for notification of completion.

Note that checking the lock expiry is not useful, as it can be extended.



