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

Above we see the implementation of a local state. 

However, most of the time, we don't run a single server. The state can be distributed.

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

### Data representation

We can represent states as follow

```
pending, success, failed
```

For asynchronous flow, we may not be able to mark the step as success or not, so we need another boolean:

```
not started, pending, success, failed
```

For idempotent operation, it can just be

```
happened, not happened
```

Perhaps we have a SLA for retries and/or expiration

```
remaining
limit
retriesIn
```

If a step failed, we may also want to record the reason and mark the step as retryable, or permanently failed:

```
err
canRetry
terminated
```

We can provide manual cancellation if we no longer want to run the step. The state machine can check if the flow is failed.


Another possibility is reversal. After successful flow, we may still want to reverse the state.

This is commonly known as saga.

## Locking

State transition should only be done by a single process. For this, we need to either lock the entity in-transition or add check to prevent modifying the state of the entity in the database.

The former is necessary if we care about idempotency of the operation (exactly omce), such as payments. The latter is acceptable when there are no harmful side-effects like making a campaign inactive as opposed to handling refund.

The check can be as simple as checking the version of the entity being modified or the prev/next status or both.

The pseudocode is as follow

```
func transition(from, to)

begin
select...for update nowait (where tatus = from)
check valid transition
// do stuff
update ... set status = to where status = from and id = some_id
commit
```

## Status vs steps

Status transition vs steps trafnsition seems to overlap, and can be confusing when misunderstood.

First, let's define state as the current condition of the system.

A system's state can move from one to another, and that is usually through interactions with various components. We define the steps as an operation that cause a change od status in a system.

A workflow comprised of a series of steps that is executed in a particular order. In a more complex system, the steps can be undo (saga). Each steps can have it's own internal status too (not started, pending, success and failed) and usually the sum of these states define the state of the system.

Usually a timestamp is used to mark that the step is completed for strictly sync task. For async task where the step csn be waiting for the trigger, e.g message queue.
It is more useful than a boolean because of the additional information it provides.

Asynchronous task adds complexity, because now within a step, we have a series of mini steps to take before completing the steps. And there is a lot to handle
- exactly once only
- idempotency
- failure handling
- retries
- change in state while processing (aborted, or cancelled by admin)


### Bitwise for sequential steps

We can use bitwise operators for sequential steps.

The limitation is it is limited to 32 steps.

But we can easily use this to check if all the steps are executed linearly.


```
# mark both steps as completed
a = step1 | step2

# check has step 1
a&step1 == step1

# check we have completed n steps
a == 1<<(n+1)-1
```


## Status patterns

This three status goes a long way:

```
pending, success, failed
```

Usually for async task, we also have the `idle` status:

```
not_started/idle, pending, success, failed
```

Any other status can be categorized as `unknown`. Sometimes the status can also be placed under `limbo`, if we choose not to handle them.

For a workflow, we can have a series of steps with the statuses above. The status of the workflow depends on the individual statuses. There is also some logic we must follow
- a step can only be started after the previous step completed
- each step must be completed in sequence
- a step can fail, or not failed
- if a step failed, it can either retry, or choose to rollback all previous steps before, only if they can be rollback
- steps can be sync or async. Async steps usually wait listens to external events to move the state
- the overall workflow can be paused and resumed. This happens at workflow level, not steps

With the rules above in mind, we can design:
- forward only transaction (all steps must succeed), or can be compensated
- sync/async step

## Consequences

- a standardised approach on dealing with idempotency and state transitions
- guarding against non-linesr flow


