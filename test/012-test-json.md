# Test JSON

We want to compare JSON, because it is human-readable.

There are a few strategies to diff json. 

One option is to define the json schema using cuelang, which is less verbose.

We can store both the schema and the example payload in golang's txtar. Then, we can validate with either of them.

https://github.com/alextanhongpin/learn-cuelang/blob/master/go/validate.go


We can convert the golang type to cue:
https://github.com/alextanhongpin/learn-cuelang/blob/master/go/go-to-cue.go

Unfortunately there doesnt seem to be any way to convert json to cue validation. But we can take advantage by just doing equality check using the json value.


Pseudocode is as follow:

- create the file with a schema and data
- if it exists, skip
- load the schema and data from the file
- if there is a schema, compare the schema
- if there is a data, compare the data
- if the schema mismatch, show the error
- if the data mismatch, show the diff

