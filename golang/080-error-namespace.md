# Error Namespace


Once we have errors set for the application, the next thing we want is to namespace them. This avoid issues with finding the root cause of the error.

For example, once we have several applications using the same error convention, we may find this in our log.

```
code: user/not_found, msg: User does not exist
code: user/not_found, msg: User may have been deleted
```

But they actually belong to different apps. We should prefix the code with a namespace. The namespace could be the app name, or the library where the error originated from, e.g.:

```
code: authsvc.user/not_found, msg: User does not exist
code: core.user/not_found, msg: User may have been deleted
```

The first originates from the `authsvc`, the second is from the `core` package.

Aside from that, we should also log the app version.
