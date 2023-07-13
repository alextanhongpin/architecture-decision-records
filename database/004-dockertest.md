# Testing using docker

We want to run and execute our tests in containers.

This gives us several advantage over just mocking.

We can verify
- the sql query generated is valid
- the sql actually executes
- the data is serialized and deserialized correctly
- the sql have the same fingerprint
