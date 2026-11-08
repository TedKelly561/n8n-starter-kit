#!/usr/bin/env bash
# Health check, run by cron every 5 minutes.
#
# Usage: scripts/healthcheck.sh [--quiet]
#
# Checks: every container healthy, n8n answering through Caddy, disk space,
# age of the newest good backup, TLS certificate expiry (skipped in local mode).
# One alert per problem: an alert is sent when a problem first appears (and again
# every ALERT_REPEAT_HOURS while it lasts), and a RESOLVED message when it clears.
# Pings HEALTH_HEARTBEAT_URL when everything is fine, <url>/fail otherwise.
set -Eeuo pipefail
. "$(dirname "$0")/lib.sh"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
load_env
with_lock healthcheck

ALERT_STATE="$STATE_DIR/alerts"
mkdir -p "$ALERT_STATE"
declare -A PROBLEMS=()
problem() { PROBLEMS["$1"]="$2"; }
ok() { [ "$QUIET" = 1 ] || info "ok: $*"; }

# ---------------------------------------------------------------- containers
while read -r svc; do
  st="$(service_health "$svc")"
  if [ "$st" = healthy ]; then ok "$svc healthy"
  else problem "container-$svc" "Container $svc is $st"; fi
done < <(expected_services)

# ---------------------------------------------------------------- through Caddy
URL="$(proxy_url)/healthz/readiness"
if curl -fsS -m 10 -o /dev/null "$URL" 2>/dev/null; then ok "n8n answers via Caddy ($URL)"
else problem proxy "n8n does not answer through Caddy at $URL"; fi

# ---------------------------------------------------------------- disk
LIMIT="${DISK_WARN_PERCENT:-85}"
DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
[ -d "$DOCKER_ROOT" ] || DOCKER_ROOT=/
seen_fs=""
for p in "$KIT_DIR" "$BACKUP_DIR" "$DOCKER_ROOT"; do
  line="$(df -P "$p" 2>/dev/null | awk 'NR==2')" || continue
  fs="$(echo "$line" | awk '{print $6}')"
  case " $seen_fs " in *" $fs "*) continue ;; esac
  seen_fs="$seen_fs $fs"
  pct="$(echo "$line" | awk '{gsub("%","",$5); print $5}')"
  key="disk-$(echo "$fs" | tr '/' '_')"
  if [ "$pct" -ge "$LIMIT" ]; then problem "$key" "Disk $fs is ${pct}% full (limit ${LIMIT}%)"
  else ok "disk $fs ${pct}%"; fi
done

# ---------------------------------------------------------------- backup age
MAX_H="${BACKUP_MAX_AGE_HOURS:-26}"
LB="$(latest_backup)"
if [ -z "$LB" ]; then
  problem backup-age "No complete backup found in $BACKUP_DIR"
else
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$LB/.complete") ) / 3600 ))
  if [ "$age_h" -ge "$MAX_H" ]; then problem backup-age "Newest good backup is ${age_h}h old ($(basename "$LB")), limit ${MAX_H}h"
  else ok "newest backup ${age_h}h old"; fi
fi

# ---------------------------------------------------------------- certificate
if [ "${LOCAL_MODE:-false}" != "true" ]; then
  if command -v openssl >/dev/null 2>&1; then
    end="$(echo | timeout 15 openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    if [ -z "$end" ]; then
      problem cert "Could not read the TLS certificate for $DOMAIN"
    else
      days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      if [ "$days" -lt "${CERT_WARN_DAYS:-14}" ]; then problem cert "TLS certificate for $DOMAIN expires in $days days ($end)"
      else ok "certificate valid for $days days"; fi
    fi
  fi
fi

# ---------------------------------------------------------------- alerting (deduplicated)
now="$(date +%s)"
repeat_s=$(( ${ALERT_REPEAT_HOURS:-24} * 3600 ))
for key in "${!PROBLEMS[@]}"; do
  msg="${PROBLEMS[$key]}"
  err "$msg"
  f="$ALERT_STATE/$key"
  if [ ! -f "$f" ]; then
    send_alert "PROBLEM: $msg" "First seen $(ts). What to do: docs/RUNBOOK.md" || true
    printf '%s\n%s\n%s\n' "$now" "$now" "$msg" > "$f"
  else
    last="$(sed -n 2p "$f")"
    if [ "$repeat_s" -gt 0 ] && [ $(( now - last )) -ge "$repeat_s" ]; then
      send_alert "STILL BROKEN: $msg" "First seen $(date -u -d "@$(sed -n 1p "$f")" +%Y-%m-%dT%H:%M:%SZ). See docs/RUNBOOK.md" || true
      printf '%s\n%s\n%s\n' "$(sed -n 1p "$f")" "$now" "$msg" > "$f"
    fi
  fi
done
for f in "$ALERT_STATE"/*; do
  [ -f "$f" ] || continue
  key="$(basename "$f")"
  if [ -z "${PROBLEMS[$key]:-}" ]; then
    send_alert "RESOLVED: $(sed -n 3p "$f" 2>/dev/null || echo "$key")" "Back to normal at $(ts) (first seen $(date -u -d "@$(sed -n 1p "$f")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?'))." || true
    rm -f "$f"
  fi
done

if [ "${#PROBLEMS[@]}" -eq 0 ]; then
  ping_heartbeat "${HEALTH_HEARTBEAT_URL:-}"
  [ "$QUIET" = 1 ] || info "All checks passed."
  exit 0
fi
ping_heartbeat "${HEALTH_HEARTBEAT_URL:-}" fail
exit 1
