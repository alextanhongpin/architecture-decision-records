# Idempotency in Database


## Status

`draft`


## Context

We want to implement idempotency for different scenarios in database.

Some of the patterns includes
- idempotency key existing: the key has been seen once, we don't care about the request/response
- idempotency key + request: the key exist, and the request matched.
- idempotency key + request + response: similar as above, but returns the response

For batch operations, we can have two layers of idempotency.

The first is about the batch operation.

The second is for each operation in the batch to be executed. Say we have a batch operation of 50 items to be looped and executed.

We have an idempotency to check if the batch operation is completed. If not, we execute each item, skipping those that has already been executed.

In short, this is similar to a cursor. Once all the steps are completed, update the batch key so that we can return the whole data.



### Idempotency request

```
As a user,
When I make repeated request,
Then I should get the same response
```

Redis:

```
# set if not exists
setnx key {status: pending, request} px lock-duration
# if exists
check request match
# match: return response
# not match: request does not match error

# if not exist
do operation
# if fail: delete key
# if success
set key {status: success, request, response} px retention-duration
```

### Postgres 
