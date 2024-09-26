# Dependency Injection


All initialization of the dependencies should be in a package `container`.

You do not need a `config` layer, it is redundant to load the values just to pass to another constructor.

Instead, aim for zero constructor args, and create the actual dependencies required by the application. If the dependencies args differs, just create multiple separate instances.

Don't mix test dependencies with application dependencies. This avoids risk of actually touching non-test configuration.


## Singleton, scoped and transient dependencies

- singleton: use sync Once/Value or its variants, name doesn't have New,e.g. `DB`
- scoped: use `NewDB`
- transient: use `NewDB`
