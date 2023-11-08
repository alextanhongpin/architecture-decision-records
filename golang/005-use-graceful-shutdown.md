# Use Graceful Shutdown

##  What

Graceful shutdown ensures existing processes are terminated before the server is shut down. This could be

- connection to external services and databases
- processes such as database transactions that has yet to commit
- a (long) running http requests that has yet to return a response
- logger that has yet to flush its output to stderr/stdout

## Why

Without graceful shutdown, the program is terminated immediately, leading to partial failures and potentially data loss.

For example, your server may be configured to receive a webhook. When the webhook is received, the request will be stored in the database. However, due to sudden termination, the program exits before the database saves the request.

## How

The implementation below shows how to implement a generic method to handle graceful shutdown.

```go
package server

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/rs/zerolog/log"
)

const (
	MaxBytesSize    = 1 << 20 // 1 MB
	readTimeout     = 5 * time.Second
	shutdownTimeout = 5 * time.Second
	handlerTimeout  = 5 * time.Second
)

func New(handler http.Handler, port int) {
	log := log.With().Str("pkg", "server").Logger()

	// SIGINT: When a process is interrupted from keyboard by pressing CTRL+C.
	//         Use os.Interrupt instead for OS-agnostic interrupt.
	//         Reference: https://github.com/edgexfoundry/edgex-go/issues/995
	// SIGTERM: A process is killed. Kubernetes sends this when performing a rolling update.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Instead of setting WriteTimeout, we use http.TimeoutHandler to specify the
	// maximum amount of time for a handler to complete.
	handler = http.TimeoutHandler(handler, handlerTimeout, "")

	// Also limit the payload size to 1 MB.
	handler = http.MaxBytesHandler(handler, MaxBytesSize)
	srv := &http.Server{
		Addr:              fmt.Sprintf(":%d", port),
		ReadHeaderTimeout: readTimeout,
		ReadTimeout:       readTimeout,
		Handler:           handler,
		BaseContext: func(_ net.Listener) context.Context {
			// https://www.rudderstack.com/blog/implementing-graceful-shutdown-in-go/
			// Pass the main ctx as the context for every request.
			return ctx
		},
	}

	// Initializing the srv in a goroutine so that
	// it won't block the graceful shutdown handling below
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Err(err).Msg("listen error")
		}
	}()

	// Listen for the interrupt signal.
	<-ctx.Done()

	// Restore default behaviour on the interrupt signal and notify user of shutdown.
	stop()

	// The context is used to inform the server it has 5 seconds to finish
	// the request it is currently handling
	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Err(err).Msg("forced to shut down")
	} else {
		log.Info().Msg("exiting")
	}
}
```

Example of graceful shutdown

```go
func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		select {
		case <-ctx.Done():
			fmt.Println("http graceful shutdown")
			w.WriteHeader(http.StatusOK)
		case <-time.After(2 * time.Second):
			fmt.Fprint(w, "hello world")
		}
	})
	server.New(mux, 8080)
}
```
