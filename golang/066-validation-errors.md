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
