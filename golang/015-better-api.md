When integrating third party APIs, developer need to write a client to call the third part API 

The focus shouldnt be on the http client, but the abstraction of the API.

- convert JSON to go struct
- test the client by using a testserver (serialization, deserialization)
- convert to domain model in repository layer
- no business logic
