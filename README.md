# n8n starter kit: self-hosted n8n on Docker, with backups, rollback and alerts

A production-ready, self-hosted [n8n](https://n8n.io) setup on Docker Compose with
Postgres, automatic HTTPS (Caddy), nightly backups, restore drills, safe updates with
automatic rollback, and alerts that go to a person.

It is built for **small field-service, repair and warranty businesses** that want
automations they can trust: work orders in, customer updates out, nothing lost in between.
I'm Ted Kelly ([tedkelly.dev](https://tedkelly.dev)). I build automations for these
businesses for a fixed price, then run them for a monthly retainer. This is the base I
run them on, and you can use it yourself.

```bash
git clone https://github.com/TedKelly561/n8n-starter-kit.git && cd n8n-starter-kit && ./setup.sh
```

---

## For owners: what this is

n8n is the engine that runs your automations: "when a work order email arrives, create
the job, text the customer, tell the technician". This kit is the safe home for that
engine on a small server you control, so your customer data stays with you and the
monthly bill stays small.

### What you get

- **n8n** on your own domain with HTTPS, a real database (Postgres), and sensible limits
  for a 2 GB server.
- **Backups every night**: the database, every workflow, and the stored logins
  (encrypted), kept 14 days plus 8 weekly copies, optionally copied off the server.
- **A weekly restore drill**: the newest backup is restored into a scratch database and
  checked, so you find out a backup is broken on a quiet Sunday, not during an outage.
- **A copy of every workflow version** you can go back to.
- **Safe updates**: one command, backup first, automatic rollback if the new version
  is not healthy.
- **Alerts to a person**: if a workflow fails, a disk fills up, a backup is late or the
  certificate is about to expire, someone gets one message in Slack/Discord or email.
  One per problem, plus a "resolved" when it is fixed. No spam.
- **A morning digest**: one message a day with what ran and what failed.

### The safety method, and where each rule is built in

| Rule | How the kit enforces it |
|---|---|
| **Shadow mode first** | `SHADOW_MODE=true` is the default in `.env` and is readable in every workflow as `$env.SHADOW_MODE`. The bundled *Shadow Mode Example* shows the pattern: the workflow does all its thinking but only **logs** what it would do (`shadow-log.jsonl`). Go live only after the log matches reality. |
| **One change a day** | Every change is a line in `ops-log.md`. `scripts/update.sh` refuses a second change on the same day (`--force "reason"` overrides and records why). Log manual changes with `scripts/log-change.sh "what changed"`. |
| **Every install checked against an export** | Each backup records row counts for every table from the dump itself, plus the workflow/credential export. `restore-drill.sh` (weekly) restores into a throwaway database and checks every count matches; `restore.sh` checks checksums, the encryption key and the workflow count before and after. |
| **A rollback copy of every version** | `export-workflows.sh` (nightly) writes every workflow as JSON into a separate git repo (`data/history/`) and commits only when something changed. `update.sh` keeps a pre-update backup and the previous version tag. |
| **Fail to a person** | The *Error Alert* workflow sends workflow name, node, error and a link to the failed execution. `healthcheck.sh` alerts on containers, disk, backup age and certificate. Heartbeats (e.g. Healthchecks.io) catch the case where the server itself is dead. |
| **Never drop work silently** | Failed executions are kept (with their data) so they can be retried; the alert says so. If no alert channel is configured, the alert workflows fail loudly instead of pretending. Backups that fail are marked and alerted, and the last good backup is never deleted. |

### What it needs

- A small VPS: **2 GB RAM**, 1-2 vCPU, 25+ GB disk, Ubuntu 22.04 or 24.04.
  About **$6-12/month** from Hetzner, DigitalOcean, Vultr, Linode and similar.
- A domain or subdomain, e.g. `n8n.yourcompany.com`, with a **DNS A record** pointing to
  the server's IP.
  If you use Cloudflare, set that record to **DNS only (grey cloud)** until the first
  certificate is issued. You can turn the proxy on afterwards (SSL mode "Full (strict)").
- Docker with the Compose plugin (`curl -fsSL https://get.docker.com | sh`).
- About 15 minutes.

### What it costs

| Item | Typical cost |
|---|---|
| VPS, 2 GB | $6-12 / month |
| Domain | $10-15 / year (or a subdomain of the one you have: free) |
| n8n Community Edition | $0 (see the license note in the FAQ) |
| Healthchecks.io heartbeats | $0 on the free tier |
| Off-site backups (Backblaze B2, S3, ...) | cents per month at this size |
| Slack/Discord alerts | $0 |

---

## Install

On a fresh server, as a user in the `docker` group (or root):

```bash
git clone https://github.com/TedKelly561/n8n-starter-kit.git && cd n8n-starter-kit && ./setup.sh
```

Setup asks for the domain, an admin email and the timezone. Non-interactive:

```bash
./setup.sh --domain n8n.example.com --email you@example.com --tz America/Chicago --yes
./setup.sh --local --yes                 # test on your own machine: http://localhost
./setup.sh --domain ... --monitoring     # add Uptime Kuma at status.<domain>
```

What `setup.sh` does (safe to re-run at any time):

1. Checks Docker, Compose, free ports 80/443, RAM and disk.
2. Creates `.env` from `.env.example` (mode 600) and generates strong secrets. Existing
   secrets are **never** overwritten.
3. Starts Postgres, n8n and Caddy, and waits until all are healthy and n8n answers
   through Caddy.
4. Imports and publishes the safety workflows (Error Alert, Daily Health Digest) plus the
   Shadow Mode Example, and a read-only database login for the digest. Existing
   workflows are left alone on re-runs.
5. Installs the cron jobs (health every 5 min, workflow export 02:15, backup 02:30,
   restore drill Sunday 04:00).
6. Takes the first workflow export and backup, and prints next steps.

> **Store `N8N_ENCRYPTION_KEY` in a password manager now** (`grep N8N_ENCRYPTION_KEY .env`).
> It encrypts every stored login. Without it, credential backups are useless.

> **Open the site and create the owner account immediately.** Until the owner exists,
> the first visitor to the URL can claim it.

After install:

1. Put a Slack or Discord incoming webhook in `.env` as `ALERT_WEBHOOK_URL`, then
   `docker compose up -d`.
2. Create two checks on [healthchecks.io](https://healthchecks.io) and set
   `HEARTBEAT_URL` (backup, daily) and `HEALTH_HEARTBEAT_URL` (every 5 minutes).
3. Set `BACKUP_AGE_RECIPIENT` (an `age` public key; keep the private key off the server)
   so `.env` is included in backups, and `RCLONE_REMOTE` for an off-site copy.
4. In every workflow you build: **Settings > Error workflow > Error Alert**.

---

## Day-2 operations

All commands run from the kit folder. Logs of the cron jobs are in `data/logs/`.

| Task | Command |
|---|---|
| Back up now | `./scripts/backup.sh` |
| List backups | `ls data/backups/` |
| Restore a backup | `./scripts/restore.sh data/backups/2026-11-08_023000` (asks first; `--yes` to skip) |
| Prove the latest backup restores | `./scripts/restore-drill.sh` |
| Save workflow versions now | `./scripts/export-workflows.sh` |
| See workflow history | `git -C data/history log --stat` |
| Update n8n | `./scripts/update.sh 2.47.2` |
| Roll back n8n by hand | `./scripts/update.sh <previous tag> --force "rollback"` (previous tag is in `data/state/previous-n8n-version`) |
| Roll back one workflow | `git -C data/history show <commit>:<id>.json > old.json`, then *Import from file* in the editor |
| Health check now | `./scripts/healthcheck.sh` |
| Record a manual change | `./scripts/log-change.sh "Work-order intake: shadow -> live"` |
| Logs | `docker compose logs -f n8n` (also `caddy`, `postgres`) |
| Status | `docker compose ps` |
| Restart | `docker compose restart n8n` |
| Apply `.env` changes | `docker compose up -d` |
| Re-install cron jobs | `./scripts/install-cron.sh` |

**When an alert fires**, follow [docs/RUNBOOK.md](docs/RUNBOOK.md).

### How a safe update works

`update.sh <tag>`:

1. Refuses if `ops-log.md` already has a change today (`--force "reason"` overrides).
2. Pulls the new image first. A tag that does not exist changes nothing.
3. Takes a backup and records the current tag and the database migration count.
4. Switches `N8N_VERSION` in `.env`, restarts n8n, waits for health, checks the version
   and the API through Caddy.
5. If anything fails: switches back to the old tag. If the new version already changed
   the database (migrations ran), the pre-update backup is restored too. Then it checks
   health again, alerts, and logs `ROLLED-BACK` (or `FAILED` if a person is needed).

### Backups in detail

Each nightly folder `data/backups/YYYY-MM-DD_HHMMSS/` holds:

- `db.sql.gz`: full Postgres dump.
- `workflows/*.json`: every workflow (`n8n export:workflow --all --separate`).
- `credentials.json`: every credential, **still encrypted** (never `--decrypted`).
- `env.tar.gz.age` or `.gpg`: `.env`, only when `BACKUP_AGE_RECIPIENT` or
  `BACKUP_GPG_PASSPHRASE` is set. Otherwise skipped with a warning.
- `manifest.txt`, `rowcounts.txt`, `SHA256SUMS`, and a `.complete` marker.

Retention keeps the newest backup of each of the last 14 days and of each of the last
8 weeks; safety backups made by update/restore are kept at least 7 days; the newest good
backup is never deleted. With `RCLONE_REMOTE` set, each backup is also copied off-site.

---

## Technical reference

### Layout

```
docker-compose.yml        n8n, postgres, caddy (+ uptime-kuma in the "monitoring" profile)
.env.example              every setting, documented (copied to .env by setup.sh)
setup.sh                  one-command install, idempotent
caddy/Caddyfile           HTTPS, security headers, /metrics blocked
caddy/optional/           Uptime Kuma site template (basic auth)
scripts/
  lib.sh                  shared helpers
  backup.sh               nightly backup + retention + off-site + heartbeat
  restore.sh              restore production from a backup
  restore-drill.sh        restore into a throwaway database and compare counts
  export-workflows.sh     workflow history (git) in data/history
  update.sh               safe update with automatic rollback
  healthcheck.sh          checks + deduplicated alerts + heartbeat
  import-workflows.sh     import the bundled workflows
  install-cron.sh         install/refresh the cron block
  log-change.sh           record a manual change in ops-log.md
workflows/                Error Alert, Shadow Mode Example, Daily Health Digest
docs/                     RUNBOOK, SECURITY, TESTED
data/                     (created, gitignored) backups, history, logs, state
ops-log.md                (created, gitignored) one line per change
```

### Pinned versions

| Image | Tag | Set in `.env` as |
|---|---|---|
| n8nio/n8n | `2.46.6` | `N8N_VERSION` |
| postgres | `17.11-alpine` | `POSTGRES_VERSION` |
| caddy | `2.11.9-alpine` | `CADDY_VERSION` |
| louislam/uptime-kuma | `2.5.9-slim` | `UPTIME_KUMA_VERSION` |

### Services

- **caddy**: the only container with published ports (80, 443, 443/udp). Gets and
  renews Let's Encrypt certificates for `DOMAIN`, adds security headers (HSTS, nosniff,
  frame and referrer policy), hides `/metrics`. Local mode serves plain HTTP on
  127.0.0.1 only.
- **n8n**: Postgres backend, `N8N_ENCRYPTION_KEY` from `.env`, secure cookies,
  `N8N_METRICS=true` (internal only), execution pruning after 14 days
  (`EXECUTIONS_DATA_MAX_AGE=336`), diagnostics off, task runners on,
  `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` so workflows can read `$env.SHADOW_MODE`, file
  nodes restricted to `/home/node/.n8n-files`. 1 GB memory limit.
- **postgres**: on an internal-only Docker network, no published port, named volume.
  384 MB memory limit, settings sized for a 2 GB server.
- **uptime-kuma** (optional, `--monitoring`): at `status.<domain>` behind Caddy basic
  auth (bcrypt hash generated by setup, password in `.env`) and Kuma's own login.

Every service has a health check, `restart: unless-stopped` and rotated logs
(10 MB x 5 files).

### Bundled workflows

| Workflow | Published by setup | What it does |
|---|---|---|
| Error Alert | yes | Error Trigger -> message to `ALERT_WEBHOOK_URL` with workflow, node, error, execution link. n8n only runs a *published* error workflow. |
| Daily Health Digest | yes | 07:05 daily: executions and failures in the last 24 h, one message. Reads two tables through a read-only Postgres login. |
| Shadow Mode Example | no | Webhook `POST /webhook/shadow-example` -> IF `$env.SHADOW_MODE` -> shadow: append to `/home/node/.n8n-files/shadow-log.jsonl`; live: the real action. |

Read the shadow log: `docker compose exec n8n cat /home/node/.n8n-files/shadow-log.jsonl`.

### Security defaults

Only 80/443 are exposed; Postgres is internal; no default passwords (all generated);
`.env` is mode 600 and gitignored; secure cookies; owner account created by you on first
visit; Caddy security headers; `/metrics` not public; credentials only ever exported
encrypted. Server hardening (UFW firewall, SSH keys, unattended upgrades) is in
[docs/SECURITY.md](docs/SECURITY.md).

---

## FAQ

**Can I run it without a domain?** For testing, yes: `./setup.sh --local`. For real
use you need a domain so webhooks and the editor work over HTTPS.

**The certificate is not issued.** Check the A record points to this server, ports
80/443 are open in the firewall and at the provider, and Cloudflare is grey-cloud. Then
`docker compose logs caddy`.

**I lost `N8N_ENCRYPTION_KEY`.** Workflows and data can be restored, but every stored
credential must be re-entered. This is why setup tells you to save it, and why backups
can include an encrypted `.env`.

**Why is n8n not on the `latest` tag?** Because "latest" changes under you. Updates are
deliberate: `./scripts/update.sh <tag>`, one a day, with a backup and rollback.

**Which Postgres?** The kit pins `postgres:17.11-alpine`, inside the range n8n 2.46
supports. Major Postgres versions cannot read each other's data folders, so a major
upgrade (for example an older install on 16) is a dump and restore: see "Moving Postgres
to a new major version" in the runbook. Treat it as that day's one change.

**Restore re-imports workflows?** By default `restore.sh` restores the database dump,
which already contains workflows and credentials with their published state. Importing
the JSON export on top would unpublish every workflow, so it only does that when the
backup has no dump or you pass `--import-exports`.

**Can I run `n8n execute` from the CLI?** Inside the running container the task broker
port is taken; use `docker compose exec -e N8N_RUNNERS_BROKER_PORT=5690 n8n n8n execute --id=<id>`.

**Is n8n free for this?** n8n Community Edition uses the Sustainable Use License: free
to self-host for your own internal business use. Offering n8n itself to others as a
hosted service needs a commercial agreement with n8n. Read the license for your case.

**Will it fit on 1 GB?** It can run with swap, but 2 GB is the supported size.

---

## Related

- [tedkelly.dev](https://tedkelly.dev): build-and-run automation for field-service,
  repair and warranty businesses.
- Demo workflows that run on this kit:
  - [work-order-intake](https://github.com/TedKelly561/work-order-intake): emails and forms into clean work orders.
  - [daily-digest](https://github.com/TedKelly561/daily-digest): one morning summary for the owner.
  - [thread-updates](https://github.com/TedKelly561/thread-updates): customer status updates in the same thread.

## License

MIT, see [LICENSE](LICENSE). n8n, Postgres, Caddy and Uptime Kuma have their own licenses.
