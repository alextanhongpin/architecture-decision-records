# Factories vs Fixtures


## Context

We want to allow an easier way to construct and/or create entities.

By constructing, we want to allow creating different variants of an entity.

For example, your application has user with different roles, such as `superuser`, `admin`, `guest`, `owner` etc.
During testing, we want to ensure all of these roles are covered. Hence, the factory should allow creation ofnalthe different roles.

We want to differentiate between creating it in memory vs creating it in the database.

Factories are meant for creating local (non-persistent) entities while fixtures allows creating the rows in the database.

Fixtures are useful when you want to test your repository layer.

creating entities in the database may not always be straightforward, because the order of creation matters when there are foreign keys involved. We will explore a better way of writing our code that allows less LOC.

When defining invariant, there are several useful tips.

- for field level, use field name as prefix, e.g. amount zero, amount negative, age below 13
- for entity level, use a type, state or specific name, e.g product can be iphone, android, state can be expired, paid, specific name like book title/country
- for user, use persona, e.g. Alice, Bob, John
- for user, use roles like superuser, admin, guest.


End result:

chainable constructor, less line of code. Show the metrics before and after.

