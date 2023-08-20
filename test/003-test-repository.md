# Test Repository

## Status

`draft`

## Context

Testing repository should be done by executing the tests through an actual database.

This can be achieved by running test containers using docker.

Performance can be improved by database specific settings, e.g. disabling fsync or running it in tmpfs.


The guarantee it delivers is better than the following options
- mocking
- running embedded database (still not an option for postgres and mysql)
- swapping to sqlite

We only test against an actual database in the repository layer. Once we have successfully tested the repository layer, subsqelayers that calls the repository (e.g usecase) can just nocthr repository.

Other testing pattern applies here
- migration
  - run it once for the whole database in your test startup, and cleanup afterwards
  - migrate only the tables you need (some libraries can migrate by inferring the data structure like gorm. if you have migration files, you can selectively run the files that modifies the table you want to test)
- seed
  - seed the base data, e.g. user with different membership. Dont seed the table you want to test. Instead, use the repository methods to create them.

Parallel
- use template database
