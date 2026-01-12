# MarinApp — Server Setup & Deployment

This document describes how to install and run **MarinApp** on the Ubuntu VPS using the existing `/opt/infra` infrastructure model.

It follows the same conventions as the rest of this repository:

* Root-operated server
* Docker Compose per app
* Nginx reverse proxy (Docker)
* No secrets committed to Git
* Deterministic, repeatable steps

This file is intended to be a **knowledge base / runbook** you can reuse or hand to an AI agent without additional context.

---

## 1. Prerequisites

Before installing MarinApp, the following must already be in place:

* Ubuntu VPS with `/opt/infra` initialized
* Docker + Docker Compose installed
* Shared Docker network `proxy` created
* Nginx reverse proxy running from `/opt/infra/proxy`
* Valid DNS records:

  * `app.marin.cr` → VPS IP
  * `api.marin.cr` → VPS IP
* SSL certificates already issued via Let’s Encrypt

If any of the above is missing, complete the base server and proxy setup first.

---

## 2. Directory Layout

MarinApp lives under:

```
/opt/infra/apps/marinapp
```

After installation, the structure looks like:

```
/opt/infra/apps/marinapp
├── .env                    # Root env file (NOT committed)
├── compose.yml              # Docker Compose file
├── install-marinapp.sh      # Installer script
└── src/                     # Application source code
    └── apps/
        ├── web/             # Frontend (Vite / SPA)
        │   └── .env -> ../../.env (symlink)
        └── api/             # Backend API
```

Key points:

* **`.env` lives at the app root** and is shared
* The web app uses a **symlink** to the root `.env`
* `src/` is fully replaceable and can be reinstalled safely

---

## 3. Environment File

Before running the installer, create the root `.env` file:

```bash
nano /opt/infra/apps/marinapp/.env
```

This file contains all runtime configuration (API keys, DB strings, OAuth config, etc.).

⚠️ **Never commit this file to Git.**

---

## 4. Install Script

### 4.1 Make the installer executable

From the app directory:

```bash
cd /opt/infra/apps/marinapp
chmod +x install-marinapp.sh
```

---

### 4.2 What `install-marinapp.sh` does

The installer is intentionally simple and transparent. It performs the following steps in order:

1. **Ensures the app root exists**

   * Creates `/opt/infra/apps/marinapp` if missing

2. **Downloads the latest source code**

   * Fetches `main.zip` from the MarinApp GitHub repository

3. **Removes any existing source tree**

   * Deletes the current `src/` directory (safe, reproducible)

4. **Extracts the repository**

   * Unzips the archive
   * Renames `MarinApp-main` → `src`

5. **Cleans up temporary files**

   * Deletes the downloaded zip

6. **Creates a web `.env` symlink**

   * Links:

     ```
     src/apps/web/.env → /opt/infra/apps/marinapp/.env
     ```
   * This ensures a single source of truth for configuration

7. **Stops on errors**

   * `set -euo pipefail` guarantees partial installs do not continue

The script does **not**:

* Start containers
* Modify Docker or Nginx
* Touch certificates

This separation is intentional.

---

### 4.3 Run the installer

```bash
cd /opt/infra/apps/marinapp
./install-marinapp.sh
```

After completion, verify:

```bash
ls -la src/
ls -la src/apps/web/.env
```

---

## 5. Docker Compose

Start (or rebuild) MarinApp using Docker Compose:

```bash
cd /opt/infra/apps/marinapp
docker compose up -d --build
```

Verify containers are running:

```bash
docker ps | grep marinapp
```

Expected containers:

* `marinapp-web`
* `marinapp-api`

---

## 6. Nginx Reverse Proxy Configuration

MarinApp is exposed through Nginx using **two hostnames**:

* `https://app.marin.cr` → Web UI
* `https://api.marin.cr` → API

The proxy configuration lives at:

```
/opt/infra/proxy/nginx/conf.d/marinapp.conf
```

Key characteristics of the configuration:

* HTTP → HTTPS redirect
* ACME challenge support on port 80
* HTTP/2 enabled
* Large file uploads supported (`client_max_body_size 5g`)
* API and Web routed to separate internal ports

After modifying Nginx config, always reload safely:

```bash
docker exec proxy-nginx nginx -t
docker exec proxy-nginx nginx -s reload
```

---

## 7. Important Note: Web Environment Variable Reload (Vite)

### Problem Encountered

After the initial installation, an issue was encountered where the **web project did not load environment variables**, even though:

* The root `.env` file existed
* The symbolic link `src/apps/web/.env → /opt/infra/apps/marinapp/.env` was correctly created

This can happen with **Vite-based projects**, because environment variables are **baked at build time**, not runtime. Simply restarting containers is **not sufficient** when environment variables change or when the symlink is created after the first build.

### Required Fix (Prominent – Do Not Skip)

Whenever you:

* Run `install-marinapp.sh`
* Change values in `/opt/infra/apps/marinapp/.env`
* Refresh or update the application source code

You **must** force a clean rebuild of the web container **with the environment exported**.

Run the following exactly:

```bash
cd /opt/infra/apps/marinapp

# Export variables from .env into the shell
set -a
. ./.env
set +a

# Force a clean rebuild of the web image
docker compose build --no-cache web

# Restart the stack
docker compose up -d
```

### Why this is necessary

* Vite reads environment variables **during build**, not at container startup
* Docker will happily reuse a cached image with stale variables
* The explicit `set -a` export ensures Docker sees the variables at build time

This step is **intentional, required, and expected** for MarinApp updates.

---

## 8. Validation Checklist

After deployment, verify:

### Web

* Open `https://app.marin.cr`
* TLS certificate is valid (Let’s Encrypt)
* UI loads without console errors

### API

```bash
curl -I https://api.marin.cr
```

* Returns `200` or expected API response

### Uploads

* Large file uploads work (multi‑GB supported)
* No `413 Request Entity Too Large` errors

---

## 8. Optional Operational Steps

### 8.1 Restart MarinApp containers

```bash
cd /opt/infra/apps/marinapp
docker compose restart
```

### 8.2 Restart Nginx (only if needed)

Normally **reload** is sufficient. Full restart is rarely required.

```bash
cd /opt/infra/proxy
docker compose restart
```

### 8.3 Reinstall application code

Safe and repeatable:

```bash
cd /opt/infra/apps/marinapp
./install-marinapp.sh
docker compose up -d --build
```

---

## 9. Design Notes

* Source code is **stateless** and replaceable
* Configuration is centralized in `.env`
* Docker images are rebuilt explicitly
* Nginx owns TLS and public exposure

This keeps upgrades, rollbacks, and debugging straightforward.

---

## 10. Summary

MarinApp follows the same infrastructure philosophy as the rest of this platform:

* Clear separation of concerns
* Minimal magic
* Explicit steps
* Git‑tracked configuration (without secrets)

This document is the authoritative reference for installing and operating MarinApp on the server.
