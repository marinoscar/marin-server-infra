# OpenClaw Backup and Restore Setup

## Overview

Automated daily backup and on-demand restore of the OpenClaw configuration and plugin data. Backups are stored as timestamped zip archives in AWS S3 with a rolling retention policy of 15 copies.

Two scripts handle the full lifecycle:

| Script | Purpose |
|--------|---------|
| `openclaw-backup.sh` | Creates a zip of `.openclaw`, uploads to S3, enforces retention |
| `openclaw-restore.sh` | Downloads a backup from S3, restores it with automatic rollback on failure |

**Schedule:** Backups run daily at 3:00 AM Costa Rica time (CST, UTC-6) via cron.

---

## Architecture

### What gets backed up

The `.openclaw` directory at `/opt/infra/apps/openclaw/data/home/.openclaw/` contains all OpenClaw state that is not part of the container image:

| Contents | Description |
|----------|-------------|
| `openclaw.json` | Gateway configuration (ports, auth, integrations) |
| `credentials/` | Paired service credentials (e.g., Mattermost) |
| `extensions/` | Installed plugins and their source code |
| `workspace/` | Workspace files (SOUL.md, IDENTITY.md, AGENTS.md, etc.) |
| `memory/` | SQLite database with conversation memory |
| `agents/` | Agent session logs and auth profiles |
| `identity/` | Device authentication and pairing data |
| `devices/` | Paired and pending device registrations |
| `cron/` | Scheduled job definitions |
| `logs/` | Config audit trail |
| `canvas/` | Canvas UI assets |
| `completions/` | Shell completion scripts (bash, zsh, fish, PowerShell) |

This directory is bind-mounted from the Docker container (`./data/home:/home/openclaw`), so both scripts operate directly on the host filesystem without needing to exec into the container.

### Backup flow

```
/opt/infra/apps/openclaw/data/home/.openclaw/
  ↓  zip -r (from inside the directory, relative paths)
/tmp/bk-YYYYMMDDHHMMSS.zip
  ↓  aws s3 cp
s3://<bucket>/bk-YYYYMMDDHHMMSS.zip
  ↓  aws s3 ls + count
  ↓  delete oldest if count > 15
  ↓  rm temp zip
Log → /opt/infra/apps/openclaw/openclaw-backup.log
```

### Restore flow

```
s3://<bucket>/bk-YYYYMMDDHHMMSS.zip
  ↓  aws s3 cp
/tmp/bk-YYYYMMDDHHMMSS.zip
  ↓  unzip -t (validate before touching anything)
  ↓  confirmation prompt
  ↓  docker compose down
.openclaw → .openclaw.pre-restore  (safety backup via cp -a)
  ↓  rm + mkdir + unzip -o
.openclaw (restored from zip)
  ↓  chown 1001:1001, chmod 700
  ↓  docker compose up -d
  ↓  rm temp zip
Log → /opt/infra/apps/openclaw/openclaw-restore.log

On failure at any step:
  .openclaw.pre-restore → .openclaw  (automatic rollback)
  docker compose up -d               (restart container)
```

---

## Prerequisites

### AWS CLI v2

