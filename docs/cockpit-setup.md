# Cockpit Behind Docker Nginx Reverse Proxy (admin.marin.cr)

This document captures the **final, working setup** for running **Cockpit** on an Ubuntu host (systemd) while exposing it **only** via **https://admin.marin.cr** through an **Nginx reverse proxy running in Docker**.

It also documents the **permanent fix** for the “Cockpit socket failed with Result: resources” issue that can appear after a reboot.

---

## 1. High-level architecture (final state)

**What runs where**

- **Cockpit**: installed on the **host OS** (systemd socket/service)
- **Nginx**: runs in **Docker** as the single internet-facing entry point
- **TLS**: Let’s Encrypt cert for `admin.marin.cr` mounted into the Nginx container
- **Security layers**
  - Internet access: **HTTPS enforced**
  - Nginx: **HTTP Basic Auth**
  - Cockpit: **Linux user authentication**
  - Cockpit binding: **localhost only** (no public listener)

**Traffic flow**

```
Internet
  ↓
https://admin.marin.cr
  ↓
Nginx (Docker container, host network)
  ↓
Reverse proxy to localhost
  ↓
Cockpit (systemd, 127.0.0.1:9090)
```

---

## 2. Why Cockpit is NOT run in Docker

Cockpit is a system administration UI that integrates deeply with the host:
- systemd/journald
- users/groups/sudo
- storage/mounts
- networking

Running it in Docker typically requires privileged containers and breaks key functionality. The correct approach is: **Cockpit on host**, **reverse proxy in Docker**.

---

## 3. The permanent fix (why it broke after reboot)

### Symptom
`systemctl status cockpit.socket` shows something like:

- **Active: failed (Result: resources)**
- “Failed to listen on cockpit.socket …”

### Root cause (most common in this setup)
Cockpit was configured to bind to **an interface/IP that is not guaranteed to exist at boot**, e.g. Docker bridge `172.17.0.1` (docker0).

After a reboot (or if Docker starts later than systemd), that IP may not be ready when `cockpit.socket` starts, so systemd fails the socket with a “resources” error and **does not automatically recover**.

### Permanent solution
Bind Cockpit to **localhost only**:

- ✅ stable across reboot
- ✅ works with Nginx in host network mode
- ✅ reduces attack surface

---

## 4. Install Cockpit (host)

```bash
sudo apt update
sudo apt install -y cockpit
```

Verify:

```bash
sudo systemctl status cockpit.socket --no-pager
```

---

## 5. Bind Cockpit to localhost only (systemd drop-in)

### 5.1 Create the drop-in directory + file

```bash
sudo mkdir -p /etc/systemd/system/cockpit.socket.d
sudo nano /etc/systemd/system/cockpit.socket.d/listen.conf
```

Paste:

```ini
[Socket]
# IMPORTANT:
# - The empty ListenStream= line resets the upstream defaults
# - Only bind to localhost so the socket never depends on docker0/bridge IPs
ListenStream=
ListenStream=127.0.0.1:9090
```

### 5.2 Apply the change

```bash
sudo systemctl daemon-reload

# If it ever shows "failed", clear the failed state first:
sudo systemctl reset-failed cockpit.socket || true

sudo systemctl restart cockpit.socket
sudo systemctl enable cockpit.socket
```

### 5.3 Verify it’s correct

Show the effective config:

```bash
sudo systemctl cat cockpit.socket
```

Confirm only localhost is listening:

```bash
sudo ss -lntp | grep 9090 || true
```

Expected: **only** `127.0.0.1:9090` (no `0.0.0.0`, no `172.17.0.1`).

Optional quick local check:

```bash
curl -vk https://127.0.0.1:9090/ | head
```

---

## 6. Create Linux admin user (host)

Cockpit authenticates against Linux users.

```bash
sudo adduser marinoscar
sudo usermod -aG sudo marinoscar
```

Verify:

```bash
groups marinoscar
```

---

## 7. Nginx runs in Docker (host networking)

### 7.1 Why host networking
On many VPS providers, container-to-host reachability via `docker0` can be flaky due to firewall/nftables rules.

**Using host networking makes Nginx talk to `127.0.0.1` directly**, which is the most reliable option.

### 7.2 Example Docker Compose

Edit:

```bash
sudo nano /opt/infra/proxy/compose.yml
```

Example:

```yaml
services:
  nginx:
    image: nginx:1.27-alpine
    container_name: proxy-nginx
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/snippets:/etc/nginx/snippets:ro
      - ./letsencrypt:/etc/letsencrypt
      - ./webroot:/var/www/certbot
```

Bring it up:

```bash
cd /opt/infra/proxy
sudo docker compose up -d --force-recreate
```

Verify ports:

```bash
sudo ss -lntp | grep -E ':80|:443' || true
```

---

## 8. HTTP Basic Auth credentials (for Nginx)

Install tool:

```bash
sudo apt install -y apache2-utils
```

Create auth file:

```bash
sudo mkdir -p /opt/infra/proxy/nginx/snippets/auth
sudo htpasswd -c /opt/infra/proxy/nginx/snippets/auth/admin.htpasswd marinoscar
```

**Important lesson learned:** The auth file must exist before container start, or you must recreate/restart the container after creating it.

---

## 9. TLS certificate (Let’s Encrypt)

Nginx serves the ACME challenge via webroot.

Create challenge directory:

```bash
sudo mkdir -p /opt/infra/proxy/webroot/.well-known/acme-challenge
```

Verify reachability:

