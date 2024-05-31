# Running Python in Golang

## Status

`pending` 
## Context
I want to run python in golang to make use of the machine learning features.

However, there are no easy way to accomplish it.

## Decision

Experiment using docker containers and run it from golang.

We can easily spin new containers and call them to get the results.

This assumes the deployment environment supports running containers.

What other options do we have?
- compile python to binary, then run them alongside golang?
- create grpc or http servers