Both scripts require AWS CLI v2 on the host. To install:

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp/aws-install
/tmp/aws-install/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws-install
```

Verify:

```bash
aws --version
```

### zip and unzip

The `zip` command is used by the backup script; `unzip` is used by the restore script. Both should already be available. If not:

```bash
apt install zip unzip
```

---

## Configuration

All configuration is stored in `/opt/infra/apps/openclaw/.env`. The following variables are required by both scripts:

| Variable | Purpose |
|----------|---------|
| `S3_BUCKET` | Name of the S3 bucket for storing backups |
| `S3_REGION` | AWS region of the S3 bucket (e.g., `us-east-1`) |
| `AWS_ACCESS_KEY_ID` | AWS IAM access key with S3 read/write permissions |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret key |

To change the bucket, region, or credentials:

```bash
nano /opt/infra/apps/openclaw/.env
```

### Required IAM permissions

The AWS IAM user needs the following S3 permissions on the target bucket:

- `s3:PutObject` — upload backups
- `s3:GetObject` — download backups for restore
- `s3:ListBucket` — list available backups and count for retention
- `s3:DeleteObject` — remove old backups during retention cleanup

### Retention policy

The backup script keeps the **15 most recent** backups. When a new backup pushes the count above 15, the oldest backups are automatically deleted from S3. To change this limit, edit `MAX_BACKUPS` in the backup script:

```bash
nano /opt/infra/apps/openclaw/openclaw-backup.sh
```

Look for:

```bash
MAX_BACKUPS=15
```

---

## Backup

### Cron setup (automated daily backup)

The backup runs daily at 3:00 AM Costa Rica time (UTC-6). Since Costa Rica does not observe daylight saving time, this is always 9:00 UTC.

To add the cron job (as root):

```bash
crontab -e
```

Add this line:

```
0 9 * * * /opt/infra/apps/openclaw/openclaw-backup.sh
```

Save and exit. Verify:

```bash
crontab -l
```

#### Cron schedule breakdown

```
0 9 * * *
│ │ │ │ │
│ │ │ │ └── Day of week (any)
│ │ │ └──── Month (any)
│ │ └────── Day of month (any)
│ └──────── Hour: 9 UTC = 3 AM CST (UTC-6)
└────────── Minute: 0
```

### Manual backup

To run a backup manually at any time:

```bash
cd /opt/infra/apps/openclaw
./openclaw-backup.sh
```

The script logs to both stdout and the log file, so you can watch progress in real time.

### What the backup script does step by step

1. **Sources `.env`** to load S3 credentials and bucket configuration
2. **Validates prerequisites**: checks that `aws` and `zip` are installed, the `.openclaw` directory exists, and all required environment variables are set
3. **Creates the zip**: changes into the `.openclaw` directory and runs `zip -r /tmp/bk-YYYYMMDDHHMMSS.zip .` so all paths inside the archive are relative
4. **Uploads to S3**: uses `aws s3 cp` to upload the zip to the configured bucket
5. **Cleans up**: removes the temporary zip from `/tmp`
6. **Enforces retention**: lists all `bk-*.zip` files in the bucket, counts them, and deletes the oldest if there are more than 15. Filenames sort chronologically because of the `YYYYMMDDHHMMSS` timestamp format
7. **Logs everything**: each step is logged with an ISO timestamp to `openclaw-backup.log`

If any step fails, the ERR trap logs the failure line number, removes the temp zip, and exits.

### Checking backup logs

```bash
tail -30 /opt/infra/apps/openclaw/openclaw-backup.log
```

A successful run looks like:

```
2026-03-18T09:00:00+00:00 ===== Starting OpenClaw backup =====
2026-03-18T09:00:00+00:00 Zipping ... -> /tmp/bk-20260318090000.zip
2026-03-18T09:00:00+00:00 Zip created: bk-20260318090000.zip (428K)
2026-03-18T09:00:00+00:00 Uploading to s3://.../bk-20260318090000.zip
2026-03-18T09:00:02+00:00 Upload complete
2026-03-18T09:00:02+00:00 Temp file removed
2026-03-18T09:00:02+00:00 Checking retention (max 15 backups)...
2026-03-18T09:00:03+00:00 Found 5 backups in S3
2026-03-18T09:00:03+00:00 Within retention limit, no cleanup needed
2026-03-18T09:00:03+00:00 ===== Finished OpenClaw backup =====
```

---

## Restore

### Usage modes

The restore script supports three usage modes:

```bash
cd /opt/infra/apps/openclaw

# Interactive mode: lists all backups, shows dates, prompts you to pick one
./openclaw-restore.sh

# Direct mode: restore a specific backup by filename
./openclaw-restore.sh bk-20260318023153.zip

# List mode: view available backups without restoring
./openclaw-restore.sh --list
```

### Interactive mode walkthrough

When you run `./openclaw-restore.sh` without arguments, the script:

1. Connects to S3 and lists all available backups
2. Displays them in a numbered list with human-readable timestamps:

```
Available backups (newest last):
--------------------------------------
   1) bk-20260315090000.zip  (2026-03-15 09:00:00)
   2) bk-20260316090000.zip  (2026-03-16 09:00:00)
   3) bk-20260317090000.zip  (2026-03-17 09:00:00)
   4) bk-20260318023153.zip  (2026-03-18 02:31:53)
