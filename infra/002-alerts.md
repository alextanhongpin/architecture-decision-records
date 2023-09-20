# Alerts

## Status

`draft`

## Context

How alerts are created for services, and how to notify developers (email, slack).

This includes real time monitoring.


There are a few metrics to measure, namely RED and USE.

RED is an acronym for rate, errors and duration.

USE is an acronym for utilization, saturation and errors.

For each of our services, we just need to set an SLA.

### Error rates

Error rates is the measure of the total errors divided by the total requests in a given period


The problem with error rates is it is independent of the total number of requests. For example, the error rate when receiving 1 error out of 2 requests and 1000 errors out of 2000 requests is still 50.

Setting an error rate to <50% often leads to noisy alerts, especially when the number of request is low. 

To reduce false positive, set the error rates threshold to be above 50%. 


### Escalation

When it comes to metrics, assigning priority doesn't make sense, since everything is a priority.

Instead, we want to focus on the speed of escalation. Is the service quickly hitting the threshold? Or are they something that can we can spend investigating slowly?

For alerts that requires fast escalation, set a smaller period, but high enough threshold for stronger confidence. For example, error rate within the last 5 minutes hitting 90%.

An SLA on the other hand could be less than 10% error within 1 week.

