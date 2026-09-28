# Sipeed Tang Nano 20K — Specifications & Pinout Sheet

This document summarizes the technical specifications, peripheral mapping, and physical pinout for the **Sipeed Tang Nano 20K** development board.

Accompanying official documents in this folder:
- **Datasheet (PDF)**: [Sipeed_Tang_Nano_20K_Datasheet_V1.3.pdf](file:///home/terence/TangNano20K/docs/Sipeed_Tang_Nano_20K_Datasheet_V1.3.pdf) (v1.3)
- **Schematic (PDF)**: [Tang_Nano_20K_3923_Schematics.pdf](file:///home/terence/TangNano20K/docs/Tang_Nano_20K_3923_Schematics.pdf) (rev 3923)

---

## 1. Overview & Core FPGA Specifications

The Tang Nano 20K is built around the **Gowin GW2AR-LV18QN88C8/I7** FPGA chip.

| Parameter | Value |
| :--- | :--- |
| **FPGA Part Number** | `GW2AR-LV18QN88C8/I7` (Family: `GW2A-18C`, Package: `QN88`) |
| **Logic Units (LUT4)** | 20,736 |
| **Flip-Flops (FF)** | 15,552 |
| **Block SRAM (B-SRAM)** | 828 Kbits (46 units) |
| **Shadow SRAM (S-SRAM)** | 41,472 bits |
| **Multipliers (18x18)** | 48 units |
| **Phase-Locked Loops (PLLs)** | 2 |
| **I/O Banks** | 8 |
| **Embedded SDRAM** | 64 Mbits (32-bit wide SDR SDRAM, SiP) |
| **Configuration Flash** | 64 Mbits (XT25F64F SPI/QSPI NOR Flash) |
| **Power Supply** | 5V @ ~0.5A via USB Type-C |
| **Board Dimensions** | 22.55 mm × 54.04 mm |
| **Operating Temperature** | 0°C to 65°C |

---

## 2. Onboard Peripherals

- **Debugger / USB Interface**: Bouffalo Lab **BL616**
  - High-speed USB-JTAG for bitstream programming
  - USB-to-UART bridge (FPGA communication at default 115200 baud)
  - USB-to-SPI bridge
  - Software control interface for the MS5351 clock generator
- **Clock Generator**: **MS5351** (I2C controlled, provides 3 additional programmable clocks to FPGA)
- **Primary Oscillator**: 27 MHz active crystal oscillator (Pin `4`)
- **Display Interfaces**:
  - **HDMI (DVI TX)**: Bank 5 AC-coupled LVDS differential pairs
  - **RGB LCD Connector**: Standard 40-pin FPC (RGB565 / RGB888, capacitive touch signals)
- **Audio Output**: **MAX98357A** I2S Class-D mono amplifier driving speaker pads (`J4`)
- **Removable Storage**: microSD (TF) card slot (SPI / 4-bit SD mode)
- **User LEDs**: 6 × active-low monochrome LEDs (Pins `15`, `16`, `17`, `18`, `19`, `20`)
- **RGB LED**: 1 × addressable WS2812B RGB LED (Pin `79`)
- **User Buttons**: 2 × active-high push buttons with 1 kΩ pull-down resistors (Pins `88` [S1] and `87` [S2])

---

## 3. Clock Architecture

| Clock Signal | FPGA Pin | Source / Function |
| :--- | :---: | :--- |
| `clk` | **4** | Onboard 27 MHz crystal oscillator (`LPLL1_T_in`) |
| `ms5351_clk0` | **10** | MS5351 programmable clock output 0 (`GCLKT_6`) |
| `ms5351_clk1` | **11** | MS5351 programmable clock output 1 (`GCLKC_6`) |
| `ms5351_clk2` | **13** | MS5351 programmable clock output 2 (`LPLL2_T_in`, shared with BL616 SPI SCLK) |

---

## 4. Header Pinout (J5 & J6)

The Tang Nano 20K exposes two 20-pin 2.54 mm headers (**J5** and **J6**).

### Header J6 (FPGA Pin Side)

| Pin # | Label / Signal | FPGA Pin | Default IO | Shared / Alternative Functions |
| :---: | :--- | :---: | :---: | :--- |
| 1 | `73` | 73 | LVCMOS33 | GPIO |
| 2 | `74` | 74 | LVCMOS33 | GPIO |
| 3 | `75` | 75 | LVCMOS33 | BL616 SPI MISO |
| 4 | `85` | 85 | LVCMOS33 | microSD DAT1 |
| 5 | `77` | 77 | LVCMOS33 | RGB LCD Pixel Clock (`lcd_clk`) |
| 6 | `15` | 15 | LVCMOS33 | **LED0** (active-low), LCD Touch XR |
| 7 | `16` | 16 | LVCMOS33 | **LED1** (active-low), LCD Touch YD |
| 8 | `27` | 27 | LVCMOS33 | RGB LCD Blue 4 (`lcd_b[4]`) |
| 9 | `28` | 28 | LVCMOS33 | RGB LCD Blue 3 (`lcd_b[3]`) |
| 10 | `25` | 25 | LVCMOS33 | RGB LCD HSYNC (`lcd_hs`), HDMI CEC |
| 11 | `26` | 26 | LVCMOS33 | RGB LCD VSYNC (`lcd_vs`), HDMI HPD |
| 12 | `29` | 29 | LVCMOS33 | RGB LCD Blue 2 (`lcd_b[2]`) |
| 13 | `30` | 30 | LVCMOS33 | RGB LCD Blue 1 (`lcd_b[1]`) |
| 14 | `31` | 31 | LVCMOS33 | RGB LCD Blue 0 (`lcd_b[0]`) |
| 15 | `17` | 17 | LVCMOS33 | **LED2** (active-low), LCD Touch XL, DS2 CLK |
| 16 | `20` | 20 | LVCMOS33 | **LED5** (active-low), DS2 MOSI |
| 17 | `19` | 19 | LVCMOS33 | **LED4** (active-low), DS2 MISO |
| 18 | `18` | 18 | LVCMOS33 | **LED3** (active-low), LCD Touch YU, DS2 CS |
| 19 | `3V3` | — | Power | +3.3V System Output |
| 20 | `GND` | — | Ground | Ground |

### Header J5

| Pin # | Label / Signal | FPGA Pin | Default IO | Shared / Alternative Functions |
| :---: | :--- | :---: | :---: | :--- |
| 1 | `5V` | — | Power | +5V Input / USB VBUS |
| 2 | `GND` | — | Ground | Ground |
| 3 | `76` | 76 | LVCMOS33 | BL616 SPI MOSI |
| 4 | `80` | 80 | LVCMOS33 | microSD DAT2 |
| 5 | `42` | 42 | LVCMOS33 | RGB LCD Red 0 (`lcd_r[0]`) |
| 6 | `41` | 41 | LVCMOS33 | RGB LCD Red 1 (`lcd_r[1]`) |
| 7 | `56` | 56 | LVCMOS33 | Audio I2S BCLK (`i2s_bclk`), SSPI pin |
| 8 | `54` | 54 | LVCMOS33 | Audio I2S DIN (`i2s_din`), SSPI pin |
| 9 | `51` | 51 | LVCMOS33 | Audio Power Amplifier Enable (`pa_en`) |
| 10 | `48` | 48 | LVCMOS33 | RGB LCD Data Enable (`lcd_de`) |
| 11 | `55` | 55 | LVCMOS33 | Audio I2S LRCK (`i2s_lrck`), SSPI pin |
| 12 | `49` | 49 | LVCMOS33 | RGB LCD Backlight Enable (`lcd_bl`) |
| 13 | `86` | 86 | LVCMOS33 | BL616 SPI DIR |
| 14 | `79` | 79 | LVCMOS33 | **WS2812B RGB LED** Data In |
| 15 | `GND` | — | Ground | Ground |
| 16 | `3V3` | — | Power | +3.3V System Output |
| 17 | `72` | 72 | LVCMOS33 | GPIO, DS2 CS |
| 18 | `71` | 71 | LVCMOS33 | GPIO, DS2 MISO |
| 19 | `53` | 53 | LVCMOS33 | HDMI DDC SCL (`hdmi_scl`), SSPI pin, DS2 MOSI |
| 20 | `52` | 52 | LVCMOS33 | HDMI DDC SDA (`hdmi_sda`), SSPI pin, DS2 CLK |

---

## 5. Dedicated Onboard Signals & Interfaces

### Onboard LEDs & Buttons
- **LEDs** (`0 = ON`, `1 = OFF`):
  - `led[0]` $\rightarrow$ Pin 15
  - `led[1]` $\rightarrow$ Pin 16
  - `led[2]` $\rightarrow$ Pin 17
  - `led[3]` $\rightarrow$ Pin 18
  - `led[4]` $\rightarrow$ Pin 19
  - `led[5]` $\rightarrow$ Pin 20
- **Buttons** (`1 = Pressed`):
  - `btn_s1` $\rightarrow$ Pin 88 (MODE0 strap pin)
  - `btn_s2` $\rightarrow$ Pin 87 (MODE1 strap pin)

### UART (BL616 to Host via USB)
- `uart_tx` (FPGA $\rightarrow$ Host): Pin **69**
- `uart_rx` (Host $\rightarrow$ FPGA): Pin **70**

### HDMI (TMDS Pairs)
Drive with `TLVDS_OBUF` on Bank 5:
- `tmds_clk_p` / `tmds_clk_n`: Pins **33** / **34**
- `tmds_d_p[0]` / `tmds_d_n[0]`: Pins **35** / **36**
- `tmds_d_p[1]` / `tmds_d_n[1]`: Pins **37** / **38**
- `tmds_d_p[2]` / `tmds_d_n[2]`: Pins **39** / **40**

### MicroSD Card
- `sd_clk`: Pin **83**
- `sd_cmd`: Pin **82** (MOSI in SPI mode)
- `sd_dat[0]`: Pin **84** (MISO in SPI mode)
- `sd_dat[1]`: Pin **85**
- `sd_dat[2]`: Pin **80**
- `sd_dat[3]`: Pin **81** (CS in SPI mode)

### Configuration Pins Note
Dual-purpose configuration pins require releasing if used as regular GPIO:
- **SSPI pins**: `52`, `53`, `54`, `55`, `56` (requires `--sspi_as_gpio` in place-and-route and packing).
- **MSPI pins**: `57`, `59`, `60`, `61`, `62` (requires `--mspi_as_gpio`).

---

## 6. Physical Constraints Template (`.cst`)

```cst
// Clock
IO_LOC "clk" 4;
IO_PORT "clk" IO_TYPE=LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3;

// LEDs (Active Low)
IO_LOC "led[0]" 15;
IO_PORT "led[0]" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "led[1]" 16;
IO_PORT "led[1]" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "led[2]" 17;
IO_PORT "led[2]" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "led[3]" 18;
IO_PORT "led[3]" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "led[4]" 19;
IO_PORT "led[4]" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "led[5]" 20;
IO_PORT "led[5]" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;

// User Buttons (Active High)
IO_LOC "btn_s1" 88;
IO_PORT "btn_s1" IO_TYPE=LVCMOS33 PULL_MODE=DOWN BANK_VCCIO=3.3;
IO_LOC "btn_s2" 87;
IO_PORT "btn_s2" IO_TYPE=LVCMOS33 PULL_MODE=DOWN BANK_VCCIO=3.3;

// UART
IO_LOC "uart_tx" 69;
IO_PORT "uart_tx" IO_TYPE=LVCMOS33 DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "uart_rx" 70;
IO_PORT "uart_rx" IO_TYPE=LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3;
```
