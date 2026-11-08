#!/usr/bin/env bash
# One-command install for the n8n starter kit.
#
#   git clone https://github.com/TedKelly561/n8n-starter-kit.git && cd n8n-starter-kit && ./setup.sh
#
# Options (all optional; without them setup asks):
#   --domain NAME       public hostname, e.g. n8n.example.com (DNS A record -> this server)
#   --email ADDRESS     Let's Encrypt account / admin email
#   --tz ZONE           timezone, e.g. America/Chicago
#   --local             local test mode: plain HTTP on 127.0.0.1, no certificate
#   --http-port N       host port for HTTP  (default 80)
#   --https-port N      host port for HTTPS (default 443)
#   --monitoring        also run Uptime Kuma at status.<domain> (basic auth + its own login)
#   --no-cron           do not install cron jobs
#   --cron-file PATH    write the cron block to PATH instead of the crontab (testing)
#   --yes, -y           non-interactive: accept defaults, do not ask
#
# Safe to re-run: existing secrets in .env are never overwritten, existing
# workflows are left alone, the cron block is replaced, not duplicated.
set -Eeuo pipefail
cd "$(dirname "$0")"
. ./scripts/lib.sh

DOMAIN_ARG=""; EMAIL_ARG=""; TZ_ARG=""; LOCAL=""; YES=0; NO_CRON=0; CRON_FILE=""
HTTP_PORT_ARG=""; HTTPS_PORT_ARG=""; MONITORING_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN_ARG="${2:?}"; shift 2 ;;
    --email) EMAIL_ARG="${2:?}"; shift 2 ;;
    --tz) TZ_ARG="${2:?}"; shift 2 ;;
    --local) LOCAL=true; shift ;;
    --http-port) HTTP_PORT_ARG="${2:?}"; shift 2 ;;
    --https-port) HTTPS_PORT_ARG="${2:?}"; shift 2 ;;
    --monitoring) MONITORING_ARG=true; shift ;;
    --no-cron) NO_CRON=1; shift ;;
    --cron-file) CRON_FILE="${2:?}"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see ./setup.sh --help)" ;;
  esac
done
INTERACTIVE=0; [ "$YES" = 0 ] && [ -t 0 ] && INTERACTIVE=1

ask() { # ask <prompt> <default> -> answer
  local a
  if [ "$INTERACTIVE" = 1 ]; then
    read -r -p "$1 [${2}]: " a
    printf '%s\n' "${a:-$2}"
  else
    printf '%s\n' "$2"
  fi
}

gen_secret() { # 64 hex chars
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; echo; fi
}

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

printf '%s\n' "${C_BLD}n8n starter kit setup${C_OFF}  (safe to re-run)"

# ================================================================ 1. prerequisites
step "Checking prerequisites"
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install it with: curl -fsSL https://get.docker.com | sh"
docker info >/dev/null 2>&1 || die "Docker is installed but not reachable. Is the daemon running, and is $(id -un) in the docker group (or root)?"
detect_compose || die "Docker Compose v2 is missing. Install the docker-compose-plugin package."
info "docker $(docker version -f '{{.Server.Version}}' 2>/dev/null), $("${COMPOSE_CMD[@]}" version --short 2>/dev/null || echo compose)"
for c in curl gzip sha256sum awk git; do
  command -v "$c" >/dev/null 2>&1 || die "'$c' is required (apt install $c)"
done
command -v flock >/dev/null 2>&1 || warn "flock not found (util-linux): overlapping cron runs will not be prevented"
mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))
if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 1800 ]; then
  warn "only ${mem_mb} MB RAM. 2 GB is recommended; add swap: fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
else
  info "RAM ${mem_mb} MB"
fi
disk_free_gb=$(( $(df -Pk . | awk 'NR==2 {print $4}') / 1024 / 1024 ))
[ "$disk_free_gb" -ge 5 ] || warn "only ${disk_free_gb} GB disk free; backups need room"

# ================================================================ 2. settings
step "Settings"
NEW_ENV=0
if [ ! -f "$ENV_FILE" ]; then
  cp .env.example "$ENV_FILE"
  NEW_ENV=1
fi
chmod 600 "$ENV_FILE"

cur_domain="$(env_get DOMAIN)"; cur_local="$(env_get LOCAL_MODE)"
[ "$cur_domain" = "n8n.example.com" ] && cur_domain=""
[ -z "$LOCAL" ] && [ -z "$DOMAIN_ARG" ] && [ "$cur_local" = "true" ] && LOCAL=true
[ -n "$LOCAL" ] || LOCAL=false

host_tz="$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
cur_tz="$(env_get GENERIC_TIMEZONE)"; [ -n "$cur_tz" ] && [ "$cur_tz" != UTC ] || cur_tz="$host_tz"
cur_email="$(env_get ACME_EMAIL)"

if [ "$LOCAL" = true ]; then
  DOMAIN=localhost
