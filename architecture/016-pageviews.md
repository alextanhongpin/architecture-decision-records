# Storing Pageviews

## Context

We want an efficient way to store page views.

The page views data should be persisted in the database with a granularity of at least 1 day.

We could further store compress data that is more than a month/year to summaries.

## Decision

There are many options to store, e.g. postgres, redis, cassandra counter etc. We can benchmark the storing and retrieval for 1 million page views, at the rate of 1000 views per second.
