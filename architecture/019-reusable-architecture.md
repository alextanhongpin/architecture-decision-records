# Reusable architecture 


After trying many architecture pattern like clean, onion, hexagonal etc, they all doesn't seem to fit the bill.


There are many architecture goals, but they are mostly to satisfy the engineer's preference. There is always these strange tendencies to organize code in a way only one would understand, but that ultimately leads to others getting confused on the execution.

Why is it important then to come up with a standarized code structure?

The reasons are
- lower mental barrier when starting a project
- no digging into the rabbit hole on what's the best practice to do sth
- avoid circling back into other options when one is decided - and justification on why the alternative is unacceptable


What are the goals of the system, and what is considered a good architecture that fulfills it?


- simplicity in reproducing a new service
- template for future projects
- easier testing (aka dependencies are declared as interfaces)
- faster developement
- better monitoring

## Feature driven
Each directory is a feature.

Each feature contains use cases.
