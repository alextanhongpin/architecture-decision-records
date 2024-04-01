# Use Healthcheck

## Status

`draft`

## Context

We need healthcheck endpoint to monitor the state of the application, and as an indicator if the service is healthy.

## Decision

Healthcheck endpoint follows the suggested naming from Kubernetes.

We can use it to check health of the dependencies too (db, redis, external service?) at certain interval.
Aside from that, we can return the version and git commit hash, as well as last build date (docker image) and uptime.


Health endpoint can be skipped from logging. Also, should the name be `/healthz` or `/health` following kubernetes implementation?

## Consequences

Better visibility on the service health.
