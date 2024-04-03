## Testing out logs

In unit test, we can also write the logs output so that we can trace the sequence.

This is useful to know what logs add value or not.
The same applies to errors and error stack.


- ring buffer


## Example

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"bytes"
	"fmt"
	"log/slog"
)

func main() {
	var sb = bytes.NewBuffer(nil)
	logger := slog.New(slog.NewJSONHandler(sb, nil))
	logger.Info("hello", slog.String("key", "value"))
	logger.Info("world", slog.Int("n", 37))
	fmt.Println(sb.String())
}
```

Output:

```
{"time":"2009-11-10T23:00:00Z","level":"INFO","msg":"hello","key":"value"}
{"time":"2009-11-10T23:00:00Z","level":"INFO","msg":"world","n":37}
```

We can then compare the output line-by-line by parsing it as JSON, and doing a partial match.
