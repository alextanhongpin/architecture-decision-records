# Singleflight

## Status

`draft`


## Context

Package singleflight provides a duplicate function call suppression mechanism.


In short, if we have a tasks that takes a long time and we want to compute it once when serving multiple requests, then singleflight fits the bill.

Some example of tasks:
- generating a large CSV (multiple requests for generating the same CSV report)
- rebuilding a materialized view

## Decision

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"
)

var g = singleflight.Group{}

func main() {
	now := time.Now()

	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		fmt.Println(do("foo"))
	}()

	go func() {
		defer wg.Done()

		fmt.Println(do("foo"))
	}()

	wg.Wait()

	fmt.Println("took", time.Since(now)) // This will only take 1s instead of 2s.
	fmt.Println("terminating")
}

func do(name string) (string, error) {
	resp, err, _ := g.Do(name, func() (interface{}, error) {
		fmt.Println("this is called only once")
		time.Sleep(1 * time.Second)
		return "bar", nil
	})
	if err != nil {
		return "", err
	}
	return resp.(string), nil
}
```

## Consequences

We can reduce duplicate requests for long running tasks.
