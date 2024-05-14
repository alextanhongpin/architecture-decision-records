# Rate limit in db

instead of using postgres, we can use sqlite, since it is faster.

it saves ram by storing the rate limit per user in disk.

we can periodically clear the table. 

we can also use this to block users with many attempts

- last count
- last allow at
- user
- resource

if denied
- increment denied count, clears after 1 day
- set reset at, which is multiply of denied count * retry interval
- deny once, 1m (after 3 failed attempts)
- deny twice, 5m
- deny thrice, 15min
- deny fourth, 1h
- deny fifth, 1 day
