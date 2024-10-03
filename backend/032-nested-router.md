

Create a nested route:


```go
package main

import (
	"fmt"
	"net/http"
)

func main() {
	mux := http.NewServeMux()
	//mux.Handle("GET /foo/", http.StripPrefix("/foo", fooHandler()))
	// Need the ending trailing slash and strip prefix for it to work.
	mux.Handle("GET /foo/", http.StripPrefix("/foo", &FooHandler{}))
	//mux.Handle("GET /foo/{pathname...}", &FooHandler{})
	mux.Handle("GET /bar", barHandler())

	fmt.Println("listening on :8080")
	http.ListenAndServe(":8080", mux)
}

type FooHandler struct{}

func (h *FooHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /foo1", func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("foo")
		w.Write([]byte("foo1"))
	})
	mux.HandleFunc("GET /foo2", func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("foo")
		w.Write([]byte("foo2"))
	})
	//handler, pattern := mux.Handler(r)
	//fmt.Println("pattern", pattern)
	mux.ServeHTTP(w, r)
}

func fooHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("foo")
		w.Write([]byte("foo1"))
	})
	mux.HandleFunc("GET /foo2", func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("foo")
		w.Write([]byte("foo2"))
	})
	return mux
}

func barHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("bar", r.Pattern)
		w.Write([]byte("bar"))
	})
	mux.HandleFunc("GET /2", func(w http.ResponseWriter, r *http.Request) {
		fmt.Println("bar", r.Pattern)
		w.Write([]byte("bar"))
	})
	return mux
}
```

Controller - group of http handlers, without routing
Handler - the route definition for the controllers
