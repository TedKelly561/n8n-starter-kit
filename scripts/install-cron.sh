#!/usr/bin/env bash
# Install (or refresh) the kit's cron jobs in the current user's crontab.
# Idempotent: the kit's lines live between BEGIN/END markers and are replaced.
#
# Usage: scripts/install-cron.sh [--file PATH] [--remove] [--print]
#   --file PATH  write the resulting crontab to PATH instead of installing it (testing)
#   --remove     remove the kit's block
#   --print      only print the block
#
# Schedule (server local time):
#   every 5 min   healthcheck.sh       containers, proxy, disk, backup age, certificate
#   02:15 daily   export-workflows.sh  rollback copy of every workflow version (git)
#   02:30 daily   backup.sh            database + n8n export + encrypted .env, retention
#   04:00 Sunday  restore-drill.sh     restore latest backup into a throwaway database
set -euo pipefail
. "$(dirname "$0")/lib.sh"

TARGET=""; REMOVE=0; PRINT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file) TARGET="${2:?}"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    --print) PRINT=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

BEGIN="# BEGIN n8n-starter-kit ($KIT_DIR) - managed by scripts/install-cron.sh"
END="# END n8n-starter-kit ($KIT_DIR)"
L="$KIT_DIR/data/logs"
q() { printf "'%s'" "$1"; }
BLOCK="$BEGIN
*/5 * * * * cd $(q "$KIT_DIR") && ./scripts/healthcheck.sh --quiet >> $(q "$L/healthcheck.log") 2>&1
15 2 * * * cd $(q "$KIT_DIR") && ./scripts/export-workflows.sh >> $(q "$L/export-workflows.log") 2>&1
30 2 * * * cd $(q "$KIT_DIR") && ./scripts/backup.sh >> $(q "$L/backup.log") 2>&1
0 4 * * 0 cd $(q "$KIT_DIR") && ./scripts/restore-drill.sh >> $(q "$L/restore-drill.log") 2>&1
$END"

[ "$PRINT" = 1 ] && { printf '%s\n' "$BLOCK"; exit 0; }
mkdir -p "$L"

current() {
  if [ -n "$TARGET" ]; then cat "$TARGET" 2>/dev/null || true
  else crontab -l 2>/dev/null || true; fi
}
# Strip any previous copy of our block.
NEWTAB="$(current | awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip')"
if [ "$REMOVE" = 0 ]; then
  NEWTAB="$(printf '%s\n%s\n' "$NEWTAB" "$BLOCK" | sed '/./,$!d')"
fi

if [ -n "$TARGET" ]; then
  printf '%s\n' "$NEWTAB" > "$TARGET"
  info "cron block written to $TARGET"
elif command -v crontab >/dev/null 2>&1; then
  printf '%s\n' "$NEWTAB" | crontab -
  info "cron jobs $([ "$REMOVE" = 1 ] && echo removed || echo installed) for user $(id -un)"
else
  printf '%s\n' "$BLOCK" > "$KIT_DIR/data/crontab.txt"
  warn "'crontab' is not installed (apt install cron). Block saved to data/crontab.txt; install it with: crontab data/crontab.txt"
  exit 2
fi
