# Separate migration

## Status

`draft`

## Context


Should migration be run in the application or should it be done externally?

When the database is still small (e.g. no fixed threshold, depends on db, but you can set a baseline based on table size in gigabytes), then it is possible to run migration in the app.

However, larger tables requires different handling.


## Decision


Do migration in app when it is small.

For external migration, look at ghost or lhm soundcloud to learn their migration strategy.

Some things can be kept simple by not running migrations that can lock the table, simply by creating a new table.


## Consequences

There are no downtime when the correct migration strategy is implemented.
