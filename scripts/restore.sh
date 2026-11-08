#!/usr/bin/env bash
# Restore production from a backup folder.
#
# Usage: scripts/restore.sh <backup-dir> [--yes] [--skip-safety-backup]
#                           [--import-exports] [--ignore-key-mismatch]
#
#   1. checks the backup (complete marker, SHA256SUMS, encryption key fingerprint)
#   2. takes a safety backup of the current state (unless --skip-safety-backup)
#   3. stops n8n, recreates the database from db.sql.gz
#   4. imports workflows/credentials from the n8n export when the backup has no
#      database dump, or when --import-exports is given (normally the dump
#      already contains them, and re-importing would unpublish active workflows)
#   5. starts n8n, waits for health, checks workflow counts against the backup
set -Eeuo pipefail
. "$(dirname "$0")/lib.sh"

SRC=""; YES=0; SAFETY=1; IMPORT=0; IGNORE_KEY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --skip-safety-backup) SAFETY=0; shift ;;
    --import-exports) IMPORT=1; shift ;;
    --ignore-key-mismatch) IGNORE_KEY=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) SRC="$1"; shift ;;
  esac
done
[ -n "$SRC" ] || die "usage: scripts/restore.sh <backup-dir> [--yes]"
load_env
SRC="$(cd "$SRC" 2>/dev/null && pwd)" || die "backup folder not found"

step "Checking backup $SRC"
[ -f "$SRC/.complete" ] || die "backup has no .complete marker (it did not finish); pick another"
( cd "$SRC" && sha256sum -c --quiet SHA256SUMS ) || die "checksum mismatch: backup is damaged"
info "checksums OK"
HAS_DB=0; [ -f "$SRC/db.sql.gz" ] && HAS_DB=1
[ "$HAS_DB" = 1 ] || IMPORT=1
mval() { grep -E "^$1=" "$SRC/manifest.txt" 2>/dev/null | cut -d= -f2-; }
WANT_WF="$(mval workflows)"
BK_FP="$(mval encryption_key_fingerprint)"
CUR_FP="$(printf '%s' "$N8N_ENCRYPTION_KEY" | sha256sum | cut -c1-16)"
if [ -n "$BK_FP" ] && [ "$BK_FP" != "$CUR_FP" ]; then
  err "This backup was made with a DIFFERENT N8N_ENCRYPTION_KEY (fingerprint $BK_FP, current $CUR_FP)."
  err "Credentials would not decrypt. Put the original key in .env (from your password manager"
  err "or the encrypted env archive in the backup), then run this again."
  [ "$IGNORE_KEY" = 1 ] || exit 1
  warn "--ignore-key-mismatch given: continuing anyway"
fi
info "backup from $(mval created), n8n $(mval n8n_version), $WANT_WF workflows"

if [ "$YES" != 1 ]; then
  printf '%sThis REPLACES the live n8n database with the backup. Type "restore" to continue: %s' "$C_BLD" "$C_OFF"
  read -r answer
  [ "$answer" = "restore" ] || die "cancelled"
fi

if [ "$SAFETY" = 1 ]; then
  step "Safety backup of the current state"
  "$KIT_DIR/scripts/backup.sh" --tag pre-restore --no-retention --no-offsite >/dev/null \
    || die "safety backup failed. Fix that first, or re-run with --skip-safety-backup if the live data is already lost."
  info "safety backup: $(cat "$STATE_DIR/last-backup")"
fi

fail() {
  ops_log restore FAILED "from $(basename "$SRC"): $1"
  send_alert "Restore FAILED" "$1 (backup $(basename "$SRC"))" || true
  die "$1"
}

step "Stopping n8n"
dc stop n8n >/dev/null 2>&1

if [ "$HAS_DB" = 1 ]; then
  step "Restoring database"
  wait_healthy 120 postgres || fail "postgres is not healthy"
  dc exec -T postgres psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE);" \
    -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";" || fail "could not recreate database"
  gzip -dc "$SRC/db.sql.gz" | dc exec -T postgres psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null \
    || fail "database restore failed"
  info "database restored"
  ensure_readonly_role || warn "could not re-create read-only role"
fi

step "Starting n8n"
dc up -d n8n >/dev/null 2>&1
wait_healthy 300 n8n || fail "n8n did not become healthy after restore"

if [ "$IMPORT" = 1 ]; then
  step "Importing workflows and credentials from the n8n export"
  if [ -d "$SRC/workflows" ] && [ -n "$(ls -A "$SRC/workflows" 2>/dev/null)" ]; then
    tar -C "$SRC" -cf - workflows | dc exec -T n8n sh -ec 'rm -rf /tmp/kit-restore; mkdir -p /tmp/kit-restore; tar -C /tmp/kit-restore -xf -'
    dc exec -T n8n n8n import:workflow --separate --input=/tmp/kit-restore/workflows/ || fail "workflow import failed"
  fi
  if [ -f "$SRC/credentials.json" ]; then
    dc exec -T n8n sh -c 'cat > /tmp/kit-restore/credentials.json' < "$SRC/credentials.json"
    dc exec -T n8n n8n import:credentials --input=/tmp/kit-restore/credentials.json || fail "credential import failed"
  fi
  dc exec -T n8n rm -rf /tmp/kit-restore || true
  warn "Imported workflows are unpublished. Review and publish them in the editor."
fi

step "Verifying"
GOT_WF="$(psql_q 'SELECT count(*) FROM workflow_entity;' | tr -d '\r')"
if [ -n "$WANT_WF" ] && [ "$GOT_WF" != "$WANT_WF" ]; then
  fail "workflow count mismatch after restore: expected $WANT_WF, got $GOT_WF"
fi
curl -fsS -m 10 -o /dev/null "$(proxy_url)/healthz" || warn "n8n is healthy but not answering through Caddy"
info "workflows: $GOT_WF (expected ${WANT_WF:-?})"
ops_log restore OK "from $(basename "$SRC") ($GOT_WF workflows)"
info "Restore complete."
if ls "$SRC"/env.tar.gz.* >/dev/null 2>&1; then
  echo "Note: .env was NOT changed. The backup holds an encrypted copy if you need it:"
  echo "  age -d -i key.txt $SRC/env.tar.gz.age | tar -tzf -     (or gpg -d ...env.tar.gz.gpg)"
fi
