# Mattermost — Server Setup & Deployment

This document describes how to install and run **Mattermost** (team messaging platform) on the Ubuntu VPS using the existing `/opt/infra` infrastructure model.

It follows the same conventions as the rest of this repository:

* Root-operated server
* Docker Compose per app
* Nginx reverse proxy (Docker)
* No secrets committed to Git
* Deterministic, repeatable steps

This file is intended to be a **knowledge base / runbook** you can reuse or hand to an AI agent without additional context.

---

## 1. Prerequisites

Before installing Mattermost, the following must already be in place:

* Ubuntu VPS with `/opt/infra` initialized
* Docker + Docker Compose installed
* Shared Docker network `proxy` created
* Nginx reverse proxy running from `/opt/infra/proxy`
* PostgreSQL running and accessible (from `/opt/infra/apps/postgres`)
* Valid DNS record:
  * `team.marin.cr` → VPS IP
* SSL certificate will be issued as part of this setup

If any of the above is missing, complete the base server and proxy setup first.

---

## 2. Directory Layout

Mattermost lives under:

```
/opt/infra/apps/mattermost
```

After installation, the structure looks like:

```
/opt/infra/apps/mattermost
├── .env                    # Environment file (NOT committed)
├── compose.yml             # Docker Compose file
├── config/                 # Mattermost configuration (NOT committed)
├── data/                   # Persistent data (NOT committed)
└── logs/                   # Application logs (NOT committed)
```

Key points:

* **`.env` contains all configuration** including database and S3 credentials
* **`config/` stores Mattermost config.json** (auto-generated on first run)
* **`data/` stores local data** (file uploads go to S3)
* Directories must be owned by UID 2000 (mattermost user in container)

---

## 3. Create the PostgreSQL Database

Mattermost requires a database. Create one in your existing PostgreSQL instance.

### 3.1 Connect to PostgreSQL

```bash
docker exec -it infra-postgres psql -U admin -d postgres
```

### 3.2 Create the database

```sql
CREATE DATABASE mattermost;
\q
```

### 3.3 Verify the database exists

```bash
docker exec -it infra-postgres psql -U admin -c "\l" | grep mattermost
```

---

## 4. Create the Application Folder

```bash
mkdir -p /opt/infra/apps/mattermost/{config,data,logs}
cd /opt/infra/apps/mattermost
```

Set ownership for the data folders (Mattermost runs as UID 2000):

```bash
chown -R 2000:2000 /opt/infra/apps/mattermost/{config,data,logs}
```

---

## 5. Create the Environment File

```bash
nano /opt/infra/apps/mattermost/.env
```

Add the following (update values as needed):

```env
# Database (external PostgreSQL)
MM_SQLSETTINGS_DRIVERNAME=postgres
MM_SQLSETTINGS_DATASOURCE=postgres://admin:YOUR_PASSWORD@pgadmin.marin.cr:5432/mattermost?sslmode=disable&connect_timeout=10

# Site URL
MM_SERVICESETTINGS_SITEURL=https://team.marin.cr

# S3 File Storage
MM_FILESETTINGS_DRIVERNAME=amazons3
MM_FILESETTINGS_AMAZONS3BUCKET=marin-team
MM_FILESETTINGS_AMAZONS3REGION=us-east-1
MM_FILESETTINGS_AMAZONS3ACCESSKEYID=YOUR_AWS_ACCESS_KEY
MM_FILESETTINGS_AMAZONS3SECRETACCESSKEY=YOUR_AWS_SECRET_KEY
MM_FILESETTINGS_AMAZONS3SSL=true

# Timezone
TZ=America/Costa_Rica
```

**Important notes:**

* `MM_SQLSETTINGS_DATASOURCE` — Use the same password from `/opt/infra/apps/postgres/.env`
* `pgadmin.marin.cr` — Public hostname for PostgreSQL (do not use Docker internal names)
* S3 credentials — Use AWS IAM credentials with access to the `marin-team` bucket
* All Mattermost settings can be overridden via `MM_` environment variables

**Never commit this file to Git.**

---

## 6. Create the Docker Compose File

```bash
nano /opt/infra/apps/mattermost/compose.yml
```

```yaml
services:
  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: infra-mattermost
    restart: unless-stopped
    ports:
      - "127.0.0.1:8065:8065"
    env_file:
      - .env
    volumes:
      - ./config:/mattermost/config
      - ./data:/mattermost/data
      - ./logs:/mattermost/logs

networks:
  default:
    name: proxy
    external: true
```

Key points:

* Binds to `127.0.0.1:8065` only (localhost, not public)
* Uses external `proxy` network
* Data persisted in `./config`, `./data`, and `./logs` folders

---

## 7. Start the Stack and Verify

```bash
cd /opt/infra/apps/mattermost
docker compose up -d
```

Verify container is running:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep mattermost
```

Expected:
* `infra-mattermost` shows `127.0.0.1:8065->8065/tcp`

Check logs for startup errors:

```bash
docker logs --tail 50 infra-mattermost
```

Verify Mattermost is responding locally:

```bash
curl -I http://127.0.0.1:8065/
```

Expected: `200 OK`.

---

## 8. Configure Nginx Reverse Proxy

### 8.1 Create Nginx configuration (HTTP only first)

```bash
nano /opt/infra/proxy/nginx/conf.d/team.marin.cr.conf
```

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name team.marin.cr;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
```

### 8.2 Test and reload Nginx

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

---

## 9. Issue TLS Certificate

### 9.1 Issue the certificate

```bash
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot:latest certonly \
  --webroot -w /var/www/certbot \
  -d team.marin.cr \
  --email oscar@marin.cr \
  --agree-tos \
  --no-eff-email
```

