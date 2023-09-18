# Optimistic Locking

## Status

`draft`

## Context

Optimistic locking allows multiple transactions to complete without interfering with one another, without acquiring a lock. Before committing, each transaction verifies that no other transaction has modified the record it has read.

## Decision

Add a concurrency token or version column to a row if optimistic locking is required.
