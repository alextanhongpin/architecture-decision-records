
Can consider adding `>=` in query string...

```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"net/url"
)

func main() {
	u, err := url.Parse("http://gugle.com?price=>10&age=<10&date=2024")
	fmt.Println(u, err)
	fmt.Println("Hello, 世界", u.Query())
	// http://gugle.com?price=>10&age=<10&date=2024 <nil>
	// Hello, 世界 map[age:[<10] date:[2024] price:[>10]]
}
```
