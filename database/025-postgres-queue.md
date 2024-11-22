# Postgres as a queue

This is an extension to previous docs about using postgres as a queue.

We want to scale this approach.

This can be done by creating partitions, and using a unique key to identify which partition to send the data to.


Then multiple consumer groups can be created to process the queue. How do we handle dynamic partitioning?

## Polling

The problem with polling is it can result in an infinite loop, when the processing fails.

There are multiple ways to mitigate this
- visible timeout: when selecting a record, set the visible timeout to the next one minute
- increment the retries and limit the number of retries 
- dead letter queue: move the item into a separate queue
- status change: change the status upon failure

## Efficient polling 


Instead of selecting one at a time, we can lock multiple rows at the same time. This requires proper handling, especially since we are running under the exactly once delivery assumption.

```
begin

select *
from jobs
order by id
for update skip locked
limit 1000;

for each job
  if is_processed(job) in cache
    update job status in db
    continue
  set job visibility in cache
  err = processs(job)
  set job status in cache
  update job status in db
commit
```
