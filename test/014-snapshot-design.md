# Snapshot Design


- formats
- options
  - ignore fields cmp
  - ignore paths cmp
  - mask field
  - file name/ext
  - color ansi diff or plain text
  - input/output directory
  - output raw
  - overwrite
  - notes
- output

## Jsondump

```
jsondump.Dump(t)
```

Dumps the struct as a pretty json object.

Usually the options for comparison are the same for the given type, so we want to be able to register them:
dump struct as json

```
jsondump.Register[T](opts)
```

The resulting options will then be combined with additional options.

We can create a new dumper with global options too

```
jd := jsondump.New(opts)
jd.Register(t, opts)
```

Both global and type options should be combined together. Note that type options is specifically for comparison, while global may be file location etc.

Jsondump will only dump 
- when no file exists
- when an overwrite is issues

Jsondump will only compare if
- already exists a snapshot
- which means first invocation needs to be executed twice

## Type Registry 

instead of creating multiple dumper for each type, or using struct tags to control the fields options, it is better to define a global type registry.

The dumper can then accept the registry as an option.

```
reg := jsondump.NewRegistry()
reg.Register(type, opts)

jsondump.Dump(t, v, jsondump.WithRegistry(reg))
```
