# What was tested

**Date:** 2026-11-08
**Where:** a Linux container (16 GB RAM) with Docker Engine 29.9.2 and Docker Compose v5.6.1,
local mode (`./setup.sh --local --yes`, plain HTTP on 127.0.0.1:80).
**Images:** `n8nio/n8n:2.46.6` (also `2.46.5` and `2.47.2` for update tests),
`postgres:16.15-alpine`, `caddy:2.11.9-alpine`, `louislam/uptime-kuma:2.5.9-slim`.

Alerts and heartbeats went to a small local webhook catcher container on the kit's
`web` network, used as `ALERT_WEBHOOK_URL`, `HEARTBEAT_URL` and `HEALTH_HEARTBEAT_URL`.

## Static checks

| Check | Result |
|---|---|
| `bash -n` on `setup.sh` and every `scripts/*.sh` | pass |
| `shellcheck -x -S warning` on all scripts (v0.11) | pass, no findings |
| `set -euo pipefail` (or `-Eeuo`) in every executable script | pass (`lib.sh` is sourced only) |
| `docker compose config -q`, default and `--profile monitoring` | pass |
| `docker compose config` with an un-generated `.env` refuses to run (no default passwords) | pass |
| `caddy adapt` with a production `CADDY_SITE_ADDRESS` (n8n.example.com) | pass |
| Workflow JSON parsed by `node` (plus every connection points at an existing node) and `python3 -m json.tool` | pass, 3/3 |

## Live tests

| # | Test | Command | Result |
|---|---|---|---|
| 1 | Install from scratch | `./setup.sh --local --yes --monitoring` | pass: secrets generated, `.env` mode 600, all 4 services healthy, n8n answers via Caddy, workflows imported, cron block written, first export + backup |
| 2 | Re-run is idempotent | `./setup.sh --local --yes` again | pass: secrets unchanged (hash compared), workflows "left as is", cron block appears exactly once |
| 3 | Pristine install with a pre-made `.env` (no secrets) at n8n 2.46.5 | `docker compose down -v`, `./setup.sh --local --yes --no-cron` | pass |
| 4 | Health via Caddy | `curl http://127.0.0.1/healthz` | pass (200); `/metrics` returns 404 publicly; security headers present (HSTS, nosniff, X-Frame-Options, Referrer-Policy, Permissions-Policy, COOP) |
| 5 | Postgres not exposed | `docker compose ps` | pass: only Caddy publishes ports (bound to 127.0.0.1 in local mode) |
| 6 | Uptime Kuma behind basic auth | `curl -H 'Host: status.localhost' http://127.0.0.1/` | pass: 401 without, 302 (Kuma login) with the generated credentials |
| 7 | Error Alert workflow | a test workflow with Error workflow = Error Alert, made to fail | pass: one message with workflow name, node, error text, execution link |
| 8 | Shadow Mode Example | `POST /webhook/shadow-example` | pass: responds `{"mode":"shadow",...}` and appends a line to `/home/node/.n8n-files/shadow-log.jsonl` |
| 9 | Daily Health Digest | `n8n execute --id=KitHealthDigest1` | pass: one message "N executions, M failed" with per-workflow links, via the read-only Postgres login |
| 10 | Backup | `./scripts/backup.sh` | pass: `db.sql.gz`, `workflows/*.json`, encrypted `credentials.json`, `manifest.txt`, `rowcounts.txt`, `SHA256SUMS`, `.complete`; heartbeat ping received |
| 11 | `.env` archive, age | `BACKUP_AGE_RECIPIENT=age1...` | pass: `env.tar.gz.age` decrypts with the private key |
| 12 | `.env` archive, gpg | `BACKUP_GPG_PASSPHRASE=...` | pass: `env.tar.gz.gpg` decrypts |
| 13 | `.env` archive skipped | neither set | pass: skipped with a warning |
| 14 | Retention | 70 synthetic daily backups + a partial + a tagged one, then `backup.sh` | pass: 14 daily + 8 weekly kept (20 folders), partial older than 1 day removed, newest kept, tagged safety backup kept |
| 15 | Backup failure | postgres stopped, `backup.sh` | pass: exit 1, folder marked `.failed`, alert names the step and the kept good backup, heartbeat `/fail` |
| 16 | Restore drill | `./scripts/restore-drill.sh` | pass: throwaway `postgres:16.15-alpine` with no network; 173 tables, all row counts match; workflows 4/4, credentials 1/1; container removed |
| 17 | Restore drill catches a bad backup | drill on a copy with a wrong count | pass: FAILED, alert sent |
| 18 | Workflow history | `./scripts/export-workflows.sh` twice | pass: first run commits, second run "No workflow changes. Nothing committed." |
| 19 | Update, same tag | `./scripts/update.sh 2.46.6 --yes` | pass: backup, health, version and API check, `OK` in `ops-log.md` |
| 20 | Update, real version change | `./scripts/update.sh 2.46.6` from 2.46.5 | pass: running version 2.46.6, previous tag recorded |
| 21 | One change a day | second `update.sh` the same day | pass: refused and logged `REFUSED`; `--force "reason"` overrides |
| 22 | Update to a bogus tag | `update.sh 9.99.99-bogus --force ...` | pass: pull fails, nothing changed, logged `ABORTED` |
| 23 | Update to an image that fails its health check, after it ran new DB migrations | test-only image `FROM n8nio/n8n:2.47.2` listening on the wrong port; `update.sh 2.47.2-broken-test --force ...` | pass: unhealthy after timeout, migrations changed (331 -> 352) so the pre-update backup was restored, back on 2.46.6 with 331 migrations, healthy, API OK, alert sent, logged `ROLLED-BACK` |
| 24 | Health check alerting | `docker compose stop n8n` (and separately postgres, uptime-kuma), `healthcheck.sh` 2x, start, `healthcheck.sh` | pass: one PROBLEM alert per problem, no repeat on the second run, RESOLVED when fixed; heartbeat ok / `/fail` / ok |
| 25 | Restore | changed and deleted workflows after a backup, `./scripts/restore.sh <dir> --yes` | pass: safety backup taken first, database restored, deleted workflow back, rename reverted, published workflows still published, credentials still decrypt (digest ran) |
| 26 | Restore refuses a different encryption key | manifest with another key fingerprint | pass: refused with instructions |
| 27 | Restore from the n8n export | `restore.sh ... --import-exports` | pass, but every workflow comes back unpublished (n8n behaviour), which is why this is not the default |
| 28 | Cron lines | each line of the generated block run under `env -i PATH=/usr/bin:/bin sh -c` | pass |

