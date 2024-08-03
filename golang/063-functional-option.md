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
