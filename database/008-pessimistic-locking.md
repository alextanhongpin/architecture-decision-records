# Pessimistic Locking

## Status 

`draft`


## Context 

We want lock a resource so that only one agent can act on a given resource at a given time.

The locking should not involve table locking, to avoid any impact on the database.

## Decision

Pessimisting locking with advisory lock Postgres or redis redlock.





## Consequences
