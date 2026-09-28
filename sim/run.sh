#!/bin/sh
# ============================================================================
#  sim/run.sh -- build and run every testbench with iverilog.
#
#  Run from anywhere; tools run from the repo root so `include and $readmemh
#  paths resolve.  The HDMI unit testbenches come from the TN20K-HDMI
#  reference project, together with the src/hdmi core they test.
#  tb_top needs the ROM images in roms/ (see roms/README.md).
# ============================================================================
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

mkdir -p build

# Icarus ignores the argument of $finish(1), so each testbench prints PASS or
# a line starting with FAIL, and the log is checked for those.
run_tb () {
    name=$1
    shift
    printf '=== %s ===\n' "$name"
    iverilog -g2005 -o "build/$name" "sim/$name.v" "$@"
    log="build/$name.log"
    status=0
    "./build/$name" >"$log" 2>&1 || status=$?
    cat "$log"
    if [ "$status" -ne 0 ]; then
        printf 'FAILED: %s exited %s\n' "$name" "$status"
        exit 1
    fi
    if grep -q '^FAIL' "$log" || ! grep -q 'PASS' "$log"; then
        printf 'FAILED: %s did not report PASS\n' "$name"
        exit 1
    fi
    printf '\n'
}

# The RTL list is SRCS in the Makefile (continued lines up to the first
# line without a trailing backslash).
srcs=$(awk '/^SRCS *=/ {on=1; sub(/^SRCS *=/, "")} on {l=$0; sub(/\\$/, "", l); printf "%s ", l; if ($0 !~ /\\$/) exit}' Makefile)
hdmi='src/hdmi/hdmi_tx.v src/hdmi/hdmi_island_scheduler.v src/hdmi/hdmi_data_island.v
      src/hdmi/hdmi_packet_ecc.v src/hdmi/hdmi_packets.v src/hdmi/hdmi_tmds_encoder.v'
island='src/hdmi/hdmi_data_island.v src/hdmi/hdmi_packet_ecc.v src/hdmi/hdmi_tmds_encoder.v'

run_tb tb_tmds_encoder src/hdmi/hdmi_tmds_encoder.v
run_tb tb_packet_ecc   src/hdmi/hdmi_packet_ecc.v
run_tb tb_packets      src/hdmi/hdmi_packets.v
# shellcheck disable=SC2086
run_tb tb_data_island  $island

# Apple video and colour bars through hdmi_tx, every pixel decoded from the
# TMDS lanes (about a minute).
# shellcheck disable=SC2086
run_tb tb_video_hdmi src/video_generator.v src/colorbar_gen.v $hdmi

# Board level: top.v on behavioural Gowin primitives, pins deserialised.
# shellcheck disable=SC2086
run_tb tb_top sim/models/gowin_prims.v $srcs

echo 'all testbenches passed'
