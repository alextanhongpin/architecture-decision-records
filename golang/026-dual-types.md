# Use Dual Types

## Status 

`draft`

## Context

Generics in go doesn't fit all usecases. Most of the time, we want to store the payload as bytes vefir


```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
)

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

var UserCreatedEvent Event[UserCreated] = "user_created"

```
