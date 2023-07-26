# Limit Text Length

## Status

`draft`

## Context

Some database like mysql has `varchar(n)` type that limits the size of the column. For Postgres, using `text` seems to be the norm, which however does not have any character limitation.

MySQL truncates the text without warning, so it may sometimes lead to unexpected behaviour. For mysql version >8, constraint checks has been added. However, it is unclear if the text will be truncated first or checked before truncating.

The issue with long text is we can't control what the users input. So it is always better to set limit to avoid abuse (like storing huge json as string).

Also, it will lead to huge index size if the column is indexed.


## Decision

Add constraint check to limit the text length.

For postgres, we can create custom types with different length, such as `short_text`, `long_text` that suits our application use case.

Application should also handle checking, though the behavior may drift if thr database constraints are updated without the application knowing.


## Consequences

- predictable behaviour with text length
- better performance because users can't throw long text
