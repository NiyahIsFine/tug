#!/bin/sh
set -eu
workspace=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(python3 "$workspace/scripts/component_version.py" server)
mkdir -p "$workspace/dist"
cd "$workspace/server"
for architecture in amd64 arm64; do
    CGO_ENABLED=0 GOOS=linux GOARCH="$architecture" go build -trimpath \
        -ldflags="-s -w -X main.version=$version" \
        -o "$workspace/dist/tug-server-linux-$architecture" ./cmd/tug-server
done
sha256sum "$workspace"/dist/tug-server-linux-*
