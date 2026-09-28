# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

An Apple //e implemented in Verilog for the Sipeed Tang Nano 20K (Gowin GW2AR-LV18QN88C8/I7). The build uses the open-source toolchain (Yosys, nextpnr-gowin, gowin_pack, openFPGALoader). Video and audio go out over HDMI (720x480p with 48 kHz audio in data islands), audio also through the onboard MAX98357A I2S amp, and keyboard input plus a hardware debugger run over the 115200-baud UART on the BL616 USB-serial bridge.

## Commands

```sh
make            # full build: synth -> pnr -> pack => build/apple2_tn20k.fs
make synth      # yosys only (build/apple2_tn20k.json)
make pnr        # nextpnr-gowin (build/apple2_tn20k_pnr.json)
make flash-sram # load bitstream into SRAM (volatile, fast; use for iteration)
make flash      # write bitstream to onboard flash (persistent)
make clean

scripts/prog.sh         # program OpenFPGA Deck bitstream (build/bitstream/Apple_TN20K.fs) to SRAM
scripts/prog.sh --flash # program bitstream to onboard SPI flash
```

- **New source files must be added to `SRCS` in the Makefile**, and to `sources:` in `fpga.yaml` if you also want the OpenFPGA Deck tool's build to work (it generates `build/yosys/synth.ys` from `fpga.yaml` on each run; keep the two lists in sync).
- nextpnr runs with `--timing-allow-fail --ignore-loops`, so a successful build does not mean timing was met. `constraints/top.sdc` constrains `clk` to 27 MHz (without it nextpnr silently checks against a meaningless 12 MHz default); check the nextpnr output for the achieved Fmax on the `clk_pixel` domain.
- `sim/run.sh` builds and runs all testbenches with iverilog (~1 min) and exits non-zero on failure; each testbench prints `PASS` or a line starting with `FAIL`, which `run.sh` greps for (Icarus ignores `$finish(1)`). `tb_video_hdmi` runs `video_generator` + `colorbar_gen` through `hdmi_tx` with `top.v`'s wiring and decodes every pixel from the TMDS lanes against an independent model of the text screen / bars (it catches a one-pixel look-ahead error). `tb_top` runs the whole `top.v` on `sim/models/gowin_prims.v` (behavioral `rPLL`/`CLKDIV`/`OSER10`/`TLVDS_OBUF`; Yosys' `cells_sim.v` has only empty shells for these, and no `CLKDIV`), checks the pins replay `hdmi_tx`'s symbols and that HDMI audio runs at 48 kHz; it needs the ROMs. The `tb_tmds_encoder`/`tb_packet_ecc`/`tb_packets`/`tb_data_island` unit tests and `sim/include/hdmi_ref.vh` come from the TN20K-HDMI reference project with the core.
- The HDMI core `` `include``s `src/hdmi/hdmi_defs.vh` by repo-relative path, like the ROM paths, so run tools from the repo root.
- ROMs are gitignored (Apple copyright), so a fresh clone needs the user to supply them; see `roms/README.md`. ROMs are loaded with `$readmemh` using paths relative to the repo root (`roms/apple2e_rom.hex` is 16 KB covering $C000–$FFFF; `roms/apple2e_char.hex` is 8 KB). Run tools from the repo root.

## Architecture

The design runs almost entirely in one clock domain. `clk_gen.v`'s rPLL turns the 27 MHz crystal into `clk_tmds` (135 MHz, 5× pixel clock), and `clk_pixel` is then derived from `clk_tmds` via a `CLKDIV` (divide-by-5) rather than tapped directly off the crystal — the HDMI `OSER10` serializers need a fixed, drift-free phase relationship between `clk_pixel` (PCLK) and `clk_tmds` (FCLK), which only a shared hardware divider off the same PLL output guarantees; feeding OSER10 two independently-routed clocks (frequency-locked but not phase-locked) causes the display to intermittently drop in and out of sync.

**Clock enables, not clocks.** `clk_gen.v` makes `ce_1m` (1.0227 MHz) and `ce_14m` from 32-bit phase accumulators. The 65C02 is clocked at 27 MHz but gated by `RDY = ce_1m & cpu_rdy`, and all softswitch and I/O logic is qualified by `ce_1m`. Keep new CPU-visible logic in this pattern.

**Shared RAM time multiplexing** (`apple2_core.v`): the 64 KB RAM is a single-port BRAM (`apple2_ram_64k` in `apple2_mem.v`). On cycles where `ce_1m=1`, the CPU (or the debugger) owns the address bus. On all other cycles the video generator's `vram_addr` is used, and `vram_data` is latched from those cycles. Video therefore sees RAM with a one-cycle registered latency, and `video_generator.v` prefetches the next column (`fetch_col`) to allow for this.

**Memory map / decode** (`apple2_core.v`): $0000–$BFFF main RAM; $C0xx I/O; $C100–$CFFF internal ROM; $D000–$FFFF language card (ROM or RAM, with the //e bank-switch semantics at $C080–$C08F). Aux memory, RAMRD/RAMWRT and 80-column display are *not* implemented. The 80STORE, 80COL and ALTCHAR flags are latched but have no effect on memory or video. `cpu_din` is a combinational mux: `input_controller` claims $C0xx reads through `io_hit`/`io_dout` (keyboard $C000/$C010, pushbuttons $C061–3, paddles $C064/5, $C070), and the core supplies $C011–$C01F status reads.

**Debugger path** (`serial_debugger.v`): pressing Ctrl+B (0x02) on the UART toggles `dbg_mode` and drops `cpu_rdy` to freeze the CPU. While paused, `effective_cpu_addr` switches to `dbg_mem_addr` so the debugger can read memory through the same `cpu_din` mux (`dbg_mem_din`). Commands are r/s/c/m/t/h. In console mode it mirrors COUT ($FDED) output to UART TX. `input_controller` owns the UART RX and passes `rx_byte`/`rx_valid` to the debugger; it drops keystrokes while `dbg_mode` is set. It also turns ANSI arrow-key escape sequences into Apple control codes.

**Video** (`video_generator.v`): the Apple 560×384 raster (192 lines doubled, 14 px per column) is centered at x=80..639, y=48..431 of the 720×480 frame, and `vbl` feeds $C019. The generator handles the Apple interleaved row addressing for text, lo-res and hi-res. It has no timing of its own: `hdmi_tx` owns the raster and samples `video_rgb` combinationally for its `(pixel_x, pixel_y)`, and because the generator's colour output is registered, `top.v` feeds it the *next* pixel (`h_cnt = pixel_x + 1`, `v_cnt = pixel_y`). `h_cnt` must step by one every clock (its column counter and RAM prefetch count clocks). Anything new that drives `hdmi_rgb` must honour the same same-cycle contract (`colorbar_gen` is combinational on `pixel_x`/`pixel_y`).

**HDMI** (`src/hdmi/`): ported from the TN20K-HDMI reference project (`~/TN20K-HDMI`, hardware-confirmed there), whose CLAUDE.md documents the internals; keep the files in step with it. `hdmi_tx` does CEA-861 720×480p59.94 (VIC 2) timing, the TMDS encoders (fixed 2-cycle latency in every mode, which the island scheduler's alignment depends on), and data islands carrying Audio Sample Packets, ACR (N=6144, CTS=27000), and the AVI and Audio InfoFrames. Mode and audio constants are in `hdmi_defs.vh`. The only local change is `hdmi_tx`'s `RGB_QUANT` parameter: `top.v` sets full range (`2'b10`) in the AVI InfoFrame because the Apple palette is 0–255 (a sink would otherwise assume limited range for a CE mode and crush blacks). The `OSER10` + `TLVDS_OBUF` serializers are a generate loop in `top.v`; lane 3 is the TMDS clock (`0000011111`). `TLVDS_OBUF` is required on pins 33-40 (apicula rejects `ELVDS_OBUF` there with "it is a true lvds pin"), with `IO_TYPE=LVDS25` and one single-pin `IO_LOC` per leg in the `.cst`; the Tang Nano 9K's GW1NR-9 needs emulated LVDS instead, so don't copy that board's HDMI code here. The HDMI link has its own reset (`hdmi_rst_n`: PLL lock plus 128 pixel clocks), independent of `sys_reset`, so S2 resets the Apple without the display re-syncing.

