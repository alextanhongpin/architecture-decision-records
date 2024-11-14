# Monitoring

You can't improve what you can't measure.

For API, use RED.

For other product level metrics, we need to define what are the metrics that are useful
- daily usage
- daily active users
- revenue


## Monitoring Service

HTTP
- method
- path pattern (without params)
- status code

Simple service
- service name
- action
- status (ok or error)

SQL
- repository name
- query
- error code

Cache
- repository name
- key pattern
- hit or miss

For each service, we need a top-k.
  
