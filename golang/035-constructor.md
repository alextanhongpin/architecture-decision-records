# Constructor


## Status

`draft`


## Context


### Large constructor issue

### Why setter and getter should not be used

### public vs private fields?

Use public

### Optional option


### Functional option

Avoid if possible.

## Decision

Use public fields for large structs, e.g. for data transfer objects (DTO) or for optional options or common dependencies (e.g Logger).

