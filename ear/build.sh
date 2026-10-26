#!/bin/sh
# Builds buddy-ear (the buddy's ears and voice) from ear.swift, on this Mac.
# Needs macOS 26 or later and Apple's Command Line Tools (xcode-select --install).
# Exit 3: no Swift compiler. buddy-ear.hash records which sources the binary came from.
set -e
D=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# xcode-select -p fails quietly without the tools; /usr/bin/swiftc would pop an installer
xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/swiftc ] || { echo "no swiftc" >&2; exit 3; }
hash=$(cat "$D/ear.swift" "$D/Info.plist" | shasum -a 256 | cut -d' ' -f1)
/usr/bin/swiftc -O -swift-version 5 -o "$D/buddy-ear.tmp" "$D/ear.swift" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$D/Info.plist" 2>"$D/build.log" \
  || { grep -E "error:" "$D/build.log" >&2; rm -f "$D/buddy-ear.tmp"; exit 1; }
mv "$D/buddy-ear.tmp" "$D/buddy-ear"
printf '%s\n' "$hash" >"$D/buddy-ear.hash"
