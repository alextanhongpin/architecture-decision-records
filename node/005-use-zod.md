# Use Zod

We use Zod for validation and also checking if an object is serialized correctly, especially from repository layer (sql) or rest layer (user input).


## Using branded types

Branded types can be used with Zod.

```typescript
import z from "zod";

const EmailSchema = z.custom<Email>((val) => z.string().parse(val));

// This is not Email type.
const email = EmailSchema.parse("hello");
function logEmail(email: Email) {
  console.log(email);
}

logEmail(email);
```

They can later be composed with objects:

```typescript
const LoginRequestSchema = z.object({
  email: EmailSchema,
});
```


## Using zod with custom error

If you already have your own custom error, you can also use it with Zod.

```typescript
export const EmailSchema = z.custom<Email>((val) =>
  z
    .string()
    .refine(
      (val) => EmailFactory.valid(val as Email),
      (val) => {
        const error = new EmailValidationError(val as Email);
        return {
          message: error.message,
          path: ["email"],
          params: error.toJSON(),
        };
      }
    )
    .parse(val)
);
```

## Objects

Basically, we create a schema using zod first, then we infer the type.

Reference [here](https://github.com/colinhacks/zod#objects):
```ts
// all properties are required by default
const Dog = z.object({
  name: z.string(),
  age: z.number(),
});

// extract the inferred type like this
type Dog = z.infer<typeof Dog>;

// equivalent to:
type Dog = {
  name: string;
  age: number;
};
```

