# Use Repository

#### What

A repository is an **interface** that provides access to a **data store**. It is responsible for **persisting** and **retrieving** entities.

#### When

You should use a repository when you need to:

* **Abstract away the details of the data store**. You don't want your application code to be coupled to the specific implementation of the data store.
* **Encapsulate the logic for persisting and retrieving entities**. This makes your application code more maintainable and easier to test.

#### How

To use a repository, you first need to create an instance of the repository interface. You can then use the repository methods to persist and retrieve entities.

Here is an example of how to use a repository in Java:

```java
// Create a repository instance
Repository<User> repository = new UserRepository();

// Persist an entity
User user = new User("john@example.com", "password");
repository.save(user);

// Retrieve an entity
User retrievedUser = repository.findById(user.getId());
```

#### Anti-patterns

There are a few common anti-patterns to avoid when using repositories.

* **Not using an interface**. If you directly implement the repository interface in your application code, you will tightly couple your application code to the specific implementation of the data store. This makes your application code less maintainable and more difficult to test.
* **Not encapsulating the logic for persisting and retrieving entities**. If you put the logic for persisting and retrieving entities in your application code, you will make your application code more difficult to maintain and test.

#### Fetching aggregates

When you fetch an entity from a repository, you may also want to fetch the entity's associated entities. This is called **fetching an aggregate**.

For example, if you fetch a `User` entity from a repository, you may also want to fetch the user's `Address` and `Phone` entities.

You can fetch an aggregate by using the `findById()` method with a `fetch` parameter. The `fetch` parameter specifies the entities that you want to fetch along with the entity that you are querying for.

Here is an example of how to fetch an aggregate in Java:

```java
// Fetch a user and its associated entities
User user = repository.findById(user.getId(),
    Fetch.of(Address.class, Phone.class));
```

#### Ports (interfaces) and adapters

When you use a repository, you should define a **port** (interface) for the repository and implement the port in an **adapter**. The port defines the public API for the repository, and the adapter implements the port and provides the concrete implementation of the repository.

This separation of concerns makes your application code more maintainable and easier to test.

Here is an example of how to define a port and an adapter for a repository in Java:

```java
// Define the port for the repository
public interface UserRepository {

  User findById(String id);

}

// Implement the adapter for the repository
public class UserRepositoryAdapter implements UserRepository {

  private final UserRepositoryImpl repository;

  public UserRepositoryAdapter(UserRepositoryImpl repository) {
    this.repository = repository;
  }

  @Override
  public User findById(String id) {
    return repository.findById(id);
  }

}
```
