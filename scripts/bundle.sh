#!/bin/bash
# Builds and signs the app bundle under build/ (docs/ARCHITEKTUR.md E.3, E.4).
# Usage: scripts/bundle.sh dev|prod [--neue-referenz]
# Never starts, installs, registers or quits any app (installing is scripts/install.sh).
# Two ways of signing:
#   1. Apple Development identity, pinned in local/signing.env (SIGN_ID=<sha1>, TEAM_ID=<team>); on the first
#      run that is the first "Apple Development" line of `security find-identity` and the team of its
#      certificate (neither enters the repo). The owner confirms the pin by adding CONFIRMED=yes; until then
#      every run says so. An unreadable pin aborts. The designated requirement (identifier, Apple anchor, team)
#      is compared with local/designated-requirement-<profile>.txt: a missing reference is written on the first
#      build, a difference aborts (R-083), --neue-referenz replaces it. macOS keeps the permissions over rebuilds.
#   2. No such identity and no pin (or FLOWIQ_SIGN=adhoc): local ad-hoc signature (`codesign -s -`), no
#      reference check. macOS then ties the four permissions to each single build.
# FLOWIQ_BUILD_DIR=<folder> writes the bundle and its build counter there instead of build/ (for trial builds
# next to a running app). A bundle whose signature, team or requirement fails is deleted, never left behind.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="0.1.0"
case "${1:-}" in
  dev) profile=development; bundle_id=de.flowiq.app.dev; name="FlowIQ Dev"; support="FlowIQ-Dev" ;;
  prod) profile=production; bundle_id=de.flowiq.app; name="FlowIQ"; support="FlowIQ" ;;
  *) echo "Aufruf: scripts/bundle.sh dev|prod [--neue-referenz]" >&2; exit 64 ;;
esac
case "${2:-}" in "" | --neue-referenz) ;; *) echo "Unbekannter Schalter: $2" >&2; exit 64 ;; esac
die() { echo "bundle: $*" >&2; exit 1; }
sign_mode="${FLOWIQ_SIGN:-auto}"
case "$sign_mode" in auto | adhoc) ;; *) die "FLOWIQ_SIGN kennt nur adhoc, nicht: $sign_mode" ;; esac
out="${FLOWIQ_BUILD_DIR:-build}"
mkdir -p local "$out" # local/ is private and gitignored; a fresh clone has none

