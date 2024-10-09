# Use Camel-Case for REST Response

## Status
Accepted

## Context
This decision applies to the backend team responsible for REST-based APIs. It aims to standardize the naming convention for fields in API responses and query strings to use camel-case, aligning with the existing convention in GraphQL.

## Decision
Fields returned in REST API should use camel-case instead of snake-case. This applies to query strings too, not just the API response body.

## Rationale
- **Consistency**: JavaScript variables naming convention favors camel-case over snake-case. Standardizing on camel-case avoids the need for conversion between formats on the frontend.
- **Efficiency**: Avoiding conversion on both the client and server side reduces the potential for errors and simplifies the codebase.

## When to Apply
- When receiving requests from a client.
- When returning responses to the client.

## How to Apply
- Ensure all fields in the API responses and query strings are in camel-case format.
- Apply this standard consistently across all REST-based APIs.

## Examples
### Before
```json
{
  "user_id": 123,
  "user_name": "JohnDoe"
}
