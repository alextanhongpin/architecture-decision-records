# State Machine



State machines describes the transition of states and the accompanying action that follows the state change.

Most of the time however, we just want to guard against invalid state transition.

Below is a simple implementation of a function to check if a state transition is valid.

```go
package main

import (
	"fmt"
)

func main() {
	fmt.Println(IsValidTransition(Pending, Success))
	fmt.Println(IsValidTransition(Success, Failed))
}

type Status string

const (
	Ready   Status = ""
	Pending Status = "pending"
	Failed  Status = "failed"
	Success Status = "success"
)

func IsValidTransition(prev, next Status) bool {
	return (prev == Ready && next == Pending) ||
		(prev == Ready && next == Failed) ||
		(prev == Ready && next == Success) ||
		(prev == Pending && next == Failed) ||
		(prev == Pending && next == Success)
}
```


We can then implement it this way:

```golang
package main

import (
	"errors"
	"fmt"
)

var ErrInvalidStateTransition = errors.New("invalid state transition")

func main() {
	o := &Order{}
	fmt.Println(o.Complete(), o.status)
	fmt.Println(o.Complete(), o.status)
}

type Order struct {
	status Status
}

func (o *Order) Complete() error {
	prev, next := o.status, Success

	// Guard
	if !IsValidTransition(prev, next) {
		return ErrInvalidStateTransition
	}

	// Do something ...

	// Transition
	o.status = next

	return nil
}
```
