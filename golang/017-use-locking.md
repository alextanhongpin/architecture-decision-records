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

## Decision

We will use Redis for distributed locking in our system. Redis is a fast, in-memory key-value store that is well-suited for locking applications. It provides a simple and efficient locking API that is easy to use.

## Consequences

Using Redis for distributed locking will have the following consequences:

* It will improve the consistency of our system by preventing race conditions.
* It will reduce the risk of data corruption.
* It will make our system more scalable by allowing us to handle more concurrent requests.

## Next Steps

We will need to implement the Redis locking mechanism in our system. We will also need to test the mechanism to ensure that it is working correctly.
