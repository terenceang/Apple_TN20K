DEVICE = GW2AR-LV18QN88C8/I7
FAMILY = GW2A-18C
BOARD  = tangnano20k

SRCS = src/cpu/ALU.v \
       src/cpu/cpu_65c02.v \
       src/clk_gen.v \
       src/apple2_mem.v \
       src/apple2_core.v \
       src/video_generator.v \
       src/input_controller.v \
       src/sound_generator.v \
       src/serial_debugger.v \
       src/hdmi/tmds_encoder.v \
       src/hdmi/hdmi_tx.v \
       src/top.v

CST = constraints/top.cst

all: pack

build:
	mkdir -p build

synth: build/apple2_tn20k.json

build/apple2_tn20k.json: $(SRCS) roms/apple2e_rom.hex roms/apple2e_char.hex | build
	yosys -p 'read_verilog $(SRCS); synth_gowin -top top -family gw2a -noabc9 -json build/apple2_tn20k.json'

pnr: build/apple2_tn20k_pnr.json

build/apple2_tn20k_pnr.json: build/apple2_tn20k.json $(CST)
	nextpnr-gowin --device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST) --ignore-loops --timing-allow-fail --json build/apple2_tn20k.json --write build/apple2_tn20k_pnr.json

pack: build/apple2_tn20k.fs

build/apple2_tn20k.fs: build/apple2_tn20k_pnr.json
	gowin_pack -d $(FAMILY) --sspi_as_gpio -o build/apple2_tn20k.fs build/apple2_tn20k_pnr.json

flash-sram: build/apple2_tn20k.fs
	openFPGALoader -b $(BOARD) -m build/apple2_tn20k.fs

flash: build/apple2_tn20k.fs
	openFPGALoader -b $(BOARD) build/apple2_tn20k.fs

clean:
	rm -rf build/apple2_tn20k.json build/apple2_tn20k_pnr.json build/apple2_tn20k.fs

.PHONY: all synth pnr pack flash flash-sram clean
