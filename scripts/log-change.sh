#!/usr/bin/env bash
# Record a manual change (new workflow, live-mode switch, credential change...)
# in ops-log.md so the one-change-a-day rule covers it too.
#
# Usage: scripts/log-change.sh "Switched work-order intake from shadow to live"
#        scripts/log-change.sh --check     # exit 1 if a change is already logged today
set -euo pipefail
. "$(dirname "$0")/lib.sh"
[ $# -gt 0 ] || die 'usage: scripts/log-change.sh "what changed"'
if [ "$1" = "--check" ]; then
  t="$(changes_today)"
  if [ -n "$t" ]; then printf 'Already changed today:\n%s\n' "$t"; exit 1; fi
  echo "No change logged today."; exit 0
fi
t="$(changes_today)"
[ -z "$t" ] || warn "this is not the first change today (one change a day):"$'\n'"$t"
ops_log change OK "$*"
info "logged in ops-log.md"
