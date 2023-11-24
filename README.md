# Architecture Decision Records

My own personal ADR.


## Why

- to record the why
- narrow down hard choices (most comparisons are apple vs oranges)
- what is obvious to you may not be obvious to others
- a decision tree for architecture
- a framework to pick the right decision for the right problem. This is not meant to standardize and practices. Part of the `it depends` philosophy.
- At the same time, we want to avoid not having any opinions. Bad practices can actually propagate in an organization (copy paste code). I have seen examples where codes are just reused without understanding the context or implications and they are spread across different repositories.
- could this decisions be translated into linters etc so that it won't be manual? we can use llm too to suggest the changes to users. Build a linter

  
## Template

```markdown
# Title

## Status

<!--What is the status, such as proposed, accepted, rejected, deprecated, superseded, etc.? -->
`proposed`


## Context

<!--What is the issue that we're seeing that is motivating this decision or change?-->


## Decision

<!--What is the change that we're proposing and/or doing?-->


## Consequences

<!--What becomes easier or more difficult to do because of this change?-->
```
