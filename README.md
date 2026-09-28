# Apple //e on Tang Nano 20K

An Apple //e implemented in Verilog for the [Sipeed Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html) (Gowin GW2AR-18). It is built entirely with the open-source Yosys / nextpnr / Apicula toolchain.

## Features

- **65C02 CPU** at 1.023 MHz (Arlet Ottens' core with 65C02 extensions)
- **64 KB RAM** in block RAM, with a **language card** for $D000–$FFFF bank switching
- **HDMI/DVI video** at 720×480p60, with the 560×384 Apple display centered; text, lo-res and hi-res modes, including mixed mode and page 2
- **Audio** from the $C030 speaker toggle, played through the onboard MAX98357A I2S amplifier
- **UART keyboard** at 115200 baud over the USB-C serial bridge (or a Bluetooth-to-UART module); ANSI arrow keys are mapped to Apple control codes
- **Gamepad over UART**: pushbuttons $C061–$C063 and paddles 0/1
- **Built-in hardware debugger**: press Ctrl+B to freeze the CPU and inspect registers, single-step, or dump memory
- **Diagnostic LEDs**: heartbeat, PLL lock, reset, CPU write, text mode, key strobe

Not yet implemented: auxiliary memory / 80-column display, peripheral slots, disk drives, and interrupts.

## Requirements

- Tang Nano 20K board
- [Yosys](https://github.com/YosysHQ/yosys), [nextpnr-gowin](https://github.com/YosysHQ/nextpnr), [Apicula](https://github.com/YosysHQ/apicula) (`gowin_pack`)
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader)
- Apple //e ROM images. **These are not included**; see [`roms/README.md`](roms/README.md)

## Building

```sh
make            # synthesize, place & route, pack => build/apple2_tn20k.fs
make flash-sram # load into SRAM (lost on power cycle)
make flash      # write to onboard flash (persistent)
make clean
```

You can also run the stages separately with `make synth` and `make pnr`. Timing failures are allowed in place & route, so check the nextpnr report after making changes.

## Using it

1. Connect HDMI and USB-C, then flash the bitstream.
2. Open a serial terminal on the board's UART at **115200 8N1**, for example `picocom -b 115200 /dev/ttyUSB1`.
3. Type to send keystrokes to the Apple //e. Text the machine prints through COUT is echoed back to the terminal.

### Debugger

Press **Ctrl+B** to pause the CPU and enter the debugger. Press it again to leave.

| Key | Action                                         |
|-----|------------------------------------------------|
| `r` | Show CPU registers (PC, A, X, Y, SP, P, opcode) |
| `s` | Single-step one instruction                    |
| `c` | Continue execution                             |
| `m` | Dump 16 bytes of memory                        |
| `t` | Show hardware status (softswitches, video, audio, clocks) |
| `h` | Help                                           |

### Gamepad protocol

The gamepad sends a 5-byte packet on the same UART: `FF 01 <buttons> <x> <y>`. Bits 0–2 of `<buttons>` map to PB0–PB2. `<x>` and `<y>` are paddle positions from 0 to 255.

### LEDs

| LED | Meaning                  |
|-----|--------------------------|
| 0   | Heartbeat                |
| 1   | PLL locked               |
| 2   | Running (out of reset)   |
| 3   | CPU memory write         |
| 4   | Text mode                |
| 5   | Keyboard strobe pending  |

## Project layout

```
src/top.v               top level: wires everything together, LEDs, reset
src/apple2_core.v       CPU, address decode, softswitches, language card
src/apple2_mem.v        RAM and ROM block-RAM modules
src/clk_gen.v           PLL (135 MHz TMDS) and 1 MHz / 14 MHz clock enables
src/video_generator.v   Apple II raster to 720x480 timing
src/hdmi/               TMDS encoder and serializer
src/sound_generator.v   speaker to I2S
src/input_controller.v  UART RX, keyboard, gamepad, $C0xx input registers
src/serial_debugger.v   UART TX, console mirror, hardware debugger
src/cpu/                65C02 core
constraints/top.cst     pin assignments
roms/                   ROM images (supply your own)
```

## License

[MIT](LICENSE) © 2026 Terence Ang.

The 65C02 core in `src/cpu/` is by Arlet Ottens, David Banks and Ed Spittles, and stays under its original permissive terms (see the file headers). Apple //e ROMs are copyright Apple and are not part of this project.
