# n8n — Server Setup & Deployment

This document describes how to install and run **n8n** (workflow automation platform) on the Ubuntu VPS using the existing `/opt/infra` infrastructure model.

It follows the same conventions as the rest of this repository:

* Root-operated server
* Docker Compose per app
* Nginx reverse proxy (Docker)
* No secrets committed to Git
* Deterministic, repeatable steps

This file is intended to be a **knowledge base / runbook** you can reuse or hand to an AI agent without additional context.

---

## 1. Prerequisites

Before installing n8n, the following must already be in place:

* Ubuntu VPS with `/opt/infra` initialized
* Docker + Docker Compose installed
* Shared Docker network `proxy` created
* Nginx reverse proxy running from `/opt/infra/proxy`
* PostgreSQL running and accessible (from `/opt/infra/apps/postgres`)
* Valid DNS record:
  * `n8n.marin.cr` → VPS IP
* SSL certificate will be issued as part of this setup

If any of the above is missing, complete the base server and proxy setup first.

---

## 2. Directory Layout

n8n lives under:

```
/opt/infra/apps/n8n
```

After installation, the structure looks like:

```
/opt/infra/apps/n8n
├── .env                    # Environment file (NOT committed)
├── compose.yml             # Docker Compose file
└── data/                   # Persistent n8n data (NOT committed)
```

Key points:

* **`.env` contains all configuration** including database credentials
* **`data/` stores n8n files** including encryption keys and user data
* Data folder must be owned by UID 1000 (node user in container)

---

## 3. Create the PostgreSQL Database

n8n requires a database. Create one in your existing PostgreSQL instance.

### 3.1 Connect to PostgreSQL via pgAdmin

Open `https://pgadmin.marin.cr` and log in.

### 3.2 Create the database

In pgAdmin, run the following SQL (or use the GUI):

```sql
CREATE DATABASE n8n;
```

Alternatively, connect via CLI:

```bash
docker exec -it infra-postgres psql -U appuser -d postgres
```

Then run:

```sql
CREATE DATABASE n8n;
\q
```

### 3.3 Verify the database exists

```sql
\l
```

You should see `n8n` in the list.

---

## 4. Create the Application Folder

```bash
mkdir -p /opt/infra/apps/n8n/data
cd /opt/infra/apps/n8n
```

Set ownership for the data folder (n8n runs as UID 1000):

```bash
chown -R 1000:1000 /opt/infra/apps/n8n/data
```

---

## 5. Create the Environment File

```bash
nano /opt/infra/apps/n8n/.env
```

Add the following (update values as needed):

```env
# n8n Configuration
N8N_HOST=n8n.marin.cr
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://n8n.marin.cr/

# Security
N8N_ENCRYPTION_KEY=CHANGE_ME_GENERATE_A_RANDOM_32_CHAR_STRING
N8N_USER_MANAGEMENT_JWT_SECRET=CHANGE_ME_GENERATE_ANOTHER_RANDOM_STRING

# Database (PostgreSQL)
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=host.docker.internal
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=appuser
DB_POSTGRESDB_PASSWORD=YOUR_POSTGRES_PASSWORD

# Timezone
GENERIC_TIMEZONE=America/Costa_Rica
TZ=America/Costa_Rica

# Execution settings
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=168
```

**Important notes:**

* `N8N_ENCRYPTION_KEY` — Generate with: `openssl rand -hex 16`
* `N8N_USER_MANAGEMENT_JWT_SECRET` — Generate with: `openssl rand -hex 32`
* `DB_POSTGRESDB_HOST` — Use `host.docker.internal` because n8n container needs to reach PostgreSQL on the host
* `DB_POSTGRESDB_PASSWORD` — Use the same password from `/opt/infra/apps/postgres/.env`
* `WEBHOOK_URL` — Must match your public URL exactly for webhooks to work

**Never commit this file to Git.**

---

## 6. Create the Docker Compose File

```bash
nano /opt/infra/apps/n8n/compose.yml
```

```yaml
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: infra-n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    env_file:
      - .env
    volumes:
      - ./data:/home/node/.n8n
    extra_hosts:
      - "host.docker.internal:host-gateway"

networks:
  default:
    name: proxy
    external: true
```

Key points:

* Binds to `127.0.0.1:5678` only (localhost, not public)
* Uses external `proxy` network
* `extra_hosts` allows container to reach host services (PostgreSQL)
* Data persisted in `./data` folder

---

## 7. Start the Stack and Verify

```bash
cd /opt/infra/apps/n8n
docker compose up -d
```

Verify container is running:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep n8n
```

Expected:
* `infra-n8n` shows `127.0.0.1:5678->5678/tcp`

Check logs for startup errors:

```bash
docker logs --tail 50 infra-n8n
```

Verify n8n is responding locally:

```bash
curl -I http://127.0.0.1:5678/
```

Expected: `200 OK` or redirect response.

---

## 8. Configure Nginx Reverse Proxy

### 8.1 Create Nginx configuration (HTTP only first)

```bash
nano /opt/infra/proxy/nginx/conf.d/n8n.marin.cr.conf
```

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name n8n.marin.cr;

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

### 8.3 Verify HTTP is working

```bash
curl -I http://n8n.marin.cr/
```

Expected: `301` redirect (certificate not yet issued).

---

## 9. Issue TLS Certificate

### 9.1 Ensure folders exist

```bash
mkdir -p /opt/infra/proxy/{letsencrypt,webroot}
```

### 9.2 Issue the certificate

```bash
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot:latest certonly \
  --webroot -w /var/www/certbot \
  -d n8n.marin.cr \
  --email oscar@marin.cr \
  --agree-tos \
  --no-eff-email
