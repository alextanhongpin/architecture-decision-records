# Database ORM

To use ORM or not. 

ORM such as bun has some advantages when t comes to loading deeply nested associations.

They also have the advantage of being able to execute raw query.

Some disadvantages however is that it doesnt conform to the standard sql interface. 

There are also harder to integrate with when tools like go txdb.

The worst part is that they may no longer receives update or they are deprecated in favor of newer orm (e.g. from go-pg to bun).

