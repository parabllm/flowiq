#!/bin/bash
# FlowIQ gate (docs/ARCHITEKTUR.md appendix F): privacy, line budget, exceptions, forbidden patterns,
# then a build with warnings as errors and all tests. `--static` stops before build and tests.
# Exit 1 on any finding, also when fewer tests run than pruefgrenzen.tsv demands (0 is always red).
# CHECK_TEST_FILTER only exists for counter-checks: any filter runs fewer tests and turns the gate red.
# Patterns live only in this file, which is therefore not scanned for them itself.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
fail=0
section() { printf '\n== %s\n' "$1"; }
forbid() { # label, hits
  [ -z "$2" ] && return
  echo "VERBOTEN ($1):"
  echo "$2"
  fail=1
}

section "Datenschutz"
scripts/datenschutz-check.sh --all || fail=1

section "Zeilenbudget"
scripts/zeilenbudget.sh || fail=1

section "Ausnahmen je Modul"
scripts/ausnahmen.sh || fail=1

section "Verbotene Muster"
code=(Sources Tests Package.swift)
everything=(Sources Tests Package.swift Resources scripts .githooks)
swift_files=$(find Sources Tests -name '*.swift' -type f | sort; echo Package.swift)
scan() { grep -rnIE "$1" "${code[@]}"; }
not_self() { grep -vE '^scripts/(check|datenschutz-check)\.sh:'; }
outside_theme() { grep -rnE "$1" Sources | grep -v '^Sources/FlowIQ/Theme/'; }
named_colors='red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|white|gray|black|clear'
raw_color="0x[0-9A-Fa-f]{6}|Color\((red|white|hex):|NSColor\((srgbRed|red|white|calibrated)"
raw_color="$raw_color|(Color|NSColor)\.($named_colors|system[A-Z][A-Za-z]*)\b|\(\.($named_colors)\)"
raw_size="(width|height|minWidth|maxWidth|minHeight|maxHeight|idealWidth|idealHeight|spacing|cornerRadius|radius"
raw_size="$raw_size|lineWidth|size|opacity|minLength|duration|tracking): *([1-9]|0\.)"
raw_size="$raw_size|\.padding\(([^)]*, *)?([1-9]|0\.)|\.system\(size:|systemFont\(ofSize:"
network='URLSession|NSURLConnection|NWConnection|NWListener|import Network|CFNetwork|WKWebView|Process\(|posix_spawn'
network="$network|Data\(contentsOf: *URL\(string:"
writes='createFile|moveItem|copyItem|removeItem|trashItem|replaceItem|linkItem|createSymbolicLink|createDirectory'
writes="$writes|setAttributes|\.write\(to:|FileHandle\((forWritingTo|forUpdating)|fopen\("
max_line=120