```

### 9.3 Verify certificate was issued

```bash
ls -la /opt/infra/proxy/letsencrypt/live/n8n.marin.cr/
```

Expected: `fullchain.pem`, `privkey.pem`, etc.

---

## 10. Update Nginx for HTTPS

### 10.1 Update the configuration

```bash
nano /opt/infra/proxy/nginx/conf.d/n8n.marin.cr.conf
```

Replace with:

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name n8n.marin.cr;

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

    server_name n8n.marin.cr;

    ssl_certificate     /etc/letsencrypt/live/n8n.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/n8n.marin.cr/privkey.pem;

    # n8n may handle large payloads
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:5678;

        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support (required for n8n editor)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 600;
        proxy_send_timeout 600;
    }
}
```

**Important:** WebSocket headers are required for the n8n editor to function properly.

### 10.2 Test and reload

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

### 10.3 Verify HTTPS

```bash
curl -I https://n8n.marin.cr/
```

Expected: `200 OK`.

---

## 11. Complete Initial Setup

### 11.1 Access n8n

Open in browser: `https://n8n.marin.cr`

### 11.2 Create owner account

On first access, n8n will prompt you to create the owner account:

1. Enter your email address
2. Enter your first and last name
3. Create a strong password
4. Click "Next"

This creates the admin user stored in PostgreSQL.

### 11.3 Verify database connection

After setup, check that n8n is using PostgreSQL:

```bash
docker exec -it infra-postgres psql -U appuser -d n8n -c "\dt"
```

You should see n8n tables like `credentials_entity`, `execution_entity`, `workflow_entity`, etc.

---

## 12. Certificate Renewal

The certificate for `n8n.marin.cr` will be included in the centralized renewal script.

If you have `/opt/infra/shared/renew-all-certs.sh` configured, it will automatically renew this certificate.

If not, add n8n to your renewal cron job or create a dedicated script:

```bash
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot:latest renew --webroot -w /var/www/certbot

docker exec proxy-nginx nginx -s reload
```

---

## 13. Validation Checklist

After deployment, verify:

### Web UI

* Open `https://n8n.marin.cr`
* TLS certificate is valid (Let's Encrypt)
* Can log in with owner account
* Editor loads without WebSocket errors

### Webhooks

* Create a test workflow with a webhook trigger
* Copy the webhook URL
* Test with curl:

```bash
curl -X POST https://n8n.marin.cr/webhook-test/your-webhook-path
```

### Database

```bash
docker exec -it infra-postgres psql -U appuser -d n8n -c "SELECT COUNT(*) FROM workflow_entity;"
```

---

## 14. Operational Commands

### Start/stop n8n

```bash
cd /opt/infra/apps/n8n
docker compose up -d
docker compose down
```

### View logs

```bash
docker logs --tail 100 infra-n8n
docker logs -f infra-n8n
```

### Restart n8n

```bash
cd /opt/infra/apps/n8n
docker compose restart
```

### Update n8n to latest version

```bash
cd /opt/infra/apps/n8n
docker compose pull
docker compose up -d
```

### Backup n8n data

The critical data is in PostgreSQL. Export workflows:

```bash
docker exec -it infra-postgres pg_dump -U appuser n8n > /opt/infra/apps/n8n/n8n-backup-$(date +%Y%m%d).sql
```

Also backup the data folder (contains encryption key):

```bash
tar -czf /opt/infra/apps/n8n/data-backup-$(date +%Y%m%d).tar.gz /opt/infra/apps/n8n/data
```

---

## 15. Troubleshooting

### A) Container won't start: database connection error

**Cause:** PostgreSQL not reachable or wrong credentials.

**Fix:**

1. Verify PostgreSQL is running: `docker ps | grep postgres`
2. Check credentials in `.env` match `/opt/infra/apps/postgres/.env`
3. Verify database exists: `docker exec -it infra-postgres psql -U appuser -c "\l"`
4. Check logs: `docker logs infra-n8n`

### B) WebSocket errors in browser console

**Cause:** Nginx not forwarding WebSocket headers.

**Fix:** Ensure these lines are in your Nginx config:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

### C) Webhooks not working / wrong URL

**Cause:** `WEBHOOK_URL` doesn't match public URL.

**Fix:** Update `.env` with correct URL and restart:

```bash
cd /opt/infra/apps/n8n
docker compose restart
```

### D) Permission denied on data folder

**Cause:** Data folder not owned by UID 1000.

**Fix:**

```bash
chown -R 1000:1000 /opt/infra/apps/n8n/data
docker compose restart
```

### E) 502 Bad Gateway after container restart

**Fix:** Restart Nginx:

```bash
docker restart proxy-nginx
```

---

## 16. Security Considerations

* **Keep encryption key safe:** The `N8N_ENCRYPTION_KEY` in `.env` encrypts all credentials. If lost, stored credentials cannot be decrypted.
* **Backup the data folder:** Contains the encryption key file as a fallback.
* **Use strong passwords:** For both n8n owner account and PostgreSQL.
* **Consider IP allowlisting:** At the Nginx level if n8n should only be accessed from specific IPs.

---

## Current Final State (Known-Good)

* n8n: internal on `127.0.0.1:5678` (not public)
* Nginx: routes `https://n8n.marin.cr` → `http://127.0.0.1:5678`
* Database: PostgreSQL `n8n` database on existing instance
* TLS: Let's Encrypt cert at `/opt/infra/proxy/letsencrypt/live/n8n.marin.cr/`

---

## Sources

* [n8n Docker Documentation](https://docs.n8n.io/hosting/installation/docker/)
* [n8n Docker Compose Setup](https://docs.n8n.io/hosting/installation/server-setups/docker-compose/)
* [n8n Hosting Repository (PostgreSQL)](https://github.com/n8n-io/n8n-hosting/blob/main/docker-compose/withPostgres/README.md)