Idle memory on the test host: n8n about 380 MB, Postgres about 25 MB, Caddy about 12 MB.

## Not tested here (and why)

- **Real Let's Encrypt certificates and the certificate-expiry check**: no public DNS
  name points at this test container. Only local mode (plain HTTP) was run; the
  production Caddyfile was validated with `caddy adapt` only.
- **Real off-site copies with rclone**: rclone is not installed and there is no remote.
  The `RCLONE_REMOTE` code path did not run.
- **Real email alerts** (msmtp/sendmail): not installed here. Webhook alerts were tested.
- **Real Slack/Discord delivery and Healthchecks.io**: the local catcher stood in for them.
  The payload has both `text` (Slack) and `content` (Discord).
- **Installing into a real crontab**: `crontab` is not installed in this container, so
  `--cron-file` was used and each cron line was run by hand in a cron-like environment.
- **Interactive prompts** of `setup.sh` (no terminal here); flags were used.
- **Ubuntu 22.04/24.04 specifically**: scripts use only bash 4+, GNU coreutils/date,
  util-linux `flock` and `ss`, all standard on those releases, but they were run on this
  container's distribution.
- **The UFW and SSH steps** in docs/SECURITY.md.

## Things noticed while testing

- n8n 2.46 logs "Postgres 16 is outside the supported range and receives compatibility
  support only. Upgrade to Postgres 17 or newer." Everything worked on 16.15; the
  runbook has the steps to move to 17.
- n8n listens on `::` by default and crash-loops on hosts without IPv6. The kit sets
  `N8N_LISTEN_ADDRESS=0.0.0.0`.
- n8n only runs a *published* error workflow, so setup publishes Error Alert.
- A named volume for `/home/node/.n8n-files` is created root-owned; the one-shot
  `n8n-files-init` service makes it writable by n8n.
- In this sandbox n8n's own background calls to api.n8n.io failed on TLS (the sandbox
  intercepts outbound HTTPS). That is noise in the logs here, not a kit problem.
