# Logging

## Status


`draft`

## Context

We want to log sql performance, as well as bad queries.
The benefits are as follow:

- track bad queries
- track slow queries
- track usage
- track cache hits

Bad queries can be result of poor concatenation of query, due to conditionals or poor serialization
Slow queries can be due to missing index.
Usage differs per query, and it is important to optimize the most frequently used query, e.g. by caching.

## Decision

Look at how opentelemetry logs the sql. We do not want to log every query due to performance reason

Some cloud providers already provide proper monitoring too, as well as database functionality.

How can we track it from postgres?

What other metrics do we want to measure?


- how to enable slow query logging
- how to check usage
- how to benchmark performance 
