# Use Healthcheck

## Status

`draft`

## Context

We need healthcheck endpoint to monitor the state of the application, and as an indicator if the service is healthy.

## Decision

Healthcheck endpoint follows the suggested naming from Kubernetes.

We can use it to check health of the dependencies too (db, redis, external service?) at certain interval.
Aside from that, we can return the version and git commit hash, as well as last build date (docker image) and uptime.

## Consequences

Better visibility on the service health.
