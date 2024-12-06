# Public Fields


Use public fields as much as possible, combined with interfaces.

In golang, you might come across decisions to use public vs private fields.

However, most of the time, using public has more advantages.

## Simpler constructor

If the struct has many fields, you need a large constructor. If you are passing another struct simply because you have too many fields, that defeats the purpose and you might as well keep the fields public.

## Interface limits action

If the concern of using public fields is direct access to the field, you can limit that with interface.

For example, when constructing a repository, you might make the client public, because when declaring thr repository as dependency, you will only expose the specific method used.


## Mocking made easy

Declare the fields as interfaces, and easily swap them during testing.
