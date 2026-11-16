#!/bin/bash
# Line budget per module. Reads budget.tsv (columns modul, budget, grenze; row GESAMT or Summe is the total)
# and counts the physical lines of every .swift file below Sources/<module>/ (flowiq-tool lives in
# Sources/FlowIQTool). Exit 1 when a module or the total is above its grenze, when a file has more
# than 800 lines, or when a source folder has no row. Above budget but within grenze is reported only.
# Usage: scripts/zeilenbudget.sh [sources-dir] [budget.tsv]
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
sources="${1:-$root/Sources}"
table="${2:-$root/budget.tsv}"
file_limit=800
[ -f "$table" ] || { echo "zeilenbudget: $table fehlt"; exit 2; }

count_lines() { # all .swift files below $1, a last line without newline counts too
  [ -d "$1" ] || { echo 0; return; }
  find "$1" -name '*.swift' -type f -exec awk 'END { print NR }' {} \; </dev/null \
    | awk '{ s += $1 } END { print s + 0 }'
}

judge() { # lines, budget, limit -> state text (runs in a subshell, the caller sets fail)
  if [ "$1" -gt "$3" ]; then echo "ÜBER DER GRENZE"
  elif [ "$1" -gt "$2" ]; then echo "über Budget, unter Grenze"
  elif [ $(($1 * 100)) -ge $(($2 * 85)) ]; then echo "Warnung: ab 85 % des Budgets"
  else echo "ok"; fi
}

fail=0
total=0
known=" "
sum_budget=""
sum_name=""
sum_limit=""
while IFS=$'\t' read -r module budget limit _ || [ -n "$module" ]; do
  case "$module" in "" | modul | \#*) continue ;; esac
  limit="${limit:-$budget}"
  case "$budget$limit" in *[!0-9]* | "") echo "Ungültige Zeile in $table: $module"; fail=1; continue ;; esac
  case "$module" in GESAMT | Summe) sum_name=$module; sum_budget=$budget; sum_limit=$limit; continue ;; esac
  dir="$module"
  [ "$module" = "flowiq-tool" ] && dir="FlowIQTool"
  known="$known$dir "
  lines=$(count_lines "$sources/$dir")
  total=$((total + lines))
  printf '%-16s %5d Zeilen, Budget %5d, Grenze %5d  %s\n' "$module" "$lines" "$budget" "$limit" \
    "$(judge "$lines" "$budget" "$limit")"
  [ "$lines" -gt "$limit" ] && fail=1
done < "$table"

if [ -z "$sum_limit" ]; then
  echo "Zeile GESAMT fehlt in $table"
  fail=1
else
  printf '%-16s %5d Zeilen, Budget %5d, Grenze %5d  %s\n' "$sum_name" "$total" "$sum_budget" "$sum_limit" \
    "$(judge "$total" "$sum_budget" "$sum_limit")"
  [ "$total" -gt "$sum_limit" ] && fail=1
fi

for folder in "$sources"/*/; do
  [ -d "$folder" ] || continue
  name=$(basename "$folder")
  case "$known" in *" $name "*) ;; *) echo "Modul ohne Budget: $name"; fail=1 ;; esac
done

long=$(find "$sources" -name '*.swift' -type f \
  -exec awk -v max="$file_limit" 'END { if (NR > max) print FILENAME ": " NR " Zeilen" }' {} \; </dev/null)
[ -z "$long" ] || { echo "Datei über $file_limit Zeilen:"; echo "$long"; fail=1; }

[ $fail -eq 0 ] && echo "zeilenbudget: eingehalten" || echo "zeilenbudget: ÜBERSCHRITTEN"
exit $fail
