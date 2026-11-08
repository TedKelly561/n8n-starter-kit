# Runbook: what to do when an alert fires

Work from the kit folder (`cd ~/n8n-starter-kit`). First three commands, always:

```bash
docker compose ps                    # what is up, what is unhealthy
./scripts/healthcheck.sh             # all checks, in plain words
tail -n 20 ops-log.md                # what changed recently (most outages follow a change)
```

If the last change in `ops-log.md` was today, suspect it first and undo it before
anything else.

## "n8n workflow FAILED: <name>" (Error Alert)

The work is not lost: it is in the failed execution linked in the message.

1. Open the link. Read the red node's error.
2. Fix the cause (expired login? the other system down? bad input?).
3. Open the execution and click **Retry** (with the current or original workflow).
4. If the same workflow fails repeatedly and you cannot fix it now, **unpublish** it
   and tell whoever relies on it to handle items by hand until it is fixed.

## "Container X is unhealthy / exited / missing"

```bash
docker compose logs --tail 100 X
docker compose up -d                 # starts anything that is down
```

- **postgres**: usually disk full (see below) or memory. `docker compose logs postgres`.
- **n8n**: look for `migration`, `ECONNREFUSED`, `out of memory`. If it began after an
  update, roll back: `./scripts/update.sh <previous tag> --force "rollback"` (previous
  tag: `cat data/state/previous-n8n-version`).
- **caddy**: `docker compose logs caddy`, usually certificate or config.

## "n8n does not answer through Caddy"

n8n healthy but Caddy not passing traffic: `docker compose restart caddy`, then check
`docker compose logs caddy`. In production also check DNS still points here.

## "Disk is N% full"

```bash
df -h; du -sh data/backups data/logs; docker system df
docker image prune -a                # removes images no container uses (keeps running ones)
```

Old executions are pruned after `EXECUTIONS_DATA_MAX_AGE` hours; lower it in `.env`
and `docker compose up -d` if executions are the problem. Never delete the newest
backup folder.

## "Backup FAILED" or "Newest good backup is Nh old"

```bash
tail -n 50 data/logs/backup.log
./scripts/backup.sh                  # run by hand and read the error
```

Typical causes: disk full, n8n or postgres unhealthy, `age`/`rclone` missing or
misconfigured, cron not installed (`crontab -l`). The previous good backup is always
kept.

## "Restore drill FAILED"

The latest backup did not restore cleanly or the counts differ. Production is fine; the
backup is not. Read the report in `data/logs/restore-drill-*.txt`, run
`./scripts/backup.sh` and then `./scripts/restore-drill.sh` again. If it fails twice,
treat backups as broken: fix it today.

A single mismatch on `workflow_entity` can happen if someone saved a workflow in the
seconds between the database dump and the workflow export. Run the drill again.

## "TLS certificate expires in N days"

Caddy renews automatically about 30 days before expiry, so this means renewal is
failing. `docker compose logs caddy | grep -i -E "acme|certificate|error"`. Usual
causes: DNS changed, port 80 blocked, Cloudflare proxy (orange cloud) in front during
renewal with SSL mode not Full.

## "n8n update rolled back"

Nothing to do urgently: the kit is back on the old version. Read
`data/logs/update-failed-*.log`, check the n8n release notes, and try again another day.

## "URGENT: n8n update and rollback FAILED"

```bash
cat data/state/previous-n8n-version          # the version that worked
ls -d data/backups/*pre-update*              # the backup taken just before
./scripts/restore.sh data/backups/<that folder>
```

If `.env` still names the new version, set `N8N_VERSION` back to the old one first.

## Heartbeat missed (Healthchecks.io says "down")

The server or cron is not running at all. Log in to the provider console. If the server
is up: `crontab -l` (is the kit block there?), `systemctl status cron`, `docker ps`.

## Restore onto a new server (disaster recovery)

1. New VPS, Docker, then `git clone` the kit and copy your backup folder onto it.
2. Put the **old** `N8N_ENCRYPTION_KEY` (password manager, or decrypt the backup's
   `env.tar.gz.age` with `age -d -i key.txt ... | tar -xzf -`) into a new `.env` before
   the first start, or simply restore the whole old `.env`.
3. `./setup.sh --domain <same domain> --email ... --yes`
4. `./scripts/restore.sh <backup folder> --skip-safety-backup`
5. Point DNS at the new server.

## Moving Postgres to a new major version

1. `./scripts/backup.sh` and note the folder.
2. `docker compose stop n8n postgres && docker compose rm -f postgres`
3. `docker volume rm n8nkit_pgdata` (only after step 1 succeeded and the drill passed).
4. Set `POSTGRES_VERSION` in `.env` to the new pinned tag; `docker compose up -d postgres`.
5. `./scripts/restore.sh <folder> --skip-safety-backup`, then `./scripts/log-change.sh "Postgres 16 -> 17"`.
