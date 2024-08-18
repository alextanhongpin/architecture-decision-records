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

### Implementation

Similar to `httpdump`, we can first dump the request/response pair to a file. The handler will be called at most once. If the file already exists, the handler will no longer be called. Alternatively, the file can be created manually. The advantage is we can just specify the files required and simulate a lot of different responses.

Unfortunately the downside is, if the API contract changes, there will be a drift between the actual and expected request/response.

Therefore `httpreplay` is not a replacement for `httpdump`. However, it can complement `httpdump` and make fewer requests as well as removing dependencies. We can for example run the dump once, but then reused it multiple times in other tests.

The API may look like this:

```go
client := httpreplay.Load(filepath)
client.Do(req)
```

The request must match the target dump file request in order for the response to be returned.

Otherwise `ErrRequestMismatch` will be returned.

The returned type should be a httpclient. We should be modifying the http transport to compare and route the requests.

Since the client can be called with multiple requests, we need to allow replaying multiple requests and perhaps in the same order as it is loaded. Calling a request will consume it, and will no longer be able to return the response again.

Thr idea above points to sequential activation. So the client
- needs to know how many requests the usecase will call
- what is the expected request for each invocation
- useful for asserting each and every step in a test

An alternative is to just do a pattern match against the current request, without removing them once the request has been made. If there are multiple matching request, they follow the order.



## Consequences

API becomes more predictable.

Dumping the request/response makes the API calls more transparent too - something often overlooked when working with API integration. 
