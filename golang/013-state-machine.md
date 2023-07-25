# Linear Flow with State Machine

## Status

`draft`

## Context

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

One use of state machine when working in distributed system is to guard against non-linear path. 

Some examples of non-linear path includes
- the system has two sequential steps that needs to be executed in serial in order to accomplish a task. If not guarded, user can call step 2 before step 1.
- with the same example above, user can also attempt to call step 1 after step 2 is completed. It may be intentional or not.

In short, each steps needs to know about the previous and next steps to be called. 

This can be made more complicated if the flow has multiple steps that are conditional, or if each steps itself has it's own flow.

Do the following litmus test to check if your app has non-linesr flows
- do you require multiple API calls to complete a flow

Aside from non-linear path, state machine can also help with optimistic concurrency

- do you have a class with multiple methods working on the same resource

## Decision

For each flow, we can assign a unique identifier, e.g. `create-order-flow-${some unique id}`.

Then, before executing the flow, we can do the following

- lock by the identifier (e.g. using distributed lock or postgres advisory lock, or other distributed locking mechanism)
- check the state of the step if it is allowed. This could be statuses stored in different tables. Check if prev step and next step status match.

We could alternatively store the whole flow state as a DAG that could server as a document too.

This is not the same as a rule engine, as we do not care about the rules for the step to be valid. We only need to know if the step can be executed relative to previous steps or not.

```go
orderFlow = NewOrderFlowDecider()

orderFlow.Lock(ctx, orderId)
defer orderFlow.Unlock()

if orderFlow.CanCreate() {

}

func (d *OrderFlowDecider) CanCreate() {
  // check prev step state (if no previous step, then check if the flow is allowed)
  // check current step state
  return false
}
```

For most cases, you might not care about the intermediate flow, or perhaps the flow can be treated as a single step. In that case, it is sufficient to just check if the identifier exists.

## Consequences

- a standardised approach on dealing with idempotency and state transitions
- guarding against non-linesr flow


