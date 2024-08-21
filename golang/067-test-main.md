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

func TestSth(t *testing.T) {
  // Get a global DSN
  dsn := pgtest.DSN()
  // Get a normal db connection.
  db := pgtest.DB(t)
  // Get a transaction db connection
  // Automatically rolls back changes.
  tx := pgtest.Tx(t)

  // Sometimes we want to work on a separate db instance.
  p := pgtest.New(t, pgtest.Image("postgres:17"), pgtest.Hook(migrate))
  dsn := p.DSN()
  db := p.DB()
  tx := p Tx()
}
```

## Design 

```go

var client *Client

func Init(opts ...Option) func() {
  once.Do(func() {
    client = NewClient()
  })
  return client.Stop
}

func DB(t *testing.T) {}
func Tx(t *testing.T) {}

type Client struct {
  dsn string
}

func (c *Client) init() {
  c.dsn = ...
}

func (c *Client) DB() {
  return sql.Open(c.dsn)
}
func (c *Client) Tx() {
  // once
  txdb.Register("txdb", "postgres", c.dsn)
  return sql.Open("txdb", uuid.New().String())
}
```
