# Fallback Pattern

What us fallback pattern in golang?

Golang's error handling is explicit, so the errors usually need to handled after the execution of the function/methods that returns it.

However, there are some errors that we want to silently ignore, but at the same time we want to be notified of it.

These errors are usually infrastructure related, and can be categorized as non-critical.

For example, if the redis client fails and we have a rate limiting logic applied, we nay choose to fallback to the in-memory approach instead of failing all requests.


We can just register a handler `OnError` to capture this error, and then fallback to alternatives.

If the `OnError` is not supplied, then by default we panic whenever there is an error related to infrastructure. This forces the client to think about how to handle such cases.
