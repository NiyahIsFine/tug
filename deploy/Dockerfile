FROM --platform=$BUILDPLATFORM golang:1.26.2-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN test "$VERSION" = "$(tr -d '\r\n' < VERSION)" && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w -X main.version=$VERSION" -o /out/tug-server ./cmd/tug-server

FROM alpine:3.23
ARG VERSION
ARG SOURCE_REPOSITORY=https://github.com/NiyahIsFine/tug
ARG SOURCE_REVISION=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="Tug server" \
      org.opencontainers.image.source=$SOURCE_REPOSITORY \
      org.opencontainers.image.revision=$SOURCE_REVISION \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.created=$BUILD_DATE
RUN apk add --no-cache ca-certificates
COPY --from=build /out/tug-server /usr/local/bin/tug-server
USER 65532:65532
EXPOSE 16640
HEALTHCHECK --interval=60s --timeout=3s --start-period=5s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:16640/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/tug-server"]
