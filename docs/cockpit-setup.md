# Cockpit Behind Docker Nginx Reverse Proxy (admin.marin.cr)

This document captures the **final, working, production-grade setup** for running **Cockpit** on a VPS **behind an Nginx reverse proxy running in Docker**, secured with **Let’s Encrypt TLS** and **HTTP Basic Auth**, and documents **all lessons learned** so this can be repeated cleanly without falling into the same traps.

This is intentionally detailed and opinionated.

---

## 1. High-level Architecture (Final State)

### What we are running

* **Cockpit**: Installed directly on the host (systemd service)
* **Nginx**: Runs inside Docker, acts as the single internet-facing entry point
* **TLS**: Let’s Encrypt certificates stored on the host and mounted into Nginx
* **Security**:

  * HTTPS enforced
  * HTTP Basic Auth at Nginx layer
  * Cockpit authentication via Linux users
  * Cockpit bound only to localhost

### Final traffic flow

```
Internet
  ↓
https://admin.marin.cr
  ↓
Nginx (Docker container, host network)
  ↓
HTTP proxy (localhost)
  ↓
Cockpit (systemd, 127.0.0.1:9090)
```

### Why this architecture

* Cockpit **must run on the host** (it manages systemd, storage, networking, users)
* Docker-to-host networking via `docker0` is unreliable on many VPS providers
* Using **host network mode** for the reverse proxy eliminates an entire class of routing/firewall issues
* Nginx remains containerized, reproducible, and consistent with the rest of the platform

---

## 2. Why Cockpit is NOT Run in Docker

Cockpit is:

* A **system administration interface**
* Deeply integrated with:

  * systemd
  * journald
  * storage devices
  * user accounts
  * networking

Running Cockpit in Docker would:

* Break core functionality
* Require privileged containers
* Defeat the security model

**Correct decision**: Install Cockpit directly on the host OS.

---

## 3. Why Nginx Runs in Docker (but with host networking)

### Why Docker at all

* Consistent with the rest of the platform
* Clean separation of concerns
* Easy certificate mounting
* Repeatable configuration

### Why `network_mode: host`

Initial attempts used:

* Docker bridge networking
* `host.docker.internal`
* `docker0` (172.17.0.1)

**Observed failure mode**:

* Containers could not reach host services on docker0
* Requests would hang (no timeout, no response)
* This is common on VPS platforms due to firewall / nftables rules

**Final decision**:

* Run Nginx in **host network mode**
* Proxy to `127.0.0.1` directly

This is the most reliable and simplest solution.

---

## 4. Directory Structure

All proxy-related assets live under:

```
/opt/infra/proxy
├── compose.yml
├── nginx
│   ├── conf.d
│   │   └── 50-admin.marin.cr.conf
│   └── snippets
│       └── auth
│           └── admin.htpasswd
├── letsencrypt
│   └── live/admin.marin.cr/
└── webroot
    └── .well-known/acme-challenge/
```

---

## 5. Install Cockpit (Host)

```bash
apt update
apt install -y cockpit
```

Verify:

```bash
systemctl status cockpit.socket
```

---

## 6. Bind Cockpit to Localhost Only (Security)

Create override:

```bash
mkdir -p /etc/systemd/system/cockpit.socket.d
nano /etc/systemd/system/cockpit.socket.d/listen.conf
```

```ini
[Socket]
ListenStream=
ListenStream=127.0.0.1:9090
```

Apply:

```bash
systemctl daemon-reload
systemctl restart cockpit.socket
```

Verify:

```bash
ss -tulnp | grep 9090
```

Expected:

```
127.0.0.1:9090
```

---

## 7. Create Linux Admin User

Cockpit authenticates against Linux users.

```bash
adduser marinoscar
usermod -aG sudo marinoscar
```

Verify:

```bash
groups marinoscar
```

---

## 8. Nginx Docker Compose (Host Network Mode)

Edit:

```bash
nano /opt/infra/proxy/compose.yml
```

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
docker compose up -d --force-recreate
```

Verify ports:

```bash
ss -tulnp | grep -E ':80|:443'
```

---

## 9. Create HTTP Basic Auth Credentials

Install tool:

```bash
apt install -y apache2-utils
```

Create auth file:

```bash
mkdir -p /opt/infra/proxy/nginx/snippets/auth
htpasswd -c /opt/infra/proxy/nginx/snippets/auth/admin.htpasswd marinoscar
```

Important lesson learned:

> The auth file **must exist before the container is started**, or you must recreate the container.

---

## 10. Obtain TLS Certificate (Let’s Encrypt)

Nginx serves the ACME challenge via webroot.

Create challenge directory:

```bash
mkdir -p /opt/infra/proxy/webroot/.well-known/acme-challenge
```

Verify reachability:

```bash
echo ok > /opt/infra/proxy/webroot/.well-known/acme-challenge/test.txt
curl http://admin.marin.cr/.well-known/acme-challenge/test.txt
```

Run certbot (host):

```bash
apt install -y certbot
certbot certonly \
  --webroot \
  --webroot-path=/opt/infra/proxy/webroot \
  --email you@marin.cr \
  --agree-tos \
  --no-eff-email \
  -d admin.marin.cr
```

Certificates land in:

```
/opt/infra/proxy/letsencrypt/live/admin.marin.cr/
```

---

## 11. Nginx Virtual Host Configuration

Edit:

```bash
nano /opt/infra/proxy/nginx/conf.d/50-admin.marin.cr.conf
```

```nginx
server {
  listen 80;
  server_name admin.marin.cr;

  location /.well-known/acme-challenge/ {
    root /var/www/certbot;
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

  location / {
    proxy_http_version 1.1;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        $connection_upgrade;

    proxy_pass http://127.0.0.1:9090;
  }
}
```

Reload:

```bash
nginx -t
nginx -s reload
```

---

## 12. Validation Checklist (Critical)

### Host checks

```bash
curl -I http://127.0.0.1:9090/ping
```

Expected: `200 OK`

### External checks

```bash
curl -I https://admin.marin.cr
```

Expected: `401 Unauthorized`

### Browser flow

1. Open [https://admin.marin.cr](https://admin.marin.cr)
2. Enter Basic Auth credentials
3. Cockpit login screen appears
4. Login as Linux user
5. Click "Turn on administrative access" to elevate

---

## 13. Lessons Learned (Read This Before Repeating)

1. **Do NOT fight Docker-to-host routing on VPSes**

   * If containers hang connecting to docker0, switch to host network

2. **Cockpit redirects HTTP → HTTPS internally**

   * Proxying via docker0 + TLS causes hangs
   * Localhost HTTP avoids this entirely

3. **Auth files must exist before container start**

   * Otherwise mounts appear empty

4. **Use Basic Auth + Cockpit auth (defense in depth)**

5. **Bind Cockpit to localhost only**

   * Nginx is the only ingress

---

## 14. Current State Summary

* admin.marin.cr
* TLS enforced
* Basic Auth required
* Cockpit not exposed to internet
* Nginx containerized
* Cockpit host-native
* Clean, repeatable, secure

---

## Final Note

This setup is **production-grade**, **secure**, and **battle-tested**.
If you follow this document step-by-step, you will not repeat the earlier mistakes.

Victory achieved — document preserved.
