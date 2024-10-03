

Create a nested route:


```go
package main

import (
	"fmt"
	"net/http"
)

func main() {
	mux := http.NewServeMux()
	mux.Handle("GET /foo", fooHandler())
	mux.Handle("GET /bar", barHandler())

	fmt.Println("listening on :8080")
	http.ListenAndServe(":8080", mux)
}

func fooHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("foo")
		w.Write([]byte("foo"))
	})
	return mux
}

func barHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("bar")
		w.Write([]byte("bar"))
	})
	return mux
}
```

Controller - group of http handlers, without routing
Handler - the route definition for the controllers
