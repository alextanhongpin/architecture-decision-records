# Grouping Structs

## Status

`draft`

## Context

When designing structs, we often ask ourselves, how granular should a struct be? For example, for a usecase, do we want to have multiple usecase structs, each with the same interface method implementation, or just a single one with multiple methods?

Granular example:
```go
type CreateUserUseCase struct {
  repo createUserRepository
}
func (uc *CreateUserUseCase) Do(ctx context.Context, req CreateUserRequest) error { ... }

type UpdateUserUseCase struct {
  repo updateUserRepository
}
func (uc *UpdateUserUseCase) Do(ctx context.Context, req UpdateUserRequest) error { ... }
```

Grouped example:

```go
type UserUseCase struct {
  repo userRepository
}
func (uc *UserUseCase) CreateUser(ctx context.Context, req CreateUserRequest) error { ... }

type UpdateUserUseCase struct {}
func (uc *UserUseCase) UpdateUser(ctx context.Context, req UpdateUserRequest) error { ... }
```

Note that there are already a few differences.
- the granular example requires defining a repo/struct for each usecase
- the granular example shares the same `Do` method, but still have different request type

## Decision

We can have best of both worlds. The decision is not mutually exclusive. We should group by feature, e.g. a user can have `ManageUserUseCase` (CRUD) as well as `SearchUserUseCase` (more specific).

On a different scenario, e.g. repository, it is better to have one single repository than multiple repository structs, since we can restrict the access through interface.

## Consequence
