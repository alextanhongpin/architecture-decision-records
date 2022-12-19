
## Distroless

`Distroless` images contains only your application and its runtime dependencies. They do no contain package manager, shells or any other programs you would expect to find in standard Linux distribution. [^1]


## Multi-stage build with Distroless example

```Dockerfile
FROM golang:1.19.4-alpine3.17 AS builder

# Add timezone information.
RUN apk update && apk add --no-cache git ca-certificates tzdata && update-ca-certificates

# Create appuser.
ENV USER=appuser
ENV UID=10001

RUN adduser \
	--disabled-password \
	--gecos "" \
	--home "/nonexistent" \
	--shell "/sbin/nologin" \
	--no-create-home \
	--uid "${UID}" \
	"${USER}"

WORKDIR $GOPATH/src/alextanhongpin/app/

COPY go.mod go.mod

RUN go mod download
RUN go mod verify

COPY . .

RUN CGO_ENABLED=0 go build -ldflags="-w -s" -o /go/bin/app

FROM gcr.io/distroless/static-debian11

COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

COPY --from=builder /go/bin/app /go/bin/app

USER appuser:appuser

CMD ["/go/bin/app"]
```


[^1]: https://github.com/GoogleContainerTools/distroless

