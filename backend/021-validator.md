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

To create a very generic one, we just need to supply 

```
name: string
cond: func(t typ) bool
error: the error
```

all we need is an expression parser:

```
// return error, because bool is binary. There can be multiple error
"min": func stringParser(expr string) func(val string) error {
  return func(s string) error {
   
  }
}

validator("email")
or
func (s string) error {
  // override error message
  return validator("error")(s)
}
```

```
p := strparser()
p.Add(key, fn)
compile(p, expr) {
 exprs := expr.split(',')
 for expr in exprs {
   fns.push(p.Parse(expr))
 }
 return fns
}

validate(val, fns...)
```
