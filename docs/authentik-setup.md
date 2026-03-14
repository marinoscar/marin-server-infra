# Authentik — Server Setup & Deployment

This document describes how to install and run **Authentik** (open-source identity provider) on the Ubuntu VPS using the existing `/opt/infra` infrastructure model.

It follows the same conventions as the rest of this repository:

* Root-operated server
* Docker Compose per app
* Nginx reverse proxy (Docker)
* No secrets committed to Git
* Deterministic, repeatable steps

This file is intended to be a **knowledge base / runbook** you can reuse or hand to an AI agent without additional context.

---

## 1. Prerequisites

Before installing Authentik, the following must already be in place:

* Ubuntu VPS with `/opt/infra` initialized
* Docker + Docker Compose installed
* Shared Docker network `proxy` created
* Nginx reverse proxy running from `/opt/infra/proxy`
* PostgreSQL running and accessible at `pgadmin.marin.cr:5432`
* Valid DNS record:
  * `auth.marin.cr` → VPS IP
* SSL certificate will be issued as part of this setup

If any of the above is missing, complete the base server and proxy setup first.

---

## 2. Directory Layout

Authentik lives under:

```
/opt/infra/apps/authentik
```

After installation, the structure looks like:

```
/opt/infra/apps/authentik
├── .env                    # Environment file (NOT committed)
├── compose.yml             # Docker Compose file
├── data/                   # Persistent Authentik data (NOT committed)
├── certs/                  # Custom certificates (NOT committed)
└── custom-templates/       # Custom templates (optional)
```

Key points:

* **`.env` contains all configuration** including database credentials and secret key
* **`data/` stores Authentik files** including media and tenant data
* **`certs/` stores custom certificates** if needed for outposts

---

## 3. Create the PostgreSQL Database

Authentik requires a database. Create one in your existing PostgreSQL instance.

### 3.1 Connect to PostgreSQL

```bash
psql -h pgadmin.marin.cr -U admin -d postgres
```

### 3.2 Create the database and user

```sql
CREATE USER authentik WITH PASSWORD '<generated password>';
CREATE DATABASE authentik OWNER authentik;
\q
```

Generate the password beforehand:

```bash
openssl rand -base64 36 | tr -d '\n'
```

### 3.3 Verify the database exists

```sql
\l
```

You should see `authentik` in the list.

---

## 4. Create the Application Folder

```bash
mkdir -p /opt/infra/apps/authentik/{data,certs,custom-templates}
cd /opt/infra/apps/authentik
```

---

## 5. Create the Environment File

```bash
nano /opt/infra/apps/authentik/.env
```

Add the following (update values as needed):

```env
# Authentik
AUTHENTIK_SECRET_KEY=CHANGE_ME_GENERATE_WITH_OPENSSL

# PostgreSQL (external — existing server)
AUTHENTIK_POSTGRESQL__HOST=pgadmin.marin.cr
AUTHENTIK_POSTGRESQL__PORT=5432
AUTHENTIK_POSTGRESQL__NAME=authentik
AUTHENTIK_POSTGRESQL__USER=authentik
AUTHENTIK_POSTGRESQL__PASSWORD=CHANGE_ME_DATABASE_PASSWORD

# Timezone
AUTHENTIK_TIMEZONE=America/Chicago
```

**Important notes:**

* `AUTHENTIK_SECRET_KEY` — Generate with: `openssl rand -base64 60 | tr -d '\n'`
* `AUTHENTIK_POSTGRESQL__HOST` — Uses the public hostname of the existing PostgreSQL server
* `AUTHENTIK_POSTGRESQL__PASSWORD` — The password set when creating the database user in step 3

**Never commit this file to Git.**

---

## 6. Create the Docker Compose File

```bash
nano /opt/infra/apps/authentik/compose.yml
```

```yaml
services:
  server:
    image: ghcr.io/goauthentik/server:2026.2.1
    container_name: infra-authentik-server
    command: server
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9443:9443"
    volumes:
      - ./data:/data
      - ./custom-templates:/templates
    shm_size: 512mb

  worker:
    image: ghcr.io/goauthentik/server:2026.2.1
    container_name: infra-authentik-worker
    command: worker
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ./data:/data
      - ./certs:/certs
      - ./custom-templates:/templates
    shm_size: 512mb

networks:
  default:
    name: proxy
    external: true
```

Key points:

