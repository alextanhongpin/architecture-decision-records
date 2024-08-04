# Package

What makes a good package?


- does a single thing
- does it well
- easy to test
- easy to substitute with a different implementation, either as a strategy or for mocking
- separates side effect from static result (to be discussed below)
- configurable vs customizable
- clean interface
- function vs struct methods
- generics
- context propagation
- metrics
- hooks
- side-effects (time.Now)
- error handling/wrapping

## Options 



Let's start with options. Some packages requires setting some options in order to configure behaviour.

For configuration, provide an `Option` object. Using primitives is discouraged unless it only has 1 or 2 values.
Struct as an option provides clearer initialization too as the fields are named.

Below is an example of initializing a retry handler:

```go
// Good
h := retry.New(&retry.Options{
  Attempts: 10,
})
h.Do(fn)

// provide good default
h := retry.New(retry.DefaultOptions())
```

Why not use functional option? It is usually a bad idea in constructor because it just complicates the initialization process and holds a lot of assumptions about the default values.
Use less code.

Where can I use functional optional then?
In methods when you need to overwrite certain decision:

```go
// retry using the same policy, but just 3 times and abort on certain error
r.Do(fn, retry.WithAttempts(3), retry.WithAbort(ErrCircuitTripped))
```

This however, may add complexity and pollute the `Do` interface method.
In this scenario, it may be better to

- declare a separate retry mechanism
- wrap the `Do` method that overwrites the behaviour


### Naming options

We use `Options` for the default options, and `Option` for the functional option.

```go
type Options struct {}

type Option func(o *Options) 
```

It makes sense because the struct contains all options, while functional option modifies one option only.

## Function vs structs

When do we decide when to use function vs struct? For the retry, we could have use function too:

```go
type Foo struct {}

func (f *Foo) Do() error {
  return retry.Do(f.do, retry.ExponentialBackoff, 10)
}
```

So, what is the difference?

The function declaration is way simpler, and customizable. However, it lacks __abstraction__.

Now the retry implementation is hardcoded in your code. It is hard to test overwrite.

Instead, using struct allows you to just define an interface:

```go
type Foo struct {
  retryable interface {
    Do(func() error) error
  }
}
func (f *Foo) Do() error {
  return f.retryable.Do(f.do)
}
```

Now we can pass in different instances of retryable.

Alternatively, wrap the foo with similar interface: 
```go
type retryableFoo struct {
  *Foo
}

foo := retryableFoo{&Foo{}}
foo.Do()
```

The conclusion is, use struct to hide the implementation details.

However, structs have limitations with generics.

## Generics

When you need to deal with generic, declare a function with type annotations.


## Context as first argument 

Do you need to always pass context as the first argument.

Do it only if you are using the context.
