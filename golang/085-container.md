# Centralized container

Construction of dependencies (controller, action, repository) should happen in container.

This has several advantages

## Singleton and transitive dependencies

Using sync.OnceValue, we can define singleton.

## Config hidden

The environment variables can be loaded in one place, either
- lazy, when the dependency is called. Values might be missing, and trigger delayed error if invoked late.
- init, on app load. will panic if values are missing, more secure.

Otherwise, a `container` package makes more sense than `config`, which could be loaded anywhere.

The container should export ready made dependencies without the `New`, if it is a singleton.

No config should be exported.


## No construction in default package

Take for example an action package:

```go
type Login struct {
  repo LoginRepository
}

func NewLogin(db *sql.DB) *Login {
  return &Login{
    repo: repository.New(db)
  }
}
```

This is bad, because you are importing sql package which is not really part of action package.

What if we accept repo as the constructor args?

It is redundant. Make the repo field public, remove the constructor.

Construction should happen in container layer.

