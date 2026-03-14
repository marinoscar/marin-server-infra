# Portainer Behind Docker Nginx Reverse Proxy (portainer.marin.cr)

This document covers the complete setup for **Portainer CE** as a Docker container management UI, exposed via **https://portainer.marin.cr** through an **Nginx reverse proxy running in Docker**, with **Authentik OAuth2/OIDC** for single sign-on authentication.

---

## 1. High-level architecture

**What runs where**

- **Portainer CE**: Docker container with access to the host Docker socket
- **Nginx**: runs in **Docker** as the single internet-facing entry point (host network mode)
- **TLS**: Let's Encrypt cert for `portainer.marin.cr` mounted into the Nginx container
- **Authentication**: OAuth2/OIDC via Authentik (https://auth.marin.cr) — configured natively in Portainer
- **Port binding**: `127.0.0.1:9005` only (not publicly accessible)

**Traffic flow**

```
Internet
  |
https://portainer.marin.cr
  |
Nginx (Docker container, host network)
  |
Reverse proxy to localhost
  |
Portainer (Docker container, 127.0.0.1:9005)
  |
OAuth2/OIDC login redirect
  |
Authentik (127.0.0.1:9000 / auth.marin.cr)
```

**Why OAuth2/OIDC instead of forward auth (Cockpit pattern)?**

Portainer has native OAuth2/OIDC support. Using it provides true single sign-on — users authenticate once through Authentik and are logged into Portainer automatically. This is the [officially recommended integration](https://integrations.goauthentik.io/hypervisors-orchestrators/portainer/). Forward auth (as used for Cockpit) would require double authentication (Authentik SSO + Portainer login).

---

## 2. Why Portainer needs the Docker socket

Portainer manages Docker containers, images, volumes, and networks by communicating directly with the Docker daemon via `/var/run/docker.sock`. This is the standard deployment method recommended by Portainer.

**Security note:** Access to the Docker socket is equivalent to root access on the host. This is why Portainer is protected behind Authentik OAuth — only authenticated, authorized users can reach the UI.

---

## 3. Port allocation

Portainer's default HTTP port is `9000`, which conflicts with Authentik (already bound to `127.0.0.1:9000`). Portainer is mapped to **port 9005** instead:

- Container port `9000` (Portainer HTTP) → Host `127.0.0.1:9005`
- Container port `9443` (Portainer HTTPS) → Not mapped (Nginx handles TLS)
- Container port `8000` (Edge Agent) → Not mapped (not used in this setup)

---

## 4. Docker Compose configuration

**File:** `/opt/infra/apps/portainer/compose.yml`

```yaml
services:
  portainer:
    image: portainer/portainer-ce:2.39.0
    container_name: portainer
    restart: unless-stopped
    ports:
      - "127.0.0.1:9005:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
```

**Key points:**
- Binds to `127.0.0.1:9005` only — not publicly accessible, only through Nginx
- Docker socket mounted read-write for full container management
- Named volume `portainer_data` for persistent settings, users, and state
- No external network needed — Nginx runs in host network mode and reaches `127.0.0.1` directly

### Start Portainer

```bash
cd /opt/infra/apps/portainer
docker compose up -d
```

### Verify

```bash
docker ps | grep portainer
curl -s http://127.0.0.1:9005/ | head -5
```

---

## 5. Nginx virtual host config

**File:** `/opt/infra/proxy/nginx/conf.d/portainer.marin.cr.conf`

```nginx
# portainer.marin.cr
# - HTTP: ACME challenge + redirect to HTTPS
# - HTTPS: reverse proxy to Portainer (host:9005)
# - Auth: OAuth2/OIDC via Authentik (configured in Portainer settings)

server {
    listen 80;
    listen [::]:80;

    server_name portainer.marin.cr;

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

    server_name portainer.marin.cr;

    ssl_certificate     /etc/letsencrypt/live/portainer.marin.cr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/portainer.marin.cr/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:9005;

        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support (required for Portainer terminal and logs)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 600;
        proxy_send_timeout 600;
    }
}
```

**Notes:**
- No Authentik forward auth in Nginx — authentication is handled natively by Portainer via OAuth2/OIDC
- WebSocket support is required for Portainer's container console (exec) and log streaming features
- Follows the same pattern as `n8n.marin.cr.conf` and `pgadmin.marin.cr.conf`

### Apply config

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

---

## 6. TLS certificate (Let's Encrypt)

### Prerequisites

DNS A record for `portainer.marin.cr` must point to the VPS IP.

### Issue certificate

```bash
certbot certonly --webroot \
  --webroot-path=/opt/infra/proxy/webroot \
  -d portainer.marin.cr
```

### Copy to proxy directory

Since Nginx reads certs from `/opt/infra/proxy/letsencrypt/` (mounted as `/etc/letsencrypt` in the container), and certbot writes to `/etc/letsencrypt/` on the host, the cert files must be copied:

```bash
cp -rL /etc/letsencrypt/archive/portainer.marin.cr /opt/infra/proxy/letsencrypt/archive/

mkdir -p /opt/infra/proxy/letsencrypt/live/portainer.marin.cr

ln -sf ../../archive/portainer.marin.cr/cert1.pem /opt/infra/proxy/letsencrypt/live/portainer.marin.cr/cert.pem
ln -sf ../../archive/portainer.marin.cr/chain1.pem /opt/infra/proxy/letsencrypt/live/portainer.marin.cr/chain.pem
ln -sf ../../archive/portainer.marin.cr/fullchain1.pem /opt/infra/proxy/letsencrypt/live/portainer.marin.cr/fullchain.pem
ln -sf ../../archive/portainer.marin.cr/privkey1.pem /opt/infra/proxy/letsencrypt/live/portainer.marin.cr/privkey.pem

cp /etc/letsencrypt/renewal/portainer.marin.cr.conf /opt/infra/proxy/letsencrypt/renewal/
```

The existing `renew-all-certs.sh` cron job handles automatic renewal.

---

## 7. Initial Portainer setup (browser)

1. Open `https://portainer.marin.cr` in a browser
2. Create the initial **admin user** (username + password)
3. Click **"Get Started"** to connect to the local Docker environment
4. Portainer will auto-detect the Docker socket and show all running containers

**Important:** Complete this step promptly after starting Portainer. If you wait too long (several minutes), Portainer will disable the initial setup for security reasons and you'll need to restart the container:

```bash
cd /opt/infra/apps/portainer
docker compose restart
```

---

## 8. Authentik OAuth2/OIDC configuration

Authentication is handled via OAuth2/OIDC between Portainer and Authentik. This is configured in two places: Authentik admin UI and Portainer settings.

### 8.1 Configure Authentik (admin UI at auth.marin.cr)

Open `https://auth.marin.cr/if/admin/`

#### Create Application & Provider

1. Navigate to **Applications > Applications**
2. Click **"Create with Provider"**
3. Fill in:
   - **Name:** `Portainer`
   - **Slug:** `portainer`
   - **Provider type:** `OAuth2/OpenID Connect`
4. On the provider configuration page:
   - **Authorization flow:** Use the default available flow
   - **Redirect URI:** `https://portainer.marin.cr/` (strict mode)
   - **Signing Key:** Select any available signing key
5. Save
6. **Note down the Client ID and Client Secret** — you'll need them for Portainer configuration

#### Access control (optional)

1. Go to **Directory > Groups** and create a group (e.g., `portainer-admins`)
2. Add authorized users to the group
3. In **Applications > Applications > Portainer**, go to the **Policy / Group / User Bindings** tab
4. Bind the `portainer-admins` group to the application

Once a group binding exists, only members of that group can authenticate via OAuth to Portainer.

### 8.2 Configure Portainer OAuth (Portainer UI)

1. Log into Portainer at `https://portainer.marin.cr` with the admin account
2. Navigate to **Settings > Authentication**
3. Select **OAuth** as the authentication method
4. Set **Provider** to **Custom**
5. Fill in the following fields:

| Field | Value |
|-------|-------|
| **Client ID** | *(from Authentik provider, step 8.1)* |
| **Client Secret** | *(from Authentik provider, step 8.1)* |
| **Authorization URL** | `https://auth.marin.cr/application/o/authorize/` |
| **Access Token URL** | `https://auth.marin.cr/application/o/token/` |
| **Resource URL** | `https://auth.marin.cr/application/o/userinfo/` |
| **Redirect URL** | `https://portainer.marin.cr/` |
| **Logout URL** | `https://auth.marin.cr/application/o/portainer/end-session/` |
| **User Identifier** | `preferred_username` |
| **Scopes** | `email openid profile` |

**Important:** The Scopes field must use **spaces** between values, NOT commas. Portainer's UI may show commas by default — delete the commas and use spaces instead.

6. Click **Save settings**

### 8.3 Verify OAuth login

1. Open an incognito/private browser window
2. Navigate to `https://portainer.marin.cr`
3. Click **"Login with OAuth"**
4. You should be redirected to `https://auth.marin.cr` for login
5. After authenticating, you should be redirected back to the Portainer dashboard

---

### 8.4 OAuth user permissions

When a user first logs in via OAuth, Portainer creates a new user account with **no permissions** by default. This means the OAuth login flow will complete successfully but the user will see "unauthorized" when trying to access environments.

To fix this, log into Portainer with the **local admin account** (not OAuth):

1. Go to **Users** in the left sidebar
2. Find the OAuth user that was created
3. Change their role to **Administrator**

Alternatively, in **Settings > Authentication**, you can configure automatic role assignment for new OAuth users.

---

## 9. Troubleshooting

### Portainer initial setup expired

If you see a message that the admin user setup has timed out:

```bash
cd /opt/infra/apps/portainer
docker compose restart
```

Then immediately open `https://portainer.marin.cr` and create the admin user.

### OAuth login completes but returns "unauthorized"

This happens when the OAuth user exists in Portainer but has no role/permissions assigned. See section 8.4 above — log in with the local admin account and promote the OAuth user to Administrator.

### Podman misdetection bug (version-specific)

Portainer 2.27.4 (and possibly nearby versions) has a bug where it incorrectly detects the Docker environment as Podman, causing the error: *"the Podman environment option doesn't support Docker environments"*. The local environment shows as "up" in the list but clicking it shows "unreachable" and then flips to "down".

**Fix:** Upgrade to Portainer 2.39.0 or later. Reset the data volume when upgrading:

```bash
cd /opt/infra/apps/portainer
docker compose down
docker volume rm portainer_portainer_data
# Update image tag in compose.yml
docker compose up -d
```

### OAuth redirect loop or error

1. Verify the **Redirect URI** in Authentik matches exactly: `https://portainer.marin.cr/`
2. Check the **Scopes** field uses spaces, not commas: `email openid profile`
3. Ensure the Authentik application slug is `portainer` (used in URL paths)
4. Check Authentik logs:

```bash
docker logs --tail 50 infra-authentik-server
```

### WebSocket errors (container console not working)

Verify the Nginx config includes WebSocket headers:

```bash
docker exec proxy-nginx cat /etc/nginx/conf.d/portainer.marin.cr.conf | grep -A2 WebSocket
```

### Container not starting

```bash
docker logs --tail 50 portainer
```

Common issue: Docker socket permissions. Verify:

```bash
ls -la /var/run/docker.sock
```

Should show `srw-rw----` owned by `root:docker`.

### Nginx not loading cert

If Nginx fails with "cannot load certificate":

1. Verify cert exists in the proxy directory:

```bash
ls -la /opt/infra/proxy/letsencrypt/live/portainer.marin.cr/
```

2. Verify symlinks point to valid files:

```bash
readlink -f /opt/infra/proxy/letsencrypt/live/portainer.marin.cr/fullchain.pem
```

---

## 10. Security notes

### Docker socket access

Mounting the Docker socket (`/var/run/docker.sock`) gives Portainer full control over the Docker daemon, which is equivalent to root access on the host. This is the intended and standard deployment method for Portainer.

**Mitigations:**
- Portainer is only accessible through the Nginx reverse proxy (bound to `127.0.0.1`)
- Authentication via Authentik OAuth restricts who can log in
- Optional group-based access control in Authentik further limits access
- Portainer has its own role-based access control for fine-grained permissions

### OAuth vs forward auth

This setup uses **OAuth2/OIDC** (native Portainer integration) rather than **forward auth** (as used for Cockpit). The key differences:

| Aspect | OAuth2/OIDC (Portainer) | Forward Auth (Cockpit) |
|--------|------------------------|----------------------|
| Login steps | Single (Authentik SSO) | Double (Authentik SSO + Cockpit login) |
| Nginx config | No auth directives | `auth_request` + snippet |
| User management | Authentik creates Portainer users on first login | Separate Linux users needed |
| Session handling | Portainer manages its own sessions via OAuth tokens | Authentik cookie checked on every request |
| Official support | Yes (documented integration) | No (generic forward auth) |

### TLS

All traffic between the browser and Nginx is encrypted via TLS (Let's Encrypt). Traffic between Nginx and Portainer is unencrypted HTTP on localhost — this is acceptable because it never leaves the host network stack.

---

## 11. Maintenance

### Update Portainer

Edit `/opt/infra/apps/portainer/compose.yml` and change the image tag, then:

```bash
cd /opt/infra/apps/portainer
docker compose pull
docker compose up -d
```

### Backup

Portainer data is stored in the named volume `portainer_portainer_data`. To back up:

```bash
docker run --rm -v portainer_portainer_data:/data -v /tmp:/backup alpine tar czf /backup/portainer-backup.tar.gz -C /data .
```

### Logs

```bash
docker logs --tail 100 portainer
docker logs --tail 100 proxy-nginx
```
