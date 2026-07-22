#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(tr -d '\r\n' < "$repo_root/.toolchain-version")
tag=upstream-5d08e47160ad

machine=$(uname -m)
case "$machine" in
    x86_64|amd64)
        arch=x86_64
        expected=958a4325cf3d108590fa21069cca2a87d881eff3ca75a6e53b73056b49d6437e
        ;;
    aarch64|arm64)
        arch=aarch64
        expected=9750043eeaae775cffb049837be4d5dd9e6ebb055802743db1e87262148f4e88
        ;;
    *)
        echo "unsupported Linux host architecture: $machine" >&2
        exit 1
        ;;
esac

asset="zig-$arch-linux-$version.tar.xz"
toolchain_root="$repo_root/.toolchains/zig-canonical"
install_dir="$toolchain_root/zig-$arch-linux-$version"
zig="$install_dir/zig"

if [ -x "$zig" ]; then
    actual=$($zig version)
    if [ "$actual" != "$version" ]; then
        echo "canonical Zig version mismatch: expected $version, got $actual" >&2
        exit 1
    fi
    printf '%s\n' "$zig"
    exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

mkdir -p "$toolchain_root"
archive="$toolchain_root/$asset"
url="https://github.com/adybag14-cyber/zig/releases/download/$tag/$asset"

printf 'Downloading canonical Zig %s for %s Linux\n' "$version" "$arch" >&2
curl --fail --location --retry 3 --output "$archive" "$url"
printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status || {
    rm -f "$archive"
    echo "canonical Zig archive checksum mismatch" >&2
    exit 1
}

tar -xJf "$archive" -C "$toolchain_root"
rm -f "$archive"

[ -x "$zig" ] || { echo "toolchain extraction did not produce $zig" >&2; exit 1; }
actual=$($zig version)
[ "$actual" = "$version" ] || {
    echo "canonical Zig version mismatch after extraction: expected $version, got $actual" >&2
    exit 1
}

printf '%s\n' "$zig"
