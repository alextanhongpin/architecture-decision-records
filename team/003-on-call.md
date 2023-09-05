# On Call


## Status

`draft`

## Context

On call rotation should involve all engineers.

However, there are few issues that are usually not addressed in the on-call scheduling:

- experience: on call for a new joiner can be tough especially when there's not much context
- action item: under high pressure, it is easy to be clueless and maybe even careless when attempting to resolve the issue.
- responsibility: an issue can span across different responsibility. Is it happening on the frontend, backend, infra etc, and does the team consist solely on single stack engineers?


## Decisions

If there are new joiners, the best way to onboard them to on-call rotation is to have a more senior engineer to partner with. Also, each on-call should ideally have one primary and another secondary engineer.

When creating alerts/metrics that triggers the on-call, we should also link all relevant docs that could be useful:

- link to runbook, which includes mitigation steps or previous resolution 
- link to centralised logging (e.g. kibana)
- link to project repository
- link to other relevant docs

Whenever an issue is resolved, it is important to always add the steps to resolve it in the runbook if the issue is expected to be recurring.

If the issue is unexpected and is of high priority, then a post mortem should be created.

Sometimes we have to deal with services written by other teams. There can be absolutely zero context on what the service does and how to resolve the issue.

The best way is to just find the owners of the service for help  If they are no longer there, then a quick fix should be to toggle off the service (feature toggle is a must have), and spend some time understanding the service before deciding on the resolution.

A quick fix may not always be desirable, as it could lead to more damage.

## Conclusion

Dealing with on call should be plan strategically.
