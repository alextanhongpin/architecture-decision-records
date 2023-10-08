# Semaphore

## Status

`draft`

## Context


Bulkhead limits concurrent goroutines as a way of preventing system overload. This is essentially the worker pool pattern.

https://github.com/resilience4j/resilience4j/issues/1367



## Decision

Implement semaphore to control the number of running goroutines.
A timeout can be set so that the worker does not wait forever.

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"golang.org/x/sync/semaphore"
)

func main() {
	sem := semaphore.NewWeighted(1)
	ctx := context.Background()

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()

		fmt.Println("no timeout:start")
		do(ctx, sem)
		fmt.Println("no timeout:end")
	}()

	go func() {
		defer wg.Done()
		ctx1, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
		defer cancel()

		// Add a delay to ensure that this task starts later.
		// This goroutine will failed to acquire the semaphore due to timeout.
		time.Sleep(50 * time.Millisecond)
		fmt.Println("timeout:start")
		do(ctx1, sem)
		fmt.Println("timeout:end")
	}()

	wg.Wait()

	fmt.Println("terminating")
}

func do(ctx context.Context, sem *semaphore.Weighted) {
	fmt.Println("starting ...")
	if err := sem.Acquire(ctx, 1); err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			fmt.Println("took too long...")
			return
		}
		panic(err)
	}

	// Pretend to do work
	time.Sleep(1 * time.Second)
	fmt.Println("done")

	defer sem.Release(1)
}
```

## Consequences

We can limit the number of running operations.
