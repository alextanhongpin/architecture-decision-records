A more scalable approach to calculate the error rate instead of using fixed window.

We can compare the difference here.
```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"math/rand"
	"time"
)

func main() {
	lastSuccess := time.Now()
	lastFailure := time.Now()
	var success, failure float64
	for _ = range 100 {
		time.Sleep(time.Duration(rand.Intn(200)) * time.Millisecond)

		if rand.Intn(10) >= 1 {
			failure = count(lastFailure, failure)
			lastFailure = time.Now()
		} else {
			success = count(lastSuccess, success)
			lastSuccess = time.Now()
		}
		fmt.Println(success, failure, failure/(failure+success))
	}
}
func count(last time.Time, n float64) float64 {
	delta := time.Now().Sub(last)
	rate := float64(delta) / float64(10*time.Second)
	rate = min(1, rate)
	rate = 1 - rate
	n *= rate
	n++
	return n
}
```

- instead of using distributed cache, you can use sqlite or even in-memory, especially if the metrics isn't tied to revenue
- most of the ideas behind rate limiting is to just prevent resource abuse, so as long as it doesn't bring down an instance, it is fine if the user exceeds the limits
- alternatively, when the limit is reached, we can just increment a counter, and then check how many times the counter is triggered
