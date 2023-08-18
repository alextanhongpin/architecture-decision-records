# expvar


## Status

`draft`

## Context

The _exp_ stands for `export` and _var_ stands for `variables`. The `expvar` package is standard package to expose useful custom metrics without the need of external infrastructure such as Prometheus or OpenTelemetry.


For example, we can choose to keep track of:

counter
- http requests
- number of goroutine for background tasks
- the number of cron job execution
- the number of job processed
- the number of errors for a particular service

status
- the last execution time for the cron job
- the last ping time to Redis
- heartbeat of long running processes
