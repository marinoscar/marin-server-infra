# OpenClaw Backup Setup

## Overview

Automated daily backup of the OpenClaw configuration and plugin data to AWS S3. The backup script creates a timestamped zip archive of the `.openclaw` directory, uploads it to a configured S3 bucket, and enforces a rolling retention policy of 15 copies.

**Schedule:** Daily at 3:00 AM Costa Rica time (CST, UTC-6) via cron.

## Architecture

```
Source:  /opt/infra/apps/openclaw/data/home/.openclaw/
  ↓  zip
Temp:   /tmp/bk-YYYYMMDDHHMMSS.zip
  ↓  aws s3 cp
S3:     s3://<bucket>/bk-YYYYMMDDHHMMSS.zip
  ↓  retention check
  ↓  delete oldest if count > 15
Log:    /opt/infra/apps/openclaw/openclaw-backup.log
```

The `.openclaw` directory contains the OpenClaw gateway configuration (`openclaw.json`) and plugin data. This directory is bind-mounted from the Docker container, so the backup runs directly on the host without needing to exec into the container.

## Prerequisites

### AWS CLI v2

The backup script requires AWS CLI v2. To install:

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

### zip

The `zip` command should already be available. If not:

```bash
apt install zip
```

## Configuration

All configuration is stored in `/opt/infra/apps/openclaw/.env`. The following variables are required:

| Variable | Purpose |
|----------|---------|
| `S3_BUCKET` | Name of the S3 bucket for storing backups |
| `S3_REGION` | AWS region of the S3 bucket |
| `AWS_ACCESS_KEY_ID` | AWS IAM access key with S3 write permissions |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret key |

To change the bucket, region, or credentials, edit the `.env` file:

```bash
nano /opt/infra/apps/openclaw/.env
```

### Retention Policy

The script keeps the **15 most recent** backups. When a new backup pushes the count above 15, the oldest backups are automatically deleted from S3. To change this limit, edit the `MAX_BACKUPS` variable in the script:

```bash
nano /opt/infra/apps/openclaw/openclaw-backup.sh
```

Look for:

```bash
MAX_BACKUPS=15
```

## Cron Setup

The backup runs daily at 3:00 AM Costa Rica time (UTC-6). Since Costa Rica does not observe daylight saving time, this is always 9:00 UTC.

To add the cron job:

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

### Cron schedule breakdown

```
0 9 * * *
│ │ │ │ │
│ │ │ │ └── Day of week (any)
│ │ │ └──── Month (any)
│ │ └────── Day of month (any)
│ └──────── Hour: 9 UTC = 3 AM CST (UTC-6)
└────────── Minute: 0
```

## Manual Execution

To run a backup manually at any time:

```bash
cd /opt/infra/apps/openclaw
./openclaw-backup.sh
```

The script logs to both stdout and the log file, so you can watch progress in real time.

## Restore Procedure

### 1. List available backups

```bash
cd /opt/infra/apps/openclaw
set -a && . .env && set +a
aws s3 ls "s3://${S3_BUCKET}/" --region "${S3_REGION}"
```

### 2. Download the desired backup

```bash
aws s3 cp "s3://${S3_BUCKET}/bk-YYYYMMDDHHMMSS.zip" /tmp/ --region "${S3_REGION}"
```

Replace `bk-YYYYMMDDHHMMSS.zip` with the actual filename from step 1.

### 3. Stop the OpenClaw container

```bash
cd /opt/infra/apps/openclaw
docker compose down
```

### 4. Back up the current state (safety net)

```bash
mv data/home/.openclaw data/home/.openclaw.old
```

### 5. Extract the backup

```bash
mkdir data/home/.openclaw
cd data/home/.openclaw
unzip /tmp/bk-YYYYMMDDHHMMSS.zip
```

### 6. Fix file ownership

The OpenClaw container runs as UID 1001. Ensure the restored files have the correct owner:

```bash
cd /opt/infra/apps/openclaw
chown -R 1001:1001 data/home/.openclaw
chmod 700 data/home/.openclaw
```

### 7. Start the container

```bash
docker compose up -d
```

The OpenClaw gateway takes approximately 60-70 seconds to initialize after starting.

### 8. Verify

```bash
docker logs --tail 20 openclaw-ssh
```

Once verified, remove the safety backup:

```bash
rm -rf data/home/.openclaw.old
```

## Verification Commands

Check the backup log:

```bash
tail -30 /opt/infra/apps/openclaw/openclaw-backup.log
```

List backups in S3:

```bash
cd /opt/infra/apps/openclaw
set -a && . .env && set +a
aws s3 ls "s3://${S3_BUCKET}/" --region "${S3_REGION}"
```

Verify cron is active:

```bash
crontab -l
```

## Troubleshooting

### AWS CLI not found

The script will exit with a clear error message and install instructions. Follow the steps in the Prerequisites section above.

### S3 access denied

Check that the credentials in `.env` are correct and that the IAM user has `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, and `s3:DeleteObject` permissions on the target bucket.

### Source directory not found

The `.openclaw` directory may not exist if the OpenClaw container has never started. Start the container first and wait for the gateway to initialize (~70 seconds).

### Permission denied on .openclaw

The backup script must run as root (which cron does by default). The `.openclaw` directory is owned by UID 1001 with mode 0700, but root can always read it.

### Empty or very small backup

If the zip file is only a few KB, the `.openclaw` directory may contain minimal data. This is normal for a fresh installation. The backup is still valid.

## Files Reference

| File | Purpose |
|------|---------|
| `apps/openclaw/openclaw-backup.sh` | Backup script |
| `apps/openclaw/openclaw-backup.log` | Backup log (auto-created) |
| `apps/openclaw/.env` | S3 credentials and bucket config |
| `docs/openclaw-backup-setup.md` | This document |
