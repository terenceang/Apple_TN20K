#!/bin/sh
# Load build/bitstream/<name>.fs (where scripts/build.sh and OpenFPGA Deck
# both put it) into the Tang Nano 20K: SRAM by default (lost on power
# cycle), or pass --flash to write the configuration flash.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
. scripts/toolchain.sh
fs="build/bitstream/$(sed -n 's/^name: *//p' fpga.yaml).fs"
if [ "$1" = "--flash" ]; then
    openFPGALoader -b tangnano20k -f "$fs"
else
    openFPGALoader -b tangnano20k "$fs"
fi
