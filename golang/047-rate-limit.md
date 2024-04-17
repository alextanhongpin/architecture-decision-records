# Rate Limit

## Status

`draft`

## Context

Rate-limit is one of the most essential features to protect your service from abuse.

### Fixed Window

In the fixed window, we just set a threshold for a given time window. In redis, we can just increment a key:

```
> INCR key
1 # Only expire when set for the first time
> EXPIRE key period
```

This is one of the simplest algorithm, and also provides very useful values such as:
- remaining: the number of remaining calls in this time window
- limit: the max request count
- retry in: when the next call can be made (should be 0)
- reset in: the next time window

There is no point of having a `burst`, since we don't throttle.

### Fixed Rate Window

The issue with fixed window is there is no smoothing. The limit can be exceeded at the start of the time window.

Ideally, we want to allow only specific number of requests per time window. For example, if the rate limiter is configured to allow 5 requests per second, we want each request to happen with a gap of 200ms.

We can do that by performing more calculation:

```
start_time_window = floor(now / period) * period
allowed = ceil((now - start_time_window) / period) * limit
allow = consumed + new_token < allowed + burst
```

We can still use a single key, so it is performant. The advantage is we have smoothing, and allow burst.

### Fixed window

Fixed window can be simple. E.g. just taking the current time now and round it down, then setting the key in redis and expire it after a period.

However, the issue happens when rounding the keys all to the same period. All requests will expire at the same time! Would it be better to have different start time instead? (redis should be performant enough at handling expired keys)

This means we can no longer use the basic strategy to set and expire the key anymore. We need to store both the expiration and count in the value. We can use redis pexpiretime.

## Decision


Apply different rate limit strategy for different usecase.

For example, to protect your endpoint, just a fixed-window should be sufficient.


## Consequences
