#!/bin/sh
# Sourced by the other scripts: put the same OSS CAD Suite that OpenFPGA Deck
# uses at the front of PATH, so CLI and Deck builds run identical tools.
#   1. $OSS_CAD_SUITE, if set
#   2. "openfpga.toolchain.path" from the VS Code user settings
#   3. whatever is already on PATH
_settings="$HOME/.config/Code/User/settings.json"
if [ -z "$OSS_CAD_SUITE" ] && [ -f "$_settings" ]; then
    OSS_CAD_SUITE=$(sed -n 's/.*"openfpga\.toolchain\.path"[^"]*"\([^"]*\)".*/\1/p' "$_settings")
fi
if [ -n "$OSS_CAD_SUITE" ] && [ -x "$OSS_CAD_SUITE/bin/yosys" ]; then
    PATH="$OSS_CAD_SUITE/bin:$PATH"
    export PATH
fi
# Distro packages name the Gowin nextpnr differently from OSS CAD Suite.
if command -v nextpnr-himbaechel >/dev/null 2>&1; then
    NEXTPNR=nextpnr-himbaechel
else
    NEXTPNR=nextpnr-himbaechel-gowin
fi
