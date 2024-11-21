# Postgres as a queue

This is an extension to previous docs about using postgres as a queue.

We want to scale this approach.

This can be done by creating partitions, and using a unique key to identify which partition to send the data to.


Then multiple consumer groups can be created to process the queue. How do we handle dynamic partitioning?

## Polling

The problem with polling is it can result in an infinite loop, when the processing fails.

There are multiple ways to mitigate this
- visible timeout: when selecting a record, set the visible timeout to the next one minute
- dead letter queue: move the item into a separate queue
