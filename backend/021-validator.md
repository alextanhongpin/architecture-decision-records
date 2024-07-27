# Validator

Let's design our own validator. The requirements are as follow

- no reflect
- compile-time safety
- chainable
- supports slices
- generic enough
- can add own validation
- can customize errors


```
v = new ValidatorType()
v.add("type", fn)
err = v.validator("type", value)
```
