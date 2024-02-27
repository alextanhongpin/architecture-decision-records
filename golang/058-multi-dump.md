# Multi Dump


## Context

Snapshot testing involves creating an artifact containing a snapshot of the data you want to compare.
However, if there are multiple snapshots executed in a test, sometimes we just want to output them in one file.

For example, we may want to show the input and output of an operation.

We could display them as a single data structure, but representing them as multiple files seems to be a better choice.


Pseudo code:

1. init a dumper per test
2. call dump specific method

in golang, we can use txtar to dump the output to multiple files in one file. 
