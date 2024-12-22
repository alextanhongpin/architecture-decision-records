# Working with Forms

Working with forms in Golang, especially when paired with htmx can get messy.

In interactive web apps, forms can appear anywhere, not just in a single page, which is easier.

For example, we can fetch a list of items, and for each item we can edit it inline, or delete it.

When paired with HTMX, we also need to return the existing forms with new data, such as action URLs and/or validation errors.


## Embedding vs HTML file

Usually embedding is not the way to go. Although it may seem intuitive, but mixing HTML with golang code is a mixture of concerns.

Also, you lose capabilities of templating, hot-reload etc.


## Lifecycle

For a given entity, we have the typical CRUD

- create: NewEntityForm returns a form that can be submitted, mostly empty with reference id
- parse: parse the HTML form into golang struct, and validate as well
- update: form for update, we have a SetEntity to populate the form values on the server-side
- delete: usually just a delete URL would suffice

## Base Form

```go
type Form[T any] struct {
  Title string
  Method string
  Action string
  Data T
  Errors map[string]string
}
```

Note that we embed the `Data`, since it is dynamic.

The other option is to embed `Form`, but that might cause some fields to conflict.

