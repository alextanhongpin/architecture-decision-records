# Json Response

What is the best way to represent data?


```json5
{
  "data": null,
  "error": {
    "code": "",
    "message": "",
    // "validationErrors": {}
  },
  "errors": {},
  // Graphql-style cursor pagination: https://graphql.org/learn/pagination/
  "pageInfo": {
    "hasNextPage": false,
    "hasPrevPage": true,
    "endCursor": "",
    "startCursor": ""
  }
}
```

The format below is a little more inconvenient. For each different entity, we need to extract the types separately as compared to just `response.data`.
For strongly typed language also, it means more types needs to be created to parse the different entities.

```json5
{
  "type": "user",
  "user": {},
  "error": {
    "code": "",
    "message": "",
  }
}
```
