#!/bin/sh
# Fetch a Zig package from codeberg.org when local DNS can't reach it
# (some ISP resolvers return a bogus address for codeberg.org).
# Resolves codeberg.org via 1.1.1.1, downloads the commit archive and installs
# it as <hash> in the global cache and in ./zig-pkg.
#
#   tools/fetch-codeberg.sh <owner/repo> <commit> <expected-hash>
set -eu
repo=$1 commit=$2 hash=$3
ip=$(dig +short codeberg.org @1.1.1.1 | tail -1)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -sfL -m 120 --resolve "codeberg.org:443:$ip" -o "$tmp/a.tar.gz" \
  "https://codeberg.org/$repo/archive/$commit.tar.gz"
mkdir -p "$tmp/$hash"
tar xzf "$tmp/a.tar.gz" -C "$tmp/$hash" --strip-components=1
cache=${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}/p
mkdir -p "$cache" zig-pkg
(cd "$tmp" && tar czf "$cache/$hash.tar.gz" "$hash")
rm -rf "zig-pkg/$hash"
cp -r "$tmp/$hash" zig-pkg/
echo "installed $hash"
