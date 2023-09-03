# Use Global Log

## Status

`draft`

## Context

Logging is a common in every application. However, in layered architecture, we need to pass the logger through dependency injection down every possible layer. Some libraries like `zap` allows the usage of global logger. 

There are several pros and cons for passing logger explicitly.

Cons
- repetitive: the constructor will always have a logger as an argument
- cleanup: if we change the logger implementation, we have to modify all code

Pros
- testing: we can mute the logger, or even mock and test the logger for specific layer
- request-scoped: for some cases, we want the logger to be scoped to a request, e.g. to toggle log level for a specific request after some trigger

## Decisions

Although using a global logger may seem convenient, we lose control over the execution of the logger.

For example, during testing, we may want to mock the logger with an in-memory implementation to assert the values. 

Also, having a global logger makes it hard to customize the behaviour without affecting other parts of the application that depends on the same logger.

The decision is to pass the logger explicitly.
