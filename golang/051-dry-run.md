# Dry Run

## Status

`draft`

## Context

Dry run is useful for testing out the behaviour without changing internal state.

During dry run, the library can

- run initial validation
- log execution steps
- return expected result after executing `ExecutionResult`
- generate potential events 

Dry run is common in toolings, such as Terraform etc. However, it can also be added to domain-heavy application. A client can for example call the endpoint with dry run (or `validate_only`) option for validation and showing errors on thr form.

One other example of dry run is rate limiter.

A rate limiter has an `Allow` method that checks if the operation is allowed, and increments the counter. However, there are times where we just want to check if an operation is allowed without actually incrementing the counter. A method `AllowAt` can be used to check if we can execute the operation at a later time.


## Decision

Dry run can be added 
- in a CLI
- in API as `validate_only` option
- in packages

when we need to assert behaviours/expected outcome without changing internal state.

## Consequences
