# Postgres App

## Introduction
This document outlines the architectural decisions for coupling a use case with a PostgreSQL database in our application.

## Use Cases
- User runs migration
- User initializes database
- User initializes instance
- Application run process

## Requirements
- Minimum columns must be present
- Ability to swap repository implementations
- Support for nested transactions
- Comprehensive error handling
- Default handlers

## Components
- **Authentication**: Mechanisms for user authentication
- **Tagging**: System for tagging database entries
- **Queue**: Job queue management
- **Saga**: Implementation of saga patterns for distributed transactions
- **Idempotency Store**: Ensuring idempotency in operations
- **Locking**: Mechanisms for database locking

## Error Handling
Detail the strategies for handling errors, including common pitfalls and their solutions.

## Extending Postgres App

One of the most crucial part is allowing custom logics to be extended. In order to achieve this, a common db transaction library is required, so that all steps run atomically.

There can only be pre and post hooks however. The underlying steps cannot be modified.

For example, modifying a auth usecase to customize the email validation:


```go

func (uc *UseCase) Login(ctx, email...

}
```

## `dapp` 

We use the name distributed app, or short `dapp` for application that requires db storage.


Some useful dapps:

- idempotency
- saga
- lock
- config
- feature flags
- ab
- experiments
