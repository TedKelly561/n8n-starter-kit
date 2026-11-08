#!/usr/bin/env bash
# Safe n8n update with automatic rollback.
#
# Usage: scripts/update.sh <new-n8n-tag> [--yes] [--force "reason"] [--health-timeout SECONDS]
#
#   - refuses if another change was already logged today in ops-log.md
#     (one change a day; --force "reason" overrides and records the reason)
#   - pulls the new image first (a tag that does not exist changes nothing)
#   - takes a backup, records the current tag and the database migration count
#   - switches N8N_VERSION in .env, restarts n8n, waits for health, checks the
#     version and the HTTP API through Caddy
#   - if unhealthy: switches back to the previous tag; if the new version ran
#     database migrations (or the old version will not start), restores the
#     pre-update database backup; then verifies health again
#   - appends the outcome to ops-log.md either way, alerts on failure
set -Eeuo pipefail
. "$(dirname "$0")/lib.sh"

NEW=""; YES=0; FORCE_REASON=""; HEALTH_TIMEOUT="${UPDATE_HEALTH_TIMEOUT:-300}"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --force) FORCE_REASON="${2:-}"; [ -n "$FORCE_REASON" ] || die "--force needs a reason, e.g. --force \"security fix\""; shift 2 ;;
    --health-timeout) HEALTH_TIMEOUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) NEW="$1"; shift ;;
  esac
done
[ -n "$NEW" ] || die "usage: scripts/update.sh <new-n8n-tag>   (current: $(env_get N8N_VERSION))"
printf '%s' "$NEW" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || die "invalid tag: $NEW"
load_env
with_lock update

OLD="$N8N_VERSION"
CHANGE="n8n $OLD -> $NEW"
NOTE=""; [ -n "$FORCE_REASON" ] && NOTE=" (forced: $FORCE_REASON)"
step "Update $CHANGE"

# ---------------------------------------------------------------- one change a day
TODAY="$(changes_today)"
if [ -n "$TODAY" ]; then
  if [ -z "$FORCE_REASON" ]; then
    ops_log update REFUSED "$CHANGE: another change already made today"
    err "One change a day: ops-log.md already has a change today:"
    printf '  %s\n' "$TODAY" >&2
    die "Wait until tomorrow, or re-run with --force \"reason\"."
  fi
  warn "Overriding one-change-a-day: $FORCE_REASON"
fi

# ---------------------------------------------------------------- pull first
info "pulling n8nio/n8n:$NEW"
if ! docker pull -q "n8nio/n8n:$NEW" >/dev/null 2>&1; then
  if docker image inspect "n8nio/n8n:$NEW" >/dev/null 2>&1; then
    warn "pull failed, using the image already on this server"
  else
    ops_log update ABORTED "$CHANGE: image tag could not be pulled, nothing changed$NOTE"
    die "could not pull n8nio/n8n:$NEW (typo, or no network). Nothing was changed."
  fi
fi

if [ "$YES" != 1 ]; then
  printf 'Update %s now? A backup is taken first. [y/N] ' "$CHANGE"
  read -r a; case "$a" in y|Y|yes) ;; *) ops_log update ABORTED "$CHANGE: cancelled by operator"; die "cancelled" ;; esac
fi

# ---------------------------------------------------------------- backup + record
step "Pre-update backup"
wait_healthy 60 postgres n8n || { ops_log update ABORTED "$CHANGE: stack unhealthy before update"; die "stack is not healthy now; fix that before updating"; }
"$KIT_DIR/scripts/backup.sh" --tag "pre-update-$NEW" --no-retention --no-offsite >/dev/null \
  || { ops_log update ABORTED "$CHANGE: pre-update backup failed"; die "backup failed; not updating"; }
BK="$(cat "$STATE_DIR/last-backup")"
M0="$(psql_q 'SELECT count(*) FROM migrations;' | tr -d '\r')"
printf '%s\n' "$OLD" > "$STATE_DIR/previous-n8n-version"
info "backup: $BK; previous tag $OLD recorded; migrations: $M0"

check_ok() {
  # Healthy container, expected version, API answering through Caddy.
  local want="$1" v code
  wait_healthy "$HEALTH_TIMEOUT" n8n || return 1
  v="$(n8n_version_running)"
  if printf '%s' "$want" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' && [ "$v" != "$want" ]; then
    err "running version is '$v', expected $want"; return 1
  fi
  curl -fsS -m 10 -o /dev/null "$(proxy_url)/healthz/readiness" || { err "health endpoint not reachable via Caddy"; return 1; }
  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$(proxy_url)/rest/settings" || true)"
  [ "$code" = 200 ] || { err "API /rest/settings answered HTTP $code"; return 1; }
  info "n8n $v healthy, API OK"
}

# ---------------------------------------------------------------- switch
step "Switching to $NEW"
env_set N8N_VERSION "$NEW"; export N8N_VERSION="$NEW"
if dc up -d n8n >/dev/null 2>&1 && check_ok "$NEW"; then
  ops_log update OK "$CHANGE, backup $(basename "$BK")$NOTE"
  info "Update complete: $CHANGE"
  echo "Watch the next few executions. To go back: scripts/update.sh $OLD --force \"rollback\""
  exit 0
fi

# ---------------------------------------------------------------- rollback
step "New version unhealthy: rolling back to $OLD"
FAIL_LOG="$LOG_DIR/update-failed-$(date +%Y%m%d-%H%M%S).log"
dc logs --no-color --tail 200 n8n > "$FAIL_LOG" 2>&1 || true
warn "last n8n logs saved to $FAIL_LOG"
env_set N8N_VERSION "$OLD"; export N8N_VERSION="$OLD"
M1="$(psql_q 'SELECT count(*) FROM migrations;' 2>/dev/null | tr -d '\r' || echo unknown)"
DB_RESTORED=no

restore_db() {
  warn "restoring the pre-update database backup $(basename "$BK")"
  dc stop n8n >/dev/null 2>&1 || true
  "$KIT_DIR/scripts/restore.sh" "$BK" --yes --skip-safety-backup && DB_RESTORED=yes
}

if [ "$M1" != "$M0" ]; then
  warn "database migrations changed ($M0 -> $M1): the database must go back too"
  restore_db || true
else
  dc up -d n8n >/dev/null 2>&1 || true
fi
ROLLBACK_OK=0
if check_ok "$OLD"; then
  ROLLBACK_OK=1
elif [ "$DB_RESTORED" = no ]; then
  warn "old version will not start on the current database"
  restore_db || true
  check_ok "$OLD" && ROLLBACK_OK=1
fi

if [ "$ROLLBACK_OK" = 1 ]; then
  ops_log update ROLLED-BACK "$CHANGE failed; back on $OLD (database restored: $DB_RESTORED), logs $(basename "$FAIL_LOG")$NOTE"
  send_alert "n8n update rolled back" "Update $CHANGE was unhealthy. Automatically rolled back to $OLD (database restored: $DB_RESTORED). Logs: $FAIL_LOG" || true
  err "Update failed and was rolled back to $OLD. See $FAIL_LOG"
  exit 1
fi
ops_log update FAILED "$CHANGE failed AND rollback to $OLD is unhealthy. Needs a person now.$NOTE"
send_alert "URGENT: n8n update and rollback FAILED" "Update $CHANGE failed and rollback to $OLD is not healthy. Pre-update backup: $BK. See docs/RUNBOOK.md." || true
die "Rollback is not healthy. Follow docs/RUNBOOK.md (restore from $BK)."
