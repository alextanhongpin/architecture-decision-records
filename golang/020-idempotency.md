# Idempotency


## Status

`draft`


## Context

We want to implement idempotency to prevent issues with double requests. This can be for example, double withdrawal or double delivery of SMS.

For most cases, we can keep the idempotent key in the same table, e.g. orders.

But for some, we might need to hold

## Decision

## Consequences
