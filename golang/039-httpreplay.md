# HTTP Replay

## Status

`draft`

## Context

The ability to replay HTTP is useful when working on API integration. I often came across integrating with API without having the documentation side by side, so the payload shape is mostly unknown.

This becomes a problem when the payload size is huge and when `fmt.Println` doesn't make the data easier to digest.

One common approach is to just write the payload to a file.

## Decision

Implement a module `httpreplay` which is similar to `httpdump`, except that it works with http client and dumps the payload to a writer.

The function should only have two options:

- filename to write to
- overwrite the existing dump
