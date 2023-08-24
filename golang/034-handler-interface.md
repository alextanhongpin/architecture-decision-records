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

In go1.21, `sync.Once` added `once.Func`, `once.Value` and `once.Values` which could be a reference for generic types. Below we see example of how we can make the methods more generic. This could be useful, say, if we want the second return value to be something other than error. Note that the generic types are limited to two, and not more. The request is not defined here.

```go
// Executes without returning error. Error handling is the caller's responsibility. Common pattern in concurrency or background job.
type Func interface {
  Exec(context.Context) 
}

type Value[T any] interface {
  Exec(context.Context) (T)
}

type Values[T, U any] interface {
  Exec(context.Context) (T, U)
}
```


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

### Closed vs Open generics

One issue with using generic handler is that we need to instantiate one new implementation per type. There is no official term, but I will just use the term closed generics here. 

On the other hand, open generics doesnt restrict the generic types, and are commonly function.


```go
func Exec[T any](retry retrier, h handler[T]) (T, error) {
  var v T
  var err error
  err = retry.Do(func() {
    v, err = h()
    return err
  })
  return v, err
}
```