* Binds to `127.0.0.1:9000` and `127.0.0.1:9443` only (localhost, not public)
* Uses external `proxy` network
* No Docker socket mount (security — outposts deployed manually if needed)
* No bundled PostgreSQL — uses existing instance at `pgadmin.marin.cr`
* Data persisted in `./data` folder

---

## 7. Start the Stack and Verify

```bash
cd /opt/infra/apps/authentik
docker compose up -d
```

Verify containers are running:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep authentik
```

Expected:
* `infra-authentik-server` shows `127.0.0.1:9000->9000/tcp, 127.0.0.1:9443->9443/tcp`
* `infra-authentik-worker` shows running

Check logs for startup errors:

```bash
docker logs --tail 50 infra-authentik-server
```

Look for: `PostgreSQL connection successful` and `Starting HTTP server`.

Verify Authentik is responding locally:

```bash
curl -I http://127.0.0.1:9000/
```

Expected: `302` redirect to authentication flow.

**Note:** First startup takes 1-2 minutes as database migrations run. The worker container runs migrations; the server will return `503` until migrations complete.

---

## 8. Configure Nginx Reverse Proxy

### 8.1 Create Nginx configuration (HTTP only first)

```bash
nano /opt/infra/proxy/nginx/conf.d/auth.marin.cr.conf
```

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name auth.marin.cr;

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
  -d auth.marin.cr \
  --email oscar@marin.cr \
  --agree-tos \
  --no-eff-email
```

### 9.3 Verify certificate was issued

```bash
ls -la /opt/infra/proxy/letsencrypt/live/auth.marin.cr/
```

Expected: `fullchain.pem`, `privkey.pem`, etc.

---

## 10. Update Nginx for HTTPS

### 10.1 Update the configuration

```bash
nano /opt/infra/proxy/nginx/conf.d/auth.marin.cr.conf
```

Replace with:

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name auth.marin.cr;

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

    server_name auth.marin.cr;

    ssl_certificate     /etc/letsencrypt/live/auth.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/auth.marin.cr/privkey.pem;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:9000;

        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # WebSocket support (required for Authentik UI)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_read_timeout 600;
        proxy_send_timeout 600;
    }
}
```

**Important:** WebSocket headers are required for the Authentik admin interface to function properly.

### 10.2 Test and reload

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

### 10.3 Verify HTTPS

```bash
curl -I https://auth.marin.cr/
```

Expected: `302` redirect to authentication flow.

---

## 11. Complete Initial Setup

### 11.1 Access Authentik

Open in browser: `https://auth.marin.cr/if/flow/initial-setup/`

### 11.2 Create admin account

On first access via the initial setup URL, Authentik will prompt you to set the password for the default `akadmin` user:

1. Enter a strong password
2. Click "Set password"

This creates the admin user stored in PostgreSQL.

---

## 12. Certificate Renewal

The certificate for `auth.marin.cr` will be included in the centralized renewal script.

The existing `/opt/infra/shared/renew-all-certs.sh` will automatically renew this certificate as it handles all certs under `/opt/infra/proxy/letsencrypt/`.

---

## 13. Validation Checklist

After deployment, verify:

### Web UI

