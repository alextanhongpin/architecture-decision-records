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
