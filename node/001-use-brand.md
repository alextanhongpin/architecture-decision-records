# Use Brand


Type alias doesn't prevent us from passing primitives:

```typescript
type Email = string

function printEmail(email: Email) {
    console.log(`your email is: ${email}`)
}

printEmail('john.appleseed@mail.com')
```

With branded types:

```typescript
type Brand<T, U> = T & {__type: U}

type Email = Brand<string, 'EMAIL'>

function printEmail(email: Email) {
    console.log(`your email is: ${email}`)
}

// Argument of type 'string' is not assignable to parameter of type 'Email'.
//  Type 'string' is not assignable to type '{ __type: "EMAIL"; }'.
printEmail('john.appleseed@mail.com') // Invalid

printEmail('john.appleseed@mail.com' as Email) // Valid
```

## Assertion function

```typescript
function assertIsDefined<T>(value: T): asserts value is NonNullable<T> {
  if (value === undefined || value === null) {
    throw new Error(`${value} is not defined`)
  }
}
```

## External input


When receiving an external request, we do not know if the type is valid. We can use `asssertion function` that will throw if the type is not valid.


Without assertion function, typescript does not know if the `email` variable is supposed to be type `Email`:

```typescript
function printEmail(email: Email) {
    console.log(`your email is: ${email}`)
}

const email = 'john.appleseed@mail.com' // type is `string`
printEmail(email) // Invalid, since the type is still `string`.
```


With assertion function:

```typescript
// An assertion function.
function assertIsEmail(email: string): asserts email is Email {
    if (!email.includes('@')) throw new Error('not an email')
}

function printEmail(email: Email) {
    console.log(`your email is: ${email}`)
}

const email = 'john.appleseed@mail.com' // type is string
assertIsEmail(email) // type is now Email
printEmail(email) // Valid.
```
