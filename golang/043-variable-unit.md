# Variable unit

## Status

`draft`

## Context

When we increment a counter, we usually use a single unit of count. This is sufficient for most cases. However, there are times when we need to use a variable unit of count to add weight to the context.

For example, when performing rate limiting, we may want to increment the rate limit by 10 for each POST request, but only by 1 for each GET request. This allows us to give more weight to POST requests, which are more likely to consume resources than GET requests.

Another example is when using a semaphore to limit the number of goroutines that can access a shared resource. We may want to use a larger unit of count for the semaphore when the resource is more expensive to access. This will prevent too many goroutines from accessing the resource at the same time, which could lead to performance problems.

## Description
A variable unit is a unit of count that can be increased or decreased depending on the context. This is useful when we need to give more weight to certain events or resources.

### Examples
Here are some examples of how variable units can be used:

- **Rate limiting**: We can use a variable unit to increment the rate limit by a different amount for each type of request. For example, we could increment the rate limit by 10 for each POST request, but only by 1 for each GET request.
- **Semaphores**: We can use a variable unit to increase the size of the semaphore when the resource is more expensive to access. This will prevent too many goroutines from accessing the resource at the same time, which could lead to performance problems.
- **Background job priority**: We can use a variable unit to increase the priority of background jobs that are more important. This will ensure that these jobs are processed before less important jobs.

## Conclusion

Variable units can be used to add weight to the context and give more importance to certain events or resources. This can be useful for rate limiting, semaphores, and background job priority.
