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
		"name": Validate(name == "", "name is required"),
	})
	fmt.Println("Hello, 世界", ve)
}

func Validate(invalid bool, msg string) string {
	if invalid {
		return msg
	}

	return ""
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
