# Factory

## Status

`draft`

## Context

This does not relate to the Gang of Four _factory_ pattern.

In golang, a factory is just a constructor. The output of the constructor is usually a pointer or a value.

For simple objects, a function normally suffice.

For objects that requires dependencies, using struct methods to encapsulate the the dependencies.

For constructing objects that requires multiple steps, use a builder.

## Decisions

The convention is to prefix the constructor with `New` when returning a pointer, or `Make` when returning a value.

### Mega constructor 

If there are more than 2 arguments in the constructor, it is a sign to refactor it. Pass an `Option` instead 

### Functional Optional

For simplicity, avoid functional optional. Plain `Option` struct still works best.
