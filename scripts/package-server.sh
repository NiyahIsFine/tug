#!/bin/sh
set -eu
workspace=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=${RELEASE_DIRECTORY:-"$workspace/dist/releases/server"}
version=$(python3 "$workspace/scripts/component_version.py" server)
if [ -e "$output" ]; then
    printf 'Refusing to overwrite package directory: %s\n' "$output" >&2
    exit 1
fi
commit=$(git -C "$workspace" rev-parse HEAD)
repository=${GITHUB_REPOSITORY:-$(git -C "$workspace" remote get-url origin)}
dirty=false
if [ -n "$(git -C "$workspace" status --porcelain --untracked-files=normal)" ]; then dirty=true; fi
mkdir -p "$output"
python3 - "$output/server-source.json" "$version" "$commit" "$repository" "$dirty" <<'PY'
import datetime
import json
import sys

path, version, commit, repository, dirty = sys.argv[1:]
if len(commit) != 40 or any(character not in "0123456789abcdef" for character in commit):
    raise SystemExit("Invalid source commit")
with open(path, "w", encoding="utf-8") as output:
    json.dump(dict(component="tug-server", version=version, source_commit=commit,
                   working_tree_dirty=dirty == "true", repository=repository,
                   platforms=["linux/amd64", "linux/arm64"],
                   built_at=datetime.datetime.now(datetime.timezone.utc).isoformat()), output, indent=2)
    output.write("\n")
PY
for architecture in amd64 arm64; do
    binary="$workspace/dist/tug-server-linux-$architecture"
    python3 - "$binary" "$architecture" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as binary:
    header = binary.read(20)
expected = {"amd64": 62, "arm64": 183}[sys.argv[2]]
if header[:6] != b"\x7fELF\x02\x01" or struct.unpack("<H", header[18:20])[0] != expected:
    raise SystemExit("Incorrect Linux ELF architecture")
PY
    directory="$output/tug-server-linux-$architecture"
    mkdir "$directory"
    install -m 755 "$binary" "$directory/tug-server"
    cp "$output/server-source.json" "$directory/source.json"
    printf '%s\n' "linux/$architecture" > "$directory/platform.txt"
    tar --mode=0755 -czf "$output/tug-server-linux-$architecture-$version.tar.gz" -C "$output" "tug-server-linux-$architecture"
done
cd "$output"
sha256sum "tug-server-linux-amd64-$version.tar.gz" "tug-server-linux-arm64-$version.tar.gz" server-source.json > server-sha256.txt
printf 'Server packages: %s\n' "$output"
