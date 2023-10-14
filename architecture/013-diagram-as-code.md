# Diagram as Code

## Status

`draft`

## Context

We want to explore using diagram as code tool such as Mermaid.js.


## Decisions

Use diagram as code.


### Cron Job

Example of a cron job that runs daily:

```mermaid
sequenceDiagram
    participant src as Server
    participant sys as LeaderboardService
    title: Leaderboad Cron Jobs

    src->>+sys: update leaderboard
    loop daily
        sys->>sys: update rank
        sys->>sys: update level
        sys-->-src: done
    end
```

### Usecase as Flow Diagram

Start by providing the diagram, then explain each step where necessary:

```mermaid
---
title: Leaderboard Update Level
---
%%{init: {'theme': 'default', 'themeVariables': {'darkMode': false}, "flowchart" : { "curve" : "stepBefore" } } }%%
flowchart TD
    start([Start])
    valid_date?{is 1st of 15th?}
    is_new_season?{is new season?}

    find_active_leaderboard[/Find active leaderboard/]
    find_last_leaderboard[/Find last leaderboard/]
    not_found{Not found}
    update_ranking[/Update ranking/]
    update_ranking_after_level_up[/Update ranking after level up/]
    update_level[/Update level/]
    exit([End])

    start --> valid_date?
    valid_date? -- no --> exit
    valid_date? -- yes --> is_new_season?
    is_new_season? -- no --> find_active_leaderboard
    find_active_leaderboard --> not_found

    is_new_season? -- yes --> find_last_leaderboard
    find_last_leaderboard --> not_found

    not_found -- yes --> exit

    not_found -- no --> update_ranking
    update_ranking --> update_level
    update_level --> update_ranking_after_level_up
    update_ranking_after_level_up --> exit
```

#### is 1st of 15th?

The leaderboard level up is only done every 1st or 15th of the month.

#### is new season?

When a new season starts, we need to use the old leaderboard as reference.

```sql
select * from leaderboards where ...
```
