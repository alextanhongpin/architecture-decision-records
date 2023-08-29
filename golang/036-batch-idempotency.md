# Batch Idempotency

## Status

`draft`

## Context

What is even more challenging than idempotency is batch idempotency. Imagine you have a task which is composed of many subtasks, and each of them has to be completed once only.

The task could either succeed or failed, but they could be executed once only.


Take for example, you have are integrating payment to a provider that sells top-up for phone. However, there is no API for batch payment, so to make 10 top-ups, you need to pay 10 times.

You are designing a product that allows batch top-up to end customers, but they only make a single payment. Internally, you are actually looping through the phone numbers and making individual payments. A lot of things could go wrong here, which includes failure in one of the payment (and potentially partial refunds), or maybe intermittent errors on the provider side, but however the request is retried at a later time which is no longer valid (e.g. when the payment has certain deadline etc and the request expires) and worst of all - double or more similar requests executed.

There are several outcomes that we can expect:

1. all requests completed (with our without failures in between)
2. some requests failed (non-retryable)
3. all requests failed

Which outcome to expect depends on your requirements. If the whole batch operation is expected to be atomic, then all requests must either succeed or failed.

If full rollback cannot be achieve, then compensation can be done, which makes the behaviour similar to Saga, except the steps is a single operation from the batch operation.

### Keeping track of state

The states needs to be persisted in a storage as a workflow state.

Each operation, and the desired outcome needs to be configured in order to mark the operation as completed.

### Lifecycle

The lifecycle of the idempotent batch operation could be as follow:

1. generate a predictable key for the batch operation
2. lock the batch key to ensure work is done on a single machine
3. execute the operation one by one
4. for each operation, keep track of the idempotency status
5. once all tasks are done (or failed), mark the batch as done
