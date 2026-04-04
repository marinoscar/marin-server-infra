# Apache Guacamole — Remote Desktop Gateway (remote.marin.cr)

This document describes how to install and run **Apache Guacamole** on the Ubuntu VPS using the existing `/opt/infra` infrastructure model.

It follows the same conventions as the rest of this repository:

* Root-operated server
* Docker Compose per app
* Nginx reverse proxy (Docker)
* No secrets committed to Git
* Deterministic, repeatable steps

Guacamole provides browser-based remote desktop access (RDP, VNC, SSH) to devices on the operator's home network via **Tailscale** mesh VPN.

---

## 1. High-level Architecture

**What runs where**

- **guacd**: protocol daemon (Docker, host network) — handles RDP/VNC/SSH connections to target machines
- **guacamole**: web frontend (Docker, host network) — Tomcat on port 8081 (custom `server.xml`)
- **Nginx**: reverse proxy (Docker, host network) — TLS termination + Authentik forward auth
- **Tailscale**: mesh VPN (host systemd service) — provides connectivity to home network devices

**Traffic flow**

```
Internet
  |
https://remote.marin.cr
  |
Nginx (Docker container, host network)
  |
auth_request -> Authentik (127.0.0.1:9000)
  |  (authenticated)
Reverse proxy to localhost
  |
Guacamole web UI (Docker, host network, 127.0.0.1:8081/guacamole/)
  |  (Guacamole XML login)
guacd (Docker, host network, port 4822)
  |
Tailscale (host, tailscale0 interface)
  |
Home devices (Tailscale DNS or 100.x.x.x, port 3389 RDP)
```

**Why both containers use host network**

Both guacd and guacamole run with `network_mode: host`:

- **guacd** makes actual RDP/VNC/SSH connections to target machines. Host network gives it direct access to Tailscale IPs (100.x.x.x) via the host's `tailscale0` interface.
- **guacamole** must communicate with guacd on `127.0.0.1:4822`. Placing guacamole on a Docker bridge network fails because UFW blocks traffic from the bridge gateway to the host's listening ports. Using host network for both avoids this issue entirely.

**Why port 8081 (not 8080)**

CrowdSec LAPI already listens on `127.0.0.1:8080`. A custom `server.xml` is mounted into the guacamole container to change Tomcat's listen port from 8080 to 8081.

**Why double login (Authentik + Guacamole)**

Authentik controls who can reach the Guacamole page (SSO at Nginx). Guacamole's own XML-based login is required because the XML provider only serves connections to users who authenticate through it. Header-based auth (which would skip the Guacamole login) was tested but does not work with the XML provider — the two auth backends don't merge connection data. The double login is the only reliable approach with XML-based config.

---

## 2. Prerequisites

Before installing Guacamole, the following must already be in place:

* Ubuntu VPS with `/opt/infra` initialized
* Docker + Docker Compose installed
* Nginx reverse proxy running from `/opt/infra/proxy`
* Authentik running and accessible at `127.0.0.1:9000`
* Tailscale installed and authenticated on the host (`tailscale status` shows connected)
* Valid DNS record:
  * `remote.marin.cr` → VPS IP
* SSL certificate will be issued as part of this setup

If any of the above is missing, complete the relevant setup first.

---

## 3. Directory Layout

Guacamole lives under:

```
/opt/infra/apps/guacamole
```

After installation, the structure looks like:

```
/opt/infra/apps/guacamole
├── compose.yml                      # Docker Compose file
├── server.xml                       # Custom Tomcat config (port 8081)
└── guacamole-home/                  # Guacamole config directory (NOT committed)
    └── user-mapping.xml             # User and connection definitions
```

Key points:

* **`guacamole-home/` is gitignored** — it contains credentials (user-mapping.xml has password hashes)
* **`server.xml`** is a copy of Tomcat's default server.xml with the connector port changed from 8080 to 8081
* **No database** — authentication and connections are defined in `user-mapping.xml`
* **No `.env` file needed** — all configuration is in compose.yml, server.xml, and user-mapping.xml

