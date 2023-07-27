# Integration test with grpctest and grpcdump

## Status

`draft`

## Context

Integration testing is important to validate the behaviour of your system. For gRPC, we also want to test if the client/server interaction is correct, especially when we have interceptors setup. 

When testing gRPC, we look at the following:

- service request
- service response
- metadata request
- header response
- trailer response
- status code (and error)
- messages

However, testing them individually means copy-pasting code from one test to another, with just some variation to the wanted result. For scenarios where we have a large number of fields to assert, snapshot testing helps save time.



## Decision

### Setup buffered connection

To test the integration between client and server, we can use buffered connection. This is preferable over stubbing, since stubbing doesn't really test the streaming component.

We can setup the server in the test main, or per test.

### Snapshot testing

The suggested dump format is:

The idea of snapshot testing is to replace manual assertion with visualization. 


## Consequences
