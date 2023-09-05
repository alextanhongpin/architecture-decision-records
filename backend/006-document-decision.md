# Document Decision

## Status

`draft`


## Context

A lot of technical decisions doesn't translate to code directly. 

Also, most decisions should also be based on abstraction, not implementation. The idea is we do want to couple the decision to the implementation. One quick litmus test is, can we rewrite it in language x while preserving the behaviour and/or outcome?

Comments in code may be useful, but does not give the full picture of the feature we are implementing.

## Decision

Place documentation close to the source code.

Any changes to the docs should not trigger deployment/CI/CD as they could be updated frequently.

Identify the type of changes too, some are small enough that they do not warrant a documentation, a git message or PR description is sufficient.

Avoid images, use text based image generator like mermaid which works in Markdown.


