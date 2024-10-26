# JWT Middleware

Don't create JWT middleware. It is redundant.

- you need to attach it to all handlers that is required
- context will be created, just to be retrieved later
- use a function instead
