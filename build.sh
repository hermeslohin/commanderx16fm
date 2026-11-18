#!/usr/bin/env bash
# Build X16 Files. Works from a fresh clone:
#   build/x16fm.prg                 the program
#   build/x16link.bin x16docs.bin   X16Link libraries (sources vendored in lib/x16link)
# With an SD dir argument, copies them there as X16FM.PRG, X16LINK.BIN, X16DOCS.BIN.
# Env: PROG8C = Prog8 12.3.x compiler command (default: java -jar ~/prog8c.jar), BUILD = output dir.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${X16LINK_LIB:-$HERE/lib/x16link}"
B="${BUILD:-$HERE/build}"
mkdir -p "$B"
P8="${PROG8C:-java -jar $HOME/prog8c.jar} -target cx16 -srcdirs $LIB -srcdirs $HERE"
run() { local log="$1"; shift; "$@" > "$log" 2>&1 || { cat "$log"; exit 1; }; grep -E "^Data:|BSS_SLABS" "$log" | sed "s|^|  $(basename "$log" .log): |" || true; }
run "$B/x16link.log" $P8 -out "$B" "$LIB/x16link.p8"
run "$B/x16docs.log" $P8 -out "$B" "$LIB/x16docs.p8"
run "$B/x16fm.log" $P8 -out "$B" "$HERE/x16fm.p8"
if [ $# -ge 1 ]; then
  SD="$1"; mkdir -p "$SD"
  cp "$B/x16fm.prg" "$SD/X16FM.PRG"
  for f in x16link x16docs; do cp "$B/$f.bin" "$SD/$(echo $f | tr a-z A-Z).BIN"; done
  echo "copied to $SD"
fi
