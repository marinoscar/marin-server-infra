# Build boringproxy
FROM golang:1.17-alpine3.15 AS builder
WORKDIR /build
RUN apk add --no-cache git ca-certificates
COPY ./src/ .
RUN cd cmd/boringproxy && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -o /out/boringproxy

# Minimal runtime with certs available
FROM scratch
WORKDIR /storage

# ✅ Add trusted root certificates
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# binary
COPY --from=builder /out/boringproxy /boringproxy

EXPOSE 80 443
ENTRYPOINT ["/boringproxy"]
