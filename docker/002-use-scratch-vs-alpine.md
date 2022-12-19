## Using scratch vs alpine

The issue with `scratch` is the lack of debugging capability (same for `distrolless`, see below).

> FROM scratch literally is an empty, zero-byte image / filesystem, where you add everything yourself [^2].

So when running the following command, we will get an error:

```
$ docker exec -it $(docker ps -q) ps -ef
```
Output:

```
OCI runtime exec failed: exec failed: unable to start container process: exec: "ps": executable file not found in $PATH: unknown
```

The solution is to replace `FROM scratch` with:

```Dockerfile
FROM alpine:latest

# Allow `$ docker exec -it (pid) bash` instead of `$ docker exec -it (pid) /bin/sh`
RUN apk add bash
```