---

## 4. Create the Application Folder

```bash
mkdir -p /opt/infra/apps/guacamole/guacamole-home
cd /opt/infra/apps/guacamole
```

---

## 5. Create user-mapping.xml

This file defines the Guacamole user and RDP connections. Authentik handles who can reach the page; this file handles the Guacamole login and connection definitions.

### 5.1 Generate an MD5 password hash

```bash
echo -n 'YOUR_PASSWORD_HERE' | md5sum
```

Copy the hash (first 32 characters).

### 5.2 Create the file

```bash
nano /opt/infra/apps/guacamole/guacamole-home/user-mapping.xml
```

```xml
<user-mapping>

    <!-- Password hash generated with: echo -n 'PASSWORD' | md5sum -->
    <authorize username="YOUR_USERNAME"
               password="REPLACE_WITH_MD5_HASH"
               encoding="md5">

        <!-- Connections use Tailscale DNS names or IPs (100.x.x.x) -->
        <connection name="My Desktop">
            <protocol>rdp</protocol>
            <param name="hostname">myhost.your-tailnet.ts.net</param>
            <param name="port">3389</param>
            <param name="ignore-cert">true</param>
            <param name="security">any</param>
            <param name="resize-method">display-update</param>
        </connection>

        <!-- Add more connections as needed -->

    </authorize>

</user-mapping>
```

**Important notes:**

* Replace `YOUR_USERNAME` with your desired Guacamole login username
* Replace `REPLACE_WITH_MD5_HASH` with the hash from step 5.1
* Replace `myhost.your-tailnet.ts.net` with the Tailscale hostname or IP (100.x.x.x) of the target
* RDP username is omitted so Guacamole prompts for Windows credentials at connect time
* `ignore-cert` is `true` because home machines typically use self-signed RDP certs
* `security` is `any` to let the connection negotiate the best available method
* `resize-method` set to `display-update` enables dynamic resolution changes

**Never commit this file to Git.**

---

## 6. Create the Custom server.xml

The default Guacamole Docker image runs Tomcat on port 8080, which conflicts with CrowdSec LAPI. Extract the default `server.xml` and change the port:

```bash
# Start a temporary container to extract server.xml
docker run --rm guacamole/guacamole cat /usr/local/tomcat/conf/server.xml > /opt/infra/apps/guacamole/server.xml

# Change port 8080 to 8081
sed -i 's/Connector port="8080"/Connector port="8081"/' /opt/infra/apps/guacamole/server.xml

# Verify
grep 'Connector port' /opt/infra/apps/guacamole/server.xml
```

Expected: `Connector port="8081"`.

---

## 7. Create the Docker Compose File

```bash
nano /opt/infra/apps/guacamole/compose.yml
```

```yaml
services:
  guacd:
    image: guacamole/guacd:latest
    container_name: infra-guacd
    restart: unless-stopped
    network_mode: host

  guacamole:
    image: guacamole/guacamole:latest
    container_name: infra-guacamole
    restart: unless-stopped
    network_mode: host
    environment:
      GUACD_HOSTNAME: "127.0.0.1"
      GUACD_PORT: "4822"
      GUACAMOLE_HOME: "/guacamole-home"
    volumes:
      - ./guacamole-home:/guacamole-home:ro
      - ./server.xml:/usr/local/tomcat/conf/server.xml:ro
    depends_on:
      - guacd
```

Key points:

* **Both services use `network_mode: host`** — guacd needs Tailscale access, guacamole needs to reach guacd on `127.0.0.1:4822`. Bridge network was tested and fails because UFW blocks bridge-to-host traffic on port 4822.
* **Custom `server.xml`** overrides Tomcat's default port from 8080 to 8081 (CrowdSec uses 8080)
* **`GUACAMOLE_HOME`** points to the mounted directory containing `user-mapping.xml`
* **Volumes are read-only** (`:ro`) — Guacamole only reads the config
* **No `WEBAPP_CONTEXT`** — Guacamole serves at `/guacamole/` (Tomcat default). Nginx rewrites the path.

