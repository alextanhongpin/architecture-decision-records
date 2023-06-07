# Use Unit of Work

[uow](https://github.com/alextanhongpin/uow)


Unit of work is a pattern to manage thr lifecycle of database transaction in your application.

Most people are aware of the repository pattern. However, most repository are designed poorly. They are assumed to work in separate connection, hence running them in a transaction is not possible.

In this ADR, we present a design that allows repository to take propagate transaction using context.

This ADR will also address the following questions

- where do we initialize the transaction
- committing and rollback
- running nested transactions
- rollbacking transactions in tests
- Query and Exec transaction