### 9.2 Verify certificate was issued

```bash
ls -la /opt/infra/proxy/letsencrypt/live/team.marin.cr/
```

Expected: `fullchain.pem`, `privkey.pem`, etc.

---

## 10. Update Nginx for HTTPS

### 10.1 Update the configuration

```bash
nano /opt/infra/proxy/nginx/conf.d/team.marin.cr.conf
```

Replace with:

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name team.marin.cr;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name team.marin.cr;

    ssl_certificate     /etc/letsencrypt/live/team.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/team.marin.cr/privkey.pem;

    # Mattermost file uploads
    client_max_body_size 100m;

    # WebSocket endpoint
    location ~ /api/v[0-9]+/(users/)?websocket$ {
        proxy_pass http://127.0.0.1:8065;

        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 600;
        proxy_send_timeout 600;
    }

    location / {
        proxy_pass http://127.0.0.1:8065;

        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 600;
        proxy_send_timeout 600;
    }
}
```

**Important:** WebSocket headers are required for the Mattermost client to function properly. The separate WebSocket location block ensures proper handling of persistent connections.

### 10.2 Test and reload

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

### 10.3 Verify HTTPS

```bash
curl -I https://team.marin.cr/
```

Expected: `200 OK`.

---

## 11. Complete Initial Setup

### 11.1 Access Mattermost

Open in browser: `https://team.marin.cr`

### 11.2 Create admin account

On first access, Mattermost will prompt you to create the admin account:

1. Enter your email address
2. Enter your username
3. Create a strong password
4. Create your first team

### 11.3 Verify S3 file storage

After setup, upload a file in a chat message. The file should be stored in the `marin-team` S3 bucket. You can verify in the AWS S3 console.

---

## 12. Certificate Renewal

The certificate for `team.marin.cr` will be included in the centralized renewal script.

If you have `/opt/infra/shared/renew-all-certs.sh` configured, it will automatically renew this certificate.

---

## 13. Validation Checklist

After deployment, verify:

### Web UI

* Open `https://team.marin.cr`
* TLS certificate is valid (Let's Encrypt)
* Can log in with admin account
* No WebSocket errors in browser console

### File uploads

* Send a message with a file attachment
* Verify the file is accessible
* Check S3 bucket for stored file

### Database

```bash
docker exec -it infra-postgres psql -U admin -d mattermost -c "\dt" | head -20
```

---

## 14. Operational Commands

### Start/stop Mattermost

```bash
cd /opt/infra/apps/mattermost
docker compose up -d
docker compose down
```

### View logs

```bash
docker logs --tail 100 infra-mattermost
docker logs -f infra-mattermost
```

### Restart Mattermost

```bash
cd /opt/infra/apps/mattermost
docker compose restart
```

### Update Mattermost to latest version

```bash
cd /opt/infra/apps/mattermost
docker compose pull
docker compose up -d
```

### Backup Mattermost data

The critical data is in PostgreSQL. Export:

```bash
docker exec -it infra-postgres pg_dump -U admin mattermost > /opt/infra/apps/mattermost/mattermost-backup-$(date +%Y%m%d).sql
```

---

## 15. Troubleshooting

### A) Container won't start: database connection error

**Cause:** PostgreSQL not reachable or wrong credentials.

**Fix:**

1. Verify PostgreSQL is running: `docker ps | grep postgres`
2. Check credentials in `.env` match `/opt/infra/apps/postgres/.env`
3. Verify database exists: `docker exec -it infra-postgres psql -U admin -c "\l"`
4. Check logs: `docker logs infra-mattermost`

### B) WebSocket errors in browser console

**Cause:** Nginx not forwarding WebSocket headers.

**Fix:** Ensure these lines are in your Nginx config:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

### C) Permission denied on config/data/logs folders

**Cause:** Folders not owned by UID 2000.

**Fix:**

```bash
chown -R 2000:2000 /opt/infra/apps/mattermost/{config,data,logs}
docker compose restart
```

### D) S3 file upload errors

**Cause:** Invalid S3 credentials or bucket permissions.

**Fix:**

1. Verify AWS credentials in `.env`
2. Ensure the `marin-team` bucket exists in `us-east-1`
3. Check IAM user has `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` permissions on the bucket
4. Check logs: `docker logs infra-mattermost | grep -i s3`

### E) 502 Bad Gateway after container restart

**Fix:** Restart Nginx:

```bash
docker restart proxy-nginx
```

---

## 16. Security Considerations

* **Use strong passwords:** For the Mattermost admin account
* **S3 bucket policy:** Ensure the S3 bucket is not publicly accessible
* **Consider IP allowlisting:** At the Nginx level if Mattermost should only be accessed from specific IPs
* **Rate limiting:** Mattermost has built-in rate limiting; configure in System Console if needed

---

## Current Final State (Known-Good)

* Mattermost: internal on `127.0.0.1:8065` (not public)
* Nginx: routes `https://team.marin.cr` → `http://127.0.0.1:8065`
* Database: PostgreSQL `mattermost` database on existing instance
* File storage: AWS S3 bucket `marin-team` in `us-east-1`
* TLS: Let's Encrypt cert at `/opt/infra/proxy/letsencrypt/live/team.marin.cr/`

---

## Sources

* [Mattermost Docker Deployment](https://docs.mattermost.com/deployment-guide/server/deploy-containers.html)
* [Mattermost Environment Variables](https://docs.mattermost.com/administration-guide/configure/environment-variables.html)
* [Mattermost Server Deployment Planning](https://docs.mattermost.com/deployment-guide/server/server-deployment-planning.html)
