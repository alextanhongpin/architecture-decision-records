# Batch Idempotency

## Status

`draft`

## Context

What is even more challenging than idempotency is batch idempotency. Imagine you have a task which is composed of many subtasks, and each of them has to be completed once only.

The task could either succeed or failed, but they could be executed once only.


Take for example, you have are integrating payment to a provider that sells top-up for phone. However, there is no API for batch payment, so to make 10 top-ups, you need to pay 10 times.

You are designing a product that allows batch top-up to end customers, but they only make a single payment. Internally, you are actually looping through the phone numbers and making individual payments. A lot of things could go wrong here, which includes failure in one of the payment (and potentially partial refunds), or maybe intermittent errors on the provider side, but however the request is retried at a later time which is no longer valid (e.g. when the payment has certain deadline etc and the request expires) and worst of all - double or more similar requests executed.
