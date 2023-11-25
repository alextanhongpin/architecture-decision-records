# Constructors in Golang

## Status

`draft`

## Context

A constructor is a function that creates a new instance of a struct. In Golang, constructors are usually named `New` or `Make`.

There are many ways to create a new instance of a struct in Golang. The most common way is to use a constructor.
We can also use a struct method or a builder to create a new instance of a struct. Another popular way is to use functional options.

### When to use a constructor

There are three main reasons to use a constructor in Golang:

1. To initialize fields in a struct.
2. To perform validation on the struct's fields.
3. To create a new instance of a struct with a specific set of values.

Constructor methods starts to suffer when there are more than 2 arguments. The order of the arguments becomes confusing and it is hard to remember the order of the arguments. One way to get around this is to pass another struct that contains all the fields that can be assigned. However, this becomes redundant when all the fields matches the struct that we want to construct.
It is easier to just make the struct fields public and assign them directly.

### When to use a struct method

A struct method is a function that is defined on a struct. Struct methods can be used to initialize fields, perform validation, and create new instances of a struct.

Struct methods are often used when the constructor for a struct is too complex or when the struct needs to be initialized in multiple ways.

### When to use a builder

A builder is a struct that is used to create a new instance of another struct. Builders are often used when the constructor for a struct is too complex or when the struct needs to be initialized in multiple ways.

Builders are more flexible than struct methods because they can be used to create new instances of a struct with different combinations of values.

### When to use a functional options

## Decisions

The convention is to prefix the constructor with `New` when returning a pointer, or `Make` when returning a value.

### Functional Optional

For simplicity, avoid functional optional. Plain `Option` struct still works best.

## Examples

```go
// A simple struct with a constructor.
type User struct {
	Name string
	Age int
}

// The constructor for the User struct.
func NewUser(name string, age int) *User {
	return &User{
		Name: name,
		Age: age,
	}
}

// A struct method that initializes the fields in a User struct.
func (u *User) Initialize() {
	u.Name = "John Doe"
	u.Age = 20
}

// A builder for the User struct.
type UserBuilder struct {
	Name string
	Age int
}

// The Build method for the UserBuilder struct.
func (b *UserBuilder) Build() *User {
	return &User{
		Name: b.Name,
		Age: b.Age,
	}
}

// Create a new instance of a User struct using the constructor.
u1 := NewUser("John Doe", 20)

// Initialize the fields in the User struct using a struct method.
u2 := &User{}
u2.Initialize()

// Create a new instance of a User struct using a builder.
u3 := &UserBuilder{
	Name: "Jane Doe",
	Age: 25,
}.Build()
```
