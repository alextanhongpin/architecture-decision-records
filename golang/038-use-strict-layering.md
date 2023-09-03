# Use strict layerig

## Status

`draft`

## Context

In layered application, we define several layers that are (mostly) split based on responsibilty.

The common layers includes but not limited to:

- presentation
- application service (aka usecase)
- repository (data facade layer, not specific to database)
- domain

A request from a client will go down the layer before getting back a request.

Each layer above also depends on the layer below directly. However, the layer below cannot call the layer above, which will result in reverse dependency.

This issue is more common in strongly typed language like golang because the types needs to be imported to fulfil the interface.

In your application, you may choose to add more layers to abstract functionality.

## Decision

Structuring your app based on layers above can be confusing, because when we think of layers, we think of hierarchy. However, we cannot design the folder structure to be bestein golang.

Below we see an example of how to structure the app, and the reasons behind it.

```
presentation/
rest/
  middleware/
  request/
  response/
  api/v1
grpc/
graphql/
domain/
  application/
    repository/
adapter/
  postgres/
  stripe/
```



