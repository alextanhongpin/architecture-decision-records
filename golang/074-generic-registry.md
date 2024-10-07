# Generic Registry

Generic types does not work all the time, sometimes we have to infer the types dynamically. Using type assertion is fast, and we can take advantage of it instead of reflection.

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"errors"
	"fmt"
	"reflect"
)

type Handler func(v any) error

type User struct {
	Name string
}

func main() {
	reg := NewRegistry[Handler]()
	Handle[User](reg, func(u User) error {
		if u.Name == "" {
			return errors.New("name is empty")
		}
		return nil
	})
	h, ok := reg.Load(User{})
	err := h(User{})
	fmt.Println("Hello, 世界", err, ok)
}

func Handle[T any](reg *Registry[Handler], fn func(v T) error) {
	var v T
	reg.Store(v, func(v any) error {
		return fn(v.(T))
	})
}

type Registry[T any] struct {
	values map[string]T
}

func NewRegistry[T any]() *Registry[T] {
	return &Registry[T]{
		values: make(map[string]T),
	}
}

func (r *Registry[T]) Store(v any, t T) {
	r.values[getTypeName(v)] = t
}

func (r *Registry[T]) Load(v any) (T, bool) {
	t, ok := r.values[getTypeName(v)]
	return t, ok
}

func getTypeName(v any) string {
	if v == nil {
		return "<nil>"
	}

	t := reflect.TypeOf(v)
	if t.Kind() == reflect.Ptr {
		t = t.Elem()
	}

	return t.String()
}
```
