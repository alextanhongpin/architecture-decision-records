# Handler Interface


## Status

`draft`

## Context

When designing libraries, it is common to have a handler.

A handler is just a function that is passed as a first class function. Handlers are normally used for callbacks.

We can design handlers as interface or purely function.

The former is useful if you have complicated dependencies for your function, and you need to chain multiple handler. A good example is the `http.HandlerFunc`. This allows interchanging between function and interface.

### Middleware

Middleware are basically decorators. They allow adding behaviour to the handler without modifying the original handler.

Designing a consistent handler interface will allow better reusability of middlewares.

### Hooks

Hooks are meant to tap into the lifecycle of the class. Ideally we should not encourage the use of hooks in application. Use middleware instead.

For publishing internal states, use event publisher instead.


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

However, just passing function is equally simple. Any handler can be converted to the function form.


### Closed vs Open generics

One issue with using generic handler is that we need to instantiate one new implementation per type. There is no official term, but I will just use the term closed generics here. 

On the other hand, open generics doesnt restrict the generic types, and are commonly function.


```go
func Do[T any](retry retrier, h handler[T]) (T, error) {
  var v T
  var err error
  err = retry.Do(func() {
    v, err = h()
    return err
  })
  return v, err
}
```

### Type Assertion

Better?


## Decisions

Do
- use function form instead of handler
- use consistent naming, `Do` to return values, `Exec` to return only errors
- pass `ctx` as the first argument - it makes it easier to evolve the function
- use open generic patterns

Don't
- use the interface form