else
  DOMAIN="${DOMAIN_ARG:-$(ask "Domain for n8n (DNS A record must point here)" "${cur_domain:-n8n.example.com}")}"
fi
EMAIL="${EMAIL_ARG:-$(ask "Admin email (Let's Encrypt notices)" "${cur_email:-admin@example.com}")}"
TZONE="${TZ_ARG:-$(ask "Timezone" "$cur_tz")}"

printf '%s' "$DOMAIN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || die "invalid domain: $DOMAIN"
printf '%s' "$EMAIL" | grep -Eq '^[^@ ]+@[^@ ]+\.[^@ ]+$' || die "invalid email: $EMAIL"
if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$TZONE" ]; then die "unknown timezone: $TZONE"; fi
if [ "$LOCAL" = false ]; then
  case "$DOMAIN" in *example.com|localhost) die "set a real domain with --domain, or use --local for a test install" ;; esac
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
    if [ -n "$ip" ]; then info "$DOMAIN resolves to $ip (must be this server's public IP)"
    else warn "$DOMAIN does not resolve yet. Add the DNS A record first, or the certificate cannot be issued."; fi
  fi
fi

HTTP_PORT="${HTTP_PORT_ARG:-$(env_get HTTP_PORT)}"; HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT_ARG:-$(env_get HTTPS_PORT)}"; HTTPS_PORT="${HTTPS_PORT:-443}"
env_set HTTP_PORT "$HTTP_PORT"; env_set HTTPS_PORT "$HTTPS_PORT"
env_set DOMAIN "$DOMAIN"; env_set ACME_EMAIL "$EMAIL"; env_set GENERIC_TIMEZONE "$TZONE"
env_set LOCAL_MODE "$LOCAL"
if [ "$LOCAL" = true ]; then
  port_suffix=""; [ "$HTTP_PORT" = 80 ] || port_suffix=":$HTTP_PORT"
  env_set PUBLIC_URL "http://localhost$port_suffix"
  env_set N8N_PROTOCOL http
  env_set N8N_SECURE_COOKIE false        # plain HTTP: browsers drop secure cookies
  env_set CADDY_SITE_ADDRESS ":80"        # any hostname, plain HTTP, no certificate
  env_set BIND_ADDRESS 127.0.0.1          # not reachable from other machines
else
  port_suffix=""; [ "$HTTPS_PORT" = 443 ] || port_suffix=":$HTTPS_PORT"
  env_set PUBLIC_URL "https://$DOMAIN$port_suffix"
  env_set N8N_PROTOCOL https
  env_set N8N_SECURE_COOKIE true
  env_set CADDY_SITE_ADDRESS "$DOMAIN"
  env_set BIND_ADDRESS 0.0.0.0
fi
[ -n "$MONITORING_ARG" ] && env_set MONITORING_ENABLED true

# Secrets: generate only what is missing. Never overwrite.
KEY_IS_NEW=0
for k in POSTGRES_PASSWORD POSTGRES_READONLY_PASSWORD N8N_ENCRYPTION_KEY; do
  if [ -z "$(env_get "$k")" ]; then
    env_set "$k" "$(gen_secret)"
    [ "$k" = N8N_ENCRYPTION_KEY ] && KEY_IS_NEW=1
    info "generated $k"
  else
    info "kept existing $k"
  fi
done
load_env
info "domain=$DOMAIN local=$LOCAL_MODE tz=$GENERIC_TIMEZONE url=$PUBLIC_URL"

# Optional monitoring site with a hashed basic-auth password.
MON_FILE="$KIT_DIR/caddy/conf.d/monitoring.caddy"
if [ "$MONITORING_ENABLED" = true ]; then
  if [ -z "${KUMA_BASIC_AUTH_PASSWORD:-}" ]; then
    env_set KUMA_BASIC_AUTH_USER admin
    env_set KUMA_BASIC_AUTH_PASSWORD "$(gen_secret | cut -c1-24)"
    load_env
  fi
  hash="$(docker run --rm "caddy:$CADDY_VERSION" caddy hash-password --plaintext "$KUMA_BASIC_AUTH_PASSWORD" | tr -d '\r\n')"
  if [ "$LOCAL_MODE" = true ]; then kuma_addr="http://${MONITORING_SUBDOMAIN}.localhost"; else kuma_addr="${MONITORING_SUBDOMAIN}.${DOMAIN}"; fi
  tpl="$(cat "$KIT_DIR/caddy/optional/monitoring.caddy.template")"
  tpl="${tpl//__KUMA_SITE_ADDRESS__/$kuma_addr}"; tpl="${tpl//__KUMA_USER__/$KUMA_BASIC_AUTH_USER}"; tpl="${tpl//__KUMA_HASH__/$hash}"
  printf '%s\n' "$tpl" > "$MON_FILE"
  info "monitoring: Uptime Kuma at $kuma_addr (basic auth user '$KUMA_BASIC_AUTH_USER', password in .env)"
else
  rm -f "$MON_FILE"
