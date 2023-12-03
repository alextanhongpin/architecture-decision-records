# How to write quality packages?

Aside from correctness, we also need to focus on
- good developer experience
- easy integration
- less code
- less dependencies
- easy to maintain
- testable


Measure
- line of codes changed
- execution time (did it become better or worse +- 10%)
- code coverage (% covered)
- memory/cpu usage (summary)
- number of dependencies imported (count and summary)


Why?
- because most of the time, code is written to only fulfil usecases
- as long as it works, it works
- we do not care about the quality of the code
- aside from capturing regression through unit/integration tests, we also want to measure performance

- How do we measure quality?
- store the last 100 benchmark
- also store the lowest benchmark
- compare the diff between last and new
