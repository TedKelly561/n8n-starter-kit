#!/usr/bin/env bash
# Nightly backup: Postgres dump, n8n workflow + credential export (encrypted),
# optional encrypted copy of .env, retention, optional off-site copy, heartbeat.
#
# Usage: scripts/backup.sh [--tag NAME] [--no-retention] [--no-offsite]
#
# A backup is only "good" once its .complete marker exists. Retention never
# removes the newest good backup, and only runs after this backup succeeded.
set -Eeuo pipefail
. "$(dirname "$0")/lib.sh"

TAG=""; DO_RETENTION=1; DO_OFFSITE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --no-retention) DO_RETENTION=0; shift ;;
    --no-offsite) DO_OFFSITE=0; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

load_env
with_lock backup

NAME="$(date +%Y-%m-%d_%H%M%S)${TAG:+-$TAG}"
DEST="$BACKUP_DIR/$NAME"
FAILED_STEP=""

on_error() {
  local rc=$?
  err "backup failed at step: ${FAILED_STEP:-unknown} (exit $rc)"
  [ -d "$DEST" ] && printf 'failed at: %s\n' "$FAILED_STEP" > "$DEST/.failed" || true
  send_alert "Backup FAILED" "Step: ${FAILED_STEP:-unknown}. Folder: $DEST. The previous good backup was kept: $(latest_backup || true). Check $LOG_DIR/backup.log." || true
  ping_heartbeat "${HEARTBEAT_URL:-}" fail
  exit "$rc"
}
trap on_error ERR

mkdir -p "$DEST"
chmod 700 "$BACKUP_DIR" "$DEST"
info "Backup to $DEST"

# ---------------------------------------------------------------- 1. database
FAILED_STEP="pg_dump"
[ "$(service_health postgres)" = "healthy" ] || { err "postgres is not healthy"; false; }
dc exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges \
  | gzip -6 > "$DEST/db.sql.gz"
gzip -t "$DEST/db.sql.gz"
# Row counts taken from the dump itself, so the restore drill can compare exactly.
gzip -dc "$DEST/db.sql.gz" | awk '
  /^COPY / { t=$2; n=0; inside=1; next }
  inside && /^\\\.$/ { print t, n; inside=0; next }
  inside { n++ }' | sort > "$DEST/rowcounts.txt"
grep -q 'workflow_entity' "$DEST/rowcounts.txt" || { err "dump has no workflow_entity table"; false; }
info "  database dump: $(du -h "$DEST/db.sql.gz" | cut -f1)"

