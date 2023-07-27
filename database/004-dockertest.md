# Testing using docker


## Status 

`draft`

## Context

We want to ensure our database layer is well tested and querying/executing the statement does what it should do 

There are several options below, each with it's pros and cons:

- running with sqlite
- running a local database instance
- running the database instance in a container
- running an embedded database
- running the database through wasm
- just validate the sql statement by using parsers

Ideally, the solution we choose provides a strong guarantee that our storage layer is working.

Some of the important things to assert includes but is not limited to the following
- the sql query generated is valid
- the sql actually executes
- the data is serialized and deserialized correctly
- the sql have the same fingerprint
- the raw sql is dumped
- the normalized sql is dumped (by normalized, we mean the format is consistent, the variables are stripped, and the keywords are canonicalized, and the order of variables does not matter)
- the logic works (inserts, query, filter)

## Decision

Use docker. The lib should provide the following interface:

`DB/Tx` 

Use sqldump.

## Consequences
