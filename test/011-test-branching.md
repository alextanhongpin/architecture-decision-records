The problem with a large function with many steps is it is proned to branching.


And branching means more tests to cover. 

To reduce branching

- test only 1 layer underneath
- remove branching logic by abstracting the step as an interface
