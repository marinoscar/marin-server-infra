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

```bash
nano /opt/infra/proxy/nginx/conf.d/50-admin.marin.cr.conf
```

[proxy/nginx/conf.d/pgadmin.marin.cr.conf](https://github.com/marinoscar/marin-server-infra/blob/a11a8a4240e1bc68c92a6b8f193c157f3bb7ae8b/proxy/nginx/conf.d/pgadmin.marin.cr.conf)

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

Perfect — here is a **clean, production-ready addition** you can drop straight into your article.
I’ve written it to match the tone, rigor, and *actual steps that worked* for **Ubuntu 24.04 (noble)**, and to explicitly document the pitfalls you hit so you (or future-you) don’t repeat them.

I recommend inserting this **after Section 12 (Validation Checklist)** and **before Lessons Learned**, because it’s an *optional but powerful enhancement* to Cockpit.

---

## 13. Enable File System Access in Cockpit (Navigator)

By default, Cockpit does **not** include a file system browser UI.
For secure, browser-based access to the server filesystem (without SSH, SFTP, or additional ports), we install **Cockpit Navigator**.

This integrates directly into Cockpit, respects Linux permissions, and works cleanly behind our existing Nginx reverse proxy.

---

### 13.1 Why Cockpit Navigator

Cockpit Navigator provides:

* Web-based file browsing
* Upload / download files
* Create, rename, delete files and folders
* Edit text files
* View and change permissions and ownership

All actions are:

* Authenticated via Cockpit (Linux users)
* Protected by sudo elevation (“Turn on administrative access”)
* Exposed **only** through the existing Cockpit UI

No new services, ports, or containers are introduced.

---

### 13.2 Important Notes (Read First)

* Ubuntu **24.04 (noble)** is **not supported** by the official 45Drives APT repository at this time
* Attempting to use the repo setup script will:

  * Fail
  * Break APT with a malformed sources file
* GitHub “latest” release URLs **do not contain `.deb` assets**

**Correct approach**: install the last known working `.deb` directly.

---

### 13.3 Install Cockpit Navigator (Ubuntu 24.04 – Tested)

Download the pinned release that is known to work:

```bash
cd /tmp
wget https://github.com/45Drives/cockpit-navigator/releases/download/v0.5.10/cockpit-navigator_0.5.10-1focal_all.deb
```

Install it:

```bash
apt install ./cockpit-navigator_0.5.10-1focal_all.deb
```

This may also install small dependencies (`zip`, `unzip`), which is expected.

---

### 13.4 Restart Cockpit (Important)

Restart **only** the Cockpit socket (do not expose new listeners):

```bash
systemctl daemon-reexec
systemctl daemon-reload
systemctl stop cockpit.service
systemctl restart cockpit.socket
```

Verify Cockpit is still bound **only** to localhost:

```bash
ss -tulnp | grep 9090
```

Expected:

```
127.0.0.1:9090
```

There must be **no** `0.0.0.0` or `172.17.0.1` listeners.

---

### 13.5 Access Navigator in the Browser

1. Open [https://admin.marin.cr](https://admin.marin.cr)
2. Authenticate via HTTP Basic Auth
3. Log into Cockpit
4. (Optional) Click **“Turn on administrative access”**
5. Select **Navigator** from the left sidebar

You can also access it directly:

```
https://admin.marin.cr/navigator/
```

---

### 13.6 Security Model (Why This Is Safe)

Navigator inherits all existing security layers:

* TLS enforced at Nginx
* HTTP Basic Auth at Nginx
* Linux user authentication in Cockpit
* Optional sudo elevation per session
* Cockpit bound to localhost only

No additional ingress paths are created.

---

### 13.7 Validation Checklist

```bash
ls -la /usr/share/cockpit/navigator
```

Expected: files present.

In the UI:

* Navigator appears in sidebar
* Root filesystem (`/`) is visible
* “Limited access” badge disappears after sudo elevation
* File operations work as expected

---

### 13.8 Known Pitfalls (Lessons Learned)

* ❌ Do not use `repo.45drives.com/setup` on Ubuntu 24.04
* ❌ Do not use wildcard GitHub URLs (`*_all.deb`)
* ❌ Do not restart `cockpit.service` without verifying socket bindings
* ✅ Use a pinned `.deb`
* ✅ Keep Cockpit bound to `127.0.0.1`

---

## (Renumber existing sections)

Your current **Lessons Learned** becomes **Section 14**, and **Current State Summary** becomes **Section 15**.

---

## Why this addition matters

This turns Cockpit into a **complete secure admin plane**:

* Systemd
* Logs
* Networking
* Storage
* **Filesystem**

—all without SSH exposure or extra services.

If you want, next I can:

* Merge this directly into a full revised markdown
* Add a “Known Gotchas” appendix
* Or create a short TL;DR diagram showing Cockpit + Navigator flow

Just say the word.


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
