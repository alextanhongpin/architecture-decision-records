# Frameworks and Templates


Collection of useful framework and template for product engineering.

Don't use them for the sake of using them. Adding more processes complicated developments and adds overhead.

Instead, try to make the process seamless.

In my own words, make it as _natural as breathing_.

## Example: ChangeDocs

Each team should have their own engineering changedocs.

This is usually used to record the changes for a decision, when it cannot be tracked in a version control.

For example, your API is experiencing heavy latency, and the root cause is found to be a slow query due to missing indices in your Postgres table.

At that time, migrations are usually run from your CI/CD. However, there is no time to go through the deployment pipeline if a quick fix is needed.

The action taken at that time is to just manually executing the index creation in production database, and syncing the schema back locally.


Those actions and the reason of change should be documented in a changedocs with the relevant people tagged.


## TODO

- onboarding steps
- on-call runbook
- development guide
	- setting up database/redis/infras
	- setting up local server
	- setting up services
- deployment guide
- database migration guide
- change docs for applying scripts
