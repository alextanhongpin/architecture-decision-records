# Cache patterns


There are many caching features thst are useful for apps.

We need to define the cache interface, and then allow others to implement them (e.g. in memory or redis).

One interesting idea is as long as the cache interface is there, we can just reuse the same cache for different feature, e.g. cache prewarming will help reduce the loader's need to fetch data.

Some useful or common implementation includes
- batch loading
- simple key value
- dataloader
- wait group
- cache expiry background
- cache warmup
- cache sharding for better writes 
- cache streaming (note that when doing warmup, we dont want to load all the data at once. it would be better to stream the changes and update part of the cache in batch.
 If the warmup requires deletion of keys, we need to know what keys have been removed.

We keep the sets of keys that are streamed. After all the keys were uodated, wr just delete those not in the nrw list.
- cache priority 


## Cache penetration

https://medium.com/@mena.meseha/3-major-problems-and-solutions-in-the-cache-world-155ecae41d4f
https://www.alibabacloud.com/en/knowledge/developer1/detailed-explanation-caching-problems?_p_lc=1

Use bloom filter, because attackers can use fake ids that will be cached if we set to `_nil_`.
