# Idempotency


## Status

`draft`


## Context

We want to implement idempotency to prevent issues with double requests. This can be for example, double withdrawal or double delivery of SMS.

For most cases, we can keep the idempotent key in the same table, e.g. orders.

But for some, we might need a way to generate the unique identifier, e.g. when creating new payouts. This is because there will not be a fixed unique identifier when a new entity is created. For such scenario, we can for example generate a sequential identifier per user as the idempotent key. However, that is still not enough because multiple calls will then generate a new identifier. We can further limit the creation of the new payouts until the previous one has been completed. In short, we limit the user action instead, e.g. `user:1:create_payout`. Another option is to check the status, e.g. take the last count of the successful or failed payout. If there is already a pending payout, the sequential number will not be included, and hence will conflict (with the proper database constraints).

When creating idempotency operation, we follow the simple flow:

1. check if idempotency key exists (basically insert a new key and check the error)
2. check if the saved request matches the current request
3. return the saved response

If the idempotency key does not exists:

1. perform the idempotent operation
2. save the request and response

Ideally, each steps should be designed as idempotent to avoid complexity.

Idempotency is not the same as distributed locking. To achieve idempotency, we also need to implement locking to ensure that

1. the same operation is not conducted twice
2. access to the same resource is locked by a mutex
3. the request must match in order to return an already completed operation 

## Decision

### Using redis

Redis is a suitable option, since it is distributed and fast.

### Using postgres

### SLA

We will store the successful idempotency keys for 7-30 days, depending on the usecase. 

## Consequences