forbid "tccutil" "$(grep -rnI 'tccutil' "${everything[@]}" | not_self)"
forbid "Benutzerpfad" "$(grep -rnI '/Users/' "${everything[@]}" | not_self)"
forbid "try!" "$(scan 'try!')"
forbid "leeres catch" "$(perl -0777 -ne 'while (/\bcatch\b[^{}\n]*\{\s*\}/g) {
  printf "%s:%d\n", $ARGV, 1 + (substr($_, 0, $-[0]) =~ tr/\n//) }' $swift_files)"
forbid "import Cocoa" "$(scan '^[[:space:]]*import Cocoa')"
forbid "unsafeFlags oder abgeschaltete Isolationsprüfung" \
  "$(grep -nE 'unsafeFlags|disable-dynamic-actor-isolation' Package.swift)"
forbid "Audio-Systemeinstellung setzen" "$(scan 'AudioObjectSetPropertyData')"
forbid "DispatchQueue.main.sync" "$(scan 'DispatchQueue\.main\.sync')"
forbid "NSLog" "$(scan 'NSLog\(')"
forbid "eraseFile" "$(scan '[Ee]raseFile')"
forbid "NSSpellChecker außerhalb SystemWordOracle und flowiq-tool" "$(scan 'NSSpellChecker' \
  | grep -vE '^Sources/(FlowIQ/SystemWordOracle\.swift|FlowIQTool/)')"
forbid "Netz außerhalb FlowIQCloud" "$(grep -rnE "$network" Sources | grep -v '^Sources/FlowIQCloud/')"
elevenlabs='ElevenLabs(LiveRecognizer|Batch)\(|OpenRouterBatch\(|CloudPost\('
forbid "Cloud-Dienst außerhalb CloudGate (Prüfung P5, OpenRouter)" "$(grep -rnE "$elevenlabs" Sources \
  | grep -v '^Sources/FlowIQCloud/CloudPolicy\.swift:')"
forbid "Schreibaufruf außerhalb SafeFS" "$(grep -rnE "$writes" Sources | grep -v '^Sources/FlowIQCore/SafeFS\.swift:')"
forbid "ExtAudioFileCreateWithURL außerhalb TrackWriter" "$(grep -rn 'ExtAudioFileCreateWithURL' Sources \
  | grep -v '^Sources/FlowIQRecording/TrackWriter\.swift:')"
forbid "AppKit oder SwiftUI in FlowIQText" "$(grep -rnE 'import (AppKit|SwiftUI)' Sources/FlowIQText)"
forbid "Farbwert außerhalb Theme/" "$(outside_theme "$raw_color")"
forbid "Größen- oder Zeitwert außerhalb Theme/" "$(outside_theme "$raw_size")"
forbid "Zeile über $max_line Zeichen" "$(perl -CSD -sne '
  chomp; print "$ARGV:$.: ", length, " Zeichen\n" if length > $max;
  close ARGV if eof' -- -max="$max_line" $swift_files $(find scripts .githooks -type f | sort))"
# Text the user reads has real umlauts (decision 16.11.): a literal with a space or a capital start that holds a
# typical ASCII stand-in. Keys, ids and file names stay ASCII; a line with "ascii-ok" is exempt.
umlaut_stems='fuer|ueber|pruef|bestaet|loesch|aender|zurueck|schluessel|geraet|naechst|spaet|waehl|moeglich|koenn'
umlaut_stems="$umlaut_stems|hoer|oeffn|groess|faell|laeuf|woert|taeglich|eintraeg|fuehr|zaehl|erklaer|muess|wuerd"
umlaut_stems="$umlaut_stems|kuerz|gruen|gueltig|haelt|staerk|hoeh|stoer|noetig|wuensch|veraend"
forbid "Ersatz-Umlaut in Oberflächentext" "$(find Sources/FlowIQ -name '*.swift' | sort | xargs perl -CSD -sne '
  next if /ascii-ok/;
  while (/"((?:[^"\\]|\\.)*)"/g) { (my $s = $1) =~ s/\\\([^)]*\)//g;
    print "$ARGV:$.: $s\n" if ($s =~ / / || $s =~ /^[A-Z]/) && $s =~ /$stems/i }
  close ARGV if eof' -- -stems="$umlaut_stems")"
[ $fail -eq 0 ] && echo "keine Treffer"

if [ "${1:-}" != "--static" ]; then
  section "Last"
  load=$(sysctl -n vm.loadavg | awk '{ print int($2) }')
  echo "1-Minuten-Last $load"
  [ "$load" -lt 20 ] || { echo "Last 20 oder mehr, Bau abgebrochen"; exit 1; }

  section "Bau (Swift 6, Warnungen sind Fehler)"
  out=$(swift build --build-tests 2>&1)
  status=$?
  warnings=$(printf '%s\n' "$out" | grep -c 'warning:')
  printf '%s\n' "$out" | perl -pe 's/\e\[[0-9;]*m//g' \
    | grep -E '^[^ ]+:[0-9]+:[0-9]+: (error|warning):|^(error|warning): ' | cut -c1-240 | sort -u | head -40
  printf '%s\n' "$out" | tail -1
  echo "Warnungen: $warnings"
  [ $status -eq 0 ] && [ "$warnings" -eq 0 ] || fail=1

  section "Tests"
  filter=()
  [ -n "${CHECK_TEST_FILTER:-}" ] && filter=(--filter "$CHECK_TEST_FILTER")
  out=$(swift test ${filter[@]+"${filter[@]}"} 2>&1)
  status=$?
  clean=$(printf '%s\n' "$out" | perl -pe 's/\e\[[0-9;]*m//g')
  printf '%s\n' "$clean" | grep -E '✘|Test run with|Fatal error' | cut -c1-240 | head -40
  ran=$(printf '%s\n' "$clean" | sed -nE 's/.*Test run with ([0-9]+) tests?.*/\1/p' \
    | awk '{ s += $1 } END { print s + 0 }')
  minimum=$(awk -F'\t' '$1 == "tests" && $2 == "mindestens" { print $3 }' pruefgrenzen.tsv)
  echo "Tests gelaufen: $ran, mindestens: ${minimum:-fehlt}"
  [ $status -eq 0 ] || fail=1
  if [ "$ran" -eq 0 ] || [ -z "$minimum" ] || [ "$ran" -lt "$minimum" ]; then
    echo "VERBOTEN (zu wenige Tests): $ran gelaufen"
    fail=1
  fi
fi

[ $fail -eq 0 ] && echo && echo "check: GRÜN" || { echo; echo "check: ROT"; }
exit $fail
