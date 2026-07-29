FROM golang:1.23-alpine AS build
WORKDIR /src/rpc
COPY rpc/go.mod rpc/go.sum ./
RUN go mod download
COPY rpc/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
    -ldflags="-s -w" -o /out/counter-adapter \
    ./reference/counter/cmd/counter-adapter

FROM scratch
COPY --from=build /out/counter-adapter /counter-adapter
USER 65532:65532
ENTRYPOINT ["/counter-adapter"]