--------------------------------------

Enter the number of the backup to restore (1-4), or 'q' to quit:
```

3. After you choose, it downloads and validates the zip, then shows a confirmation summary:

```
=== RESTORE SUMMARY ===
  Backup file : bk-20260318023153.zip
  Backup size : 428K
  Files       : 98
  Target      : /opt/infra/apps/openclaw/data/home/.openclaw

This will:
  1. Stop the OpenClaw container
  2. Save current .openclaw to .openclaw.pre-restore (safety backup)
  3. Replace .openclaw with the contents of bk-20260318023153.zip
  4. Restart the OpenClaw container

If anything fails, the safety backup will be automatically restored.

Proceed? (yes/no):
```

4. You must type `yes` (exactly) to proceed. Anything else cancels the restore.

### What the restore script does step by step

1. **Sources `.env`** to load S3 credentials and bucket configuration
2. **Validates prerequisites**: checks that `aws` and `unzip` are installed and all required environment variables are set
3. **Lists or accepts backup selection**: interactive numbered picker or validates the filename argument matches the `bk-YYYYMMDDHHMMSS.zip` format
4. **Downloads the backup**: uses `aws s3 cp` to download the zip to `/tmp`
5. **Validates the zip**: runs `unzip -t` (test mode) to confirm the archive is not corrupted, and counts the files inside
6. **Shows confirmation prompt**: displays a summary of what will happen and waits for explicit `yes`
7. **Stops the container**: runs `docker compose down` to cleanly stop OpenClaw
8. **Creates safety backup**: copies the current `.openclaw` directory to `.openclaw.pre-restore` using `cp -a` (preserves permissions, timestamps, and ownership). If a previous safety backup exists from an earlier restore, it is removed first
9. **Replaces `.openclaw`**: removes the current directory, creates a fresh one, and extracts the zip contents into it with `unzip -o`
10. **Fixes ownership**: sets ownership to `1001:1001` (the openclaw container user) and permissions to `700` on the directory
11. **Cleans up**: removes the temporary zip from `/tmp`
12. **Restarts the container**: runs `docker compose up -d`
13. **Preserves the safety backup**: the `.openclaw.pre-restore` directory remains until you explicitly remove it

### Safety nets

The restore script has multiple layers of protection against failures:

#### 1. Pre-validation (nothing is touched yet)

- The zip is downloaded and tested with `unzip -t` **before** the container is stopped or any files are modified
- The filename format is validated against the expected `bk-YYYYMMDDHHMMSS.zip` pattern
- All prerequisites (AWS CLI, unzip, env vars) are checked upfront

#### 2. Confirmation prompt

- A clear summary is shown before any destructive action
- You must type `yes` exactly — anything else cancels safely

#### 3. Safety backup

- The entire current `.openclaw` directory is copied (not moved) to `.openclaw.pre-restore` before anything is replaced
- The copy uses `cp -a` to preserve all metadata (permissions, ownership, timestamps)
- The safety backup is **never automatically deleted** — you must remove it yourself after verifying the restore works

#### 4. Automatic rollback on failure

The script tracks its progress using three state flags:

| Flag | Meaning |
|------|---------|
| `DOWNLOAD_DONE` | The zip has been downloaded to `/tmp` |
| `SAFETY_BACKUP_DONE` | The current `.openclaw` has been copied to `.openclaw.pre-restore` |
| `TARGET_REMOVED` | The current `.openclaw` has been deleted |

If any step fails (ERR trap fires), the rollback handler:

- Checks if the target was removed **and** a safety backup exists → restores the safety backup to `.openclaw`
- Cleans up the temporary zip file from `/tmp`
- Attempts to restart the container with `docker compose up -d` so the service is not left down
- Logs everything that happened during the rollback

#### 5. Container restart on failure

Even if the restore fails, the script tries to restart the container so OpenClaw is not left offline. If the container also fails to start, it logs a warning for manual intervention.

### After a successful restore

The OpenClaw gateway takes approximately 60-70 seconds to initialize after the container starts. Check progress with:

```bash
docker logs --tail 30 openclaw-ssh
```

Once you have verified everything is working correctly, remove the safety backup:

```bash
rm -rf /opt/infra/apps/openclaw/data/home/.openclaw.pre-restore
```

### Checking restore logs

```bash
tail -40 /opt/infra/apps/openclaw/openclaw-restore.log
```

A successful restore looks like:

```
2026-03-18T10:15:00+00:00 ===== Starting OpenClaw restore =====
2026-03-18T10:15:00+00:00 Backup specified via argument: bk-20260318023153.zip
2026-03-18T10:15:01+00:00 Downloaded: bk-20260318023153.zip (428K)
2026-03-18T10:15:01+00:00 Zip validated: 98 files inside
2026-03-18T10:15:05+00:00 Stopping OpenClaw container...
2026-03-18T10:15:06+00:00 Container stopped
2026-03-18T10:15:06+00:00 Creating safety backup: .openclaw -> .openclaw.pre-restore
2026-03-18T10:15:06+00:00 Safety backup created
2026-03-18T10:15:06+00:00 Removing current .openclaw directory...
2026-03-18T10:15:06+00:00 Extracting bk-20260318023153.zip -> .openclaw
2026-03-18T10:15:07+00:00 Setting ownership to 1001:1001
2026-03-18T10:15:07+00:00 Ownership and permissions set
2026-03-18T10:15:07+00:00 Starting OpenClaw container...
2026-03-18T10:15:08+00:00 Container started
2026-03-18T10:15:08+00:00 ===== Restore completed successfully =====
2026-03-18T10:15:08+00:00 Safety backup preserved at: .openclaw.pre-restore
```

A failed restore with rollback looks like:

```
2026-03-18T10:15:06+00:00 Removing current .openclaw directory...
2026-03-18T10:15:06+00:00 Extracting bk-20260318023153.zip -> .openclaw
2026-03-18T10:15:07+00:00 ERROR: Restore failed at line 308 — starting rollback...
2026-03-18T10:15:07+00:00 Rolling back: restoring safety backup...
2026-03-18T10:15:07+00:00 Rollback complete: original .openclaw restored from safety backup
2026-03-18T10:15:07+00:00 Attempting to restart the OpenClaw container...
2026-03-18T10:15:08+00:00 Container restarted
2026-03-18T10:15:08+00:00 ===== Restore FAILED (rolled back) =====
```

### Manual restore (if the script is unavailable)

If you need to restore manually (e.g., the script itself is missing or the host is in a degraded state):

```bash
# 1. Load credentials
cd /opt/infra/apps/openclaw
set -a && . .env && set +a

