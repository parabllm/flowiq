#!/bin/bash
# Copies the bundle built by scripts/bundle.sh into ~/Applications.
# Usage: scripts/install.sh dev|prod
# Starts nothing, quits nothing, registers nothing. Aborts while the app runs (quit it from its menu first)
# and when no bundle has been built. FLOWIQ_BUILD_DIR=<folder> reads the bundle from there instead of build/,
# FLOWIQ_INSTALL_DIR=<folder> writes there instead of ~/Applications.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
case "${1:-}" in
  dev) name="FlowIQ Dev" ;;
  prod) name="FlowIQ" ;;
  *) echo "Aufruf: scripts/install.sh dev|prod" >&2; exit 64 ;;
esac
die() { echo "install: $*" >&2; exit 1; }
source_app="${FLOWIQ_BUILD_DIR:-build}/$name.app"
target_dir="${FLOWIQ_INSTALL_DIR:-$HOME/Applications}"
target="$target_dir/$name.app"

[ -d "$source_app" ] || die "$source_app fehlt: erst scripts/bundle.sh $1"
codesign --verify --strict "$source_app" || die "Signatur von $source_app ist ungültig: neu bauen"
running=$(pgrep -f "/$name.app/Contents/MacOS/FlowIQ" | head -n 1 || true)
[ -z "$running" ] || die "$name läuft noch (PID $running): erst über das Menü beenden, dann installieren"

# Copy next to the target first, then swap, so a failed copy never leaves half an app behind.
mkdir -p "$target_dir"
fresh="$target_dir/.$name.app.neu"
rm -rf "$fresh"
ditto "$source_app" "$fresh" || { rm -rf "$fresh"; die "Kopieren gescheitert"; }
rm -rf "$target"
mv "$fresh" "$target"
codesign --verify --strict "$target" || die "Signatur der Kopie ist ungültig"

echo "Installiert: $target"
echo "Nichts gestartet. Start per Doppelklick im Finder oder mit: open \"$target\""
