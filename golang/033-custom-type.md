# Type

## Status

`draft`

## Context


This ADR discusses dealing with custom types in golang.

Custom types are usually used to represent value objects in DDD. The goal of value objects is to reduce primitive obsession and to encourage usage of clearer types in the code.

We want to focus on best practices for the following 
- mapping custom types to primitives and vice versa
- validation convention
- what happens in the constructor

## Decisions

We standardize the following methods for the operations we mentioned above.


### Parsing

Parsing is the process of transforming a primitive to a value object.

The methods will be named `Parse<Name>` and takes the primitives as an input (typically string) and returns the value object an error.
For raw binary, we can use Unmarshal methods.

### Format

Format is the process of transforming a value object to primitive string.

The method will be named `Format<Name>` and may accept an additional argument `layout` that determines how the output will be printed.

Otherwise, we could take advantage of golangs format verb too (e.g. for stacktrace errors).

The output will always be a human-readable string. Note that adding a layout means that the parser may require that layout too to infer the type.

For raw binary data, we can use Marshal methods.

### Constructor

Construction is the process of creating a new value object. In golang, since we can define a new type without depending on constructor, thr validation is also not mandated in the constructor.

The constructor accepts a primitive type and returns the value object without the error. 


### Validation

There should ideally be two validation method called `IsValid` and `Valid` respectively.

If the validation is external, then we will provide a method called `Validate<Name>`.

Due to how verbose golang's error handling is, we choose to delegate the error handling by placing it as a method.

This allows another wrapper to nest the value object and call the valid method to perform nested validation.

When do we choose to place validation externally as a separate function?

Rule of thumb, place domain logic as method, but business logic as function.


