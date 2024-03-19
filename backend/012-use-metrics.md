# Use metrics

## Context

Instrumenting application is essential to understand the scalability of your application.

Similar to a character in a game with HP/MP, agility, strength etc, collecting metrics will give you a better picture on your application stats.


## Decision
What stats are important? In a RESTful microservice context, we want to capture the stats for *all* endpoints we have.

This is important, and makes it easy to *trace error* when deploying new features.

For example, if we have an endpoint `POST /transactions`, capturing the success rate (defined by success 2xx over total minus irrelevant 400/404/422 code) will give better insights when we deploy a new feature that might potentially cause errors.

So, we want to log the following as labels:
- fragment path, e.g. `/transactions/{id}` (minus path params, query string)
- status code
- method

We want to record the following metrics
- total request count
- latency

and get the following visualization 
- percentile
- rate

How do we create the dashboard? If we have 100 endpoints, do we create a dashboard for each endpoints metrics? Probably nope, can we show the metric by the app and then allow granular searchinng?

### SQL

We can do the same for all clients like sql or redis etc.

### Client side

Above we implement it for server side calls. We can do the same for client side calls 



