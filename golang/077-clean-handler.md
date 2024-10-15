```go
// You can edit this code!
// Click here and start typing.
package main

import (
	"fmt"
	"net/http"
)

func main() {
	fmt.Println("Hello, 世界")
}

type endec interface {
	Decode(r *http.Request, req any) error
	Encode(w http.ResponseWriter, res any) error
	Error(w http.ResponseWriter, r *http.Request, err error)
}

type Handler struct {
	endec
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.Error(w, r, h.do(w, r))
}

func (h *Handler) do(w http.ResponseWriter, r *http.Request) error {
	var req any
	if err := h.Decode(r, &req); err != nil {
		return err
	}

	// do sth

	var res any
	return h.Encode(w, res)
}
```

actually a bit redundant, we should hide the error information.

We have two patterns

- separate encoder decoder
- base controller pattern, where we embed a struct containing all the methods
