#!/bin/bash
# Privacy gate for FlowIQ (R-002). Modes:
#   (none)      staged content of the files in the index (pre-commit)
#   --all       all tracked files in the working tree
#   --historie  every commit on every ref: patches, messages, author and committer (pre-push)
# File names are checked too. Fixed patterns: home paths (/Users/<name>, ~/Documents/<folder>/<more>, ~/Desktop,
# ~/Downloads, dot folders in the home), mail addresses, German phone numbers (with country code, or mobile
# without), keys (sk_..., sk-or-..., xi-api-key, Bearer tokens). No names in this file: extra fixed-string
# patterns (names, companies) live in local/datenschutz-muster.txt (private, never committed, optional).
# Removed before matching: noreply@anthropic.com, <name>@users.noreply.github.com, <name>@example.com|org,
# and the app's own default folder ~/Documents/FlowIQ. Exit 1 on any hit.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
private=local/datenschutz-muster.txt
pattern='/Users/[a-z]|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}|(\+49|0049)[0-9 ]{6,}'
pattern="$pattern|sk_[A-Za-z0-9]{20,}|xi-api-key: *[A-Za-z0-9]"
pattern="$pattern|~/Documents/[^/ \`\"')]+/[A-Za-z0-9._-]|~/(Desktop|Downloads)/|~/\.[a-z]"
pattern="$pattern|sk-or-[A-Za-z0-9_-]{16,}|Bearer +[A-Za-z0-9._~+/=-]{20,}"
pattern="$pattern|(^|[^0-9A-Za-z.,_-])01[5-7][0-9][ /-]?[0-9]{3} ?[0-9]{3,5}([^0-9]|$)"
allowed='noreply@anthropic\.com|[A-Za-z0-9._%+-]+@users\.noreply\.github\.com|[A-Za-z0-9._%+-]+@example\.(com|org)'
allowed="$allowed|~\\/Documents\\/FlowIQ" # slashes escaped: used inside sed s/…//
mode="${1:-staged}"
fail=0
scope="feste Muster und private Musterliste"
[ -s "$private" ] || scope="nur feste Muster, keine private Musterliste"

hits() { # text on stdin -> matching lines with line number, each line once
  local text
  text=$(LC_ALL=C sed -E "s/$allowed//g")
  {
    printf '%s\n' "$text" | grep -anE "$pattern"
    [ -s "$private" ] && printf '%s\n' "$text" | grep -aniF -f <(grep -v '^#' "$private" | sed '/^$/d')
  } | sort -t: -k1,1n -u
}

report() { # label, hits
  [ -z "$2" ] && return
  echo "TREFFER ($1):"
  echo "$2"
  fail=1
}

if [ "$mode" = "--historie" ]; then
  identities=$(git log --all --format='Commit %h Autor %an <%ae>%nCommit %h Committer %cn <%ce>')
  report "Autor oder Committer" "$(printf '%s\n' "$identities" | hits | cut -d: -f2-)"
  history=$(git log -p --all --no-color --format='commit %h%n%B' \
    | awk '/^commit [0-9a-f]+$/ { c = $2 } { print c ": " $0 }')
  report "Historie (Nachrichten und Änderungen)" "$(printf '%s\n' "$history" | hits | cut -d: -f2-)"
else
  files=$(git diff --cached --name-only --diff-filter=ACMR)
  [ "$mode" = "--all" ] && files=$(git ls-files)
  [ -z "$files" ] && { echo "datenschutz-check: nichts zu prüfen"; exit 0; }
  while IFS= read -r f; do
    case "$f" in
      local/*) echo "VERBOTEN: $f liegt in local/"; fail=1; continue ;;
      *.aac | *.m4a | *.wav | *.caf | *.mp3) echo "VERBOTEN: Audio $f"; fail=1; continue ;;
    esac
    report "Dateiname" "$(printf '%s\n' "$f" | hits)"
    [ "$f" = "scripts/datenschutz-check.sh" ] && continue
    [ "$mode" = "--all" ] && [ ! -f "$f" ] && continue # deleted in the working tree, not yet committed
    show() { if [ "$mode" = "--all" ]; then cat "$f"; else git show ":$f"; fi; }
    show | LC_ALL=C grep -qI '' || continue # binary or empty
    report "$f" "$(show | hits)"
  done <<< "$files"
fi
[ $fail -eq 0 ] && echo "datenschutz-check: sauber ($scope)" || echo "datenschutz-check: BLOCKIERT ($scope)"
exit $fail
