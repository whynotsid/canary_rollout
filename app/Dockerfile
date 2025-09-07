# syntax=docker/dockerfile:1.6
# Build Podinfo from source
FROM golang:1.24 as build
WORKDIR /src
# Grab podinfo source
RUN git clone --depth=1 https://github.com/stefanprodan/podinfo.git .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /out/podinfo ./cmd/podinfo

# Minimal runtime (non-root)
FROM gcr.io/distroless/static-debian12:nonroot
USER nonroot:nonroot
WORKDIR /app
COPY --from=build /out/podinfo /app/podinfo
EXPOSE 9898
# Health endpoint: /healthz will be served by podinfo
ENTRYPOINT ["/app/podinfo","--port=9898","--port-metrics=9999","--level=info"]
