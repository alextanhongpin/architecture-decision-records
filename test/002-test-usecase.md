# Test Usecase


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
