#!/bin/sh
# ============================================================================
#  sim/run.sh -- build and run every testbench with iverilog.
#
#  Run from anywhere; tools run from the repo root so `include and $readmemh
#  paths resolve.  tb_top and tb_cpu_trace need the ROM images in roms/
#  (see roms/README.md).
#
#  The RTL file list is fpga.yaml, read through scripts/sources.sh -- the same
#  list synthesis uses, so a new source file cannot be added to one and
#  forgotten in the other.  Only the unit testbenches list files explicitly,
#  because each exercises one module.
# ============================================================================
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

mkdir -p build

# Icarus ignores the argument of $finish(1), so a testbench cannot signal
# failure through its exit status.  The log is therefore captured and checked
# for FAIL explicitly, otherwise `set -e` would happily report success.
run_tb () {
    name=$1
    shift
    printf '=== %s ===\n' "$name"
    iverilog -g2005 -o "build/$name" "sim/$name.v" "$@"
    log="build/$name.log"
    # Capture status around the run: in a pipeline the status seen by `if` is
    # the last command's (tee's), so run it on its own first.
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

hdmi='src/hdmi/hdmi_tx.v src/hdmi/hdmi_island_scheduler.v src/hdmi/hdmi_data_island.v
      src/hdmi/hdmi_packet_ecc.v src/hdmi/hdmi_packets.v src/hdmi/hdmi_tmds_encoder.v'
island='src/hdmi/hdmi_data_island.v src/hdmi/hdmi_packet_ecc.v src/hdmi/hdmi_tmds_encoder.v'

run_tb tb_tmds_encoder src/hdmi/hdmi_tmds_encoder.v
run_tb tb_packet_ecc   src/hdmi/hdmi_packet_ecc.v
run_tb tb_packets      src/hdmi/hdmi_packets.v
# shellcheck disable=SC2086
run_tb tb_data_island  $island

# I2S frame rate and tone frequency.  The BCLK divider used to run at
# 42187.5 Hz while the HDMI resampler in top.v assumed 46875 Hz, which put the
# 1 kHz test tone out at ~900 Hz.  Nothing else caught it.
run_tb tb_sound src/sound_generator.v

# Host keyboard/gamepad protocol over the 115200-baud receiver: legacy ASCII,
# the 0xFE key packet, the 0xFF gamepad packet, ANSI cursor keys, and Ctrl+B
# staying out of the keyboard.
run_tb tb_input src/input_controller.v

# Apple video and colour bars through hdmi_tx, every pixel decoded from the
# TMDS lanes (about a minute).
# shellcheck disable=SC2086
run_tb tb_video_hdmi src/video_generator.v src/colorbar_gen.v $hdmi

# CPU boot and trace from Apple //e System ROM
run_tb tb_cpu_trace src/apple2_core.v src/apple2_mem.v src/cpu/cpu_65c02.v src/cpu/ALU.v

# Board level: top.v on behavioural Gowin primitives, pins deserialised.
# shellcheck disable=SC2046
run_tb tb_top sim/models/gowin_prims.v $(scripts/sources.sh)

echo 'all testbenches passed'
