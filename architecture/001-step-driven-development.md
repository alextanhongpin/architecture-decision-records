# Step Driven Development


Clean architecture promotes a clean separation of layers, but they are split based on responsibility.



Things have changed, and the way we develop is geared towards delivering features. Every addition or change to a feature will involve code changes across different layers, aka vertical slicing.

These layers tend to form a _gradient_, where some responsibility may overlap too.



It is hard to deal with changing requirements too, especially when you need to touch unrelated code in different layers. Hence, we want to introduce the concept of step-driven-development.


Instead of this:

```go
package main

type AuthUsecase struct {
	userRepo UserRepository
}

func (uc *AuthUsecase) Login(ctx context.Context) error {
	// Fetch user from repo ...
	// Check password match ...
}
```

We have dependencies such as repository declared etc.

```go
package main

type AuthUsecase struct {
	loginStep loginStep
}

func (uc *AuthUsecase) Login(ctx context.Context) error {
	// Do login
	// uc.loginStep
	//
}
```

If the requirement wants to add another step, such as sending email to indicate you are logged in:

```go
package main

type AuthUsecase struct {
	step0 loginStep
	step1 sendEmailOnLoginStep
}

func (uc *AuthUsecase) Login(ctx context.Context) error {
	// Do login
	// uc.step0
	// uc.step1
}
```

One advantage is we abstracted the steps so that we don't need to concern ourselves with implementation details. During testing, we can also test each steps independently.
