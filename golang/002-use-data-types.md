# Use Data Types


## What

- *Data types* implementation should be placed in `internal/types` package. So for example, if you want to implement a `set` package, then it could belong in `internal/types/set/set.go`.
- *Extended types* should also be placed in `internal/types`, if the names are conflicting, then we should _version_ it. For example, to extend the `strings` package to include methods like `ToCamelCase/ToPascalCase/ToKebabCase`, we can create a file called `internal/types/strings2`. Or if they are purely for casing, we can just call it `stringcase`. Same goes for `math2/rand2`. 
- Implementation for date times such as `Today/Tomorrow/Yesterday/StartOfTheMonth/TimeRange/DateRange` could reside in `time2` or `dates`. 


In short, for conflicting name, we can either
- be more specific `stringcase` vs `strings2`
- use plural form `times/dates` vs `time`
- add versioning `strings2` means the extended version
- prefix with `x`, so `xstrings`
- prefix with `go`, so `gostrings`

Any of the above is valid, as long as it is _consistent_.


Do not confuse `datatypes` with `value object`. For example, types such as `Age` or `Birthday` or `Name` is domain-specific. They should probably belong in the `domain` package.