```bash
echo ok | sudo tee /opt/infra/proxy/webroot/.well-known/acme-challenge/test.txt >/dev/null
curl http://admin.marin.cr/.well-known/acme-challenge/test.txt
```

Run certbot (host):

```bash
sudo apt install -y certbot

sudo certbot certonly \
  --webroot \
  --webroot-path=/opt/infra/proxy/webroot \
  --email you@marin.cr \
  --agree-tos \
  --no-eff-email \
  -d admin.marin.cr
```

Certificates will be under:

```
/etc/letsencrypt/live/admin.marin.cr/
```

(Your compose mounts `/opt/infra/proxy/letsencrypt` in the example; if you keep certs in `/etc/letsencrypt`, mount that path instead, or bind-mount `/etc/letsencrypt` into `/opt/infra/proxy/letsencrypt`.)

---

## 10. Nginx virtual host config for Cockpit

Edit:

```bash
sudo nano /opt/infra/proxy/nginx/conf.d/50-admin.marin.cr.conf
```

Recommended config (includes heartbeat + WebSocket support):

```nginx
# admin.marin.cr
# - HTTP: ACME challenge + redirect to HTTPS
# - HTTPS: Basic Auth protected reverse proxy to Cockpit (localhost:9090)
# - Heartbeat: unauthenticated endpoint for external uptime monitors

# WebSocket helper
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name admin.marin.cr;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location = /heartbeat {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "OK\n";
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name admin.marin.cr;

    ssl_certificate     /etc/letsencrypt/live/admin.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/admin.marin.cr/privkey.pem;

    auth_basic "Restricted Admin Access";
    auth_basic_user_file /etc/nginx/snippets/auth/admin.htpasswd;

    location = /heartbeat {
        auth_basic off;
        access_log off;
        add_header Content-Type text/plain;
        add_header Cache-Control "no-store";
        return 200 "OK\n";
    }

    location / {
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;

        # Cockpit uses long-lived WebSockets; reduce random disconnects
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_buffering off;

        # Option A (recommended): proxy to Cockpit over HTTPS (self-signed on localhost)
        proxy_pass https://127.0.0.1:9090;
        proxy_ssl_verify off;

        # Option B: if you KNOW your Cockpit is plain HTTP (less common), use:
        # proxy_pass http://127.0.0.1:9090;
    }
}
```

---

## 11. Nginx commands (because Nginx is in Docker)

If Nginx runs **on the host**, you would do:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

But in this setup Nginx is inside the container, so use Docker commands instead.

### 11.1 Test config
```bash
sudo docker exec proxy-nginx nginx -t
```

### 11.2 Reload (no downtime)
```bash
sudo docker exec proxy-nginx nginx -s reload
```

### 11.3 If you’re using docker compose and need the right directory
From the folder that contains your compose file:

```bash
cd /opt/infra/proxy
sudo docker compose ps
sudo docker compose restart nginx
```

---

## 12. Validation checklist (critical)

### Host checks
- Cockpit only on localhost:

```bash
sudo ss -lntp | grep 9090 || true
```

- Cockpit socket healthy:

```bash
sudo systemctl status cockpit.socket --no-pager
```

### Public checks
- Heartbeat is up:

```bash
curl -i https://admin.marin.cr/heartbeat
```

Expected:
- HTTP status: `200`
- Body: `OK`

- Admin UI requires auth:

```bash
curl -i https://admin.marin.cr/
```

Expected:
- `401 Unauthorized` (or a Basic Auth prompt in the browser)

---

## 13. Troubleshooting (fast)

### Cockpit socket stuck in failed state
```bash
sudo systemctl reset-failed cockpit.socket
sudo systemctl restart cockpit.socket
sudo systemctl status cockpit.socket --no-pager
```

### Check what it’s actually listening on
```bash
sudo ss -lntp | grep 9090 || true
```

### Confirm your drop-in is being applied
```bash
sudo systemctl cat cockpit.socket
```

### Nginx container reload after config change
```bash
sudo docker exec proxy-nginx nginx -t
sudo docker exec proxy-nginx nginx -s reload
```

### Logs
```bash
sudo journalctl -u cockpit.socket -u cockpit.service --no-pager -n 200
sudo docker logs --tail 200 proxy-nginx
```

---

## 14. Risks and security notes

### Binding Cockpit to localhost only
**Risk:** You can’t access Cockpit directly via `https://server-ip:9090/` anymore.  
**Benefit:** This is exactly what you want—Cockpit is reachable **only** through your authenticated reverse proxy.

### Reverse proxying to Cockpit over HTTPS with `proxy_ssl_verify off`
- Nginx → Cockpit on localhost uses a **self-signed** cert by default.
- Disabling verification is acceptable here because:
  - traffic never leaves the host network stack
  - Cockpit is not exposed publicly
  - the threat model for MITM on localhost is extremely low

If you want stricter verification, you can pin Cockpit’s cert/CA and enable verify, but it’s more work and usually not worth it for localhost-only.

### Double-auth (Basic Auth + Cockpit login)
This is good defense-in-depth. The main tradeoff is user convenience (two prompts).

### Reboot resilience
The permanent fix is: **do not bind Cockpit to docker0/bridge IPs**. Localhost binding avoids boot ordering issues between systemd and Docker/network availability.

---

## Appendix A: What caused the original outage?

The failure mode you hit is consistent with:

- Cockpit socket configured to listen on `172.17.0.1:9090` (docker0)
- After reboot, docker0/IP not present when cockpit.socket starts
- systemd fails the socket with **Result: resources**
- Cockpit becomes unreachable until the socket is restarted or reconfigured

The localhost-only drop-in removes that dependency and is the best long-term fix.
