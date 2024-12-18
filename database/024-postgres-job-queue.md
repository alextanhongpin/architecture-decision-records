# Postgres Job Queue

The implementation is almost similar like outbox, but with a few addition.

Things we want to support
- unique job - if an `external id` is provided (not null), then it must be unique
- adding a job in transaction - similar to outbox, job can be created atomically in a transaction
- ~priority~ - this only creates competiting consumers, hence it is dropped. We want to avoid processing only high priority job. A better way is to create separate queue for jobs that requires different priority.
- queue - jobs can be added to different queue, and they can be processed in parallel
- router - when sending multiple jobs to the same queue, we need different handling for different jobs, e.g. send welcome email or compress image. A router helps decide which function to execute
- logs - we want to store the events of the execution
- retry - a job can be retried a number of times before it is failed
- reset - a failed job can be enqueued again
- delayed job - a job can be delayed to be executed in the future. This can be paired with retry. However, it should not be treated as a cron. We can enqueue the job to a separate queue and let a Cron process the queue items
- history - jobs are persisted upon completion, with the result. However, this may increase the query size. It is recommended to run a periodic job to archive the job to a separate table. Alternatively, we can partition the job table by date. Partitioning the job table by status leads to conflict when selecting the job


## Handler

```
retryError(err, retryAt)
job.set_result
```

## Basic

The most basic job implementation just have two attributes, name and args:

```
insert into jobs(name, args) values (?, ?)
```

```sql
begin
select *
from jobs
for update
skip locked
limit 1;
-- do sth
delete from jobs where id = $1;
commit
```

This will delete completed jobs. To allow history, we need status:

```
pending
success
failed
```

To allow retries, we need to log the attempts.

To allow dead letter queue, we need to move the status to failed after n retries. We also need the ability to move it back to pending.

To allow delayed job, we need a timestamp property to indicate when the job should run.

To allow unique jobs, we need a unique id.