* Open `https://auth.marin.cr`
* TLS certificate is valid (Let's Encrypt)
* Can log in with akadmin account
* Admin interface loads without WebSocket errors

### Database

```bash
psql -h pgadmin.marin.cr -U authentik -d authentik -c "\dt" | head -20
```

---

## 14. Operational Commands

### Start/stop Authentik

```bash
cd /opt/infra/apps/authentik
docker compose up -d
docker compose down
```

### View logs

```bash
docker logs --tail 100 infra-authentik-server
docker logs --tail 100 infra-authentik-worker
docker logs -f infra-authentik-server
```

### Restart Authentik

```bash
cd /opt/infra/apps/authentik
docker compose restart
```

### Update Authentik to latest version

```bash
cd /opt/infra/apps/authentik
docker compose pull
docker compose up -d
```

**Note:** Update the image tag in `compose.yml` when upgrading to a new major version.

### Backup Authentik data

The critical data is in PostgreSQL. Export:

```bash
pg_dump -h pgadmin.marin.cr -U authentik authentik > /opt/infra/apps/authentik/authentik-backup-$(date +%Y%m%d).sql
```

---

## 15. Troubleshooting

### A) Container won't start: database connection error

**Cause:** PostgreSQL not reachable or wrong credentials.

**Fix:**

1. Verify PostgreSQL is running: `psql -h pgadmin.marin.cr -U authentik -d authentik -c "\conninfo"`
2. Check credentials in `.env`
3. Verify database exists
4. Check logs: `docker logs infra-authentik-server`

### B) 503 Service Unavailable on first start

**Cause:** Database migrations are still running (normal on first start).

**Fix:** Wait 1-2 minutes. The worker container runs migrations. Check progress with:

```bash
docker logs -f infra-authentik-worker
```

### C) WebSocket errors in browser console

**Cause:** Nginx not forwarding WebSocket headers.

**Fix:** Ensure these lines are in your Nginx config:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

### D) 502 Bad Gateway after container restart

**Fix:** Restart Nginx:

```bash
docker restart proxy-nginx
```

---

## 16. Security Considerations

* **Keep secret key safe:** The `AUTHENTIK_SECRET_KEY` in `.env` encrypts session data and tokens. If lost, all sessions are invalidated.
* **Use strong passwords:** For both akadmin account and PostgreSQL user.
* **Consider IP allowlisting:** At the Nginx level if Authentik admin should only be accessed from specific IPs.
* **Docker socket not mounted:** Outposts must be deployed manually (more secure).

---

## 17. Forward Auth Integration (Protecting Other Services)

Authentik can protect other services on this server using the **forward auth** pattern (`auth_request` in Nginx). A reusable Nginx snippet is provided for this purpose.

### Reusable snippet

```
/opt/infra/proxy/nginx/snippets/authentik-forward-auth.conf
```

This snippet provides the `/outpost.goauthentik.io` location (for auth subrequests and browser login flows) and the `@goauthentik_proxy_signin` redirect handler.

### How to protect a new service

**Step 1 — Authentik admin UI** (`https://auth.marin.cr/if/admin/`):

1. Create a **Proxy Provider** (type: Forward auth single application, external host: `https://<domain>`)
2. Create an **Application** linked to that provider
3. Edit the **authentik Embedded Outpost** and add the application to the **Selected** list
4. Optionally create a **Group** and bind it to the application to restrict access

**Step 2 — Nginx config** for the service:

Add these directives to the HTTPS `server` block:

```nginx
# Authentik forward auth
include /etc/nginx/snippets/authentik-forward-auth.conf;
auth_request        /outpost.goauthentik.io/auth/nginx;
auth_request_set    $auth_cookie $upstream_http_set_cookie;
error_page          401 = @goauthentik_proxy_signin;
```

To bypass auth on specific locations (e.g., health checks):

```nginx
location = /healthz {
    auth_request off;
    return 200 "OK\n";
}
```

**Step 3 — Reload Nginx:**

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

### Important notes

* The `/outpost.goauthentik.io` location must **not** be marked `internal` — the browser needs direct access for the login start/callback flow
* The redirect in `@goauthentik_proxy_signin` goes to `/outpost.goauthentik.io/start` on the **same domain** (not to `auth.marin.cr`). The outpost then redirects to Authentik's login page.
* After adding an application to the embedded outpost, you may need to restart Authentik (`docker compose restart`) for the outpost to pick it up
* Verify the outpost is working: `curl -s -o /dev/null -w "%{http_code}" -H "Host: <domain>" -H "X-Original-URL: https://<domain>/" http://127.0.0.1:9000/outpost.goauthentik.io/auth/nginx` — should return `401` (not `404`)

### Currently protected services

| Service | Domain | Application | Group |
|---------|--------|-------------|-------|
| Cockpit | admin.marin.cr | Cockpit | cockpit-admins |

---

## Current Final State (Known-Good)

* Authentik server: internal on `127.0.0.1:9000` (not public)
* Authentik worker: background task processor
* Nginx: routes `https://auth.marin.cr` → `http://127.0.0.1:9000`
* Database: PostgreSQL `authentik` database on existing instance at `pgadmin.marin.cr`
* TLS: Let's Encrypt cert at `/opt/infra/proxy/letsencrypt/live/auth.marin.cr/`

---

## Sources

* [Authentik Docker Compose Installation](https://docs.goauthentik.io/install-config/install/docker-compose/)
* [Authentik Configuration Reference](https://docs.goauthentik.io/install-config/configuration/)
* [Authentik Reverse Proxy Guide](https://docs.goauthentik.io/install-config/reverse-proxy/)
