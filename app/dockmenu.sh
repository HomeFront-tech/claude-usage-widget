#!/bin/sh
# Builds dockmenu.dylib (Claude Buddy.app's Dock menu "Check for Updates...", see
# dockmenu.m) on this Mac. Needs Apple's Command Line Tools (xcode-select --install).
# Exit 3: no compiler. dockmenu.hash records which sources the library came from.
# usage: dockmenu.sh [--if-stale] [out-dir]   (out-dir: where it goes; default this folder)
set -e
D=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stale=
if [ "$1" = "--if-stale" ]; then stale=1; shift; fi
O=${1:-$D}
hash=$(cat "$D/dockmenu.m" "$D/dockmenu.sh" | shasum -a 256 | cut -d' ' -f1)
# --if-stale: nothing to do when the library was built from these sources
if [ -n "$stale" ] && [ -f "$O/dockmenu.dylib" ] && [ "$(cat "$O/dockmenu.hash" 2>/dev/null)" = "$hash" ]; then exit 0; fi
# xcode-select -p fails quietly without the tools; /usr/bin/clang would pop an installer
xcode-select -p >/dev/null 2>&1 && [ -x /usr/bin/clang ] || { echo "no clang" >&2; exit 3; }
# Built to a new file and moved over the old one: the running app may have it loaded.
/usr/bin/clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=13.0 -arch arm64 -arch x86_64 \
  -framework Cocoa -Wl,-U,_lua_pushinteger -o "$O/dockmenu.tmp" "$D/dockmenu.m" 2>"$O/dockmenu.log" \
  || { grep -E "error:" "$O/dockmenu.log" >&2; rm -f "$O/dockmenu.tmp"; exit 1; }
mv "$O/dockmenu.tmp" "$O/dockmenu.dylib"
printf '%s\n' "$hash" >"$O/dockmenu.hash"
