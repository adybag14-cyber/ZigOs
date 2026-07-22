#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zig=$($repo_root/scripts/bootstrap-toolchain.sh)

cd "$repo_root"
exec "$zig" build "$@"
