# Use Context


Use context for timeout. Don't use timer, e.g. 

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"time"
)

func main() {
	t := time.NewTimer(1 * time.Second)
	done := make(chan bool)
	defer close(done)
	for {
		select {
		case <-t.C:
			fmt.Println("timeout")
			break
		case <-done:
			break
		}
	}
}
```

Because the timer cannot be cancelled, use context is better:

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"context"
	"fmt"
	"time"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	for {
		select {
		case <-ctx.Done():
			fmt.Println("timeout")
			break
		}
	}
}
```

## Context without cancel

Most of the time, we have a task that shares context when performing cleanup:

```go
func task(ctx context.Context) {
  defer unlock(ctx)
  lock(ctx)
  // do stuff
}
```

Notice the issue above? When the context is cancelled, the unlock will not be called. To ensure the `unlock` is called, we need a different context from the one passed to `lock`. This can be easily done with `context.WithoutCancel`:


```go
func task(ctx context.Context) {
  defer unlock(context.WithoutCancel(ctx))
  lock(ctx)
  // do stuff
}
```
