# Redis Convention

In this ARD, we focus on the best way to organize redis client. 

## Setter and Getter

The naive way is to just set the keys as constant, and then use the methods like set/get.

However, in large codebase, finding the pairs aren't always easy. 

```python
def cache_products(): pass
def get_cached_products(): pass
```

It is better to just create a pair of setter/getter, similar to repository pattern.

Benefits
- can mock the interface
- easier to search the code


## Centralized Redis

One advantage of having all the usecases for cache in a folder is that it is easy to migrate or make changes.
