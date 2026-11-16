#!/bin/bash
# Seeding run (LEXIKON-KONZEPT 12) over the corpus without the gold set: scripts/korpus/korpus.py erstbefuellung,
# which takes every stage result from flowiq-tool replay and judges harm with the frozen counting rule zaehlregel-v1
# (checksum verified). The output folder holds lexikon.json and kontobuch.json for the app's first import
# ("Panotti-Daten übernehmen" in the area "Wörter") plus the private table urteile.json. Everything stays in local/.
# Usage: scripts/erstbefuellung.sh <history.json> <vocabulary.json> <lexikon.tsv> <erkannt.jsonl> <local/...>
#        [--ids <lern-ids.txt>]   Tool binary: $FLOWIQ_TOOL, default .build/debug/flowiq-tool.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
[ $# -ge 5 ] || { sed -n '2,7p' "$0"; exit 64; }
history=$1 rules=$2 lexicon=$3 recognized=$4 root=$5
shift 5
case "$root" in local/*) ;; *) echo "Wurzel muss unter local/ liegen"; exit 2 ;; esac
load=$(sysctl -n vm.loadavg | awk '{ print int($2) }')
[ "$load" -lt 20 ] || { echo "Last $load, Lauf abgebrochen"; exit 1; }
python3 -I scripts/korpus/korpus.py erstbefuellung --history "$history" --regeln "$rules" --liste "$lexicon" \
  --erkannt "$recognized" --aufteilung local/korpus/goldsatz/aufteilung.tsv --aus "$root" \
  --tool "${FLOWIQ_TOOL:-.build/debug/flowiq-tool}" "$@"
