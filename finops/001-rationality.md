## FinOps Rationality

When it comes to cutting cloud cost, the first thing most people do is to switch to a different cloud provider.

Unfortunately this will only work for a short term.

The reason is simple - there are no behavioural changes that encourages savings.

Considere the following, you have a tenant that always leaves the lights on 24/7. Your solution is to simply to get rid of the tenant and get another one. The outcome will most likely be the same with the new tenant.
If instead, you set a ground rule like turning off the lights when it's not in used, you would have saved more.

Even better is to have one that automatically turns off when no presence is detected.


## Good Morning, Good Night

We can save a lot by turning the lights off too for our server. 
Think about it, let's say we are running our staging environment 24/7, that would be roughly 720 hours per month.

In reality, you dont need it running all the time.
If you have a 8hr workday, that would just be 160 a month after excluding weekends.

That would account to just 20% of the cost. If you are paying 1$ per hour the instance is running.

Write a script that will pause the instance after work hours.

Of course this works only if everyone is in the same time zone.

But within a team, this is manageable.
