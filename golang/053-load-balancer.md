# Load Balancing

## Status

`draft`

## Context

Load balancing is the process of distributing load evenly based on certain heuristic.

This is commonly used where there are multiple instance of an application and the load has to be distributed equally among them.

However, they can also be used for other purpose such as A/B testing and autoswitch.

A/B testing is a special scenario where requests are split into two groups
 Autoswitch on the other hand allows us to switch API implementation based on the health of the provider.

 One example is payment integration. You may have multiple payment provider, such as Stripe and Paypal. When one of them fails, you may want to switch to another partner, until the other recovers.


 This may be useful if the API is unreliable, or has certain rate limit applied.

 The same can be applied for scraping, buy switching API keys instead when the rate limit exceeded.
