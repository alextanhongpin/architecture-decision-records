# Test Main

In golang, we use `TestMain` to initialized global dependencies such as database or redis.


We only do it once because it takes time to setup db migration etc.

For certain scenarios, we can also spin up additional separate db just for testing.


```go
func TestMain(m *testing.M) {
  stop := pgtest.Init(pgtest.Image("postgres:17"), pgtest.Hook(migrate))
  code := m.Run()
  // We cannot defer because os.Exit does not care about defer.
  stop()
  os.Exit(code)
}
```
