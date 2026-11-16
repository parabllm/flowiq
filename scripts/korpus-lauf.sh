#!/bin/bash
# Three-way corpus run (G-REPLAY, docs/ARCHITEKTUR.md A.13): flowiq-tool replay, then two frozen counting rules
# (checksums verified, never edited): zaehlregel-v1 for harmful and helpful edits once per way, namensregel-v1
# for IQ name hits. Ways: passthrough (rawText), FlowIQ with R3 off (flowiq) and on (flowiqR3), each from rawText;
# Panotti's stored end text against Panotti's own stored raw text. rawText is the new recognition when a file
# from `flowiq-tool erkennen` is given, else Panotti's raw text. Chunks the rule calls name_disputed are written
# privately to <root>/strittig-<way>.jsonl and only counted here.
# Console: numbers and paths only. Every file with dictation text stays below the root, which must lie in local/.
# Usage: scripts/korpus-lauf.sh <history.json> <lexikon.tsv|lexikon.json> <referenz.jsonl> <local/...> [erkannt.jsonl]
# A seed list (.tsv) becomes a lexicon file of the store first (scripts/korpus/korpus.py startlexikon).
# Tool binary: $FLOWIQ_TOOL, default .build/debug/flowiq-tool.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
[ $# -ge 4 ] || { sed -n '2,10p' "$0"; exit 64; }
history=$1 lexicon=$2 reference=$3 root=$4 tool=${FLOWIQ_TOOL:-.build/debug/flowiq-tool}
rules=local/korpus/goldsatz
recognized=()
[ $# -ge 5 ] && recognized=(--erkannt "$5")
case "$root" in local/*) ;; *) echo "Wurzel muss unter local/ liegen"; exit 2 ;; esac
load=$(sysctl -n vm.loadavg | awk '{ print int($2) }')
[ "$load" -lt 20 ] || { echo "Last $load, Lauf abgebrochen"; exit 1; }
(cd "$rules" && shasum -a 256 -c zaehlregel-v1.sha256 && shasum -a 256 -c namensregel-v1.sha256) || exit 1
case "$lexicon" in
  *.tsv) mkdir -p "$root" && python3 -I scripts/korpus/korpus.py startlexikon --liste "$lexicon" \
           --aus "$root/startlexikon.json" || exit 1
         lexicon="$root/startlexikon.json" ;;
esac
"$tool" replay --history "$history" --lexikon "$lexicon" --referenz "$reference" --wurzel "$root" \
  ${recognized[@]+"${recognized[@]}"} || exit 1
python3 -I scripts/korpus/korpus.py zahlen --spur "$root/FlowIQ-Dev/replay/spur.jsonl" || exit 1
ways="$root/FlowIQ-Dev/replay/wege.json"
for pair in rawText:rawText flowiq:rawText flowiqR3:rawText processedText:panottiRawText; do
  way=${pair%%:*}
  echo "== Weg $way (Rohtext ${pair##*:})"
  python3 -I "$rules/zaehlregel-v1.py" --history "$ways" --raw-key "${pair##*:}" --end-key "$way" \
    --ref-key referenz --out "$root/chunks-$way.jsonl" || exit 1
  grep '"verdict": "name_disputed"' "$root/chunks-$way.jsonl" > "$root/strittig-$way.jsonl"
  echo "  name_disputed privat: $(wc -l < "$root/strittig-$way.jsonl" | tr -d ' ') Abschnitte"
done
echo "== Namen"
python3 -I "$rules/namensregel-v1.py" --history "$ways" --ref-key referenz \
  --way rawText --way processedText --way flowiq --way flowiqR3 || exit 1
