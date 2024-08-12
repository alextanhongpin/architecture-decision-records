# DataLoader

## Status 

`draft`

## Context

DataLoader is a pattern for batching keys to fetch results to solve the N+1 query issue. The results will also be cached, so querying with the same key does not make additional queries to the database.

DataLoader is more commonly used for GraphQL where there can be concurrent resolvers attempting to fetch the resources by ids.

DataLoader returns a thunk that could be resolved into a result or an error. When multiple queries are issued to the dataloader, the keys will first be batched in-memory.

When the number of keys hits the desired threshold, or after every tick, dataloader executes the query and returns the result.

## Decisions

There are a few common design challenges and incorrect usage patterns for dataloader.

### Keys must equal result

In DataLoader, a _batch function_ must be provided to fetch the values for the uniquely batched keys. If there are no keys, we can skip the query.

For the execution to be successful, every key must resolve to a value or an error.

The results needs to be returned in the same order as the key in order to identify the key/value pair. The key/value pair is cached for future query.

However, in reality, the following could happen:

- the number of keys does not match the number of values
- some keys does not have a value (perhaps it was deleted)
- there are duplicate keys but only one value is returned (`IN (...)` query actually removes the duplicates)
- the query failed due to internal error
- some values may be filtered due to access control

To fix the issue with the ordering, without needing the user to map the values manually, a _key mapper function_ could be provided that does the opposite of a batch function.

It takes a value, and returns the key. This holds another assumption, that the key can be derived from value, which is true for most cases 


### Duplicate keys

Duplicate keys can solved by only sending the unique keys to the batch function



### No result

When there are no result, we can just reject the key with an error.

The user is responsible to handle the error.


### Lazy initiation

A background worker needs to be initialized in order to perform the batching.
A DataLoader is commonly created per request for a given resource. When we need to fetch multiple resource, we will have to create a number of separate DataLoader, each with their own goroutine.

However, there is still no guarantee that the dataloader will be executed. So the goroutine will remain until the requests ends.

To solve this, we initialize the dataloader lazily starting from when the first key is send.

### Referencing values

Once a value for a key is fetched, the value is stored in a cache.

Subsequent load for the same key will return the same value.

Care needs to be taken for values that are pointers, as they may share the same state.

The user can clone the object before using them if the states should not be shared.


### Idle timeout

Goroutines are cheap, but no resources are cheap. When idle, we can stop the goroutine. This is determined by the idle timeout.

When there are new tasks to be scheduled, we can then restart the goroutine.

Below, we demonstrate the application of idle timeout together with debounce mechanism.

Everytime we received a new message from the work channel, we will reset the idle timeout as well as the ticker timeout. This essentially means that we will not execute the job as long as we already have a minimum batch size, or when there are no further message from the channel after the tick period.

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"time"
)

func main() {
	idle := time.NewTicker(1 * time.Second)
	defer idle.Stop()

	ch := make(chan int)
	t := time.NewTicker(100 * time.Millisecond)
	defer t.Stop()

	n := 0
	threshold := 100

	for {
		select {
		case <-idle.C:
			fmt.Println("idle")
			return
		case <-t.C:
			// Periodic.
			fmt.Println("exec batch jobs")
		case <-ch:
			n++
			if n > threshold {
				n = 0
				fmt.Println("exec batch job")
			}
			// Reset the idle timeout and perform debounce.
			t.Reset(100 * time.Millisecond)
			idle.Reset(1 * time.Second)
		}
	}
}
```

## Plain cache

When the background job is cancelled, there wont be any batching.

As a fallback, the dataloader should behave like a regular cache and get/set should work too.

## Manual flush

Dataloader can triggered to fetch the keys manually by calling the `Flush` method, instead of waiting for the batch timeout.

This is usually at the end of a for loop, once we know there are no further keys to fetch.




