# Postgres → S3 Nightly Backup — `/opt/infra` Runbook

This runbook documents the **working** nightly Postgres-to-S3 backup setup:

* **Per-database dumps** via `pg_dump --format=custom --compress=zstd:3`
* **Parallel** (4 concurrent) with **integrity verification** before upload
* **Uploaded to `s3://marin-postgres-backups/YYYY-MM-DD/`** in `STANDARD_IA` storage
* **10-day retention** enforced by S3 lifecycle rule (not the script)
* **Runs nightly at 02:00 America/Chicago** via root cron (handles DST automatically)
* **Per-execution log file** per run; 30 days of execution history retained on the host

It is paired with `postgresql-setup.md` (the install/operations runbook for the Postgres container itself).

> Operator preferences honored:
>
> * Use **nano**
> * Prefer explicit commands and verification after each step
> * No secrets committed to Git

---

## 0) Key architecture decisions

### Why `pg_dump --format=custom --compress=zstd:3`

* **Single file per database** — clean S3 layout, easy to restore individually.
* **zstd compression** is the **fastest** sensible compression for pg_dump and produces smaller files than gzip. PG 16+ added zstd/lz4 to pg_dump.
* **Custom format** supports `pg_restore --jobs=N` for fast parallel restore later.
* Compression happens **inside pg_dump** — no second `| gzip` stage, no double-write.

### Why parallel across DBs (4 workers), not parallel inside one DB

* `pg_dump --jobs=N` requires `--format=directory`, which produces a directory (multiple files per DB) — awkward for "one file per database" in S3.
* 13 databases with mixed sizes are better parallelized at the **across-DB** level via `xargs -P 4`. Largest DBs start first (`ORDER BY pg_database_size DESC`) so the four workers stay busy throughout the run.

### Why a staging tmpfile (not `pg_dump | aws s3 cp -`)

* A pure pipe finalizes the multipart upload even if `pg_dump` errors mid-stream (closed pipe → EOF → S3 commits a corrupted/partial dump).
* Writing to a host tmpfile, then `pg_restore --list` verifying the header, then `aws s3 cp` guarantees only valid dumps land in S3. The tmpfile is removed after upload. Net cost is one local NVMe write — negligible compared to the upload itself.

### Why STANDARD_IA storage class

* Backups are infrequent-access by definition. `STANDARD_IA` costs roughly half of `STANDARD` for storage and is fast to retrieve on demand. Lifecycle expiration applies the same way.

### Why `CRON_TZ=America/Chicago` (not fixed UTC)

* The user wants "2 AM Central" stable across the year. Hard-coding `0 7 * * *` UTC would be 2 AM in winter (CST) but 3 AM in summer (CDT) — undesirable. `CRON_TZ` lets cron evaluate the schedule in the named zone and handle DST transparently.

### Why retention is enforced by S3 lifecycle, not the script

