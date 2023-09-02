# Use Anonymous Struct as DTO

## Status 

`draft`

## Context

Use anonymous struct to reduce coupling between layers.

DTO is Data Transcer Object, a stateless struct that is usually just meant to pass information from one layer to another.


```go
// You can edit this code!
// Click here and start typing.
package main

import "fmt"

func main() {
	createUser(args{name: "john"})
	createUser(createUserArgs{name: "alice"})
	fmt.Println("Hello, 世界")
}

type args struct {
	name string
}

type createUserArgs = struct {
	name string
}

func createUser(args createUserArgs) {

	fmt.Println(args.name)
}

```

Using type alias together with anonymous struct has several advantages:

- we can use the named struct defined in the package
- we can define our own named typed, as long as the type definition matches

The latter is powerful, especially since you might not want to couple the implementation with an external package.
