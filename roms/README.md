# ROM images

The Apple //e ROMs are Apple copyright and are not distributed with this
repository. Supply your own dumps here before building:

| File               | Size   | Contents                                      |
|--------------------|--------|-----------------------------------------------|
| `apple2e_rom.hex`  | 16 KB  | System ROM mapped at $C000–$FFFF (16384 lines) |
| `apple2e_char.hex` | 8 KB   | Character generator ROM (8192 lines)          |

Both files are loaded with Verilog `$readmemh`: one byte per line, two hex
digits, no address markers. To convert a raw binary dump:

```sh
xxd -p -c1 apple2e_rom.bin  > apple2e_rom.hex
xxd -p -c1 apple2e_char.bin > apple2e_char.hex
```
