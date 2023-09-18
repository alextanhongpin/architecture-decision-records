# Database Design Records

## Status


`draft`


## Context


Similar to architecture design records, the database design records documents the design decisions for a database feature. The feature could include schemas, triggers, constraints logic and indices.

One or more solutions could be proposed, however, only one should be implemented in the end.

Often, the lack of proper documentation leads to legacy schemas that is hard to understand and work on. Business logic could span different applications, and could be done differently if not enforced in the design.

Although it is easy to treat the database as dumb data layer without logic, applying behaviour in database layer could simplify a lot of design decision, particularly those that requires atomicity.


## Decision


For any feature that touches the database, create a database design record as documentation.
