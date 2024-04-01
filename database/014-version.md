# Storing App Version in row

## Status

`draft`

## Context

We want to store the version of the app in the row for rapidly changing business logic.

For example, when migrating a column usage, we can either create a new column or modifying existing column.

The issue with the former is it might not be feasible for large tables.

For the latter, this might happen when we changed the usage, for example a format for reference number.

When changing the version, the app needs to know how to handle the different version.

Example:

```
// v1
sha-yymmdd

// v2
uuid
```

This might impact how joins are made.
