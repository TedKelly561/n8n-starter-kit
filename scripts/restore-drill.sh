#!/usr/bin/env bash
# Weekly restore drill: proves the latest backup actually restores.
#
# Usage: scripts/restore-drill.sh [<backup-dir>]
#
# Restores the backup into a THROWAWAY Postgres container (no network, random
# password, removed afterwards) and compares row counts for every table with
# the counts recorded from the dump, plus workflow/credential counts with the
# n8n export. Production is never touched.
set -Eeuo pipefail
. "$(dirname "$0")/lib.sh"
load_env
with_lock restore-drill

SRC="${1:-}"
[ -n "$SRC" ] || SRC="$(latest_backup)"
[ -n "$SRC" ] && [ -d "$SRC" ] || die "no complete backup found in $BACKUP_DIR"
SRC="$(cd "$SRC" && pwd)"
NAME="n8nkit-drill-$$"
REPORT="$LOG_DIR/restore-drill-$(date +%Y%m%d-%H%M%S).txt"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

result() {
  local status="$1" msg="$2"
  printf '%s %s %s\n' "$(ts)" "$status" "$msg" | tee -a "$REPORT"
  ops_log drill "$status" "$(basename "$SRC"): $msg"
  if [ "$status" = OK ]; then
    ping_heartbeat "${DRILL_HEARTBEAT_URL:-}"
  else
    send_alert "Restore drill FAILED" "$msg (backup $(basename "$SRC")). Report: $REPORT" || true
    ping_heartbeat "${DRILL_HEARTBEAT_URL:-}" fail
    exit 1
  fi
}

step "Restore drill for $SRC"
[ -f "$SRC/.complete" ] || result FAILED "backup is incomplete"
( cd "$SRC" && sha256sum -c --quiet SHA256SUMS ) || result FAILED "checksum mismatch"
[ -f "$SRC/rowcounts.txt" ] || result FAILED "backup has no rowcounts.txt"

info "starting throwaway postgres:$POSTGRES_VERSION ($NAME, no network)"
docker run -d --name "$NAME" --network none \
  -e POSTGRES_USER=drill -e POSTGRES_DB=drill \
  -e POSTGRES_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')" \
  --memory 256m "postgres:$POSTGRES_VERSION" >/dev/null
for _ in $(seq 1 60); do
  # pg_isready on the unix socket; wait for the init restart to finish too.
  if docker exec "$NAME" pg_isready -U drill -d drill >/dev/null 2>&1 \
     && docker exec "$NAME" psql -U drill -d drill -Atc 'select 1' >/dev/null 2>&1; then break; fi
  sleep 1
done
sleep 2
docker exec "$NAME" psql -U drill -d drill -Atc 'select 1' >/dev/null 2>&1 || result FAILED "throwaway postgres did not start"

info "loading dump"
gzip -dc "$SRC/db.sql.gz" | docker exec -i "$NAME" psql -v ON_ERROR_STOP=1 -q -U drill -d drill >/dev/null \
  || result FAILED "dump did not load cleanly"

info "comparing row counts"
{ echo "Restore drill $(ts)"; echo "backup: $SRC"; echo; printf '%-45s %10s %10s\n' table expected restored; } > "$REPORT"
mismatch=0; tables=0
while read -r table expected; do
  [ -n "$table" ] || continue
  got="$(docker exec "$NAME" psql -U drill -d drill -Atc "SELECT count(*) FROM $table" 2>/dev/null || echo ERR)"
  printf '%-45s %10s %10s\n' "$table" "$expected" "$got" >> "$REPORT"
  tables=$((tables+1))
  [ "$got" = "$expected" ] || { mismatch=$((mismatch+1)); err "  $table: expected $expected, got $got"; }
done < "$SRC/rowcounts.txt"

mval() { grep -E "^$1=" "$SRC/manifest.txt" | cut -d= -f2-; }
wf_db="$(docker exec "$NAME" psql -U drill -d drill -Atc 'SELECT count(*) FROM workflow_entity')"
cred_db="$(docker exec "$NAME" psql -U drill -d drill -Atc 'SELECT count(*) FROM credentials_entity')"
wf_exp="$(mval workflows)"; cred_exp="$(mval credentials)"
printf '\nworkflows: restored %s, n8n export %s\ncredentials: restored %s, n8n export %s\n' \
  "$wf_db" "$wf_exp" "$cred_db" "$cred_exp" >> "$REPORT"
[ "$wf_db" = "$wf_exp" ] || { mismatch=$((mismatch+1)); err "  workflows: db $wf_db vs export $wf_exp"; }
[ "$cred_db" = "$cred_exp" ] || { mismatch=$((mismatch+1)); err "  credentials: db $cred_db vs export $cred_exp"; }

info "  $tables tables checked; workflows $wf_db/$wf_exp; credentials $cred_db/$cred_exp"
info "  report: $REPORT"
if [ "$mismatch" -gt 0 ]; then
  result FAILED "$mismatch count mismatch(es)"
fi
result OK "$tables tables match, $wf_db workflows, $cred_db credentials"
