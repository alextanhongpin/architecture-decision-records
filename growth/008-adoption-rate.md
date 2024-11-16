# Adoption Rate

## Status

`draft`

## Context

Even for free features, we should measure the performance of the feature.

In this case, it is the adoption rate. We can meausre adoption rate month over month by just measuring the number of unique users that calls the feature divided by the current number of users.

We can rank them and see which features are used more frequently.

Wr can also measure the month over monyh increase 

If wr release a new version of a service, we can see if every users have migrated or if thr new version is more pefromant.

if yhere are errrors wr can see yhe drop ij yhe adoption rate

## Implementation 

1. record the day-by-day, month-by-month unique user (logged-in) and cumulative actions for every feature
2. calculate the growth for each actions
3. sort the actions by highest growth

## Getting started

Steps to start measuring

1. setup prometheus

## Consequences
