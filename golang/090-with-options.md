# With Options

Instead of using functional options, or pointer to option, we create an always valid instance with `New`.

The instance should have a default configuration that is sensible. 

To configure the instance, call the `WithOptions/WithConfig` method that will return a new instance with the desired configuration.


This allows
- valid instance with sensible configuration
- customizing the instance when needed
- no redundant types like functional options
- optional options


```go

type Retry struct {}

func New() *Retry {}

func (r *Retry) WithOptions(opts Option) *Retry{
   return &Retry{}
}


r := New()
r := New().WithOptions(opts)

```
