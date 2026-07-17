# TestSuite

## Status


## Context

When running tests, we run parameterized tests to explore all possible branches.

Test tables dont always work because we need to adjust the parameters and mock objects to get the desired result (success, error).

We propose creating a simple test suite that follows the act, arrange and assert method, as well as encapsulating the logic to validate result.

The suite is stateful, that is, the execution result is stored. This allows us to rerun the suite to check for idempotency.

We always create a success test with valid inputs 
