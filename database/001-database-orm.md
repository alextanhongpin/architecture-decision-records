# Database ORM

## Context
Deciding whether to use an Object-Relational Mapping (ORM) tool for database interactions.

## Decision
We considered using an ORM such as bun.

## Consequences

### Advantages
- **Nested Associations**: ORMs like bun provide advantages in loading deeply nested associations.
- **Raw Queries**: They allow the execution of raw SQL queries when needed.

### Disadvantages
- **Standard SQL Interface**: ORMs often do not conform to the standard SQL interface, leading to potential inconsistencies.
- **Integration**: They can be harder to integrate with tools like go txdb.
- **Maintenance**: Some ORMs may no longer receive updates or might be deprecated in favor of newer ORMs (e.g., go-pg to bun).

## Conclusion
Given the advantages and disadvantages, careful consideration is required to decide whether an ORM is suitable for the project's needs.
