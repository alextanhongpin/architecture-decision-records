# Use Concrete Dependencies


## Status

`draft`

## Context

For a lot of scenario, there is no need to mock thr dependencies in golang.

For example, `*http.Client` and `*redis.Client` does not need to be mocked nor replaced with interface, because there are already testing libraries that makes it easy to test the implementation without mocking.


## Decision


Use `httptest` for testing `*http.Client`.

Use `niniredis` for testing `*redis.Client`.

## Consequences

The codes become much simpler.
