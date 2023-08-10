# Use circular buffer logs


## Status 

`draft`

## Context

Logging with levels is a common operation. Normally, the logger is configured to enable logging for certain level.

For example, in production, we may want to limit only logs up to ERROR level, because logging anything below that will only lead to noise.

However, when an issue actually happens, it is not useful to just see the logs printing the cause. We want to be able to see the logs of level INFO or maybe up to TRACE to trace the sequence of execution that leads to the error.

One option is to dynamically toggle the log level when an error occurs. One issue with this approach is we night not react fast enough, especially when the error is intermittent.

## Decision

Instead of treating logs as independent steps, we can log the sequence of execution for each request. At tge end of the request, if an error occurs, we can log the whole steps.

Otherwise, we can just discard the trace.
