# Config

## Status

`draft`

## Context

When loading config, the best practice is to load them from environment variables.

However, there are times where we have to load config from other sources, such as file, external config store etc.

We first differentiate config from secrets. Config is defined as application configuration and unlike secrets, are mostly static (requires no rotation) and have no detrimental impact when fallen to the hands of others.

### Limit size

Some providers like AWS has limits in the environment variables size, e.g. up to 4096 characters. 

### Validation

We usually load config as string, without excessive validation, such as just checking if the values exists etc. Adding validation in code is good, but it cannot be shared across different services.



## Decisions

We explore pickle to generate safe, validatable configurations in our application.