fi

# ================================================================ 3. ports
step "Checking ports"
caddy_running=0
[ -n "$(dc ps -q caddy 2>/dev/null)" ] && caddy_running=1
ports="$HTTP_PORT"; [ "$LOCAL_MODE" = true ] || ports="$HTTP_PORT $HTTPS_PORT"
for p in $ports; do
  if [ "$caddy_running" = 1 ]; then info "port $p: held by this kit's Caddy (re-run)"; continue; fi
  if port_in_use "$p"; then die "port $p is already in use. Stop the other web server (nginx/apache?) or pick --http-port/--https-port."; fi
  info "port $p free"
done

# ================================================================ 4. start
step "Starting the stack (first start pulls images, give it a few minutes)"
dc config -q
dc up -d --pull missing --remove-orphans
mapfile -t SERVICES < <(expected_services)
info "waiting for: ${SERVICES[*]}"
wait_healthy 420 "${SERVICES[@]}" || die "services did not become healthy. Look at: docker compose logs --tail 100"
info "all services healthy"
for _ in $(seq 1 30); do
  curl -fsS -m 5 -o /dev/null "$(proxy_url)/healthz" 2>/dev/null && break
  sleep 2
done
if curl -fsS -m 10 -o /dev/null "$(proxy_url)/healthz"; then info "n8n answers through Caddy at $(proxy_url)/healthz"
else warn "n8n is healthy but not answering through Caddy at $(proxy_url) yet (certificate still being issued? DNS?)"; fi

# ================================================================ 5. safety workflows
step "Safety workflows"
ensure_readonly_role
"$KIT_DIR/scripts/import-workflows.sh"

# ================================================================ 6. cron
step "Scheduled jobs"
if [ "$NO_CRON" = 1 ]; then
  warn "skipped (--no-cron). Install later with: ./scripts/install-cron.sh"
elif [ -n "$CRON_FILE" ]; then
  "$KIT_DIR/scripts/install-cron.sh" --file "$CRON_FILE"
else
  "$KIT_DIR/scripts/install-cron.sh" || warn "cron jobs not installed; see message above"
fi

# ================================================================ 7. first rollback copy + backup
step "First workflow export and backup"
"$KIT_DIR/scripts/export-workflows.sh" -m "Initial export by setup.sh" || warn "workflow export failed"
if [ -z "$(latest_backup)" ]; then
  "$KIT_DIR/scripts/backup.sh" >/dev/null && info "first backup: $(latest_backup)" || warn "first backup failed; run ./scripts/backup.sh and read the error"
else
  info "existing backup found: $(latest_backup)"
fi

if [ "$NEW_ENV" = 1 ] || [ "$KEY_IS_NEW" = 1 ]; then ops_log install OK "n8n $N8N_VERSION installed (local=$LOCAL_MODE)"
else ops_log setup INFO "setup.sh re-run (n8n $N8N_VERSION)"; fi

# ================================================================ 8. next steps
if [ "$KEY_IS_NEW" = 1 ]; then
  printf '\n%s' "$C_RED$C_BLD"
  cat <<'EOF'
 ##########################################################################
 #  SAVE YOUR N8N_ENCRYPTION_KEY IN A PASSWORD MANAGER NOW.               #
 #                                                                        #
 #  It encrypts every credential n8n stores. Without it, credential       #
 #  backups are useless and every API key must be re-entered by hand.     #
 #  See it with:   grep N8N_ENCRYPTION_KEY .env                           #
 ##########################################################################
EOF
  printf '%s' "$C_OFF"
fi
[ -n "${ALERT_WEBHOOK_URL:-}" ] || warn "ALERT_WEBHOOK_URL is empty: nobody gets alerts yet. Set it in .env, then: docker compose up -d"
[ -n "${BACKUP_AGE_RECIPIENT:-}${BACKUP_GPG_PASSPHRASE:-}" ] || warn "No backup encryption set: .env is not included in backups (set BACKUP_AGE_RECIPIENT)."
cat <<EOF

${C_BLD}Done.${C_OFF} n8n $N8N_VERSION is running at ${PUBLIC_URL}

Next steps:
  1. Open ${PUBLIC_URL} NOW and create the owner account. Until you do,
     the first visitor can claim it.
  2. Put a Slack/Discord webhook in .env as ALERT_WEBHOOK_URL, then run
     "docker compose up -d". Open the Error Alert workflow and test it.
  3. Set HEARTBEAT_URL / HEALTH_HEARTBEAT_URL (healthchecks.io) so silence is noticed.
  4. Set BACKUP_AGE_RECIPIENT and, optionally, RCLONE_REMOTE for off-site copies.
  5. In each workflow: Settings > Error workflow = "Error Alert".
  6. New workflows start in shadow mode (SHADOW_MODE=true). Read the README.

Day-2: ./scripts/backup.sh | restore.sh | restore-drill.sh | update.sh <tag> | healthcheck.sh
EOF
