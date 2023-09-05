# System Flow


## Status

`draft`

## Context

Before writing code, the most important thing is to just write down the expected system flow in steps.

The system flow should describe step-by-step how to achieve the end result from the request.

Each steps are just actions that the system carry out, such as querying data, running logic such as validating or modifying them, and maybe even interacting with exterbal services.

Since steps can fail, we should also design the alternative steps or errors that will be returned.

Writing them down instead of starting with code gives better clarity, because in a lot of cases, the intent is just gone or may not be clear enough after translating to code. 
Where do we keep this steps? They can be stored along code or even better, translated as tests.

## Decisions

Consider the usecase of user registration:

```md
System flow: Register User
1. validate email format, password length and name format
2. check if email is registered
3. encrypt the password
4. save the user
5. return a token with user id as a subject
```

We can translate them to test cases such as this:

```
# Validate steps
it validates the request
it checks if the email is registered
  when registered
  when not registered
it encrypts the password
it saves the user
it returns a token

# Validates full flow
it registers a new user
  when success
  when failed
```
