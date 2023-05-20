# Use Test Snapshot

Goal
- visibility in data structure transformation (e.g. SQL, data, json)
- reduce need to write self-assertions

For most tests, the step is usually as follow
- write a test
- assert the values match the expected


However, we can just simplify it by snapshotting the result, and compared it with the previous result. ̛If the existing snapshot does not exists, it will first create the snapshot.


- avoid testing fields individually
- don't need to manually add new fields
- don't need to assert dynamic values such as date/random number/uuid
