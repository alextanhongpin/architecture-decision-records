# Packages

## Status

`draft`


## Context

When working in a large organisation, it is common to have a lot of repositories.

However, there are a lot of cross cutting concerns that are scattered across different codebase.

This includes
- error handling
- convention for logging
- distributed config/toggles
- resiliency such as circuit breaker, rate limiter
- authn/authz

When it makes sense, extract the behaviour or apply them at infra layer (rate limiting and circuit breaker can be done at api gateway ir service mesh).

However, for greater control, engineers usually have to resort to writing code at application layer.

Separate them into packages.

## Decision

A guideline for writing better package.

Start with capability:

A circuitbreaker
- has 4 states
- has a max success threshold
- has a max error threshold
- times out until it recovers
- starts with close state
- stores current success and failure count
- trips when failure count and ratio hits threshold
- can transition to different states

Go in depth each capability
- scenarios for state transition

Add diagrams to illustrate the flow.

Show sample usage.



