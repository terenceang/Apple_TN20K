# src/sdram/

`sdram.v` is Till Harbaum's SDRAM controller for the Tang Nano 20K's on-board
64 Mbit SDRAM, copied unmodified from
https://github.com/Harbaum/MiSTeryNano (`src/tang/nano20k/sdram.v`, commit
`c8e4601fbf7264e13f4b18ac2d452444de6b51c5`). **It is GPL-3.0-or-later** (header
in the file), unlike the rest of this repo (MIT).

`nano20k_sdram.cst` is the SDRAM pin block (`O_sdram_*`, `IO_sdram_dq`), taken
from https://github.com/ArthurHeymans/tang_20k_spi_flash `tangnano20k.cst`
(commit `4e8b0b1619194a95c049559f61f18ac335ff0ea1`), which builds with the
open toolchain. Merge it into `constraints/top.cst` when the ports are added
to `top.v`.

Interface: 16-bit words, 22-bit word address, a rising edge on `cs` starts an
access (7 clocks), and `refresh` requests an auto-refresh instead. Its clock
was 32 MHz upstream; it is not yet wired into the design.
