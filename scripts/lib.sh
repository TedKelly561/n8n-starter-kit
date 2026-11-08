#!/usr/bin/env bash
# Shared helpers for the n8n starter kit scripts. Source it, do not run it.
# shellcheck disable=SC2034

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$KIT_DIR/.env}"
OPS_LOG="${OPS_LOG:-$KIT_DIR/ops-log.md}"

# ---------------------------------------------------------------- output
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_OFF=''
fi

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
info() { printf '%s[%s] %s%s\n' "$C_GRN" "$(date +%H:%M:%S)" "$*" "$C_OFF"; }
warn() { printf '%s[%s] WARNING: %s%s\n' "$C_YEL" "$(date +%H:%M:%S)" "$*" "$C_OFF" >&2; }
err()  { printf '%s[%s] ERROR: %s%s\n' "$C_RED" "$(date +%H:%M:%S)" "$*" "$C_OFF" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_OFF"; }

# ---------------------------------------------------------------- env
load_env() {
  [ -f "$ENV_FILE" ] || die ".env not found at $ENV_FILE. Run ./setup.sh first."
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  # Resolve data paths relative to the kit folder.
  BACKUP_DIR="$(abs_path "${BACKUP_DIR:-./data/backups}")"
  HISTORY_DIR="$(abs_path "${HISTORY_DIR:-./data/history}")"
  STATE_DIR="$KIT_DIR/data/state"
  LOG_DIR="$KIT_DIR/data/logs"
  mkdir -p "$BACKUP_DIR" "$STATE_DIR" "$LOG_DIR"
}

abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$KIT_DIR" "${1#./}" ;;
  esac
}

# Set or replace KEY=VALUE in .env without touching other lines.
env_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {print k "=" v; next} {print}' "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-; }

# ---------------------------------------------------------------- docker compose
detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    return 1
  fi
}

dc() {
  [ -n "${COMPOSE_CMD+x}" ] || detect_compose || die "docker compose not found"
  local profile=()
  if [ "${MONITORING_ENABLED:-false}" = "true" ]; then profile=(--profile monitoring); fi
  "${COMPOSE_CMD[@]}" --project-directory "$KIT_DIR" -f "$KIT_DIR/docker-compose.yml" \
    --env-file "$ENV_FILE" "${profile[@]}" "$@"
}

expected_services() {
  printf '%s\n' postgres n8n caddy
  if [ "${MONITORING_ENABLED:-false}" = "true" ]; then printf '%s\n' uptime-kuma; fi
}

# Prints: healthy | unhealthy | starting | missing | exited | <state>
service_health() {
  local cid
  cid="$(dc ps -a -q "$1" 2>/dev/null | head -n1)"
  [ -n "$cid" ] || { echo missing; return; }
  docker inspect -f '{{if ne .State.Status "running"}}{{.State.Status}}{{else if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$cid" 2>/dev/null || echo missing
}

# wait_healthy <timeout-seconds> <service>...
wait_healthy() {
  local timeout="$1"; shift
  local deadline=$(( $(date +%s) + timeout )) svc st all
  while :; do
    all=1
    for svc in "$@"; do
      st="$(service_health "$svc")"
      [ "$st" = "healthy" ] || all=0
    done
    [ "$all" = 1 ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && {
      for svc in "$@"; do err "$svc: $(service_health "$svc")"; done
      return 1
    }
    sleep 3
  done
}

psql_q() {
  dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "$1"
}

n8n_version_running() {
  dc exec -T n8n n8n --version 2>/dev/null | tr -d '\r' | tail -n1
}

# Local URL Caddy answers on (used for health checks through the proxy).
proxy_url() {
  if [ "${LOCAL_MODE:-false}" = "true" ]; then
    printf 'http://127.0.0.1:%s\n' "${HTTP_PORT:-80}"
  else
    printf '%s\n' "${PUBLIC_URL}"
  fi
}

# ---------------------------------------------------------------- alerts
json_escape() {
  # Escapes a string for use inside JSON double quotes.
  printf '%s' "$1" | awk 'BEGIN{ORS=""} {
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"");
    if (NR>1) printf "\\n"; print }'
}

