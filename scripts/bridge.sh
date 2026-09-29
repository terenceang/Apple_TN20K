#!/bin/sh
# ============================================================================
#  scripts/bridge.sh -- run the web bridge between the browser and the BL616
#
#  The BL616 on the Tang Nano 20K is a USB-serial/JTAG bridge, and this is the
#  other half of the keyboard: the React app in web/ talks to it over a
#  WebSocket and this script gets it onto the serial port.
#
#  Arguments go straight through to web/bridge/bridge.mjs:
#
#      scripts/bridge.sh                  probe for the FPGA UART
#      scripts/bridge.sh --port /dev/ttyUSB0
#      scripts/bridge.sh --no-serve       WebSocket only, do not serve dist/
#
#  web/ must have its dependencies installed first:
#
#      cd web && npm install && npm run build
# ============================================================================
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if [ ! -d web/node_modules ]; then
    echo "bridge: web/node_modules is missing. Run: (cd web && npm install)" >&2
    exit 1
fi

exec node web/bridge/bridge.mjs "$@"
