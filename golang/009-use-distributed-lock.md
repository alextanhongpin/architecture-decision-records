# Use distributed lock


Distributed locks are used to prevent concurrent access to a shared resource by multiple processes. This can be achieved by using a distributed locking service, such as Redis or ZooKeeper.

**Note:**

* Distributed locks are not a substitute for proper concurrency control. They should only be used when it is necessary to prevent concurrent access to a shared resource.
* Distributed locks can introduce additional latency to your application. You should carefully weigh the benefits of using a distributed lock against the potential performance impact.
* Distributed locks can be used to implement distributed transactions. However, you should carefully consider the implications of using distributed transactions before doing so.
