#!/bin/sh
# ============================================================================
#  scripts/hdmi_diff.sh -- keep src/hdmi/ honest.
#
#  src/hdmi/ is a local copy of the HDMI transmitter from the TN20K-HDMI
#  project (both are yours, both MIT).  It is a copy rather than a submodule
#  so this repo builds with nothing else checked out next to it.  The one
#  deliberate local difference is hdmi_tx.v's RGB_QUANT parameter; see
#  scripts/hdmi_snapshot.sha256.
#
#  Two checks:
#    --check    (default) src/hdmi/ still matches the recorded snapshot.
#               Exits non-zero if any file here was edited locally.  Good for
#               a pre-commit hook: it means an edit to src/hdmi/ was
#               deliberate and the snapshot was re-baselined.
#    --upstream diff src/hdmi/ against a checkout of TN20K-HDMI, to see what
#               the other project has done since the snapshot was taken.
#               Informational; always exits 0.
#
#  Usage:
#    scripts/hdmi_diff.sh [--check | --upstream [path-to-TN20K-HDMI]]
# ============================================================================
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

SNAPSHOT=scripts/hdmi_snapshot.sha256
UPSTREAM_COMMIT=388b39e
DEFAULT_UPSTREAM="$HOME/TN20K-HDMI"

mode=${1:---check}
upstream=$2
[ -n "$upstream" ] || upstream=$DEFAULT_UPSTREAM

case "$mode" in
--check)
    echo "== src/hdmi/ vs the recorded snapshot (TN20K-HDMI @$UPSTREAM_COMMIT)"
    if sha256sum -c "$SNAPSHOT"; then
        echo "OK: src/hdmi/ is unmodified since the snapshot was taken."
        echo "    only hdmi_tx.v was ever meant to differ upstream (RGB_QUANT)."
    else
        echo >&2
        echo "FAILED: src/hdmi/ has local edits not reflected in $SNAPSHOT." >&2
        echo "  If they are intended, re-baseline with:" >&2
        echo "    (cd src/hdmi && sha256sum *.v *.vh | sed 's|  |  src/hdmi/|') > $SNAPSHOT" >&2
        echo >&2
        exit 1
    fi
    ;;

--upstream)
    if [ ! -d "$upstream/src/hdmi" ]; then
        echo "no TN20K-HDMI checkout at $upstream" >&2
        echo "usage: $0 --upstream [path-to-TN20K-HDMI]" >&2
        exit 2
    fi
    echo "== src/hdmi/ vs $upstream/src/hdmi"
    echo "   snapshot was taken at TN20K-HDMI $UPSTREAM_COMMIT"
    echo
    drift=0
    for f in src/hdmi/*.v src/hdmi/*.vh; do
        base=$(basename "$f")
        if [ ! -f "$upstream/src/hdmi/$base" ]; then
            printf '  %-28s only here\n' "$base"
            drift=1
        elif diff -q "$f" "$upstream/src/hdmi/$base" >/dev/null 2>&1; then
            printf '  %-28s same\n' "$base"
        else
            n=$(diff "$f" "$upstream/src/hdmi/$base" | grep -c '^[<>]')
            printf '  %-28s differs (%s changed lines)\n' "$base" "$n"
            drift=1
        fi
    done
    echo
    if [ "$drift" = 0 ]; then
        echo "No drift: the upstream project has not changed src/hdmi/ since the snapshot."
    else
        echo "Drift found. Expected: hdmi_tx.v only (RGB_QUANT)."
        echo "Anything else means TN20K-HDMI has moved on; review each file with:"
        echo "  diff -u src/hdmi/<file> $upstream/src/hdmi/<file>"
        echo "then either port the change and re-baseline the snapshot, or record"
        echo "why it does not apply here."
    fi
    ;;

*)
    echo "usage: $0 [--check | --upstream [path-to-TN20K-HDMI]]" >&2
    exit 2
    ;;
esac
