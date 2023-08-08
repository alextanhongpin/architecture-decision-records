# Status

## Status

`draft`

## Context

### Status Enum

Status here refers to the state of an entity, or a flow. For example, an `Order` can be in the following states:

- `Pending`: The `Order` is pending payment
- `Paid`: The `Order` is paid
- `Expired`: The payment is not made in the given time
- `Refunded`: The `Order` has been refunded

The state happens as a result of an action. In code, we can represent them as an enum.

```go
type OrderStatus string

var (
	OrderStatusPending OrderStatus = "pending"
	OrderStatusPaid OrderStatus = "paid"
	/* REDACTED */
)
```


### Status Inferred

However, sometimes the status can also be inferred from other related fields.

For example, when it comes to fulfillment, the status of the fulfillment may be inferred from the fields that are present or not. Below, we see an example of a `Fulfillment` (NOTE: this doesn't represent an actual domain, just an example). We have several statuses, and the current status always depends on whether certain fields are present or not.

```go
type Shipment struct {
	courier   string
	shippedAt time.Time
}

type Fulfillment struct {
	airwayBill  *string
	shipment    *Shipment
	deliveredAt *time.Time
}

func (f *Fulfillment) isPending() bool {
	return f.airwayBill == nil && f.shipment == nil && f.deliveredAt == nil
}

func (f *Fulfillment) isReady() bool {
	return f.airwayBill != nil && f.shipment == nil && f.deliveredAt == nil
}

func (f *Fulfillment) isShipped() bool {
	return f.airwayBill != nil && f.shipment != nil && f.deliveredAt == nil
}

func (f *Fulfillment) isDelivered() bool {
	return f.airwayBill != nil && f.shipment != nil && f.deliveredAt != nil
}
```

### Nested Status

This can be made more complicated with nested statuses. Extending the example above, the `OrderShipment` now depends on the `Fulfillment` status.

```go
type OrderShipment struct {
	firstMileDelivery *Fulfillment
	lastMileDelivery  *Fulfillment
}

func (os *OrderShipment) isFirstMileDelivered() bool {
	return os.firstMileDelivery != nil && os.firstMileDelivery.isDelivered()
}

func (os *OrderShipment) isLastMileDelivered() bool {
	return os.lastMileDelivery != nil && os.lastMileDelivery.isDelivered()
}

func (os *OrderShipment) status() string {
	switch {
	case os.isFirstMileDelivered() && os.isLastMileDelivered():
		return "last_mile_delivered"
	case os.isFirstMileDelivered():
		return "first_mile_delivered"
	default:
		return "pending_shipment"
	}
}
```

Note that the `last_mile_delivered` status __must__ be after the `first_mile_delivered` status.


### Status Reversal

Status does not necessarily moves in one direction only. For example, once a payment is made, an order can still be refunded, and the payment refunded.


### Status Sequence

One thing is certain - the status must move in a certain sequence. We cannot skip sequences, not accidentally undo a status. However, it is very easy to make those mistakes in a distributed system, when the sequence of events may not be linear.


For example, a customer may be making an order, but not paying immediately. However, the admin realises that the product that is ordered is no longer in stock, and procedes to cancel it. At the same time, the customer may already be proceeding with the payment. What should the final status be?


## Decision

As discussed above, the status of an entity should be updated in the right sequence. To ensure atomicity when updating the status of an entity, a lock must be acquired, and the status must be validated before any action can be taken.


Ideally, all status transition should only happen in a single place, e.g. an aggregate. Since domain aggregates should not include external dependencies like database etc that is required to store, possibly lock and update the states, we alternative approach. That can be publishing events, or creating another service `Transitioner` to validate and handle the state transition.

The logic to determine the current status could also be improved by introducing checkpointing.

A more complicated option is to use bitwise operator to check if steps are partially completed and valid. For most cases, a simple for loop is sufficient.



## Consequences

TBD