* The script intentionally never deletes from S3 (smallest blast radius — a buggy script can't wipe history).
* S3 Lifecycle is set-and-forget: AWS deletes objects ≥10 days old, every day, automatically.

---

## 1) Prerequisites

* `infra-postgres` Docker container running (see `postgresql-setup.md`).
* **AWS CLI v2** installed on the host (`/usr/local/bin/aws`).
* An **IAM user** with permissions on the `marin-postgres-backups` bucket (the marinoscar user, whose credentials live in `apps/knecta/.env`, has account-wide access and works).
* `bash`, `xargs`, `tee`, `find`, `date`, `du` — all standard on Ubuntu.

---

## 2) AWS one-time setup

These commands were run once during install. Re-run only if migrating to a new account/bucket.

```bash
# Identity check
aws sts get-caller-identity

# Bucket creation (us-east-1; that region uses a different API call shape than others — no LocationConstraint)
aws s3api create-bucket --bucket marin-postgres-backups --region us-east-1

# Block all public access
aws s3api put-public-access-block --bucket marin-postgres-backups \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 10-day lifecycle expiration
cat > /tmp/lifecycle.json <<'EOF'
{
  "Rules": [{
    "ID": "delete-after-10-days",
    "Status": "Enabled",
    "Filter": { "Prefix": "" },
    "Expiration": { "Days": 10 }
  }]
}
EOF
aws s3api put-bucket-lifecycle-configuration \
    --bucket marin-postgres-backups \
    --lifecycle-configuration file:///tmp/lifecycle.json
rm /tmp/lifecycle.json
```

Verify:

```bash
aws s3api get-public-access-block --bucket marin-postgres-backups
aws s3api get-bucket-lifecycle-configuration --bucket marin-postgres-backups
```

Expected: all four public-access flags `true`; one lifecycle rule with `Expiration.Days = 10`.

**Required IAM permissions** on `marin-postgres-backups`:

* `s3:PutObject`
* `s3:GetObject`
* `s3:GetObjectAttributes`
* `s3:ListBucket`
* `s3:DeleteObject` (only if you ever want to manually clean up; not needed by the script)

---

## 3) Script installation

### File: `/opt/infra/shared/backup-postgres-to-s3.sh`

Permissions: `-rwxr-xr-x root:root` (mode 755). Installed by `cp`-ing the committed version from the repo.

The script:

1. Loads config from `/opt/infra/shared/backup-postgres-to-s3.env`
2. Opens a per-execution log file at `/opt/infra/shared/backup-logs/backup-<timestamp>.log` and redirects all subsequent stdout+stderr to it (plus updates the `latest` symlink)
3. Dumps globals (roles, role memberships, passwords) via `pg_dumpall --globals-only` and uploads `_globals.sql`
4. Lists user databases (excluding template DBs and `postgres`) ordered by size DESC
5. Forks `pg_dump` × 4 in parallel via `xargs -P 4`; each child verifies its dump with `pg_restore --list`, then uploads via `aws s3 cp ... --storage-class STANDARD_IA`
6. Sanity-checks `aws s3 ls` count against expected (`DB_COUNT + 1`)
7. Prunes per-execution logs older than 30 days
8. Exits 0 on full success, 1 if any DB failed

### File: `/opt/infra/shared/backup-postgres-to-s3.env`

Permissions: `-rw------- root:root` (mode 600). **Not** committed to git — covered by `.gitignore` entries:

```
shared/backup-postgres-to-s3.env
shared/backup-logs/
apps/postgres/backups/
```

Content:

```env
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_DEFAULT_REGION=us-east-1
S3_BUCKET=marin-postgres-backups
# Optional overrides:
# PG_USER=admin
# PG_CONTAINER=infra-postgres
# PARALLEL_JOBS=4
# LOG_RETENTION_DAYS=30
```

The credentials were copied (script-driven) from `/opt/infra/apps/knecta/.env`. If you rotate the knecta key, also update this file.

---

## 4) Cron installation

Edit root's crontab:

```bash
sudo crontab -e
```

Add these two lines (the `CRON_TZ` line must be at the top of the relevant block — it applies to all entries below it in the same crontab):

```cron
CRON_TZ=America/Chicago
0 2 * * * /opt/infra/shared/backup-postgres-to-s3.sh 2>>/opt/infra/shared/backup-logs/cron-stderr.log
```

* `CRON_TZ=America/Chicago` makes cron evaluate the schedule in US Central time, DST-aware.
* `0 2 * * *` = every day at 02:00 local time.
* `2>>/opt/infra/shared/backup-logs/cron-stderr.log` captures anything written to stderr **before** the script's own `exec` redirect kicks in (e.g., `.env` missing). The script's own per-execution log captures everything from the redirect onwards.

Verify the cron entry:

```bash
sudo crontab -l | grep -E "CRON_TZ|backup-postgres"
```

---

## 5) What gets backed up (and what doesn't)

The script enumerates `pg_database` and includes every non-template database **except** the system `postgres` database. At time of writing this covers:

```
knecta, marinapp, memoriahub, n8n, nextcloud, wellconnect,
adventureworks, authentik, mattermost, shellkeep, sink, vault
```

— 12 user DBs plus `_globals.sql` (roles/permissions) → 13 objects per run.

**Excluded by design:**

* `template0`, `template1` — Postgres template databases (never contain user data).
* `postgres` — the default maintenance DB. Empty in this deployment; restoring it from a dump would conflict with the existing one and provides no value.

**Adding a new database to the rotation:** automatic. The script discovers DBs via `pg_database`. Just `CREATE DATABASE foo` and it gets backed up on the next run.

**Excluding a database temporarily:** edit the SQL in §2 of the script and add `AND datname<>'foo'`. Re-deploy.

---

## 6) Object layout in S3

```
s3://marin-postgres-backups/
├── 2026-05-17/
│   ├── _globals.sql        (roles, role memberships, passwords)
│   ├── adventureworks.dump
│   ├── authentik.dump
│   ├── knecta.dump
│   ├── marinapp.dump
│   ├── mattermost.dump
│   ├── memoriahub.dump
│   ├── n8n.dump
│   ├── nextcloud.dump
│   ├── shellkeep.dump
│   ├── sink.dump
│   ├── vault.dump
│   └── wellconnect.dump
├── 2026-05-18/
│   └── ...
└── ...                     (current day + last 9 days; older deleted by lifecycle)
```

All objects use `STANDARD_IA` storage class. The lifecycle rule deletes objects 10 days after their last-modified date.

---

## 7) Logging

### Layout

```
/opt/infra/shared/backup-logs/
├── backup-2026-05-17T020000-0500.log      ← one file per execution
├── backup-2026-05-18T020000-0500.log
├── ...
├── latest -> backup-...                    ← symlink to most recent
└── cron-stderr.log                         ← stderr before the redirect kicks in
```

ISO-8601 filenames with timezone offset (`-0500` in summer, `-0600` in winter) so files sort chronologically and the run's timezone is self-evident.

### What's in each per-run log

* Opening marker: `=== Starting backup for YYYY-MM-DD → s3://... ===` with AWS identity + log file path
* One line per object: `  OK <name> (<size>)` or `  FAIL <name> (<reason>)`
  * Reasons: `pg_dump error`, `pg_dumpall error`, `verification failed`, `upload error`
* `Uploaded U / E objects` integrity check
* `=== Backup complete ===` and `Exit: 0` (or `Exit: 1` if any failure)
* Every line is timestamped via the `TS()` helper

### Inspection helpers

```bash
# Most recent run, in full
sudo less /opt/infra/shared/backup-logs/latest

# Last 50 lines
sudo tail -50 /opt/infra/shared/backup-logs/latest

# Did the most recent run succeed?
sudo grep -E "Backup complete|WARN|Exit:" /opt/infra/shared/backup-logs/latest

# All runs that had a failure, across history
sudo grep -lE "FAIL|WARN" /opt/infra/shared/backup-logs/backup-*.log

# Cron-stderr fallback (should be empty)
sudo wc -l /opt/infra/shared/backup-logs/cron-stderr.log
```

### Retention

The script self-prunes per-execution logs older than `LOG_RETENTION_DAYS` (default 30) at the end of every run. `cron-stderr.log` is intentionally append-only and not auto-truncated — it should normally remain near-empty; growth means something is misconfigured at the cron level.

---

## 8) Restore procedures

### Single-database restore (e.g., recover `marinapp` from 2026-05-15)

```bash
# 1. Pull from S3
aws s3 cp s3://marin-postgres-backups/2026-05-15/marinapp.dump /tmp/marinapp.dump

# 2. Create a target DB (or drop the current one — see warnings below)
sudo docker exec infra-postgres psql -U admin -d postgres \
    -c "CREATE DATABASE marinapp_restore;"

# 3. Parallel restore
cat /tmp/marinapp.dump | sudo docker exec -i infra-postgres \
    pg_restore -U admin -d marinapp_restore --jobs=4 --no-owner --no-acl

# 4. Verify and rename when ready (manual cutover)
sudo docker exec infra-postgres psql -U admin -d marinapp_restore -c "\dt"
```

`--no-owner --no-acl` is appropriate when restoring to a different name or different cluster. For an in-place same-cluster restore, omit them.

### Full DR (rebuilding the Postgres instance from scratch)

```bash
# 1. Stand up an empty pg_data dir + start a fresh container (see postgresql-setup.md §2-5)

# 2. Restore globals FIRST so roles exist
aws s3 cp s3://marin-postgres-backups/2026-05-15/_globals.sql - \
    | sudo docker exec -i infra-postgres psql -U admin -d postgres

# 3. Recreate each database, then restore
for db in knecta marinapp memoriahub n8n nextcloud wellconnect \
          adventureworks authentik mattermost shellkeep sink vault; do
    sudo docker exec infra-postgres psql -U admin -d postgres \
        -c "CREATE DATABASE $db;"
    aws s3 cp "s3://marin-postgres-backups/2026-05-15/${db}.dump" - \
        | sudo docker exec -i infra-postgres pg_restore -U admin -d "$db" --jobs=4
done
```

### Round-trip verification (anytime — confirms backups are restorable)

```bash
TS=$(date +%F)
aws s3 cp "s3://marin-postgres-backups/${TS}/marinapp.dump" /tmp/marinapp.test.dump
sudo docker exec infra-postgres psql -U admin -d postgres \
    -c "DROP DATABASE IF EXISTS marinapp_restore_test; CREATE DATABASE marinapp_restore_test;"
cat /tmp/marinapp.test.dump | sudo docker exec -i infra-postgres \
    pg_restore -U admin -d marinapp_restore_test --no-owner --no-acl

ORIG=$(sudo docker exec infra-postgres psql -U admin -d marinapp -tAc \
    "SELECT count(*) FROM pg_class WHERE relkind='r'")
REST=$(sudo docker exec infra-postgres psql -U admin -d marinapp_restore_test -tAc \
    "SELECT count(*) FROM pg_class WHERE relkind='r'")
echo "orig=$ORIG  restored=$REST"
sudo docker exec infra-postgres psql -U admin -d postgres \
    -c "DROP DATABASE marinapp_restore_test;"
rm /tmp/marinapp.test.dump
```

---

## 9) Day-2 operations

### Manually trigger a run (e.g., before a risky migration)

```bash
sudo /opt/infra/shared/backup-postgres-to-s3.sh
```

A new per-execution log appears under `backup-logs/`. `latest` symlink updates.

### Change retention

* **S3 retention** (10 days): edit the lifecycle rule directly in S3, not in the script.
  ```bash
  aws s3api get-bucket-lifecycle-configuration --bucket marin-postgres-backups
  # modify Expiration.Days, then put-bucket-lifecycle-configuration again
  ```
* **Local log retention** (30 days): set `LOG_RETENTION_DAYS=N` in `backup-postgres-to-s3.env`.

### Change parallelism

Set `PARALLEL_JOBS=N` in the env file. Default 4 — increase if your VPS has more cores and the run is bottlenecked on CPU; decrease if you hit Postgres connection limits.

### Rotate the IAM key

Update both `apps/knecta/.env` and `shared/backup-postgres-to-s3.env` (they share the key). No script restart needed — next cron run picks up the new value.

### Migrate to a different bucket

1. Create the new bucket (steps from §2 above).
2. Update `S3_BUCKET=` in `backup-postgres-to-s3.env`.
3. Next run writes there. Old bucket keeps its history until you decommission it.

---

## 10) Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cron didn't fire | `CRON_TZ` not honored or root crontab edit didn't save | `sudo crontab -l` to verify; check `/var/log/syslog` for `CRON` entries around 02:00 local |
| `pg_dump error` for one DB | Connection limit hit during the run | Lower `PARALLEL_JOBS`; check `max_connections` |
| `verification failed` | `pg_restore --list` couldn't read the dump header | Usually transient disk space on the host; check `df -h /opt/infra/apps/postgres/backups` |
| `upload error` | IAM permission gap or network blip | `aws s3 ls s3://marin-postgres-backups/`; if AccessDenied, check the IAM policy on the user identified by `aws sts get-caller-identity` |
| Lifecycle not deleting old objects | AWS lifecycle evaluator runs once a day | First deletions happen ~24 h after rule creation. Verify rule status with `aws s3api get-bucket-lifecycle-configuration` |
| Object count mismatch | One or more dumps failed | Grep the `latest` log for `FAIL` lines; root-cause individually |
| `cron-stderr.log` growing | Script crashed before its `exec` redirect | Inspect that file directly; usually missing `.env` or wrong permissions |
| Backup looks short / too fast | `pg_dump` errored silently | Check the per-execution log for FAIL lines; verify `S3_BUCKET` env var; verify `aws sts get-caller-identity` from within the env-sourced shell |

---

## 11) Smoke test (re-runnable anytime)

```bash
# A. Files in place
ls -l /opt/infra/shared/backup-postgres-to-s3.sh        # mode 755
ls -l /opt/infra/shared/backup-postgres-to-s3.env       # mode 600
ls -l /opt/infra/docs/postgres-backup-setup.md          # mode 644

# B. Secrets not in git
git -C /opt/infra check-ignore -v shared/backup-postgres-to-s3.env

# C. AWS reachable
sudo bash -c 'set -a; . /opt/infra/shared/backup-postgres-to-s3.env; set +a; aws sts get-caller-identity'
sudo bash -c 'set -a; . /opt/infra/shared/backup-postgres-to-s3.env; set +a; aws s3 ls s3://${S3_BUCKET}/'

# D. Bucket hardening
aws s3api get-public-access-block --bucket marin-postgres-backups
aws s3api get-bucket-lifecycle-configuration --bucket marin-postgres-backups

# E. Manual run
sudo /opt/infra/shared/backup-postgres-to-s3.sh

# F. S3 contents for today
aws s3 ls --recursive s3://marin-postgres-backups/$(date +%F)/

# G. Storage class STANDARD_IA
aws s3api list-objects-v2 --bucket marin-postgres-backups --prefix "$(date +%F)/" \
    --query 'Contents[].[Key,StorageClass]' --output table

# H. Per-execution log + latest symlink
sudo ls -lh /opt/infra/shared/backup-logs/
sudo tail -5 /opt/infra/shared/backup-logs/latest

# I. Cron entry
sudo crontab -l | grep -E "CRON_TZ|backup-postgres"

# J. After overnight: cron actually fired
sudo grep -i "backup-postgres" /var/log/syslog | tail -5
```

---

## 12) Reference

* [pg_dump documentation (custom format)](https://www.postgresql.org/docs/17/app-pgdump.html)
* [pg_restore parallel restore](https://www.postgresql.org/docs/17/app-pgrestore.html)
* [S3 Lifecycle configuration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)
* [S3 STANDARD_IA storage class](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html#sc-infreq-data-access)
* See also: `docs/postgresql-setup.md` (Postgres install + pgvector)
