# Use Constant


## Avoid const*.go

Avoid naming files with any variation of `const.go` to store constants.

Each constant serves a purpose, and they probably should belong to domain layer.


## Don't uppercase constant


```go
// Bad
const CODE_NOT_FOUND = 404


// Good
const CodeNotFound = 404
```

## Prefer constructor over constant


There are many times where constructor proves to be more useful than plain constant.

For example, you may have a constant to declare the expiry time of a campaign:


```go
var CampaignExpiredAt = time.Date(2023, time.January, 1, 0, 0, 0, 0, time.Local)
```

However, it doesn't serve much purpose there. Instead, add an accompanying function that utilizes it.

```go
package main

import (
	"fmt"
	"time"
)

var CampaignExpiredAt = time.Date(2023, time.January, 1, 0, 0, 0, 0, time.Local)

func CampaignActive(now time.Time) bool {
	return now.Before(CampaignExpiredAt)
}

func main() {
	now := time.Now()
	fmt.Println(now)
	fmt.Println(CampaignActive(now))
}
```


Other examples includes
- base url
- expiry duration
- cache prefix key
