# Testing API layer

## Status

`draft`

## Context


Testing in API layer involves asserting the expected request and response payload.

For both request and response, it is important to check the marshaling and unmarshaling works as expected.

For request, we can also check if the API validates the request correctly. If the API requires authorization, tests should be included to check the error(s) when user is unauthorized.

For response, we can check the status code.

There are other parameters to such as headers, trailers etc that should also be checked.

### Client vs Server

There are two modes of testing an API.

We may want to test the implementation from the server side. This is normally the case when you wrote the handlers and have full control over the dependencies.

When testing from the server's perspective, we want to ensure the marshalling works, and changes to response is documented.


From the client's perspective, it may be important to know if the payload is validated correctly, and the response is also serialized correctly.

## Decision

### Testing request

- serialized correctly
- headers sent
- received by server 

### Testing response

- serialized correctly
- headers sent
- response code is expected
- error or payload

### Testing validation

- valid fields
- valid errors

### Testing middleware

- executed
- logic is correct

### Testing black box

### Testing snapshot


- matches
- skip dynamics values like body or header
