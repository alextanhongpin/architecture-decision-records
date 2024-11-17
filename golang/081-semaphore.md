# Semaphore

Use semaphore to limit concurrency. There are better ways though, which is to use golang's errgroup, which has a similar functionality built-in:

```go
package main

import (
	"context"
	"fmt"
	"time"

	"golang.org/x/sync/errgroup"
)

func main() {
	g, ctx := errgroup.WithContext(context.Background())
	_ = ctx
	g.SetLimit(2)
	for i := range 3 {
		// Launch a goroutine to fetch the URL.
		g.Go(func() error {
			fmt.Println("work", i)
			time.Sleep(time.Second)
			return nil
		})
	}
	// Wait for all HTTP fetches to complete.
	if err := g.Wait(); err != nil {
		panic(err)
	}
	fmt.Println("done")
}
```
