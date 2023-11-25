## Use Data Types

### Status

`Draft`

### Context

It is common to have reusable types that belong to a helper class (or `utils`, `common`, `constant`, etc). However, we should avoid using those names, and instead be more specific.

In this document, we will categorize the common data types found, and how we can better name them.

#### Data Types

Data types implementation should be placed in the `internal/types` package. For example, if you want to implement a `set` package, then it could belong in `internal/types/set/set.go`. Some other Go packages include experimental slices and maps (update: as of Go 1.21, this is part of the standard package).

#### Extended Types

Extended types should also be placed in the `internal/types` package. If the names are conflicting, then we should **version** it. For example, to extend the `strings` package to include methods like `ToCamelCase/ToPascalCase/ToKebabCase`, we can create a file called `internal/types/strings2`. Or if they are purely for casing, we can just call it `stringcase`. (Prefer something like `calc` instead of suffixing with version.)

#### Date and Time Types

Implementation for date times such as `Today/Tomorrow/Yesterday/StartOfTheMonth/TimeRange/DateRange` could reside in `dates`.

In short, for conflicting names, we can either:

- Be more specific (`stringcase` vs `strings2`)
- Use plural form (`times/dates` vs `time`)
- Use similar meaning (`clock` or `calendar`)
- Create a directory with that package name, and create new subpackages under that package

For some cases, we may also suffix the package with `util`, e.g.

- `httputil`
- `grpcutil`
- `stringsutil`
- `sliceutil`

Some standard packages do that. If the package is related to tests, then

- `httptest`
- `grpctest`
- `testutil`

Any of the above is valid, as long as it is **consistent**.

**Do not**

- Use names like `common`, `helper`, `constant`
- Use suffix numbers, like `strings2` etc
- Prefix the package name with `go`, e.g. `go strings` etc
- Use underscores for package names
- Package names that are composed of two or more words, joined without underscore, e.g. `userservice`, `usersvc`
- Use package names that are the same as the standard package, e.g. `errors`. You can still create the directory, but create the subpackage underneath, e.g. `errors/stacktrace`, or `errors/details`.
- Add versioning (`strings2` means the extended version)
- Prefix with `x`, so `xstrings`
- Prefix with `go`, so `gostrings`

### Decision

We will use the following conventions to name data types:

- Data types implementation should be placed in the `internal/types` package.
- Date and time types should reside in `dates`.
- For some cases, we may also suffix the package with `util`, e.g. `httputil`.
- Do not use names like `common`, `helper`, `constant`.
- Do not use suffix numbers, like `strings2` etc.
- Do not prefix the package name with `go`, e.g. `go strings` etc.
- Do not use underscores for package names.
- Do not use package names that are composed of two or more words, joined without underscore, e.g. `userservice`, `usersvc`.
- Do not use package names that are the same as the standard package, e.g. `errors`.

### Consequences

This will result in a standard convention to store reusable packages, and no package names like `utils`, `common`, `helper`, or `constants`.

## References

- [Golang Packages](https://golang.org/pkg/)
