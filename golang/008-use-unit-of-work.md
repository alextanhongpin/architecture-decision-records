# Use Unit of Work

## Status

`draft`

## Context

[uow](https://github.com/alextanhongpin/uow)


Unit of work is a pattern to manage the lifecycle of database transaction in your application.

(why exactly is unit of work)



Most people are aware of the repository pattern. However, most repository are designed poorly. They are assumed to work in separate connection, hence running them in a transaction is not possible.

In this ADR, we present a design that allows repository to take propagate transaction using context.

This ADR will also address the following questions

- where do we initialize the transaction
- committing and rollback
- running nested transactions
- rollbacking transactions in tests
- Query and Exec transaction

In an application, transactions are normally started in the application service layer.

However, since the repository layer itself is responsible for performing the query, the transaction connection needs to be passed down.

In the repository layer, the if no transaction connection is passed down, then the normal database connection is then used to perform the query.

In a strongly typed language, the transaction connection and nornal database connection may be of different types, so a interface (this could be abstract class in other languages) is required to represent the common methods between them.


### Passing down transaction object

We do not want to pass down the transaction as an argument to the method we want to run in a unit of work. This will lead to a poor experience where people will just pass in a nil db.

### Nesting transaction

Passing down explicitly also complicates the contract when there can be more than 2 layers that requires access to the transaction object. This can be for example, in integration testing, where we want to run a transaction in the test and perform a rollback.

## Decisions

### Context



## Consequences

- a cleaner interface for managing database transactions
- usecase layer is cleaner, since we don't explicity define the dependencies
- usecase layer becomes the origin of the transaction
- repository layer interface is cleaner, since it now supports both tx and non-tx
- repository layer needs to decide on which implementation to choose
- no accidental commit or rollback, also no forgotten commit or rollback too
- the caller will always close the transaction, none of the child can accidentally commit
