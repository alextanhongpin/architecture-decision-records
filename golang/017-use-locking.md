# Use Locking


## Status

`draft`

## Context

In distributed system, race conditions can happen, resulting in various unexpected side-effects in applications. They can be
- duplicate calls (calls register user twice)
- non-linear executions (calls step two before step one is completed)
- access to modify resource at the same time (two calls modifying a Post with different result)

Each have their own way of solving it, but requires however synchonization between different servers.

We can also apply local solutions that only works on a single server as the first layer of protection.

Locking solution present locally includes using mutex or channels as a mean of synchronization.

For distributed locking, we need to use infrastructure such as redis, consul or postgres/mysql.

Each has their own tradeoffs, pick the simplest or what is available for your needs.


## Decision


Redis:


Postgres:


Mysql:


## Consequences
