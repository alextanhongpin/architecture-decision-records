# Dry Run

## Status

`draft`

## Context

Dry run is a way to test the behavior of a system without actually making any changes. This can be useful for testing new features or for debugging problems.

During a dry run, the system will:

* Run initial validation checks
* Log execution steps
* Return expected results
* Generate potential events

Dry run is often used in toolings, such as Terraform, to test changes before they are applied to production. It can also be used in domain-heavy applications to validate user input and show errors on the form.

For example, a rate limiter might have an `Allow` method that checks if an operation is allowed and increments a counter. However, there are times when we just want to check if an operation is allowed without actually incrementing the counter. In this case, we can use a `AllowAt` method to check if we can execute the operation at a later time.

**Decision**

We will add dry run support to our CLI, API, and packages. This will allow users to test behaviors and expected outcomes without changing internal state.

**Consequences**

Adding dry run support will have the following consequences:

* It will make it easier for users to test new features and debug problems.
* It will reduce the risk of making unintended changes to production systems.
* It will increase the confidence of users in the system.

We believe that the benefits of adding dry run support outweigh the costs. We are therefore proceeding with this change.
