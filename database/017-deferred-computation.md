# Deferred Computation

Sometimes we want to update a column with some external api, but it is done asynchronously.

For example, we may want to so sentiment analysis on a description column.

However, calling the API is slow and we may want to update it daily, and not on every change of the body.

To keep track of when the column is updated, we need two columns: 
- description processed at
- description modified at

when the description is modified, we update the modified date 
we can then query the modified at > processed at and then run the update.
