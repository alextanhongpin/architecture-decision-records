# Step Driven Development


Clean architecture promotes a clean separation of layers, but they are split based on responsibility.



Things have changed, and the way we develop is geared towards delivering features. Every addition or change to a feature will involve code changes across different layers, aka vertical slicing.

## Layers
These layers tend to form a _gradient_, where some responsibility may overlap too.
Layers are rarely independent as one would think. In clean architecture for example, each layer will depend on the layers below it. For example, in golang, if we have a usecase package that calls the repository package, one would think they could be clearly substituted by just declaring the interface at the usecase layer. However, there will be some types that might need to be imported from the repository layer, hence coupling them together.

Regardless of how we layer our systems, one fact remain: layers are just human concerns. They do not in any way impact the way machine works. 

## Function as a whole

Let's say you have a large usecase. No matter how you break it into smaller functions, or moving them into different layers, the size of that usecase do not actually change. 

When we have a large usecase, it can become hard to understand the logic behind it. As human, we try to understand how logic works step by step. But when the number of steps exceeds a certain threshold, we just lose context of what the last n step is doing, and how it relates to the current step, and the usecase. Coupled with conditional logic, things gets messy fast.

If we break them up into smaller methods, we might lose context of the overall logic, because the logic now becomes fragmented across different methods or files.

As a developer, we need to find a sweet spot for the right size of a function. 

## Layers are not the same

Clean architecture helps to (probably) promote cleaner separation between layers. However, what it does not take into account (as with other architecture) is the rate of change and growth of the layers.

Lets take for example the presentation layer, specifically API controllers. Whenever we need to expose a new API, we create a new controller method to do so. The role of the controller is pretty much fixed too, it should be void of business logic and mostly does serialisation and deserialization of objects to json. 

All the layers adhere to Single Responsibility Principle.

But usecase layer grows over time. We can imagine each layer as a ping pong ball in the beginning. after countless iteration and new features added, the usecall layer now becomes the size of a basketball. A big ball of mud. 

Within the layer, there is not much guidance on how to further break it down into maintainable puzzle pieces. A method with 1000 lines will strike fear in every developer.

## Step driven development

So how toS

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
