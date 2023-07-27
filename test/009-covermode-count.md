# Use cover mode count

## Status

`draft`

## Context

When running tests, it is generally a better practice to generate a coverage profile.

Thr default mode only highlights the coverage.

However, knowing how frequent a line of code is being executed provides insights to future optimization, and possibly also catch scenarios such as O^2 tests.

## Decisions


If running without testing race conditions, we should use covermode count. Otherwise, use atomic.






## Consequences
