# Test JSON

We want to compare JSON, because it is human-readable.

There are a few strategies to diff json. 

One option is to define the json schema using cuelang, which is less verbose.

We can store both the schema and the example payload in golang's txtar. Then, we can validate with either of them.

https://github.com/alextanhongpin/learn-cuelang/blob/master/go/validate.go
