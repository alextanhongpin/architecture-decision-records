# Validator

Let's design our own validator. The requirements are as follow

- no reflect
- compile-time safety
- chainable
- supports slices
- generic enough
- can add own validation
- can customize errors

syntax

```
optional,min=10
required,in=abc def,max=10
```

```
v = new ValidatorType()
v.add("type", fn)
err = v.validator("type", value)
```

The function design should accept params

```
func validator(type, val, params string) error {
 // params can contain data or annotations like name of the field 
}

func minValidator(type, val, params string) error {
  // but this is not compile time safe
}
```
