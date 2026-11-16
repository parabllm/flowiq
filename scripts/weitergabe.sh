#!/bin/bash
# Makes a clean copy of the repo for handing on, without history.
# Usage: scripts/weitergabe.sh [target folder]   (default: ../flowiq-weitergabe)
# The committed state (HEAD) goes into the target via `git archive`, there `git init` and one commit by the
# neutral author "FlowIQ <noreply@example.com>" (set for that one commit only; no git configuration of this
# repo or of the user is changed). Then the hook path is set in the copy, the privacy check runs there over
# files and history, and the copy is searched for every term of the private lists
# local/datenschutz-muster.txt and local/weitergabe-muster.txt (both optional; the second one holds terms
# that are fine here but must not be handed on). Any hit aborts with the list and removes the copy.
# Aborts when the target exists. No remote, no push. Uncommitted changes are not part of the copy.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
die() { echo "weitergabe: $*" >&2; exit 1; }
target="${1:-../flowiq-weitergabe}"
[ $# -le 1 ] || die "Aufruf: scripts/weitergabe.sh [Zielordner]"
[ ! -e "$target" ] || die "$target gibt es schon: anderen Ordner nennen oder den alten selbst entfernen"
[ -z "$(git status --porcelain)" ] \
  || echo "Hinweis: der Arbeitsbaum hat Änderungen ohne Commit, sie fehlen im Abzug (er zeigt HEAD)."

mkdir -p "$target"
target="$(cd "$target" && pwd)"
git archive HEAD | tar -x -C "$target"
commit=$(git rev-parse --short HEAD)
neutral=(-c user.name=FlowIQ -c user.email=noreply@example.com -c commit.gpgsign=false)
(
  cd "$target"
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  git init --quiet --initial-branch=main
  git add --all
  git "${neutral[@]}" commit --quiet --no-verify -m "FlowIQ"
  git config core.hooksPath .githooks
)

fail=0
echo "== Datenschutz-Prüfung im Abzug (Dateien, dann Historie)"
(cd "$target" && scripts/datenschutz-check.sh --all) || fail=1
(cd "$target" && scripts/datenschutz-check.sh --historie) || fail=1

echo "== Begriffe der privaten Listen"
terms=$(cat local/datenschutz-muster.txt local/weitergabe-muster.txt 2>/dev/null | grep -v '^#' | sed '/^$/d' || true)
if [ -z "$terms" ]; then
  echo "keine private Liste vorhanden, übersprungen"
else
  hits=$(cd "$target" && { grep -rniIF --exclude-dir=.git -e "$terms" . | cut -c1-200
    find . -path ./.git -prune -o -print | grep -iF -e "$terms" | sed 's/^/Dateiname: /'
    git log --format='Commit: %an <%ae> %cn <%ce> %s' | grep -iF -e "$terms"; } || true)
  if [ -n "$hits" ]; then
    echo "$hits" | head -200
    echo "Treffer: $(echo "$hits" | wc -l | tr -d ' ') Zeilen (gezeigt höchstens 200)"
    fail=1
  else
    echo "keine Treffer"
  fi
fi

if [ $fail -ne 0 ]; then
  rm -rf "$target"
  die "Treffer im Abzug, $target wieder entfernt. Erst im Repo bereinigen und committen, dann erneut."
fi
echo
echo "Abzug fertig: $target"
echo "Stand $commit, ein Commit von FlowIQ <noreply@example.com>, kein Remote."