# 2. List available backups
aws s3 ls "s3://${S3_BUCKET}/" --region "${S3_REGION}"

# 3. Download the desired backup (replace filename)
aws s3 cp "s3://${S3_BUCKET}/bk-YYYYMMDDHHMMSS.zip" /tmp/ --region "${S3_REGION}"

# 4. Stop the container
docker compose down

# 5. Create safety backup of current state
cp -a data/home/.openclaw data/home/.openclaw.pre-restore

# 6. Remove current and extract backup
rm -rf data/home/.openclaw
mkdir data/home/.openclaw
cd data/home/.openclaw
unzip /tmp/bk-YYYYMMDDHHMMSS.zip

# 7. Fix ownership and permissions
cd /opt/infra/apps/openclaw
chown -R 1001:1001 data/home/.openclaw
chmod 700 data/home/.openclaw

# 8. Restart the container
docker compose up -d

# 9. Wait ~70 seconds, then verify
docker logs --tail 30 openclaw-ssh

# 10. Once verified, clean up
rm -rf data/home/.openclaw.pre-restore
rm -f /tmp/bk-YYYYMMDDHHMMSS.zip
```

---

## Verification Commands

### Check backup status

```bash
# View recent backup log entries
tail -30 /opt/infra/apps/openclaw/openclaw-backup.log

# List all backups in S3
cd /opt/infra/apps/openclaw
set -a && . .env && set +a
aws s3 ls "s3://${S3_BUCKET}/" --region "${S3_REGION}"

