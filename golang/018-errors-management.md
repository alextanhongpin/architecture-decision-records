# Errors Management

## Status

`draft`


## Context

Outlines the best practices in error management for golang.

[errors](https://github.com/alextanhongpin/errors).

## Decision

### Grouping errors

### Keep errors close to cause

### Localization and templating

- registering errors template

### Error details

Becareful of sharing states.
- constructing errors
- ensuring details are filled
- unwrapping errors

### Sentinel errors

### Stacktrace

### Error reporting

### Logging

### Translating errors between layers

### Mutability
Errors should be immutable after the state has been declared.
Sentinel errors are always immutable.

### Wrapping

Becareful of double wrapping.

### Unwrapping

### Comparing

### Multi errors

### Dont expose internal errors

### Validation errors

- valid and validate methods
- declaring validation errors

### Other types of errors

- context
- library

### Errors as values

e.g. rate limit error also serves as values.

### Retryable errors

### Testing errors

### Errors data

any attempt to use generic datatype will not end well.

Use either a fixed error data structure or more generic ones like a dictionary to store error context.


## Consequences
