# Events Library

## Status

`draft`

## Context

When integrating third-party packages, it is sometimes useful to be able to extract relevant metrics, logs and traces from the package.

The author of the package should include those instrumentation and allow the developers to extract it.

To understand what metrics could be useful, the package author can rely on experience, and can also receive feedback from the developers. 

The developers should be able to filter only the metrics they need. This requires well-documented metrics in the package as well as option to filter those metrics.

There are three kinds of instrumentation:

- logging
- tracing
- metrics

## Context

For libraries, we will use `golang.org/exp/x/event` package for instrumentation.

If you are building applications such as API servers, consider other options like Prometheus/OpenTelemetry or even `expvar`.

The `event` package also provides adapters to export the instrumentation to other `backend` handlers. The `event` package is considered a `frontend` that is responsible for sending the event to the `backend`. By separating them, we can different `backend` handling those events 

For example, we can choose `zerolog` or `zap` as the logger backend, and also switch to the new `slog` (go1.21) without huge changes in the code.

### Multi handler
