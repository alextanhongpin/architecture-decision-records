```go
// You can edit this code!
// Click here and start typing.
package main

import "fmt"

type state struct {
	count int
}

func main() {

	m := new(monad[*state])
	m.data = new(state)
	m.pipe(func(s *state) error {
		s.count++
		return nil
	}).pipe(func(s *state) error {
		s.count++
		return nil
	})
	fmt.Println(m.unwrap())
}

type monad[T any] struct {
	data T
	err  error
}

func (m *monad[T]) pipe(fn func(T) error) *monad[T] {
	if m.err != nil {
		return m
	}
	m.err = fn(m.data)
	return m
}

func (m *monad[T]) unwrap() (T, error) {
	return m.data, m.err
}
```
