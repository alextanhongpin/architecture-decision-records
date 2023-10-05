# Logging Errors


## Status

`draft`

## Context

In golang, errors are usually returned as the second value and propagated up the application.

Alternatively, we can also log the errors immediately at where they originate from.
However, it is often unclear when the former or the latter should be implemented.

We first need to identify the layers we have in the application before we can define the boundary.

This will help us decide on whether to log the errors immediately, or delegate it to the caller.

For libraries, we can just delegate it to the caller.

For most cases, delegating it to the caller seems more attractive because we only need to log once.

Logging is especially useful in application service layer, so we know which step did we failed at.

## Decision

Log at application service, or the layer where you orchestrate the steps required to drive business logic to completion.

Don't log in libraries.
