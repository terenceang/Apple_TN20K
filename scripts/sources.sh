#!/bin/sh
# Print the RTL source list from fpga.yaml, the single place it is kept.
# Usage: scripts/sources.sh [--except FILE]...  (paths relative to the repo)
root=$(cd "$(dirname "$0")/.." && pwd)
awk '/^sources:/ {on=1; next} /^[^ ]/ {on=0} on && /^ *- / {print $2}' \
    "$root/fpga.yaml" |
while read -r f; do
    skip=0
    prev=""
    for a in "$@"; do
        [ "$prev" = "--except" ] && [ "$a" = "$f" ] && skip=1
        prev=$a
    done
    [ $skip -eq 0 ] && printf '%s\n' "$f"
done
