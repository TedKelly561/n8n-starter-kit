#!/usr/bin/env bash
# Rollback copies: export every workflow as pretty JSON into HISTORY_DIR (its own
# git repo inside the data folder, NOT the kit repo) and commit only when
# something changed. `git log -p` there is the diffable history of every version.
#
# Usage: scripts/export-workflows.sh [-m "commit message"]
#
# Roll a workflow back: open the old file with
#   git -C data/history show <commit>:<id>.json > /tmp/old.json
# and import it (Workflows > Import from file), or use n8n's own version history.
set -Eeuo pipefail
. "$(dirname "$0")/lib.sh"

MSG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m) MSG="${2:?-m needs a message}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
load_env
with_lock export-workflows
command -v git >/dev/null 2>&1 || die "git is required (apt install git)"

mkdir -p "$HISTORY_DIR"
if [ ! -d "$HISTORY_DIR/.git" ]; then
  git -C "$HISTORY_DIR" init -q -b main 2>/dev/null || git -C "$HISTORY_DIR" init -q
  git -C "$HISTORY_DIR" config user.name "n8n-starter-kit"
  git -C "$HISTORY_DIR" config user.email "history@localhost"
  printf '# Workflow history\n\nOne JSON file per workflow (named by workflow id). Written by scripts/export-workflows.sh.\n' > "$HISTORY_DIR/README.md"
fi

[ "$(service_health n8n)" = "healthy" ] || die "n8n is not healthy; not exporting"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
dc exec -T n8n sh -ec '
  out=/tmp/kit-history-export
  rm -rf "$out"; mkdir -p "$out"
  n8n export:workflow --all --separate --pretty --output="$out/" > /tmp/kit-history.log 2>&1 \
    || grep -qi "no workflows found" /tmp/kit-history.log
  tar -C "$out" -cf - .
  rm -rf "$out" /tmp/kit-history.log
' | tar -C "$TMP" -xf -

# Mirror: replace workflow files, remove ones whose workflow was deleted.
find "$HISTORY_DIR" -maxdepth 1 -name '*.json' -delete
find "$TMP" -maxdepth 1 -name '*.json' -exec cp {} "$HISTORY_DIR/" \;
COUNT="$(find "$HISTORY_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"

cd "$HISTORY_DIR"
git add -A
if git diff --cached --quiet; then
  info "No workflow changes ($COUNT workflows). Nothing committed."
  exit 0
fi
CHANGED="$(git diff --cached --name-status | awk '{print $1" "$2}')"
NAMES=""
while read -r status file; do
  n=""
  case "$file" in *.json) [ -f "$file" ] && n="$( { grep -m1 '^  "name":' "$file" || true; } | sed 's/^  "name": "\(.*\)",$/\1/')" ;; esac
  NAMES="$NAMES"$'\n'"$status $file ${n:+($n)}"
done <<< "$CHANGED"
git commit -q -m "${MSG:-Workflow export $(date +%Y-%m-%d\ %H:%M)}" -m "Changed:$NAMES"
info "Committed $(git rev-parse --short HEAD): $(printf '%s\n' "$CHANGED" | grep -c .) file(s) changed, $COUNT workflows total."
