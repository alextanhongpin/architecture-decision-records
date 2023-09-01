
Use anonymous struct to reduce coupling between layers.
```go
// You can edit this code!
// Click here and start typing.
package main

import "fmt"

func main() {
	f(struct {
		age  int
		name string
	}{name: "john"})
	f(args{
		name: "alice",
	})
}

type args struct {
	age  int
	name string
}

func f(args struct {
	age  int
	name string
}) error {
	fmt.Println(args.name)
	return nil
}
```
