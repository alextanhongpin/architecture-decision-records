# Processing Outbox


There are many ways to process rows in the database that is concurrent free. We will explore several approaches based on the criteria below


- ordered vs unordered processing
- single-worker vs multi-worker
- at least once
- stream vs batch processing
- idempotency

## Ordered vs Unordered processing

We can process the rows in order, which is one-by-one in the order FIFO.

For example, we have a table with unique incrementing ids. If we have 10 rows with id 1 to id 10, we process the row with id 1, then 2 until all rows is processed.
To ensure this happens sequentially, we need to have one processor only, and we do a `select for update` and delete the entry after processing is completed.

If the order is not important, we can just do a `select for update ... skip locked`. Thr advantage is we can spawn multiple workers.

## Single worker vs multi worker

As discussed above, use single worker when processing sequentially, and multi workers for unordered processing.

To avoid conflicts from worker, we can assign each of them an id.

For example, worker 1 will only take odd number, while worker 2 takes even number.

Or simply
```
worker id = id modulo number of worker
```

The problem with this is we may have slow and fast workers. This may result in strong unordering in processing.


## At least once

We cannot have an exactly once guarantee, since the process can fail before the transaction commits.


## Stream vs batch 

For stream, we process rows one by one, regardless if it is sequential or parallel.

However, stream processing means more query to the database.
We can fetch the rows in batch instead, and delete the entire batch on completion.

We also need an approach to track the progress of each batch.


```
rows = query by batch criteria (e.g. range, limit)
for each row
  check if done
  continue if done
  do sth
  set done
end
delete batch
```

## Pooling 

Some pooling strategy for sequential ordering includes:


```
loop:
for range limit
  begin
  select for update
  if no row, break
  do work
  delete
  commit
sleep duration
```

The rows are processed sequentially. To allow concurrent processing, we just create a semaphore and run them concurrently. There is additional complexity, if one query does not return a row, we need to cancel all jobs.

Fail on first error:

```
ctx, cancel = context with cancel
wg sync.waitgroup
for range limit
  select ctx done
    break
  wg.add(1)
  sem.acquire(1)
  go func () {
    defer wg.done
    defer sem.release(1)
    row = select one
    if no row then cancel
    process row
  }()

wg.wait()
```

