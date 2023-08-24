# Handler Interface


## Status

`draft`

## Context

When designing libraries, it is common to have a handler.

A handler is just a function that is passed as a first class function.

### Hooks

We should not have hooks in the library. Instead, the user should be able to extends the handler before passing it down.



## Decision

Design handlers as generics. Handlers can be categorize into the following:

```go
// Executes and returns error.
type command[T any] interface {
  Exec(context.Context, T) error
}

// Sends a request, expects a response.
type requestReply[T, U any] interface {
  Exec(context.Context, T) (U, error)
}

// Sends a request, but no response.
type publisher[T any] interface {
  Send(context.Context, T) error
}
```

A handler can have an input and can output one or many result.
Each handler also accepts context as the first argument.

In go1.21, `sync.Once` added `once.Value` and `once.Values` which could be a reference for generic types.

There are advantages of using interface vs a function.


For example, as seen in `http.HandlerFunc`, it is easy to convert a function to fulfil the interface.


```go
type Handler[T any] func(ctx context.Context) error

func (h Handler[T]) Exec(ctx context.Context, v T) error {
  return h(ctx, v)
}
```
Another advantage is that user can provide their own implementation, which allows them to pass a struct with additional data.

Aside from that, the handler can be further decorated with capabilities such as hooks for logging, instrumentation, retry etc.


