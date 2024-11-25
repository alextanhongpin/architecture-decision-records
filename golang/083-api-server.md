# Writing api server


## Status

`draft`

## Context

We want to create a simple webapp to serve APIs.

We need a simple cookiecutter. We can use golang template capability:

https://pkg.go.dev/golang.org/x/tools/cmd/gonew


To get started, create a new copy of an existing project.


1. run the infrastructure
2. run the server
3. test the health endpoint
4. create a new endpoint
5. repository, actions, and entities


## Decision

We introduce a linear approach of designing an API server.

Thrn we introduce variations to it, such as common patterns to common solutions

We also decide on the project structure for consistent code 


## Consequences
