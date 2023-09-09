# Developer Metrics

## Status


`draft`

## Context

Measuring developer metrics is useful to understand and gain insights on how things works. It is hard to improve on things you cannot measure.

The metrics collected are not meant for comparing against different developers. The managers in charge of the developers should have a clear understanding on how the metrics and the scope of the developers tally.


What metrics are useful?
- the number of commits?
- the LOC written?
- the usefulness of the PR
- the languages that are touched.

To calculate the lines changed since last commit:

```bash
git diff --numstat head~1
```

Rate of change:

```
new value - old value / old value * 100%
```

## Decisions


To measure, first we need to understand what changes:


- the repositories that are impacted
- the number of merge commits since the last timeframe (e.g. daily from 0:00 to 0:00)
- the diff stats for each commit
- the language touched
- if readme, docs word counts change

```
stats {
	start_date: '',
	end_date: '',
	repositories: repository[],
}

repository {
	name: string
	commits: commit[]
	action: created | modified | deleted
}

commit {
	added: int
	removed: int
	language: string
}
```

Questions:
- how to fetch repositories
- for each repositories, how to fetch commits within a certain time range
- for each commit, how to find the stats
- where to run (cron, daily, github actions)
- where to store (postgres, sqlite, git commit to repository daily)
- where to visualize -> website

Range
- daily
- weekly
- monthly
- yearly
- all time


