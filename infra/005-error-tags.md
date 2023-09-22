# Error Tags


## Status

## Context

When logging, adding tags makes it easier to filter by keyword.

This is especially for stateful processes. For example, when making an API request, we can log the status or relevant status by tag.

This can be useful for reconciliation. For state machine too this is particularly useful. Sometimes the logs will be written before the entry is written to db, especially for APi requests.
