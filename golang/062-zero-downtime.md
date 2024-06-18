# Zero-downtime deployment

## Context

Without docker, how do we achieve zero downtime deployment? 

We want to deploy the golang server in a bare metal environment. 


## Decision

- Use systemd
- Use endless
- Use nginx/traefik (?)
