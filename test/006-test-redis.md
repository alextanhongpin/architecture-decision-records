# Status

`draft`

# Context

When running unit/integration tests, it is common to mock dependencies instead of making actual calls.

However, those advices can almost be disregarded as we now have more powerful devices capable of running multiple dependencies through Docker containers. There are also plenty of in-memory implementation, as we will explore later that allows us to tests against actual dependencies. 

This provides better confidence because we know the behavior of the dependencies we are testing will be similar to the ones in production.

# Decision

If we have redis as a dependency, we can use miniredis instead of mocking it.

## Consequences

We can now run tests without mocking our dependency.

This provides better confidence.
