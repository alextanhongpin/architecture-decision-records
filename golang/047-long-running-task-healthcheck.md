# Long Running Task Healthcheck


## Status

`draft`

## Context

When executing long-running tasks, we sometimes lose visibility on what is happening, or whether the service is still executing.

For example, we may need to process thousand records, and for each record we need to perform some operation like calling external services to fetch records etc.

## Decisions

Add healthcheck in between services. We can for example log the output when we hit a certain threshold or after certain duration has elapsed.

We can also add progress bar or display the progress in percent.

It can be useful to record the errors and success too. 
## Consequences

Better visibility on the progress of the job.
