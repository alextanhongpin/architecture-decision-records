# Testing API layer

## Status

`draft`

## Context


Testing in API layer involves asserting the expected request and response payload.

For both request and response, it is important to check the marshaling and unmarshaling works as expected.

For request, we can also check if the API validates the request correctly. If the API requires authorization, tests should be included to check the error(s) when user is unauthorized.

For response, we can check the status code.

There are other parameters to such as headers, trailers etc that should also be checked.

## Decision

### Testing request

### Testing response

### Testing validation

### Testing middleware

### Testing middleware

### Testing black box

### Testing snapshot
