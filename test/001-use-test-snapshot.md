# Use Test Snapshot

## Status

`draft`

## Context
Goal
- visualize the variable value by dumping the representation into a file
- visibility in data structure transformation (e.g. SQL, data, json)
- reduce need to write self-assertions. For objects with complex structure, nested objects and large number of fields, we do not one to write assertions for each of them.
- rely on PR reviews to get feedback and catch inconsistency
- git-friendly test output. Diffable and part of the commit.

In snapshot testing, we only care about two things
- values must be equal, if not, what changed?
- schema must be correct. are the types or value matches the correct schema, e.g. email, time format, uuid, is boolean/number/string


For most tests, the step is usually as follow
- write a test
- assert the values match the expected


However, we can just simplify it by snapshotting the result, and compared it with the previous result. If the existing snapshot does not exists, it will first create the snapshot.

- avoid testing fields individually
- don't need to manually add new fields
- don't need to assert dynamic values such as date/random number/uuid

Additional functionalities may include intercepting and inspecting.

Intercepting can be used to perform the following:


- masking fields before dumping them (for security purposes)
- ignoring fields from comparison
- modifying data

Inspecting on the other hand allow custom validation, that the default diff doesn't handle.

Additionally, once we have the snapshot, we can load it to be used for other tests. For example, instead of rewriting fixtures, we can just dump the state and load it in another tests for replay. 

This adds several benefits by coupling the results to a shared snapshot. When it changes, your tests should warn you about the changes.

## Decision

### Implementation

We need to create two methods
- `dump(subject, path)`
- `match(snapshot, received)`

The dump method is responsible for dumping the result to a designated format.

More about the formats below.

The match method is responsible for comparing the dump output.

### Dump output

With a simple interface above, we can design custom dumper for different snapshot.

For example, we may want to dump the following:

- http request/response
- sql statement, args and result
- grpc request and response
- graphql query, input, and result
- redis operation, key/value
- message queue topic, message response

Dumping out data provides greater visibility on the data transformation that is happening within your system, especially if you have a large function with many steps.

Since most dependencies will be mocked, it is easy to decorate those dependencies with snapshotting capabilities.

### Patterns

- input output (request response, before after) mapper, constructor, marshalunmarshal
- http
- graphql
- grpc
- sql
- message queue
- redis
- events

### Why does this work

- diffing (addition/removal of fields)
- payload dissimilarity 


## Consequences 
