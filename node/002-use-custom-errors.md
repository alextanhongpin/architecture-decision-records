# Use Custom Errors


Custom errors makes it easier to capture more meaningful errors in the application, and also allows us to map the errors easily to REST or Graphql layers.

The core domain should not contain REST http error codes (e.g. 404 Not Found).

Internal errors should not be shown to the user. As such, errors that does not extend AppError should be converted to InternalError. 

## Implementation

```typescript
const enum ErrorKind {
    NotFound = 'NOT_FOUND',
    Unknown = 'UNKNOWN'
}

type ErrorCode = string

abstract class AppError<T> extends Error {
    protected kind: ErrorKind = ErrorKind.Unknown
    protected code: ErrorCode = 'unknown'
    protected params: T = {} as T

    // Only works if using target ES2022?: ErrorOptions is a built-in type.
    constructor(message: string, options: ErrorOptions) {
        super(message, options)
        this.name = this.constructor.name
    }

    toJSON(): Record<string, any> {
        return {
            name: this.name,
            code: this.code,
            kind: this.kind,
            message: this.message,
            params: this.params
        }
    }
}

class UserError<T> extends AppError<T> {
    constructor(message: string, options: ErrorOptions) {
        super(message, options)
        this.code = 'user.unknown'
    }
}

class UserNotFoundError extends UserError<{ id: string }> {
    constructor(id: string, options: ErrorOptions) {
        super(`User '${id} is not found`, options)
        this.code = 'user.not_found'
        this.kind = ErrorKind.NotFound
        this.params = { id }
    }
}

const err = new Error('sql not found')
const userNotFoundErr = new UserNotFoundError('user-abc', { cause: err })

// This won't work.
const usecaseErr = new Error('usecase failed', { cause: userNotFoundErr })

console.log(userNotFoundErr)
console.log(userNotFoundErr.cause)
console.log(JSON.stringify(userNotFoundErr, null, 2))
console.log(usecaseErr instanceof UserNotFoundError)
```


## Error cause

The new JS target supports errors with cause. Thus, any other internal errors can be pass as the cause, similar to how golang errors wrap errors. That way, we can still present the readable AppError and log the internal errors for more information.

## Aggregate Error

For certain usecases where you need to capture multiple errors, use AggregateError, which is similar to how Notification pattern works.

## Validation errors


As mentioned, all errors should be extending AppError. If you are using external library for validation, consider wrapping the error information from the validation library into the AppError params. For example, when validating the login request, consider creating a LoginValidationError. Then when validating with Zod, pass the Zod errors as the params for the LoginValidationError 
