# Long Running Task Healthcheck

## Status

`draft`

## Context

When executing long-running tasks, it is important to have visibility into the progress of the job. This can be difficult to achieve without adding additional instrumentation to the system.

## Decisions

To improve visibility into the progress of long-running tasks, we can add healthchecks to the system. Healthchecks can be used to log the output of the task, display a progress bar, or record the errors and successes.

## Consequences

Adding healthchecks to the system can improve visibility into the progress of long-running tasks. This can help to identify problems early and prevent them from causing larger issues.

Here are some specific examples of how healthchecks can be used to improve visibility into the progress of long-running tasks:

* **Logging the output of the task:** This can help to identify errors that are occurring during the execution of the task.
* **Displaying a progress bar:** This can help users to track the progress of the task and to estimate when it will be completed.
* **Recording the errors and successes:** This can help to identify problems that are occurring during the execution of the task and to track the overall success rate of the task.

By adding healthchecks to the system, we can improve visibility into the progress of long-running tasks. This can help to identify problems early and prevent them from causing larger issues.