# Or use the restore script's list mode
./openclaw-restore.sh --list
```

### Check restore status

```bash
# View recent restore log entries
tail -40 /opt/infra/apps/openclaw/openclaw-restore.log

# Check if a safety backup exists from a previous restore
ls -la /opt/infra/apps/openclaw/data/home/.openclaw.pre-restore 2>/dev/null
```

### Check cron

```bash
crontab -l
```

### Check container health after restore

```bash
docker ps --filter name=openclaw-ssh
docker logs --tail 30 openclaw-ssh
```

---

## Troubleshooting

### Backup issues

#### AWS CLI not found

Both scripts check for `aws` at startup and exit with a clear message and install instructions. See the Prerequisites section above.

#### S3 access denied

Check that the credentials in `.env` are correct and that the IAM user has `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, and `s3:DeleteObject` permissions on the target bucket.

#### Source directory not found (backup)

The `.openclaw` directory may not exist if the OpenClaw container has never started. Start the container and wait for the gateway to initialize (~70 seconds):

```bash
cd /opt/infra/apps/openclaw
docker compose up -d
# Wait 70 seconds
docker logs --tail 10 openclaw-ssh
```

#### Empty or very small backup

If the zip file is only a few KB, the `.openclaw` directory may contain minimal data. This is normal for a fresh installation. The backup is still valid.

#### Permission denied on .openclaw

Both scripts must run as root (which cron does by default). The `.openclaw` directory is owned by UID 1001 with mode `0700`, but root can always read it.

### Restore issues

#### Downloaded zip fails validation

If `unzip -t` reports the archive is corrupt, the file may have been damaged in S3 or during transfer. Try a different backup:

```bash
./openclaw-restore.sh --list
./openclaw-restore.sh bk-YYYYMMDDHHMMSS.zip  # pick a different one
```

#### Restore failed but rollback succeeded

Check the restore log to identify which step failed:

```bash
tail -40 /opt/infra/apps/openclaw/openclaw-restore.log
```

The log will show the exact line number where the failure occurred. Common causes:

- Disk full (check with `df -h`)
- S3 download interrupted (network issue)
- Docker daemon not running (check with `systemctl status docker`)

The automatic rollback will have restored your original `.openclaw` directory and restarted the container.

#### Restore failed and rollback also failed

This is the worst case. The restore log will contain a `WARNING: Failed to restart container` message. Steps to recover:

1. Check if the safety backup exists:
   ```bash
   ls -la /opt/infra/apps/openclaw/data/home/.openclaw.pre-restore
   ```

2. If it exists, manually restore it:
   ```bash
   cd /opt/infra/apps/openclaw
   rm -rf data/home/.openclaw
   mv data/home/.openclaw.pre-restore data/home/.openclaw
   docker compose up -d
   ```

3. If neither `.openclaw` nor `.openclaw.pre-restore` exists, download a backup manually from S3 using the manual restore steps above.

#### Container starts but gateway does not initialize

The gateway can take 60-70 seconds. If it still has not started after 2 minutes:

```bash
docker logs --tail 50 openclaw-ssh
```

Look for error messages related to `openclaw.json` configuration. If the config file is from an incompatible version, you may need to restore a different backup.

#### Leftover safety backup consuming disk space

After confirming a restore works, always clean up:

```bash
rm -rf /opt/infra/apps/openclaw/data/home/.openclaw.pre-restore
```

---

## Files Reference

| File | Purpose |
|------|---------|
| `apps/openclaw/openclaw-backup.sh` | Backup script (cron and manual) |
| `apps/openclaw/openclaw-restore.sh` | Restore script with auto-rollback |
| `apps/openclaw/openclaw-backup.log` | Backup log (auto-created, append-only) |
| `apps/openclaw/openclaw-restore.log` | Restore log (auto-created, append-only) |
| `apps/openclaw/.env` | S3 credentials and bucket configuration |
| `apps/openclaw/data/home/.openclaw/` | The directory being backed up and restored |
| `apps/openclaw/data/home/.openclaw.pre-restore/` | Safety backup (exists only after a restore, until manually removed) |
| `docs/openclaw-backup-restore-setup.md` | This document |
