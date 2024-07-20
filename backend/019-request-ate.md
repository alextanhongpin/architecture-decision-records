# Request Rate

Part of thr R.ED metrics, request rate is the frequency of request within your system.

Monitoring the rate helps understand workload and traffic patterns, with burst and drop in traffic indicating anomalies.

It is also a huge component for a lot of libraries, such as

- rate limiting
- circuit breaker
- error rates
- budgets

aside from using number of requests, we can use the measurement of budget tokens.

For example, you may want to design a circuit breaker that measures the error rates and error threshold (e.g. at least 100 errors, with 90% of requests failing). 

However, we want to treat errors differently.

For example, an internal server error will use up the budget of `10`, while a timeout will use up a budget of `5` _per request_.

So the number of requests doesn't matter, but the severity will impact how the policies works.

In some cases like request timeout, there will be long delays between requests. Hence, the number of requests may be little but the system is experiencing actual error.







