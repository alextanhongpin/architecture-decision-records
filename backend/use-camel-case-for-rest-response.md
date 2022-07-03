# Use camel-case for REST response

## Who

Backend. REST-based API. GraphQL is already using camel-case naming convention for fields.

## What

Fields returned in REST API should be using camel-case instead of snake-case. This applies to query strings too, not just API response body.

## Why

- we want to avoid conversion of snake-case to camel-case on the Frontend side. JavaScript variables naming convention now favors camel-case over snake-case.
- we want to avoid the same conversion on the server-side too, especially with requests received from Frontend.


## When

- when receiving requests from a client
- when returning response to the client

## How

- when receiving and returning response to the client, ensure all fields are returned in the camel-case format
