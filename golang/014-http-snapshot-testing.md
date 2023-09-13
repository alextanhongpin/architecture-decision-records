# HTTP Snapshot Testing

## Status

<!--What is the status, such as proposed, accepted, rejected, deprecated, superseded, etc.? -->
`draft`

## Context

<!--What is the issue that we're seeing that is motivating this decision or change?-->

Most services are build to serve APIs. In golang, handlers are executed whenever an API endpoint is called. 

Golang comes with the standard library `httptest` to test the behaviour of the handlers without having to run a server.

```go
// TODO: show example here
```

Aside from testing handlers, `httptest` also provides a function to setup a test server to test the beavhiour from a client's perspective. 

```go
// TODO: show example here
```


Regardless, writing the tests can be a chore, especially when we have large payloads. There is always the question of how detailed we want our assertions to be. Should all the fields be asserted? How do we avoid duplication in assertions test between different handlers returning the same payload? 



## Decision

<!--What is the change that we're proposing and/or doing?-->

For testing HTTP endpoints, there are usually a few things to assert for both request and response:

- status code
- headers
- body (request or response payload)
- url (for request, usually the query string parameters etc)


When testing handler, we do not need to concern ourselves with the business logic, just whether the request is parsed correctly, and the response returned matches our expectation.

For this, we propose using snapshot testing.

## Consequences

<!--What becomes easier or more difficult to do because of this change?-->
Developer don't need to write manual assertions (except for some cases mentioned below). Also, the generated `.http` files provides better transparency on the structure of the request and response. One advantage is we can use VSCode extensions or CLI tools such as `http-yac` to execute the tests.