---

## 8. Start the Stack and Verify

```bash
cd /opt/infra/apps/guacamole
docker compose up -d
```

Verify containers are running:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}" | grep guac
```

Expected:
* `infra-guacd` — running
* `infra-guacamole` — running

Check logs for startup errors:

```bash
docker logs --tail 50 infra-guacamole
docker logs --tail 50 infra-guacd
```

Verify Guacamole is responding locally:

```bash
curl -I http://127.0.0.1:8081/guacamole/
```

Expected: `200` or `302` redirect to login page.

Verify guacd is listening:

```bash
ss -tlnp | grep 4822
```

Expected: guacd listening on port 4822.

---

## 9. Configure Nginx Reverse Proxy

### 9.1 Create Nginx configuration (HTTP only first)

```bash
nano /opt/infra/proxy/nginx/conf.d/remote.marin.cr.conf
```

```nginx
server {
    listen 80;
    server_name remote.marin.cr;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
```

### 9.2 Test and reload Nginx

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

---

## 10. Issue TLS Certificate

### 10.1 Ensure folders exist

```bash
mkdir -p /opt/infra/proxy/{letsencrypt,webroot}
```

### 10.2 Issue the certificate

```bash
docker run --rm \
  -v /opt/infra/proxy/letsencrypt:/etc/letsencrypt \
  -v /opt/infra/proxy/webroot:/var/www/certbot \
  certbot/certbot:latest certonly \
  --webroot -w /var/www/certbot \
  -d remote.marin.cr \
  --email oscar@marin.cr \
  --agree-tos \
  --no-eff-email
```

### 10.3 Verify certificate was issued

```bash
ls -la /opt/infra/proxy/letsencrypt/live/remote.marin.cr/
```

Expected: `fullchain.pem`, `privkey.pem`, etc.

---

## 11. Update Nginx for HTTPS

### 11.1 Update the configuration

```bash
nano /opt/infra/proxy/nginx/conf.d/remote.marin.cr.conf
```

Replace with:

```nginx
# remote.marin.cr — Apache Guacamole (Remote Desktop Gateway)
# - HTTP: ACME challenge + redirect to HTTPS
# - HTTPS: Authentik forward auth + reverse proxy to Guacamole (host:8081)
# - WebSocket required for Guacamole remote desktop streaming

server {
    listen 80;
    server_name remote.marin.cr;

    # Let's Encrypt HTTP-01 challenge
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect everything else to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name remote.marin.cr;

    ssl_certificate     /etc/letsencrypt/live/remote.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/remote.marin.cr/privkey.pem;

    # Authentik forward auth
    include /etc/nginx/snippets/authentik-forward-auth.conf;
    auth_request        /outpost.goauthentik.io/auth/nginx;
    auth_request_set    $auth_cookie $upstream_http_set_cookie;
    error_page          401 = @goauthentik_proxy_signin;

    # Heartbeat — bypass Authentik auth
    location = /heartbeat {
        auth_request off;
        access_log off;
        add_header Content-Type text/plain;
        add_header Cache-Control "no-store";
        return 200 "OK\n";
    }

    # Proxy to Guacamole
    location / {
        proxy_pass http://127.0.0.1:8081/guacamole/;
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support (critical for Guacamole tunnel)
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;

        proxy_buffering off;
        proxy_read_timeout 12h;
        proxy_send_timeout 12h;
    }
}
```

**Important notes:**

* **`proxy_pass` includes `/guacamole/`** with trailing slash. Guacamole serves at `/guacamole/` by default (Tomcat context). The trailing slash rewrites the path so `https://remote.marin.cr/` maps to `http://127.0.0.1:8081/guacamole/`.
* **WebSocket headers** are required for the remote desktop tunnel. The `$connection_upgrade` variable is defined in `05-websocket-map.conf`.
* **Timeouts set to 12 hours** for long RDP sessions.
* **`proxy_buffering off`** for real-time streaming.

### 11.2 Test and reload

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

### 11.3 Verify HTTPS

```bash
curl -I https://remote.marin.cr/
```

Expected: `302` redirect to Authentik login flow.

---

## 12. Configure Authentik

Authentik protects the Guacamole UI via forward auth. Once authenticated through Authentik, users reach the Guacamole login page.

### 12.1 Create Proxy Provider

1. Open `https://auth.marin.cr/if/admin/`
2. Navigate to **Applications → Providers**
3. Click **Create**
4. Select **Proxy Provider**
5. Fill in:
   * **Name:** Guacamole
   * **Authorization flow:** default-provider-authorization-implicit-consent
   * **Type:** Forward auth (single application)
   * **External host:** `https://remote.marin.cr`
6. Click **Finish**

### 12.2 Create Application

1. Navigate to **Applications → Applications**
2. Click **Create**
3. Fill in:
   * **Name:** Guacamole
   * **Slug:** `guacamole`
   * **Provider:** Select **Guacamole** (the provider created in step 12.1)
4. Click **Create**

### 12.3 Update Embedded Outpost

1. Navigate to **Applications → Outposts**
2. Click **Edit** on **authentik Embedded Outpost**
3. In the **Applications** section, move **Guacamole** from **Available** to **Selected**
4. Click **Update**

### 12.4 Restart Authentik (if needed)

If the outpost does not pick up the new application immediately:

```bash
cd /opt/infra/apps/authentik
docker compose restart
```

Wait 30 seconds for Authentik to restart.

### 12.5 Verify outpost responds for the new domain

```bash
curl -s -o /dev/null -w "%{http_code}" \
  -H "Host: remote.marin.cr" \
  -H "X-Original-URL: https://remote.marin.cr/" \
  http://127.0.0.1:9000/outpost.goauthentik.io/auth/nginx
```

Expected: `401` (unauthenticated but recognized — the outpost knows this domain).

If you get `404`, the outpost has not picked up the application. Restart Authentik and try again.

---

## 13. Certificate Renewal

The certificate for `remote.marin.cr` is included in the centralized renewal script.

The existing `/opt/infra/shared/renew-all-certs.sh` automatically renews this certificate as it handles all certs under `/opt/infra/proxy/letsencrypt/`.

---

## 14. Validation Checklist

After deployment, verify:

### Web UI

* Open `https://remote.marin.cr`
* Redirects to Authentik login
* After Authentik login, the Guacamole login page appears
* Can log in with the credentials from `user-mapping.xml`
* Connection list shows the configured RDP connections

### Tailscale Connectivity

```bash
# Verify Tailscale is connected
tailscale status

# Ping a home device by Tailscale DNS name
ping -c 2 mini-pc.tail60c35d.ts.net
```

### RDP Connection

* Click an RDP connection in the Guacamole UI
* Enter Windows credentials when prompted
* Remote desktop should render in the browser
* Keyboard and mouse input should work

---

## 15. Adding New RDP Connections

To add a new connection, edit `user-mapping.xml`:

```bash
nano /opt/infra/apps/guacamole/guacamole-home/user-mapping.xml
```

Add a new `<connection>` block inside the `<authorize>` element:

```xml
<connection name="Office Server">
    <protocol>rdp</protocol>
    <param name="hostname">server.tail60c35d.ts.net</param>
    <param name="port">3389</param>
    <param name="ignore-cert">true</param>
    <param name="security">any</param>
    <param name="resize-method">display-update</param>
</connection>
```

Restart the guacamole container to pick up changes:

```bash
cd /opt/infra/apps/guacamole
docker compose restart guacamole
```

Connections can use either Tailscale DNS names (e.g., `myhost.tail60c35d.ts.net`) or Tailscale IPs (e.g., `100.79.152.35`). DNS names are preferred as they survive IP changes.

### Common RDP parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `hostname` | Tailscale DNS name or IP of target | `mini-pc.tail60c35d.ts.net` |
| `port` | RDP port (usually 3389) | `3389` |
| `username` | RDP username (omit to prompt at connect time) | `oscar` |
| `password` | RDP password (omit to prompt at connect time) | |
| `domain` | Windows domain (if applicable) | `WORKGROUP` |
| `ignore-cert` | Skip RDP certificate validation | `true` |
| `security` | Security mode: `any`, `nla`, `tls`, `rdp` | `any` |
| `resize-method` | Dynamic resolution: `display-update` or `reconnect` | `display-update` |
| `enable-wallpaper` | Show desktop wallpaper | `true` |
| `enable-font-smoothing` | Enable ClearType | `true` |

---

## 16. Operational Commands

### Start/stop Guacamole

```bash
cd /opt/infra/apps/guacamole
docker compose up -d
docker compose down
```

### View logs

```bash
docker logs --tail 100 infra-guacamole
docker logs --tail 100 infra-guacd
docker logs -f infra-guacd
```

### Restart Guacamole

```bash
cd /opt/infra/apps/guacamole
docker compose restart
```

### Update Guacamole to latest version

```bash
cd /opt/infra/apps/guacamole
docker compose pull
docker compose up -d
```

**Note:** After updating, you may need to re-extract and patch `server.xml` if the Tomcat version changes. Check that port 8081 is still configured.

---

## 17. Troubleshooting

### A) Guacamole shows blank page or no connections after login

**Cause:** The username in `user-mapping.xml` does not match what you typed at the Guacamole login.

**Fix:** Verify the `<authorize username="...">` value matches your login exactly (case-sensitive).

### B) Cannot connect to RDP target (connection timeout / "server is taking too long")

**Cause:** guacd cannot reach the Tailscale hostname or IP.

**Fix:**

1. Verify Tailscale is connected: `tailscale status`
2. Ping the target from the host: `ping -c 2 mini-pc.tail60c35d.ts.net`
3. Test RDP port: `timeout 5 bash -c 'echo > /dev/tcp/mini-pc.tail60c35d.ts.net/3389' && echo OPEN || echo CLOSED`
4. Verify guacd is on host network: `docker inspect infra-guacd --format '{{.HostConfig.NetworkMode}}'` — should return `host`
5. Check guacd logs: `docker logs --tail 50 infra-guacd`
6. Verify RDP is enabled on the target machine (Windows: Settings → System → Remote Desktop → On)

### C) WebSocket connection failed (browser console error)

**Cause:** Nginx not forwarding WebSocket headers.

**Fix:** Ensure these lines are in the Nginx HTTPS server block:

```nginx
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;
```

Also verify the websocket map exists at `05-websocket-map.conf`.

### D) 502 Bad Gateway

**Cause:** Guacamole container not running or not listening on 8081.

**Fix:**

1. Check container status: `docker ps | grep guac`
2. Check port binding: `ss -tlnp | grep 8081`
3. Check logs: `docker logs --tail 50 infra-guacamole`
4. Restart: `docker compose restart`

### E) 404 on https://remote.marin.cr/

**Cause:** Tomcat serving at `/guacamole/` but Nginx `proxy_pass` missing the path.

**Fix:** Verify `proxy_pass` in the Nginx config includes `/guacamole/` with trailing slash:

```nginx
proxy_pass http://127.0.0.1:8081/guacamole/;
```

### F) Authentik returns 404 instead of 401

**Cause:** The outpost does not recognize `remote.marin.cr`.

**Fix:**

1. In Authentik admin, verify the Guacamole application is added to the **authentik Embedded Outpost**
2. Restart Authentik: `cd /opt/infra/apps/authentik && docker compose restart`
3. Re-test: `curl -s -o /dev/null -w "%{http_code}" -H "Host: remote.marin.cr" -H "X-Original-URL: https://remote.marin.cr/" http://127.0.0.1:9000/outpost.goauthentik.io/auth/nginx`

### G) Port 8080 conflict

**Cause:** CrowdSec LAPI uses port 8080 on localhost.

**Fix:** Guacamole uses a custom `server.xml` to listen on port 8081 instead. Verify: `grep 'Connector port' /opt/infra/apps/guacamole/server.xml` should show `8081`.

### H) guacamole cannot reach guacd (bridge network issue)

**Cause:** If guacamole is on a Docker bridge network, UFW blocks traffic from the bridge gateway (172.x.0.1) to guacd on the host (port 4822).

**Fix:** Both containers must use `network_mode: host`. This is the current working configuration.

---

## 18. Security Considerations

* **Authentik SSO:** Access to the Guacamole UI requires authentication through Authentik. Unauthorized users are redirected to the login page.
* **Guacamole XML login:** A second login is required at the Guacamole level. This provides defense-in-depth — even if Authentik is bypassed, Guacamole credentials are still needed.
* **No public port exposure:** Guacamole listens on `127.0.0.1:8081` only (via host network + custom server.xml) — not reachable from the internet except through Nginx.
* **guacd on port 4822:** guacd uses host network and listens on all interfaces, but UFW's default-deny policy blocks external access. Verify with `sudo ufw status | grep 4822` (should show no rule = blocked).
* **Tailscale encryption:** RDP traffic between this server and home devices travels over Tailscale's WireGuard-encrypted tunnel.
* **Credentials in user-mapping.xml:** This file contains MD5 password hashes. It is gitignored and should never be committed. RDP passwords are omitted from the XML — users are prompted at connect time.
* **RDP certificate validation:** `ignore-cert` is set to `true` for home devices with self-signed certs. For production environments, consider using valid certificates.

---

## 19. Lessons Learned During Setup

1. **Bridge network + UFW blocks guacd communication.** When guacamole runs on a Docker bridge network and guacd on host network, UFW blocks traffic from the Docker bridge gateway to port 4822. The fix is to run both on host network.

2. **Port 8080 conflict with CrowdSec.** CrowdSec LAPI listens on `127.0.0.1:8080`. With host network mode, Guacamole's default Tomcat port (8080) conflicts. A custom `server.xml` with port 8081 resolves this.

3. **Guacamole serves at `/guacamole/` by default.** The `WEBAPP_CONTEXT=ROOT` environment variable only works when the Docker entrypoint deploys the WAR file. With a custom `server.xml` mount, the entrypoint may not apply this setting. The Nginx `proxy_pass` must include `/guacamole/` to rewrite the path.

4. **Header auth does not merge with XML connections.** The Guacamole header auth extension (`HTTP_AUTH_ENABLED=true`) authenticates users but does not pull connections from `user-mapping.xml`. The two auth providers are independent — header auth creates a user with zero connections. The only way to get XML connections is to authenticate through the XML provider directly.

5. **`HEADER_ENABLED` vs `HTTP_AUTH_ENABLED`.** The Guacamole Docker image uses environment variable prefixes matching directories in `/opt/guacamole/environment/`. The header auth prefix is `HTTP_AUTH_`, not `HEADER_`. Using `HEADER_ENABLED=true` silently does nothing.

6. **Tailscale DNS names work in connection definitions.** Connections can reference Tailscale hostnames (e.g., `mini-pc.tail60c35d.ts.net`) instead of IPs. DNS names are preferred as Tailscale IPs can change.

---

## 20. Current Final State (Known-Good)

* guacd: host network, port 4822 (protocol daemon)
* guacamole: host network, port 8081 via custom server.xml (web frontend)
* Nginx: routes `https://remote.marin.cr` → `http://127.0.0.1:8081/guacamole/` with Authentik forward auth
* Auth: Authentik SSO (Nginx layer) + Guacamole XML login (application layer)
* Connections: RDP to home devices via Tailscale DNS names
* TLS: Let's Encrypt cert at `/opt/infra/proxy/letsencrypt/live/remote.marin.cr/`

---

## Sources

* [Apache Guacamole Docker Installation](https://guacamole.apache.org/doc/gug/guacamole-docker.html)
* [Apache Guacamole user-mapping.xml Reference](https://guacamole.apache.org/doc/gug/configuring-guacamole.html)
* [Apache Guacamole RDP Parameters](https://guacamole.apache.org/doc/gug/configuring-guacamole.html#rdp)
* [Tailscale Documentation](https://tailscale.com/kb)