# ---------------------------------------------------------------- 2. n8n export
FAILED_STEP="n8n export"
[ "$(service_health n8n)" = "healthy" ] || { err "n8n is not healthy"; false; }
# Export inside the container, stream out as tar. Credentials stay ENCRYPTED
# (never --decrypted): they can only be read with the same N8N_ENCRYPTION_KEY.
dc exec -T n8n sh -ec '
  out=/tmp/kit-backup-export
  rm -rf "$out"; mkdir -p "$out/workflows"
  n8n export:workflow --all --separate --output="$out/workflows/" > "$out/workflows.log" 2>&1 \
    || grep -qi "no workflows found" "$out/workflows.log"
  n8n export:credentials --all --output="$out/credentials.json" > "$out/credentials.log" 2>&1 \
    || grep -qi "no credentials found" "$out/credentials.log"
  rm -f "$out"/*.log
  tar -C "$out" -cf - .
  rm -rf "$out"
' | tar -C "$DEST" --no-same-owner --no-same-permissions -xf -
WF_COUNT="$(find "$DEST/workflows" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
CRED_COUNT=0
if [ -f "$DEST/credentials.json" ]; then
  CRED_COUNT="$( { grep -o '"data":"' "$DEST/credentials.json" || true; } | wc -l | tr -d ' ')"
  # Refuse to keep a plaintext credential export by accident.
  if grep -q '"data":{' "$DEST/credentials.json"; then err "credential export is not encrypted"; false; fi
  chmod 600 "$DEST/credentials.json"
fi
info "  workflows exported: $WF_COUNT, credentials exported (encrypted): $CRED_COUNT"

# ---------------------------------------------------------------- 3. .env (encrypted only)
FAILED_STEP="env archive"
ENV_NOTE="skipped (no BACKUP_AGE_RECIPIENT or BACKUP_GPG_PASSPHRASE set)"
CONF_FILES=(.env)
[ -n "$(ls -A "$KIT_DIR/caddy/conf.d"/*.caddy 2>/dev/null || true)" ] && CONF_FILES+=(caddy/conf.d)
if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
  command -v age >/dev/null 2>&1 || { err "BACKUP_AGE_RECIPIENT is set but 'age' is not installed (apt install age)"; false; }
  tar -C "$KIT_DIR" -czf - "${CONF_FILES[@]}" | age -r "$BACKUP_AGE_RECIPIENT" -o "$DEST/env.tar.gz.age"
  ENV_NOTE="env.tar.gz.age (age)"
elif [ -n "${BACKUP_GPG_PASSPHRASE:-}" ]; then
  command -v gpg >/dev/null 2>&1 || { err "BACKUP_GPG_PASSPHRASE is set but gpg is not installed"; false; }
  tar -C "$KIT_DIR" -czf - "${CONF_FILES[@]}" | gpg --batch --yes --quiet --pinentry-mode loopback \
    --passphrase-fd 3 --symmetric --cipher-algo AES256 -o "$DEST/env.tar.gz.gpg" 3<<<"$BACKUP_GPG_PASSPHRASE"
  ENV_NOTE="env.tar.gz.gpg (gpg symmetric)"
else
  warn ".env NOT included in this backup: set BACKUP_AGE_RECIPIENT or BACKUP_GPG_PASSPHRASE."
  warn "Keep N8N_ENCRYPTION_KEY in a password manager; without it credentials cannot be restored."
fi
info "  .env copy: $ENV_NOTE"

# ---------------------------------------------------------------- 4. manifest + checksums
FAILED_STEP="manifest"
KEY_FP="$(printf '%s' "$N8N_ENCRYPTION_KEY" | sha256sum | cut -c1-16)"
{
  echo "created=$(ts)"
  echo "host=$(hostname 2>/dev/null || echo unknown)"
  echo "n8n_version=$(n8n_version_running)"
  echo "n8n_image_tag=$N8N_VERSION"
  echo "postgres_version=$POSTGRES_VERSION"
  echo "workflows=$WF_COUNT"
  echo "credentials=$CRED_COUNT"
  echo "encryption_key_fingerprint=$KEY_FP"
  echo "env_copy=$ENV_NOTE"
} > "$DEST/manifest.txt"
chmod -R go-rwx "$DEST"
( cd "$DEST" && find . -type f ! -name SHA256SUMS ! -name '.complete' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
touch "$DEST/.complete"
printf '%s\n' "$DEST" > "$STATE_DIR/last-backup"
info "Backup complete: $DEST ($(du -sh "$DEST" | cut -f1))"

# ---------------------------------------------------------------- 5. retention
if [ "$DO_RETENTION" = 1 ]; then
  FAILED_STEP="retention"
  KEEP_DAILY="${BACKUP_KEEP_DAILY:-14}"; KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-8}"
  declare -A seen_day=() seen_week=()
  nd=0; nw=0; newest=1
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    name="$(basename "$d")"
    if [ ! -f "$d/.complete" ]; then
      # Failed/partial backups: remove after a day, they are not restorable.
      if [ -n "$(find "$d" -maxdepth 0 -mmin +1440 2>/dev/null)" ]; then rm -rf -- "$d"; info "  removed partial $name"; fi
      continue
    fi
    day="${name:0:10}"
    week="$(date -d "$day" +%G-W%V 2>/dev/null || echo "$day")"
    keep=0
    if [ "$newest" = 1 ]; then keep=1; newest=0; fi   # never delete the last good backup
    if [ -z "${seen_day[$day]:-}" ] && [ "$nd" -lt "$KEEP_DAILY" ]; then seen_day[$day]=1; nd=$((nd+1)); keep=1; fi
    if [ -z "${seen_week[$week]:-}" ] && [ "$nw" -lt "$KEEP_WEEKLY" ]; then seen_week[$week]=1; nw=$((nw+1)); keep=1; fi
    # Tagged safety backups (pre-update, pre-restore) are kept for at least 7 days.
    case "$name" in *-pre-*) [ -z "$(find "$d/.complete" -mmin +10080 2>/dev/null)" ] && keep=1 ;; esac
    if [ "$keep" = 0 ]; then rm -rf -- "$d"; info "  retention: removed $name"; fi
  done < <(ls -1d "$BACKUP_DIR"/20* 2>/dev/null | sort -r)
fi

# ---------------------------------------------------------------- 6. off-site
if [ "$DO_OFFSITE" = 1 ] && [ -n "${RCLONE_REMOTE:-}" ]; then
  FAILED_STEP="rclone off-site copy"
  command -v rclone >/dev/null 2>&1 || { err "RCLONE_REMOTE is set but rclone is not installed"; false; }
  rclone copy --transfers 2 "$DEST" "${RCLONE_REMOTE%/}/$NAME"
  info "  off-site copy: ${RCLONE_REMOTE%/}/$NAME"
fi

trap - ERR
ping_heartbeat "${HEARTBEAT_URL:-}"
echo "$DEST"
