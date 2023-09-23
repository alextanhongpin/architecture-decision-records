# Simulate

## Status

`draft` 

## Context

Aside from integration testing, it may be useful to provide some simulation server, where agent(s) can make requests to the application.

This is useful so that we can perform regression for scenarios where we perform a large migration (e.g. database major migration, frameworks).

Simulating such traffic will also allow us to find out issues related to concurrency. The logs generated can be visualized too for usefulness.

## Decisions 

We create multiple agents that will perform certaun actions. For example, a Login Agent will only cover scenarios related to logins, and we can also test if it fulfils the scenario. This could be the end of integration testing


## Consequences

Simulate allows better regression testing.
