# Wrapping errors

How do we deal with wrapping errors from lobrary perspective?

Also, how do we control how users wrapped their error.

Take for example, a retry implementation. We want to allow user to abort the retry by returning a sentinel error.

For example, we can define a sentinel error 

```go
var ErrAbort = errors.New("retry: aborted")
```

and user can use it:

```go
fmt.Errorf("%w: %s, retry.ErrAborted, "due to error")
errors.Join(retry.ErrAborted, ErrFailed)
```

as you can see, there are various ways user can wrap the error.

This may cause some issues when unwrapping.

