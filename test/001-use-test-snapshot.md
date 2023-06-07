# Use Test Snapshot

Goal
- visibility in data structure transformation (e.g. SQL, data, json)
- reduce need to write self-assertions

For most tests, the step is usually as follow
- write a test
- assert the values match the expected


However, we can just simplify it by snapshotting the result, and compared it with the previous result. ̛If the existing snapshot does not exists, it will first create the snapshot.


- avoid testing fields individually
- don't need to manually add new fields
- don't need to assert dynamic values such as date/random number/uuid


## Implementation

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

