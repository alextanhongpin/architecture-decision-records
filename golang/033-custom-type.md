# Custom Type

## Status

`draft`

## Context

This ADR discusses dealing with custom types in golang. Custom types are new types that are defined using _type definition_, and it is different from _type alias_.

Below is an example of a _type definition_ for email:


```golang
type Email string
```


Aside from reducing primitives obsession and stronger typing, custom types can also encapsulate behaviours. We want to take advantage of the latter so that the logic belongs close to the types.

We will explore the following with custom types:
- mapping custom types to primitives and vice versa
- built-in validation and external validation
- construction of custom types

## Decisions


Custom types are encouraged over primitives. Create as much custom types as possible for the sake of clarity.

### Parsing

Parsing is the process of transforming a primitive type (usually but not limited to string) to a custom type.

The parse function follows the naming convention `Parse<YourCustomType>` and takes primitive(s) as an input and returns the custom type and an error.

```go
func ParseEmail(email string) (Email, error) {
  // validate, and return the custom type.
}
```

The parse function can optionally accept a `layout` to indicate the source format that needs to be parsed. A typical example is for date time:

```go
time.Parse(layout, value)
```

### Format

Format is the process of transforming a custom type to primitive type (usually but not limited to string). It is the opposite of _parsing_.

The format function will follow the naming convention `Format<YourCustomType>` and may accept an additional argument `layout` that determines how the output will be formatted. This can also be a method to the type instead of a separate function.

```go
type Email string

func (e Email) Format() string {
	return string(e)
}
```

Note that we don't use the method `String` that fulfils the `fmt.Stringer`, as they serve a different purpose. Teh `String` method could also be used for other purposes such as redacting a value (e.g. password, credentials). The `Format` method will always produce a human-readable format, for display purposes.


### Constructor

Construction is the process of creating a new custom type. In golang, constructor function is normally prefixed with `New`, and returns a pointer. If the return type is not a pointer but just a value, then the convension is to prefix it with `Make`.

However, it is not __mandatory__ to use a constructor to create a new type. If there are no special logic during construction such as

- deriving initial value based on another value
- populating a default value that is non-zero

then a constructor is not needed. This makes it simpler too, since we can just use the type as it is.

The constructor accepts primitive(s) and returns the custom type _without validation_. We will discuss about the validation strategy below.


```go
// NewAccessToken returns a new access token with the given expiry.
// Expiry cannot be less than 0.
func NewAccessToken(subject string, expiry time.Duration) (AccessToken, error) {
  if expiry <= 0 {
		expiry = 1 * time.Hour
	}

	return encryptWithExpiry(subject, expiry)
}
```

### Validation


If you have heard about the _Always Valid_ principle, you might question, why separate validation from construction? Based on the _Always Valid_ principle, a created type can never be invalid during construction.

However, in reality, it is very easy to violate the _Always Valid_ principle in golang. Below, we see a new `Email` type initialized without going through a constructor:

```go
var email Email
```

For nested custom types (custom types embedded within another custom types), if we apply the _Always Valid_ principle, the constructor can become very messy quickly.

Instead, we choose to perform lazy validation.

Each custom type should have two validation method called `IsValid` and `Valid` respectively. `Valid` returns an error, while `IsValid` returns a boolean. The latter is useful if we do not need to use the error or we want to return our own error message.

If the validation is external, then we will provide a method called `Validate<CustomType>` that will accept the custom type and return an error. Validation can be done externally, for example for a more dynamic business logic or a validation that requires external dependencies such as API calls or checking if a row exists in the database.
