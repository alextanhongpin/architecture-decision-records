# HTTP Replay

## Status

`draft`

## Context

HTTP replays is based on a simple idea of recording the request/response of an API call the first time it is made. Subsequent calls with the same request will return the same response. The operation is idempotent.

The request/response could be persisted locally in a file.

The ability to replay HTTP is useful when working with external API integration. API calls could be expensive in terms of cost and time; they may introduce rate limit or charges per call. During integration testing, we nay also want to avoid making real API calls because:

- there is no guarantee that the calls are reproducible (e.g. a call that mutates data)
- when the API is down, tests becomes broken, which may fail CI/CD



## Decision

Implement a module `httpreplay` which is similar to `httpdump`, except that it works with http client and dumps the payload to a writer.

The function should only have two options:

- filename to write to
- overwrite the existing dump


## Consequences

API becomes more predictable.

Dumping the request/response makes the API calls more transparent too - something often overlooked when working with API integration. 
