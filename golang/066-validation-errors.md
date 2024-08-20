# Validation Errors

For validation errors, don't overengineer. The only thing we need is to standardize the return error messages.

It is sufficient to return just the errors by field.


Todo:
- show example for nested objects, array

```go
// You can edit this code!
// Click here and start typing.
package main

import "fmt"

func main() {
	name := ""
	ve := ValidationErrors(map[string]string{
		"name": Assert(name != "", "name is required"),
	})
	fmt.Println("Hello, 世界", ve)
}

func Assert(valid bool, msg string) string {
	if valid {
		return ""
	}

	return msg
}

func ValidationErrors(m map[string]string) map[string]string {
	cm := make(map[string]string)
	for k, v := range m {
		if v == "" {
			continue
		}
		cm[k] = v
	}
	return cm
}
```

## Assertions

```go
// You can edit this code!
// Click here and start typing.
package main

import "fmt"

func main() {
	var name string
	var age int
	res := Validate(
		Assert(name != "", "name", "is required"),
		Assert(age != 0, "age", "is required"),
		Assert(age >= 13, "age", "must be 13 and above"),
	)
	fmt.Println(res)
}

func Validate(assertions ...*Assertion) map[string][]string {
	m := make(map[string][]string)
	for _, a := range assertions {
		if a.cond {
			continue
		}
		m[a.name] = append(m[a.name], a.msg)
	}
	return m
}

type Assertion struct {
	name string
	cond bool
	msg  string
}

func Assert(cond bool, name, msg string) *Assertion {
	return &Assertion{
		name: name,
		cond: cond,
		msg:  msg,
	}
}
```

## Improvement

There are only three required methods
- assert
- required
- optional (chain)

There is no need to create a generic handler for all different types, because it will coerce to boolean.

```go
// You can edit this code!
// Click here and start typing.
package main

import "fmt"

func main() {
	var name string
	var age int
	var cars int
	res := Validate(
		Required(name, "name"),
		Required(age, "age"),
		Assert(age >= 13, "age", "must be 13 and above"),
		Optional(
			cars, "cars", Assert(cars > 0, "cars", "must be positive"),
		),
	)
	fmt.Println(res)
}

func Validate(assertions ...map[string][]string) map[string][]string {
	m := make(map[string][]string)
	for _, kvs := range assertions {
		for k, vs := range kvs {
			m[k] = append(m[k], vs...)
		}
	}
	return m
}

func Assert(cond bool, name, msg string) map[string][]string {
	if cond {
		return nil
	}
	return map[string][]string{name: []string{msg}}
}

func Required[T comparable](value T, name string) map[string][]string {
	var v T
	return Assert(value != v, name, "required")
}

func Optional[T comparable](value T, name string, assertions ...map[string][]string) map[string][]string {
	var v T
	if value == v {
		return nil
	}
	return Validate(assertions...)
}
```

## Design

After several attempts, we can simplify the design even further.

The output is simply a validation errors object, which can be one of the following

- nested hierachy: a flat object where each field is a string, an array of string, or an array of validation errors
- just a single object, and the key names are flattened, so it can be `nested.field` or `array[0].field`

Either one is okay, it depends on how the client handles it.

Every field will begin with a validation of
- filter(required(value, assertions))
- filter(optional(value, assertions))
- filter(assertions)

The assertions can be nested inside the `required` or `optional` validator. They will be applied/not applied based on the first value. 

The `filter` is to remove empty values.

The field names etc and the structure (object/array) should be decided by the end user. The validations are only meant to return string.

Why do we reject returning a dictionary object? Because tying the field and validation means we have to duplicate the code for different fields with same logic.

Why do we choose to return just a single concatenated error message instead of an array? Because it is simply readable to just have a key-value string.

Why do we choose to return a flattened nested key object instead of nested objects/arrays?

Because when we return the objects in an array, some objects may be empty at certain position, leaving a gap.

Instead, it will be easier to just return the index with the errors:

```
array[99].field: "required"
```


