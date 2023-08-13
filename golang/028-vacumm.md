# Vacumn

## Status

`draft`

## Context


This ADR addresses the issue with periodic operation.

An example is maintaining a dictionary of key value pairs that may expire locally in the application.

A naive approach to it is to run the cleanup operation at a specific interval. However, picking the right interval is tricky.

If the interval is too long, we risk occupying too much storage as well as prolonged period when locking the map for cleanup.

If the interval is too short, we will spend a lot of time cleaning up, which also holds the lock more frequently 

## Decision

To pick the right interval, we keep track on the number of keys set.
This is similar to redis snapshotting.

We pick a large threshold for a smaller interval, and a small threshold with larger interval. For example:


```
10000 10s
1000 20s
100 30s
10 60s
1 120s
```

The first entry means _execute if there is at least 10000 keys after 10 seconds has elapsed from the first run_.

After execution, the counter will be reset, and the last run at time will be set to now.

## Consequences

The cleanup process now depends on both the counter and period. The code should be more performant.





