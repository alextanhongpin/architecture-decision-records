# Outbox Pattern

## Status

`draft`

## Context

Closely related to unit of work, because we need to save the events to the outbox table atomically.


## Decisions

### Storage

We can store the events in an outbox table. A database with transactions such as postgres is preferred

### Publishing events

Upon writing, we can send the events immediately for processing.


### CDC

## Consequences


How do we measure the effectiveness of outbox patterns?

- atomicity in delivery
	- events are persisted atomically with the transaction
- less code to write
	- this implementation has less code that other implementation
