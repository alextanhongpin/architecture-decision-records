# HTTP Snapshot Testing

## Status

<!--What is the status, such as proposed, accepted, rejected, deprecated, superseded, etc.? -->
`proposed`

## Context

<!--What is the issue that we're seeing that is motivating this decision or change?-->
Testing golang's handler requires comparing json values. For large JSON response, there is a lack of visibility on the JSON structure. So developers need to know the shape of the before writing assertions.



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
