# Updating Rows

What is the better way?

- select the record (with locking), do some logic on the application side, and then update the record
- update the record directly in the database

The first approach is more common in the application code. It is easier to write and understand. However, it is not the best way to update the record. The second approach is better because it is faster and more efficient.

The first approach, if done without locking, may also cause inconsistency in the state of row. However, locking adds complexity and latency.

The second approach is better because it is faster and more efficient. It is also more reliable because it is done in a single step. It is also more scalable because it can be done in parallel. However, it shifts business logic to the database, which may not be desirable.

An example is for updating states. Using the first approach:

```sql
begin;
select * from orders where id = 1 for update;
-- do some logic in the application, e.g. check status pending
update orders set paid_at = now(), state = paid where id = 1;
commit;
```

Using the second approach:

```sql
update orders set paid_at = now(), state = paid where id = 1 and state = pending;
-- do some logic in the application, e.g. check affected rows
```
