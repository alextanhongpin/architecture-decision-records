## Use EXEC syntax

What is the difference between the syntax below?

```bash
# SHELL form, /bin/sh -c /go/bin/…
CMD ["/go/bin/app"] # output of 47facfd6c8ea

# EXEC form, "/go/bin/app"
CMD /go/bin/app # output of 16554a390f0d
```


> The SHELL form runs the command as a child process (on a shell).

> The EXEC form runs the executable on the main process (the one that has PID 1). [^1]


The `COMMAND` output of `$ docker ps -a`

```
CONTAINER ID   IMAGE                      COMMAND                  CREATED              STATUS                          PORTS     NAMES
16554a390f0d   alextanhongpin/app:0.0.2   "/bin/sh -c /go/bin/…"   About a minute ago   Exited (0) 39 seconds ago                 competent_merkle
47facfd6c8ea   1a73a3d36064               "/go/bin/app"            2 minutes ago        Exited (0) About a minute ago             optimistic_newton
```


This is especially important for _graceful termination_ of the server. If the shell form is used, the app will not receive the correct termination signal.




[^1]: https://engineering.pipefy.com/2021/07/30/1-docker-bits-shell-vs-exec/#:~:text=The%20SHELL%20form%20runs%20the,process%20(on%20a%20shell).&text=The%20EXEC%20form%20runs%20the,one%20that%20has%20PID%201).