# send_alert <subject> <body>. Tries every configured channel; returns 1 if none worked.
send_alert() {
  local subject="$1" body="$2" host sent=0 text payload
  host="$(hostname 2>/dev/null || echo server)"
  text="[n8n ${DOMAIN:-kit} @ $host] $subject"$'\n'"$body"
  mkdir -p "${LOG_DIR:-$KIT_DIR/data/logs}"
  printf '%s %s | %s\n' "$(ts)" "$subject" "$(printf '%s' "$body" | tr '\n' ' ')" >> "${LOG_DIR:-$KIT_DIR/data/logs}/alerts.log"

  if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
    payload="{\"text\":\"$(json_escape "$text")\",\"content\":\"$(json_escape "$text")\"}"
    if curl -fsS -m 15 --retry 2 -H 'Content-Type: application/json' -d "$payload" "$ALERT_WEBHOOK_URL" >/dev/null; then
      sent=1
    else
      warn "alert webhook failed"
    fi
  fi
  if [ -n "${ALERT_EMAIL:-}" ]; then
    local mail_cmd=""
    if command -v msmtp >/dev/null 2>&1; then mail_cmd="msmtp"
    elif command -v sendmail >/dev/null 2>&1; then mail_cmd="sendmail"
    elif [ -x /usr/sbin/sendmail ]; then mail_cmd="/usr/sbin/sendmail"; fi
    if [ -n "$mail_cmd" ]; then
      if printf 'To: %s\nSubject: [n8n] %s\n\n%s\n' "$ALERT_EMAIL" "$subject" "$text" | "$mail_cmd" "$ALERT_EMAIL"; then
        sent=1
      else
        warn "alert email via $mail_cmd failed"
      fi
    else
      warn "ALERT_EMAIL is set but neither msmtp nor sendmail is installed"
    fi
  fi
  if [ "$sent" = 0 ]; then
    # Last resort: stderr, which cron mails to the server owner if MAILTO is set.
    printf 'ALERT (no channel delivered): %s\n' "$text" >&2
    return 1
  fi
  return 0
}

# ping_heartbeat <url> [fail]
ping_heartbeat() {
  local url="$1" suffix=""
  [ -n "$url" ] || return 0
  [ "${2:-}" = "fail" ] && suffix="/fail"
  curl -fsS -m 10 --retry 3 -o /dev/null "${url%/}${suffix}" || warn "heartbeat ping failed: ${url%/}${suffix}"
}

# ---------------------------------------------------------------- ops log (one change a day)
ops_log() {
  # ops_log <kind> <result> <description>
  if [ ! -f "$OPS_LOG" ]; then
    printf '# Ops log\n\nOne line per change. update.sh refuses a second change on the same day.\n\n' > "$OPS_LOG"
  fi
  printf -- '- %s | %s | %s | %s | %s\n' "$(date +%Y-%m-%d)" "$(date +%H:%M:%S%z)" "$1" "$2" "$3" >> "$OPS_LOG"
}

# Lines for today that count as a change: kinds install/update/restore/change,
# except attempts that were refused or aborted before anything changed.
changes_today() {
  [ -f "$OPS_LOG" ] || return 0
  awk -F' [|] ' -v d="- $(date +%Y-%m-%d)" '$1==d && $3 ~ /^(install|update|restore|change)$/ && $4 !~ /^(REFUSED|ABORTED)$/' "$OPS_LOG"
}

# ---------------------------------------------------------------- locking
with_lock() {
  # with_lock <name>: exits if another copy holds the lock.
  local f="${STATE_DIR:-$KIT_DIR/data/state}/$1.lock"
  mkdir -p "$(dirname "$f")"
  exec 9>"$f"
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || die "another $1 run is in progress"
  fi
}

# Latest complete backup directory (has a .complete marker), or empty.
latest_backup() {
  local d
  for d in $(ls -1d "$BACKUP_DIR"/20* 2>/dev/null | sort -r); do
    [ -f "$d/.complete" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 0
}

# Read-only role for the Daily Health Digest workflow (SELECT on two tables only).
# Safe to run repeatedly; must run after n8n has created its tables, and again after a restore.
ensure_readonly_role() {
  local ru="${POSTGRES_READONLY_USER:-n8n_readonly}" rp="${POSTGRES_READONLY_PASSWORD:-}"
  [ -n "$rp" ] || { warn "POSTGRES_READONLY_PASSWORD empty; skipping read-only role"; return 0; }
  dc exec -T postgres psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null <<SQL
DO \$\$BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$ru') THEN
    CREATE ROLE "$ru" LOGIN PASSWORD '$rp';
  ELSE
    ALTER ROLE "$ru" LOGIN PASSWORD '$rp';
  END IF;
END\$\$;
GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO "$ru";
GRANT USAGE ON SCHEMA public TO "$ru";
GRANT SELECT ON public.execution_entity, public.workflow_entity TO "$ru";
SQL
}
