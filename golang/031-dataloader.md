# DataLoader

## Status 

`draft`

## Context

DataLoader is a concept of batching and fetching keys at a given period to reduce the N+1 query issue.

This is more common in GraphQL where there can be concurrent resolvers attempting to fetch the same resources.

Instead of fetching the rows from the database individually, dataloader first batch the keys in-memory.

After certain interval, or when the number of keys has hit the threshold, dataloader executes the query and returns the result.


## Decisions

There are a few common design challenges and incorrect usage patterns for dataloader.

### Keys must equal result

In DataLoader, a _batch function_ must be provided to fetch the values for the uniquely batched keys. If there are no keys, we can skip the query.

For the execution to be successful, every key must resolve to a value or an error.

The results needs to be returned in the same order of the key in order to cache the key/value pair for future fetch.

However, in reality, the following could happen:

- the number of keys does not match the number of values
- some keys does not have a value (perhaps it was deleted)
- there are duplicate key but only one value is returned (`IN (...)` query actually removes the duplicates)
- the query failed due to internal error
- some results may be filtered due to access control

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





