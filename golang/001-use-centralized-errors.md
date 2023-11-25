## ADR 001: Use Centralized Errors

### Status

**Deprecated**. See [ADR 018: Errors Management](./018-errors-management.md). Each package or layer should have its own error.

### Context

Currently, errors are defined in different packages and modules. This can make it difficult to track down the source of an error. It can also lead to duplicate errors being defined.

### Decision

We will centralize error handling by placing all errors in a single package, e.g. `errors`. This will simplify import paths, because all errors can be traced from a single package. It will also reduce the risk of duplicate errors being defined.

### Consequences

* We will have a single source of truth for errors.
* Import paths will be simplified.
* The risk of duplicate errors being defined will be reduced.

### Next Steps

* Update the error handling code to use the centralized error package.
* Update the documentation to reflect the changes.

### Timeline

* This ADR will be implemented in the next major release.

### Resources

* [Error Handling in Go](https://golang.org/doc/effective_go.html#errors)
* [Error Handling in Golang](https://www.digitalocean.com/community/tutorials/error-handling-in-golang)
