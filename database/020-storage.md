# Minimizing Storage


There are just a few relationships when designing storage

- one-to-one, can be avoided by placing the column in the same table. In some case it makes sense to create a separate table when the table becomes too huge and migration is not possible without downtime or when the usage is so scarce (e.g. only 1% of user fills this optional column)
- one-to-many, limit the number of rows that can be created, or archive them (e.g. old notifications)
- many-to-many, usually reference table

There are special cases where one-to-many can be placed together as an array or json column too.

However, this is only possible if there are no aggregation needed or the need to search across that individual items.


Are there other useful data structure like bloom filter that we can utilize?
The problem with bloom filter is the initial overhead when there are no data. Also there can be race condition when updating it.
You can only add, not remove entries in a bloom filter too, unless you recreate it.

This makes is suitable to capture events like user engaged etc.
