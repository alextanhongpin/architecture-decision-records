# Cache

We will explore more advanced application caching.


The most common way of caching includes lazy caching.

In this scenario, the app attempts to retrieve the data from the cache first, and return the value if it exists.

Otherwise, it will fetch the data and populate the cache before returning the value.

This works well if we visualise the operation as a sequential one.

However, there can ve scenarios where multiple requests are made before the cache is populated.

For such scenario, we may want to wait for the cache to be populated first instead of repeatedly hitting the database and setting the values.


