# Batching


## Status

`draft`

## Context

When batching, it is common to set a max size for a batch. However, it can be inefficient.

Example of batch size 10, and we have 21 items.

Then we will have the following batches:

```
batch 1: 10
batch 2: 10
batch 3: 1
```

## Decision

Batch by splitting it equally if the size is known.

```
bins = ceil(21/10) = 3
size = 21/3 = 7 
```

## Consequences

More equally distributed batch.
