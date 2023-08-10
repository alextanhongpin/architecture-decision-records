# Use Dual Types

## Status 

`draft`

## Context

Generics in go doesn't fit all usecases. Most of the time, we want to keep the data structure generic to handle polymorphism. However, golang's generic enforces the types to be known.

### Unmarshal polymorphic type

For example, we may want to unmarshal an event object by the type.


```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
)

var UserCreatedEvent Event[UserCreated] = "user_created"

func main() {
	var b = []byte(`{
  "name": "user_created",
  "data": { "name": "john" }
}`)
	evt, err := UserCreatedEvent.Unmarshal(b)
	fmt.Println(evt, err)
}

type Event[T any] string

func (e Event[T]) Marshal(v T) ([]byte, error) {
	type payload struct {
		Name string `json:"name"`
		Data T      `json:"data"`
	}

	return json.Marshal(payload{
		Name: string(e),
		Data: v,
	})
}

func (e Event[T]) Unmarshal(b []byte) (T, error) {
	type payload struct {
		Name string `json:"name"`
		Data T      `json:"data"`
	}

	var p payload

	err := json.Unmarshal(b, &p)
	if err != nil {
		return p.Data, err
	}

	if p.Name != string(e) {
		return p.Data, errors.New("event does not match")
	}

	return p.Data, nil
}

type UserCreated struct {
	Name string
}
```

### Generic channel


Another example is when sending payload to channels. We can use similar approach to above, to cast the type based on the type name.


### Templates

Generic can also be used to enforce the type of a data that is stored as any.

For example, when building templates, we don't want to have a strict type...