# 1. Guards: machine load, and the profile must not be busy recording, importing or uploading (R-050).
load=$(sysctl -n vm.loadavg | awk '{ print int($2) }')
[ "$load" -lt 20 ] || die "1-Minuten-Last $load, gebaut wird erst unter 20"
# A trial build into another folder replaces nothing that runs, so only its own bundle path counts there.
running_path="/$name.app/Contents/MacOS/FlowIQ"
[ "$out" = build ] || running_path="$(cd "$out" && pwd)$running_path"
running=$(pgrep -f "$running_path" | head -n 1 || true)
[ -z "$running" ] || die "$name läuft noch (PID $running): erst über das Menü beenden, dann bauen"
busy="$HOME/Library/Application Support/$support/laufend/.belegt"
if [ -f "$busy" ]; then
  pid=$(sed -nE 's/.*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$busy" | head -n 1)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then die "$name ist belegt (PID $pid): $(cat "$busy")"; fi
fi

# 2. Static gate (privacy, patterns, line budget).
gate=$(scripts/check.sh --static 2>&1) || { echo "$gate"; die "check.sh --static ist rot"; }

# 3. Release build.
swift build -c release --product FlowIQ
binary="$(swift build -c release --show-bin-path)/FlowIQ"
[ -x "$binary" ] || die "Binär fehlt: $binary"

# 4. Assemble <out>/<name>.app (build/ is output only and gitignored).
app="$out/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Fonts"
cp "$binary" "$app/Contents/MacOS/FlowIQ"
cp Resources/Fonts/DMSans-Regular.ttf Resources/Fonts/DMSans-Medium.ttf Resources/Fonts/DMSans-SemiBold.ttf \
  Resources/Fonts/OFL.txt "$app/Contents/Resources/Fonts/"
# Logo B "Stimme" (R-003): menu bar templates as they are, the app icon in 10 sizes from the SVG via sips and iconutil.
# Menu bar templates and the curated OpenRouter models (OpenRouterModels.load reads them from the bundle).
cp Resources/MenuBar/*.svg Resources/Cloud/openrouter-modelle.json "$app/Contents/Resources/"
iconset="$out/FlowIQ.iconset"
rm -rf "$iconset" && mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" Resources/AppIcon/appsymbol.svg \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -s format png -z "$double" "$double" Resources/AppIcon/appsymbol.svg \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
[ "$(ls "$iconset" | wc -l | tr -d ' ')" = 10 ] || die "Symbol: nicht alle 10 Größen erzeugt"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/FlowIQ.icns" || die "iconutil gescheitert"
rm -rf "$iconset"
printf 'APPL????' > "$app/Contents/PkgInfo"

# 5. Build stamp: counter per profile, commit, changed working tree.
counter="$out/.bauzaehler-$profile"
build=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
echo "$build" > "$counter"
commit=$(git rev-parse --short HEAD)
[ -z "$(git status --porcelain)" ] || commit="$commit geändert"
sed -e "s|@BUNDLE_ID@|$bundle_id|g" -e "s|@NAME@|$name|g" -e "s|@PROFILE@|$profile|g" \
    -e "s|@VERSION@|$version|g" -e "s|@BUILD@|$build|g" -e "s|@COMMIT@|$commit|g" \
    Resources/Info.plist.in > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist" || die "Info.plist ungültig"

# 6. Sign. With an Apple Development identity: SHA-1 and expected team come from local/signing.env (appendix D),
#    and the designated requirement is set explicitly to identifier, Apple anchor and team, so it survives a
#    renewed certificate. Without one: ad-hoc, and macOS asks for the permissions again after every build.
reject() { rm -rf "$app"; die "$* (Bündel gelöscht)"; }
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
pin="local/signing.env"
if [ "$sign_mode" = auto ] && [ ! -f "$pin" ]; then
  first=$(printf '%s\n' "$identities" | awk '/"Apple Development/ && id == "" { id = $2 } END { print id }')
  if [ -n "$first" ]; then
    echo "SIGN_ID=$first" > "$pin"
    echo "Identität automatisch gewählt (erste Apple-Development-Zeile) und in $pin festgehalten."
  else
    sign_mode=adhoc
  fi
fi

if [ "$sign_mode" = adhoc ]; then
  codesign --force --sign - --timestamp=none "$app" || reject "Signieren gescheitert"
  codesign --verify --strict "$app" || reject "Signatur ungültig"
  echo "Bündel: $(cd "$out" && pwd)/$name.app"
  echo "Bau $build · $commit"
  echo "Ohne Apple-Signatur gebaut. macOS vergibt die vier Rechte je Bau: nach jedem Neubau müssen Mikrofon,"
  echo "Bedienungshilfen, Eingabeüberwachung und Bildschirmaufnahme neu erlaubt werden. Mit einer kostenlosen"
  echo "Apple-ID in Xcode (Einstellungen > Accounts) entsteht eine feste Signatur."
  exit 0
fi

identity=$(sed -nE 's/^SIGN_ID=([0-9A-F]{40})$/\1/p' "$pin")
[ -n "$identity" ] || reject "$pin ist unlesbar (erwartet SIGN_ID=<40 Hex-Zeichen>), nichts ersetzt"
case "$identities" in *"$identity"*) ;; *) reject "Identität aus $pin fehlt im Schlüsselbund" ;; esac
identity_name=$(printf '%s\n' "$identities" \
  | awk -v id="$identity" '$2 == id { $1 = ""; $2 = ""; sub(/^  /, ""); print }')
cert_team=$(security find-certificate -a -Z -p 2>/dev/null \
  | awk -v sha="$identity" '/^SHA-1 hash:/ { keep = ($3 == sha) } keep && /BEGIN CERT/, /END CERT/' \
  | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null | sed -nE 's/.*OU=([A-Z0-9]+).*/\1/p') || cert_team=""
team=$(sed -nE 's/^TEAM_ID=([A-Z0-9]{10})$/\1/p' "$pin")
if [ -z "$team" ]; then
  grep -q '^TEAM_ID=' "$pin" && reject "TEAM_ID in $pin ist unlesbar, nichts ersetzt"
  [ -n "$cert_team" ] || reject "Team-Kennung des Zertifikats nicht lesbar"
  team=$cert_team
  echo "TEAM_ID=$team" >> "$pin"
  echo "Team-Kennung $team aus dem Zertifikat übernommen und in $pin festgehalten."
fi
[ "$cert_team" = "$team" ] || reject "Zertifikat gehört zu Team ${cert_team:-unbekannt}, erwartet $team"
echo "Signatur-Identität: $identity_name (${identity:0:8}), Team $team"
grep -qx 'CONFIRMED=yes' "$pin" \
  || echo "Hinweis: Identität und Team sind zu bestätigen (Zeile CONFIRMED=yes in $pin), sie gelten dann für immer."
wanted="identifier \"$bundle_id\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\""
codesign --force --sign "$identity" --timestamp=none --requirements "=designated => $wanted" "$app" \
  || reject "Signieren gescheitert"
codesign --verify --strict "$app" || reject "Signatur ungültig"
signed_team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$signed_team" = "$team" ] || reject "Team-Kennung der Signatur ${signed_team:-fehlt}, erwartet $team"

# 7. Designated requirement must never change, otherwise macOS asks for every permission again.
#    The first build writes the reference; replacing an existing one needs the explicit switch --neue-referenz.
requirement=$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')
[ "$requirement" = "$wanted" ] || reject "Designated Requirement nicht wie gesetzt: $requirement"
reference="local/designated-requirement-$profile.txt"
if [ "${2:-}" = "--neue-referenz" ]; then
  [ -f "$reference" ] && echo "Alte Referenz ersetzt: $(cat "$reference")"
  echo "$requirement" > "$reference"
  echo "Designated Requirement als Referenz festgehalten: $reference"
elif [ -f "$reference" ]; then
  [ "$(cat "$reference")" = "$requirement" ] || reject "Designated Requirement weicht von $reference ab"
else
  echo "$requirement" > "$reference"
  echo "Erster Bau mit dieser Signatur: Designated Requirement als Referenz festgehalten ($reference)."
fi

echo "Bündel: $(cd "$out" && pwd)/$name.app"
echo "Bau $build · $commit"
echo "Designated Requirement: $requirement"
