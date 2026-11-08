#!/usr/bin/env bash
# Import the bundled safety workflows (workflows/*.json) and the read-only
# Postgres credential used by the Daily Health Digest.
#
# Usage: scripts/import-workflows.sh [--force]
#
# Idempotent: a bundled workflow that already exists (same id) is left alone,
# so your edits survive a re-run. --force re-imports and overwrites them.
set -Eeuo pipefail
. "$(dirname "$0")/lib.sh"
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
load_env
[ "$(service_health n8n)" = healthy ] || die "n8n is not healthy"

exists() { [ "$(psql_q "SELECT count(*) FROM $1 WHERE id = '$2';" | tr -d '\r')" != 0 ]; }

# ---------------------------------------------------------------- credential
CRED_ID="KitPgReadonly001"
if exists credentials_entity "$CRED_ID" && [ "$FORCE" = 0 ]; then
  info "credential 'Kit Postgres (read-only)' already exists"
else
  # Plain values go in through stdin and are encrypted by n8n on import;
  # the temporary file inside the container is removed straight away.
  printf '[{"id":"%s","name":"Kit Postgres (read-only)","type":"postgres","data":{"host":"postgres","port":5432,"database":"%s","user":"%s","password":"%s","ssl":"disable","allowUnauthorizedCerts":false}}]' \
    "$CRED_ID" "$POSTGRES_DB" "${POSTGRES_READONLY_USER:-n8n_readonly}" "$POSTGRES_READONLY_PASSWORD" \
    | dc exec -T n8n sh -c 'umask 077; cat > /tmp/kit-cred.json && n8n import:credentials --input=/tmp/kit-cred.json; rc=$?; rm -f /tmp/kit-cred.json; exit $rc' >/dev/null
  info "imported credential 'Kit Postgres (read-only)'"
fi

# ---------------------------------------------------------------- workflows
imported=0
for f in "$KIT_DIR"/workflows/*.json; do
  [ -f "$f" ] || continue
  id="$(grep -m1 '^  "id":' "$f" | sed 's/.*"id": "\([^"]*\)".*/\1/')"
  name="$(grep -m1 '^  "name":' "$f" | sed 's/.*"name": "\([^"]*\)".*/\1/')"
  [ -n "$id" ] || { warn "no id in $f, skipping"; continue; }
  if exists workflow_entity "$id" && [ "$FORCE" = 0 ]; then
    info "workflow '$name' already exists (id $id), left as is"
    continue
  fi
  dc exec -T n8n sh -c 'cat > /tmp/kit-wf.json && n8n import:workflow --input=/tmp/kit-wf.json; rc=$?; rm -f /tmp/kit-wf.json; exit $rc' < "$f" >/dev/null
  info "imported workflow '$name' (id $id)"
  imported=$((imported+1))
done

# Publish the two workflows that must be live from day one. n8n only runs an
# error workflow that is published, and the digest only reads two tables and
# sends one message. The Shadow Mode Example stays unpublished (it is a demo).
PUBLISH_IDS="KitErrorAlert001 KitHealthDigest1"
if [ "$imported" -gt 0 ]; then
  for id in $PUBLISH_IDS; do
    exists workflow_entity "$id" || continue
    dc exec -T n8n n8n publish:workflow --id="$id" >/dev/null 2>&1 \
      && info "published $id" || warn "could not publish $id; publish it in the editor"
  done
  # The CLI writes to the database; n8n picks it up on restart.
  dc restart n8n >/dev/null
  wait_healthy 180 n8n || die "n8n did not come back after import"
fi
info "Bundled workflows: $(psql_q "SELECT string_agg(name, ', ' ORDER BY name) FROM workflow_entity WHERE id LIKE 'Kit%';" | tr -d '\r')"
