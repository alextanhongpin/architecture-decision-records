long living transactions

- lock the saga identifier to avoid concurrent action, and use nowait for postgres lock
- ensure that multiple processes (e.g. multiple app instances) does not operate on the same job
- store the saga logs
- allow retries
