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

Also, using it as a request DTO allows clear separation between packages. We no longer need to import the types from other layers.

One powerful effect is that it fulfills the exact definition of a DTO. The conversion from a struct to anonymous struct strips all behaviours away.

### Anonymous struct as response

```go
// You can edit this code!
// Click here and start typing.
package main

import "fmt"

func main() {
	var res Result = foo()
	fmt.Println("Hello, 世界", res)
	res.yes()
}

type Result struct {
	age int
}

func (r Result) yes() {
	fmt.Println("yesss")
}

type result = struct {
	age int
}

func foo() result {
	return result{
		age: 10,
	}
}
```

What about using it as a response struct?

This provides a lot of benefits too, such as no longer needing to map between types.

Also returning an anonymous struct strips away behaviours, so we can be sure that client does not mutate the types returned or execute business logic on methods that could have been tied to a struct.

If the returned type is assigned to a typed struct, now it has new methods that can be invoked.

### Anonymous struct for polymorphism 

```go
// You can edit this code!
// Click here and start typing.
package main

import "fmt"

func main() {
	var su SuperUser = foo()
	var u User = foo()

	fmt.Println(su.Sudo(), u.Sudo())
}

type SuperUser struct {
	name string
}

func (r SuperUser) Sudo() bool {
	return true
}

type User struct {
	name string
}

func (u User) Sudo() bool {
	return false
}

type user = struct {
	name string
}

func foo() user {
	return user{
		name: "john",
	}
}
```

Another usecase is when you have the same data type but different behaviour required. 


