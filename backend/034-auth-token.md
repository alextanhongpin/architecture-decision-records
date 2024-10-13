# Auth Token

Creating auth token that are safe to use for different platform.

We can additionally return the following metadata in the credentials:

- provider, e.g. email, facebook, google. Which provider that is used to login when supporting multiple providers. Allows identifying the primary provider when linking/unlinking additional providers.
- device, e.g. web, ios and/or android and specific device id. Allows adding rules like CORS for web specifically and identifying which device is using the token now. Web token should be requested through cookie for security

When performing destructive actions, make the user login again or validate the action.
