# Global Config


## Status
`draft`

## Context

Instead of creating multiple APIs that does a small subset of things like serving assets, we want to create global config that will be served through API endpoint.


The API can be used for config/toggle, and serve any kinds of purpose like assets etc.

The should be a functionality to upload image and convert it to urls.

The data can be primitive or json format, and they can be validated with json schema.

To avoid conflicts, the created configs will be tagged to admin user id, and can be grouped by tags.

- tags
- type
- data
- schema
- admin id
- note
