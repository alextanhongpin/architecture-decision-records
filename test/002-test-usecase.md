# Test Usecase

## Status

`draft`

## Context

There are several kinds of testing
- unit: test stateless components, such as methods for a library
- integration: test services with dependencies


Unit testing should be straightforward. However, integration testing is usually done poorly.


Most integration tests are done by mocking the dependencies, and usually either
- just test the happy path
- covers all branches (failure scenario)


but they do not really test the _behaviour_ of the system.

> Tests are meant to describe the behaviour of the system

If a user wants to integrate the service that you have, they should be able to by looking at the test cases and understand the possible scenarios when using the library.


In short, we don't really want to concern ourselves with tesing the system internal behaviour (every error branch, mocking dependencies etc), but we do want to treat the system as a blackbox, and know the triggers that will cause failure.


TODO: Add example.


## Decision

### Don't cover all paths

we should not cover all paths. If our usecase consists of multiple steps, the common pattern is usually to test every step with success/failure scenario. However, doing this for all steps while repeating the previous steps will usually lead to complexity of O^n.


### Don't mock error paths from dependencies 

There is not much value derived from mocking the failure paths, especially those from dependencies.
instead we should just focus on the happy paths.

unhappy paths are usually domain behaviour, so they could be tested separately.

### Put branching logic in steps

So that we don't have to repeat tests.

In golang, it is common to see poorly written tests.

There are tests that mocks the dependencies to return error, and that is run repeatedly until all dependencies are tested. That usually leads to tests with o2 runtime.

### Step driven development

### Mock dependencies one layer under

Dont overmock, use actual dependencies.

## Consequences 