History: an earlier HDMI-audio attempt using Sameer Puri's hdmi.sv packet library worked briefly, then reset the whole board once data-island activity ramped up (suspected power/timing margin in the much larger design). If the board resets or the link drops with this core, suspect that first. Holding S1 swaps only the picture (data islands and audio keep running), so it separates the Apple core from the HDMI link but not audio from video. Diagnose with a scope/logic analyzer rather than blind hardware iteration.

**HDMI bring-up test pattern** (`colorbar_gen.v`): holding `btn_s1` (active-high, pulled down by board 1k resistor) forces `top.v`'s HDMI mux to an 8-bar color pattern with a border and a blinking liveness box, independent of the CPU/RAM/`video_generator`, plus a 1kHz test tone (`sound_generator.v`'s `test_tone_enable`) on the I2S speaker and HDMI audio — use this to isolate the clocking/serializer/display chain from the rest of the design when video misbehaves.

**Audio** (`sound_generator.v`): any access to $C03x pulses `spkr_pulse`, which toggles the speaker flip-flop. That drives a damped-impulse sample model sent out over I2S (BCLK = 27 MHz / 9, 46.875 kHz frames). The same sample (`audio_sample` output) is resampled at 48 kHz by a fractional accumulator in `top.v` and sent over HDMI as stereo L-PCM. `test_tone_enable` (wired to `btn_s1` in `top.v`) substitutes a 1kHz square wave for bring-up testing.

**CPU** (`src/cpu/`): Arlet Ottens' 6502 core with the 65C02 extensions by David Banks and Ed Spittles. It has been modified to expose `debug_*` register ports. IRQ and NMI are tied low.

## Hardware notes

- The pin assignments live in `constraints/top.cst`. The Tang Nano 20K LEDs are active-low. Their mapping is listed at the bottom of `top.v`: heartbeat, PLL lock, reset, CPU write, text mode and key strobe.
- `btn_s1` (active-high, pulled down) holds the HDMI/audio output on the color-bar test pattern (see above). `btn_s2` (active-high, pulled down) triggers a clean manual reset. Automatic reset also runs via the power-on counter in `top.v`.
