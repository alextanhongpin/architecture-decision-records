# Passing data

For errors, avoid passing data back to users.

Errors are different than assertions, we just need tell the users what is the expected values.

In tests, we usually tell users what is their expected value, and the got value.

```
want email to be abc, got xyz
```

For errors, we can just say

```
xyz is not an email
```

We don't need to pass the data `abc` back. 


This makes error design stateless. The invariants can be defined as constant. Otherwise if it is computed, we don't want to expose the internals on why the value is expected to be.

We can just say it fails the invariant. We can still log the actual cause, but the presentation errors shouldn't include it 

