# ============================================================================
#  Thin wrapper around scripts/build.sh and scripts/prog.sh.
#
#  There is deliberately no build logic here.  This used to carry its own
#  SRCS list, its own nextpnr flags and its own output paths, which had
#  drifted from scripts/build.sh (the OpenFPGA Deck path) enough that the two
#  produced different netlists and applied different timing rules.  Now both
#  go through one implementation:
#
#      scripts/build.sh   synth_gowin -> nextpnr -> gowin_pack
#      scripts/prog.sh    openFPGALoader
#
#  The RTL file list lives in fpga.yaml and is read by scripts/sources.sh.
#  Timing target and mode constants live in src/hdmi/hdmi_defs.vh.
#
#  Everything is re-run from scratch on each invocation, so the individual
#  stages are how you iterate: build.sh --synth, then --pnr, then --pack.
# ============================================================================

BUILD = scripts/build.sh
PROG  = scripts/prog.sh

all: pack

synth:
	$(BUILD) --synth

pnr:
	$(BUILD) --pnr

pack:
	$(BUILD)

# Load into SRAM: fast, lost on power cycle.  This is the iteration path.
flash-sram:
	$(PROG)

# Write the configuration flash: persistent across power cycles.
flash:
	$(PROG) --flash

clean:
	rm -rf build

# ============================================================================
#  Web front end
#
#  `web/` is a Node project, separate from the FPGA build: `make web-build`
#  produces the bundle the bridge serves, `make bridge` runs the bridge itself
#  (scripts/bridge.sh, which is the only implementation), and `make web-test`
#  runs the JS tests. The React app, the keymap and the screen renderer are in
#  web/README.md.
# ============================================================================

web-install:
	cd web && npm install

web-build:
	cd web && npm run build

web-dev:
	cd web && npm run dev

web-test:
	cd web && npm test

web-charset:
	cd web && npm run charset

.PHONY: all synth pnr pack flash flash-sram clean \
        web-install web-build web-dev web-test web-charset
