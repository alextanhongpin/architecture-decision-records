# Use Migration

Migration can be done using [db-migrate](https://db-migrate.readthedocs.io/en/latest/Getting%20Started/configuration/).



## Installation

First, install the required dependencies.

```bash
$ npm i --save-dev db-migrate
$ npm i --save-dev db-migrate-pg # Required if using postgres as the source database.
```

## Config

Then, create the `.env` file to store the credentials:

```
DB_NAME=test
DB_USER=john
DB_PASS=123456
DB_HOST=127.0.0.1
DB_PORT=5432
```

Create a config file for `db-migrate` at `config/database.json`:

```json
{
  "development": {
    "driver": "pg",
    "user": {"ENV": "DB_USER"},
    "password": {"ENV": "DB_PASS"},
    "host": {"ENV": "DB_HOST"},
    "database": {"ENV": "DB_NAME"},
    "port": {"ENV": "DB_PORT"},
    "schema": "public"
  }
}
```

## Commands

To save us from typing the long commands, we create a makefile `Makefile.db.mk`. Splitting makefiles into smaller makefiles makes it more manageable. They can then be included in the primary Makefile:

```makefile
# Makefile
include Makefile.db.mk
```

```makefile
# Makefile.db.mk
migrator = ./node_modules/.bin/db-migrate --config config/database.json --env development --migrations-dir migrations

migrate:
	@$(migrator) up

rollback:
	@$(migrator) down

new_migration:
	@$(migrator) create $(name) --sql-file
```

We can now run the following commands:

```bash
$ make new_migration name=create_table_users
$ make migrate
$ make rollback
```
