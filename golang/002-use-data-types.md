# Use Data Types

## Status

`draft` 

## Context

It is common to have reusable types that belongs to a helper class (or utils, common, constant etc). However, we should avoid using those name, and instead be more specific.

In this RFC, we try to categorise the common data types found, and how we can better name them.

- *Data types* implementation should be placed in `internal/types` package. So for example, if you want to implement a `set` package, then it could belong in `internal/types/set/set.go`. Some other go packages includes experimental slices and maps (update: as of go1.21, this is part of the standard package)
- *Extended types* should also be placed in `internal/types`, if the names are conflicting, then we should _version_ it. For example, to extend the `strings` package to include methods like `ToCamelCase/ToPascalCase/ToKebabCase`, ~we can create a file called `internal/types/strings2`~. Or if they are purely for casing, we can just call it `stringcase`. ~Same goes for `math2/rand2`.~ (prefer something like `calc` instead of suffixing with version)
- Implementation for date times such as `Today/Tomorrow/Yesterday/StartOfTheMonth/TimeRange/DateRange` could reside in `dates`. 


In short, for conflicting name, we can either
- be more specific `stringcase` vs `strings2` (see below)
- use plural form `times/dates` vs `time`
- use similar meaning like `clock` or `calendar`
- ~add versioning `strings2` means the extended version~
- ~prefix with `x`, so `xstrings`~
- ~prefix with `go`, so `gostrings`~
- create a directory with that package name, and create new subpackages under that package

For some cases, we may also suffix the package with util, e.g.
- httputil
- grpcutil
- stringsutil
- sliceutil

Some standard package does that. If the package is related to tests, then
- httptest
- grpctest
- testutil

Any of the above is valid, as long as it is _consistent_.

Do not confuse `datatypes` with `value object`. For example, types such as `Age` or `Birthday` or `Name` is domain-specific. They should probably belong in the `domain` package.


Don't
- use names like common, helper, constant
- use suffix numbers, like strings2 etc
- prefix the package name with go, e.g. go strings etc
- use underscore for package names
- package name that is composed of two or more words, joined without underscore, e.g. userservice, usersvc
- use package name that is the same as the standard package, e.g. errors. you can still create the directory, but crrate the subpackage underneath, e.g. errors/stacktrace, or errors/details

## Decision

## Consequences

- a standard convention to store reusable packages
- no package names like utils/common/helper/constants
