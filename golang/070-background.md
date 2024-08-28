# Background

Running heavy tasks in the background helps reduce waiting time for the client.


Variations
- run a single job for every execution
- batch the requests and execute per batch
- run at every interval, e.g. cache warmup, cron
- batch and run at every interval

```
bg = newBackground(queue_size, handler) // automatically starts
defer bg.stop() // stops the bg job
defer bg.flush() // stops and flushes all the pending jobs
bg.send(a) // send single
bg.send(a, b c) // send multiple
```

```
bg background 
pg promiseGroup

// sender
p, loaded = pg.loadOrStore(key)
if !loaded { // stored
  defer p.forget(key)
}
bg.send(key)
p.await()
```

Some optimization
- use queue to prevent blocking the function
- use cache above storage

## Double store

when sending the keys
- queue the keys
- once the keys hit certain threshold or if timeout, run the batch func
- mget all redis keys
- for keys that are empty, query the db and set the cache
- if the keys are still empty fail them, else mset them
- set all values to the promises
- for non existing keys, set to nil in cache, but at the same time check the ratio of cache hit vs miss to avoid cache penetration


```
// cache + batch
// just batch
if cache
  cache.send(k)
else
  batch.send(k)

cacheBatch(n, func(keys) {
  kv := mget(keys)
  for k in keys {
    v, ok := kv[k]
    if ok {
      if v == notfound {
        pg[k].reject(notfound)
      } else {
        pg[k].resolve(v)
      }
    } else {
      db.send(k)
    }
  }
})
dbBatch(n/2, func(keys) {
  kv := sql.whereIn(keys)
  for k in keys {
    v, ok := kv[k]
    if ok {
      pg[k].resolve(v)
      if cache then cache.set(k, v, ttl) // mset can't ttl
    } else {
      pg[k].reject(keynotfound)
      if cache then cache.set(k, notfound, ttl/2)
    }
  }
})
```

actually we should just leave it to the batch function to decide:

```
kv = cache.mget(keys)
for k in keys
  v, ok = kv[k]
  if !ok {
     q.collect(k)
  } else {
     res[k] = v
  }
}
kv = db.load(q.keys)
for k in q.keys {
  v, ok = kv[k]
  if ok {
    cache.set(k, v, ttl)
  } else {
    cache.set(k, notfound, ttl/2)
  }
  res[k] = v
}
```

However, this might not optimize batching for the db if the cache hit is high.

So the first option has some merits.

```
done = make(chan bool)
ch = make(chan input)
ch = orDone(done, ch)
ch = batch(1000, 16ms)
ch = semaphore(numcpu, ch)
ch = map(ch, func() {
  // cache function
  resolve or reject cached keys
  return keys not found
})
ch = batch(100, 16ms)
ch = semaphore(numcpu, ch)
ch = map(ch, func() {
  // db function
  resolve or reject
  set cache
})
wait(ch)
```
