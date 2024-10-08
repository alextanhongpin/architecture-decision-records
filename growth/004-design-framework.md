# Design Framework

We need a new framework for designing services.

Most concepts like clean/onion/hexagonal architecture are not useful to the business.

However, we cannot dismiss them entirely, as the speed of development as well as the technical debts depends heavily on code architecture.

At the same time, we want to be able to explain what our services do in laymans term, without going into details like repo, usecase, prometheus etc.

We can describe/design our services in terms of 3 basic pillar

- action, e.g user can log in
- consequences, e.g. user can carry our priveleged actions
- metrics, e.g. the number of daily logged in, the number of failed logged ins


The metrics, at basic follows the RED metric

- request, the number of times the service is requested
- error, the reason why it is not successful 
- duration, how long it takes to complete

- We are not talking about edge cases here.
