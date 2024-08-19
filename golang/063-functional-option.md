# Functional Option pattern

When to use?
- when you want to make an option optional
- when you want to override an existing option

When not to use
- in constructor New
- to set a value, just pass a struct

```go
type Foo struct {
  msg string
}

// Overriding example
func (f *Foo) Foo(opts...Option) {
  overwriteMsg := opts.Apply(f.msg)
  // 
}
```

# Defining Options

What is a better way of defining options?

We have the following choice

1. direct, by exposing the struct fields. This is common in golang's standard library, but usually for pure options, not external dependencies like db etc
2. use a setter, but this are usually for optional fields
3. through constructor, directly by spreading arguments, or passing an `Options` struct
4. functional optional

All of them are applicable, it depends on the context of the options.

Are the options
- global, set once reuse everywhere
- local, specify when you are calling
- overridable, defaults to global, but can be override locally

For most cases, passing option struct in constructor is the simplest. You can validate the option, apply new changes as well as clone the options.

The struct naming makes it clear over just spreading the values.

For some dependencies like Clock, you can just make the field public so that it can be overwritten during tests.

## Type dependent options

When the options are type dependent, which means they differ based on the type passed in, we can use reflect type to store the options by types mapping.


## Naming

Use Config for the root, and Option for the modifier
