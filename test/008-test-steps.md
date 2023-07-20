# Test steps, not the whole implementation

## Status

`draft`

## Context

This ADR addresses the issue of testing large functions with dependencies. One common example is when testing usecase layer.

Dependencies can be mocked manually, but developers usually depends on code automated tools to help speed up development. The common pattern of testing is by asserting the calls to the dependencies. This however, results in repetition of tests written especially when we test further into the function.

```go
// Show example of repeated function here
```

Running test on subsequent steps means mocking the previous steps and repeating the test on those steps. 

This is essentially a `n log n` operation, where `n` is the number of steps with the dependencies mocked out.

This can be made worse by developers testing out different scenarios for different combinations of arguments.

However, as we observe below, we can actually tests the steps individually and remove the needs for mocking, once we fulfil certain criteria.

```go
// example
```

The most important factor on why we need to test all steps before is due to `inline logic`.

```
// example of inline logic
```

In order to cover testing the inline logic, we have to mock and test all steps above.

However, if we extract the inline logic and pass it as a dependency too, then we no longer even need to mock the test.

We can now test each steps independently, and possibly with actual dependencies, or with tests that are closer to reality.


We are also not repeating the tests for the whole test suite, as each steps are guaranteed to execute once.



## Decision

## Consequences
