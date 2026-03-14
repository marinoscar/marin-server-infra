# CrowdSec Intrusion Detection & Prevention

This document explains **what CrowdSec is**, **how it protects this server**, and **how to operate it**.

CrowdSec runs on the **host** (not in Docker), following the same pattern as Cockpit. There is no self-hosted web UI — management is via the `cscli` command line, with an optional cloud dashboard at https://app.crowdsec.net.

---

## 1. What is CrowdSec?

CrowdSec is an open-source security tool that:

1. **Reads log files** (SSH, Nginx, system logs) in real time
2. **Detects malicious behavior** by matching log patterns against known attack scenarios (brute force, SQL injection, path traversal, CVE exploits, etc.)
3. **Bans the attacker's IP address** by adding it to an iptables blocklist, so the attacker's traffic is dropped at the network level before it even reaches your applications

Think of it as a modern replacement for fail2ban, with two key advantages:

- **Much broader detection** — CrowdSec ships with 50+ attack scenarios out of the box (fail2ban typically only handles SSH brute force)
- **Community threat intelligence** — CrowdSec users worldwide share information about attacking IPs. When another CrowdSec user detects an attacker, that IP can be pre-emptively blocked on your server before it ever attacks you

### How it differs from a firewall (UFW)

UFW controls **which ports are open**. CrowdSec controls **which IPs are allowed to connect to those ports**. They work together:

- UFW says: "Only allow traffic on ports 22, 80, 443, 5432"
- CrowdSec says: "Block IP 91.202.233.33 from connecting to ANY port because it was caught brute-forcing SSH"

CrowdSec's iptables rules are evaluated **before** UFW's rules, so banned IPs are dropped before UFW even sees them.

---

## 2. Architecture

### Three components

CrowdSec has three parts that work together on this server:

```
┌─────────────────────────────────────────────────────────────┐
│                        HOST (Ubuntu VPS)                     │
│                                                              │
│  ┌──────────────────────┐                                    │
│  │   CrowdSec Agent     │  Reads log files:                  │
│  │   (crowdsec.service) │  • /var/log/auth.log (SSH)         │
│  │                      │  • /opt/infra/proxy/nginx/logs/    │
│  │   Includes LAPI      │  • journald/syslog                 │
│  │   (127.0.0.1:8080)   │                                    │
│  └──────────┬───────────┘                                    │
│             │ "Ban IP 1.2.3.4 for 4 hours"                   │
│             ▼                                                │
│  ┌──────────────────────────┐                                │
│  │   Firewall Bouncer       │  Translates ban decisions      │
│  │   (crowdsec-firewall-    │  into iptables rules via       │
│  │    bouncer.service)      │  ipset blocklists              │
│  └──────────┬───────────────┘                                │
│             │                                                │
│             ▼                                                │
│  ┌──────────────────────────┐                                │
│  │   iptables / ipset       │  Drops packets from banned IPs │
│  │   (kernel level)         │  before they reach anything    │
│  └──────────────────────────┘                                │
└──────────────────────────────────────────────────────────────┘
```

**1. Agent + LAPI** (`crowdsec.service`)
- The **Agent** continuously reads log files and compares each line against known attack patterns (called "scenarios")
- When a pattern matches (e.g., 5 failed SSH logins from the same IP in 30 seconds), the agent creates an **alert** and a **decision** (usually "ban this IP for 4 hours")
- The **LAPI** (Local API) is the internal database that stores all alerts and decisions. It listens on `127.0.0.1:8080` (localhost only, not exposed to the internet)

**2. Firewall Bouncer** (`crowdsec-firewall-bouncer.service`)
- Periodically asks the LAPI: "Give me the current list of banned IPs"
- Maintains an iptables ipset (a high-performance IP blocklist in the Linux kernel)
- When the LAPI says "ban 1.2.3.4", the bouncer adds it to the ipset
- When the ban expires, the bouncer removes it
- All traffic from banned IPs is silently dropped — the attacker gets no response at all

**3. CrowdSec Console** (optional, cloud-hosted)
- Web dashboard at https://app.crowdsec.net
- Shows alerts, decisions, and metrics in a browser
- Provides access to community blocklists
- This server is enrolled and reporting to the console

### Why host-level (not Docker)

CrowdSec runs directly on the host (installed via `apt`) rather than in a Docker container because:

- The **firewall bouncer** needs direct access to iptables/nftables to block IPs — this cannot work from inside a container
- The agent needs to read `/var/log/auth.log` (SSH logs) and journald — mounting these into a container adds complexity with no benefit
- On a single VPS, containerization would add operational overhead for zero advantage
- This follows the same pattern as **Cockpit** (host service, not Docker)

Configuration lives in `/etc/crowdsec/` (system path), similar to how UFW config lives in `/etc/ufw/`.

---

## 3. What is protected

### Complete request lifecycle

When someone connects to this server, here is what happens:

```
Attacker (1.2.3.4) tries to connect
        │
        ▼
   ┌─────────────────────┐
   │ iptables             │ Is 1.2.3.4 in the CrowdSec ipset?
   │ (CROWDSEC_CHAIN)     │──── YES → DROP (connection silently refused)
   └──────────┬──────────┘
              │ NO
              ▼
   ┌─────────────────────┐
   │ UFW                  │ Is this port allowed?
   └──────────┬──────────┘
              │ YES
              ▼
   ┌─────────────────────┐
   │ Nginx / SSH / Postgres│ Request is served
   └──────────┬──────────┘
              │ (logs are written)
              ▼
   ┌─────────────────────┐
   │ CrowdSec Agent       │ Reads log, detects attack pattern
   │                      │──── Match found → BAN 1.2.3.4
   └─────────────────────┘     (added to ipset, future requests dropped)
```

### What is monitored

| Attack surface | Log file | What CrowdSec detects |
|---|---|---|
| **SSH** (port 22) | `/var/log/auth.log` | Brute force login attempts (fast and slow), password spraying |
| **All web apps** (ports 80/443) | `/opt/infra/proxy/nginx/logs/access.log` | SQL injection probing, XSS attempts, path traversal (`../../etc/passwd`), sensitive file access (`.env`, `.git`), WordPress scanning, bad user agents, aggressive crawling, known CVE exploit attempts |
| **All web apps** (ports 80/443) | `/opt/infra/proxy/nginx/logs/error.log` | Server errors caused by attack attempts |
| **PostgreSQL** (port 5432) | Covered at IP level | If an IP is banned for attacking SSH or HTTP, it is also blocked from reaching PostgreSQL |
| **System** | journald/syslog | OS-level security events |

### Installed detection collections

Collections are bundles of parsers (log readers) and scenarios (attack patterns):

| Collection | What it detects | Examples |
|---|---|---|
| `crowdsecurity/sshd` | SSH attacks | Failed password attempts, brute force (fast: many attempts in seconds, slow: spread over minutes) |
| `crowdsecurity/nginx` | Nginx log parsing | Enables all HTTP-based detection below |
| `crowdsecurity/base-http-scenarios` | Common web attacks | SQL injection probing, XSS attempts, path traversal, sensitive file access (`.env`, `.git`, `wp-config.php`), bad user agents, admin panel probing, open proxy abuse |
| `crowdsecurity/http-cve` | Known exploit attempts | Log4j (CVE-2021-44228), Spring4Shell, Fortinet VPN exploits, Grafana path traversal, dozens of other CVEs |
| `crowdsecurity/linux` | OS-level threats | Suspicious system activity |
| `crowdsecurity/whitelist-good-actors` | False positive prevention | Whitelists known good bots (Googlebot, Bingbot, etc.) so they are not accidentally banned |

---

## 4. How Nginx logs reach CrowdSec

By default, the `nginx:1.27-alpine` Docker image sends logs to stdout/stderr (visible via `docker logs`). CrowdSec cannot read Docker stdout — it needs actual log files on the host filesystem.

### What was changed

**1. Custom `nginx.conf`** mounted into the container:

File: `/opt/infra/proxy/nginx/nginx.conf` (exact copy of the stock nginx config — no functional changes)

Mount in `compose.yml`:
```yaml
- ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
```

**2. Log directory** bind-mounted from host into the container:

```yaml
- ./nginx/logs:/var/log/nginx
```

This replaces Docker's default symlinks (`/var/log/nginx/access.log → /dev/stdout`) with actual files on the host at `/opt/infra/proxy/nginx/logs/`.

**3. CrowdSec acquisition config** tells the agent where to find these logs:

File: `/etc/crowdsec/acquis.d/nginx.yaml`
```yaml
filenames:
  - /opt/infra/proxy/nginx/logs/access.log
  - /opt/infra/proxy/nginx/logs/error.log
labels:
  type: nginx
```

**4. Log rotation** prevents log files from growing forever:

File: `/etc/logrotate.d/nginx-proxy`
```
/opt/infra/proxy/nginx/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        docker exec proxy-nginx nginx -s reopen
    endscript
}
```

Logs are rotated daily and kept for 14 days. After rotation, Nginx is told to reopen its log files so it writes to the new file.

### Important behavior change

`docker logs proxy-nginx` **no longer shows access/error log lines** — only Nginx startup messages. To view access logs:

```bash
tail -f /opt/infra/proxy/nginx/logs/access.log
```

---

## 5. Operational commands

All commands run as root.

### Viewing current state

```bash
# What IPs are currently banned?
cscli decisions list

# What attacks have been detected?
cscli alerts list

# How many logs are being processed? Are scenarios firing?
cscli metrics

# Are services running?
systemctl status crowdsec
systemctl status crowdsec-firewall-bouncer
```

### Manual banning and unbanning

```bash
# Ban a specific IP for 24 hours
cscli decisions add --ip 1.2.3.4 --reason "manual ban" --duration 24h

# Ban an entire subnet
cscli decisions add --range 1.2.3.0/24 --reason "abusive network" --duration 48h

# Unban a specific IP
cscli decisions delete --ip 1.2.3.4

# Unban all IPs (clear all decisions)
cscli decisions delete --all
```

### Viewing logs

```bash
# Follow CrowdSec agent logs in real time
journalctl -u crowdsec -f

# Follow firewall bouncer logs
journalctl -u crowdsec-firewall-bouncer -f

# View Nginx access logs (what CrowdSec reads)
tail -f /opt/infra/proxy/nginx/logs/access.log
```

### Inspecting the iptables blocklist

```bash
# Confirm CrowdSec chain exists in iptables
iptables -L -n | grep -i crowdsec

# View all currently blocked IPs with their timeout
ipset list crowdsec-blacklists-0
```

### Listing installed detection rules

```bash
# Collections (bundles of parsers + scenarios)
cscli collections list

# Individual attack scenarios
cscli scenarios list

# Log parsers
cscli parsers list
```

---

## 6. CrowdSec Console (cloud dashboard)

This server is enrolled in the CrowdSec Console at https://app.crowdsec.net. There is no self-hosted web UI — CrowdSec is managed via the `cscli` command line on the server, and the console provides a cloud-based dashboard for visibility and blocklist management.

### What the console provides

- **Alerts tab** — visual view of all detected attacks, with geolocation, AS information, and attack type. These are informational — by the time you see them, CrowdSec has already banned the attacker
- **Decisions tab** — which IPs are currently banned and why. Shows both local decisions (from your server's detection) and community blocklist decisions
- **Blocklists** — subscribe to community-shared threat intelligence. When another CrowdSec user anywhere in the world detects an attacker, that IP can be pre-emptively blocked on your server before it ever attacks you
- **Security Engines** — confirms your CrowdSec agent is online and reporting

### How the two-way sync works

CrowdSec has several console features that control what data flows between your server and the cloud:

| Feature | Direction | What it does |
|---|---|---|
| `custom` | Server → Console | Forwards alerts from custom scenarios |
| `manual` | Server → Console | Forwards manually created decisions (`cscli decisions add`) |
| `tainted` | Server → Console | Forwards alerts from modified/tainted scenarios |
| `context` | Server → Console | Forwards additional context (HTTP headers, etc.) with alerts |
| `console_management` | Console → Server | **Receives decisions from the console** (community blocklists) |

All five features are enabled on this server. The critical one is `console_management` — without it, the Decisions tab in the console shows "No Security Engine or Integration Installed" and community blocklists are not enforced.

To check the current status:
```bash
cscli console status
```

All options should show ✅. If `console_management` ever gets disabled:
```bash
cscli console enable console_management
systemctl reload crowdsec
```

### Blocklists

To subscribe to community blocklists:

1. Log in to https://app.crowdsec.net
2. Go to **Blocklists**
3. Browse available lists and click **Subscribe**
4. Select your security engine and confirm

Once subscribed, your server automatically downloads the blocklist and the firewall bouncer enforces it via iptables. Blocklisted IPs are blocked from all ports (SSH, HTTP, PostgreSQL, etc.) — the same as locally-detected bans.

### Enrollment details

The server was enrolled with:

```bash
cscli console enroll cmmpyf9e3000302l4ze6wj9pr
```

After enrollment, the instance was accepted in the console web UI, `console_management` was enabled, and CrowdSec was restarted.

### Re-enrollment (if needed)

If the enrollment is lost (e.g., after reinstalling CrowdSec):

1. Log in to https://app.crowdsec.net
2. Go to **Settings > Enrollment Keys**
3. Copy the enrollment key
4. Run: `cscli console enroll <key>`
5. Accept the instance in the console
6. Enable console management: `cscli console enable console_management`
7. Restart: `systemctl restart crowdsec`

---

## 7. UFW coexistence

CrowdSec and UFW both use iptables, but they do not conflict:

- The CrowdSec firewall bouncer creates its own chain (`CROWDSEC_CHAIN`) in iptables
- This chain is inserted at the **top** of the INPUT chain, **before** UFW's rules
- Evaluation order: CrowdSec → UFW → application

This means:
- If CrowdSec bans an IP, that IP is blocked from **all** ports (SSH, HTTP, PostgreSQL, everything)
- UFW continues to control which ports are open for non-banned IPs
- No configuration changes were needed to either CrowdSec or UFW

---

## 8. Configuration files reference

### Host-level files (not in Git)

| File | Purpose |
|---|---|
| `/etc/crowdsec/config.yaml` | Main CrowdSec configuration |
| `/etc/crowdsec/acquis.yaml` | Default log acquisition sources (SSH, syslog) |
| `/etc/crowdsec/acquis.d/nginx.yaml` | Nginx log acquisition (added during setup) |
| `/etc/crowdsec/scenarios/` | Enabled attack detection scenarios |
| `/etc/crowdsec/parsers/` | Enabled log parsers |
| `/etc/crowdsec/collections/` | Enabled collections (bundles of parsers + scenarios) |
| `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` | Firewall bouncer configuration |
| `/var/lib/crowdsec/data/` | CrowdSec database (alerts, decisions, GeoIP data) |
| `/etc/logrotate.d/nginx-proxy` | Log rotation for Nginx log files |

### Infrastructure files (in Git)

| File | Purpose |
|---|---|
| `/opt/infra/proxy/compose.yml` | Nginx compose with log volume mounts |
| `/opt/infra/proxy/nginx/nginx.conf` | Custom Nginx main config (enables file-based logging) |
| `/opt/infra/proxy/nginx/logs/` | Nginx log files (excluded from Git via `.gitignore`) |

---

## 9. Upgrading

### Update CrowdSec packages

```bash
apt update
apt upgrade crowdsec crowdsec-firewall-bouncer-iptables
```

### Update detection scenarios (without upgrading the package)

```bash
cscli hub update
cscli hub upgrade
systemctl restart crowdsec
```

This downloads the latest attack patterns from the CrowdSec hub. It is safe to run at any time.

---

## 10. Troubleshooting

### CrowdSec not detecting attacks

```bash
# Check if log sources are being read
cscli metrics
# Look for the "Acquisition Metrics" table — each log file should show lines read/parsed

# Verify log files exist and are being written to
ls -la /opt/infra/proxy/nginx/logs/
tail -5 /opt/infra/proxy/nginx/logs/access.log

# Check CrowdSec logs for errors
journalctl -u crowdsec --no-pager -n 50
```

### Firewall bouncer not blocking banned IPs

```bash
# Is the bouncer running?
systemctl status crowdsec-firewall-bouncer

# Is the bouncer registered with the LAPI?
cscli bouncers list
# Should show one entry with Valid: ✔️

# Are there any decisions to enforce?
cscli decisions list

# Is the ipset populated?
ipset list crowdsec-blacklists-0

# Does the iptables chain exist?
iptables -L CROWDSEC_CHAIN -n
```

### Services not starting after reboot

```bash
# Clear failed state and restart
systemctl reset-failed crowdsec
systemctl restart crowdsec

systemctl reset-failed crowdsec-firewall-bouncer
systemctl restart crowdsec-firewall-bouncer
```

### LAPI not responding

```bash
# Is it listening?
ss -tlnp | grep 8080

# Check agent logs
journalctl -u crowdsec --no-pager -n 50
```

### A legitimate user/IP was accidentally banned

```bash
# Unban the IP immediately
cscli decisions delete --ip X.X.X.X

# To prevent future false positives, whitelist the IP
# Create or edit /etc/crowdsec/parsers/s02-enrich/my-whitelists.yaml
```

### Nginx logs not appearing

```bash
# Is the container running?
docker ps | grep proxy-nginx

# Is the log directory mounted?
docker inspect proxy-nginx | grep -A5 "nginx/logs"

# Generate test traffic and check
curl -s https://app.marin.cr > /dev/null
tail -1 /opt/infra/proxy/nginx/logs/access.log
```

---

## 11. What is NOT covered (intentionally)

| Feature | Why it is skipped |
|---|---|
| **Nginx bouncer / WAF** | Would require switching the Nginx Docker image from `nginx:1.27-alpine` to OpenResty (for Lua module support). The firewall bouncer already blocks at the iptables level, which is a stronger position — traffic is dropped before it even reaches Nginx. |
| **Per-app container log monitoring** | All HTTP traffic goes through Nginx first, where it is already analyzed. Monitoring individual container logs would add complexity with little additional detection value. |
| **PostgreSQL-specific log parsing** | Can be added later with `cscli collections install crowdsecurity/postgres` if needed. Currently, PostgreSQL is protected at the IP level — any IP banned for SSH or HTTP attacks is also blocked from reaching port 5432. |

---

## 12. Installation steps performed

These steps are documented for reproducibility. All commands were run as root.

### Step 1: Expose Nginx logs to host filesystem

```bash
mkdir -p /opt/infra/proxy/nginx/logs
```

Created `/opt/infra/proxy/nginx/nginx.conf` (exact copy of stock `nginx:1.27-alpine` config).

Updated `/opt/infra/proxy/compose.yml` to add two volume mounts:
```yaml
- ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
- ./nginx/logs:/var/log/nginx
```

Added `proxy/nginx/logs/` to `/opt/infra/.gitignore`.

Recreated the container:
```bash
cd /opt/infra/proxy
docker compose up -d
```

Verified:
```bash
docker exec proxy-nginx nginx -t
curl -I https://app.marin.cr
tail /opt/infra/proxy/nginx/logs/access.log
```

### Step 2: Install CrowdSec

```bash
curl -s https://install.crowdsec.net | bash
DEBIAN_FRONTEND=noninteractive apt install -y crowdsec
```

Verified:
```bash
systemctl status crowdsec
cscli version
ss -tlnp | grep 8080
```

### Step 3: Configure Nginx log monitoring

```bash
cscli collections install crowdsecurity/nginx
```

Created `/etc/crowdsec/acquis.d/nginx.yaml`:
```yaml
filenames:
  - /opt/infra/proxy/nginx/logs/access.log
  - /opt/infra/proxy/nginx/logs/error.log
labels:
  type: nginx
```

```bash
systemctl restart crowdsec
```

Verified:
```bash
cscli metrics
# Confirmed nginx log file appears in acquisition metrics
```

### Step 4: Install firewall bouncer

```bash
DEBIAN_FRONTEND=noninteractive apt install -y crowdsec-firewall-bouncer-iptables
```

Verified:
```bash
systemctl status crowdsec-firewall-bouncer
cscli bouncers list
iptables -L -n | grep -i crowdsec
```

### Step 5: Enroll in CrowdSec Console

```bash
cscli console enroll cmmpyf9e3000302l4ze6wj9pr
```

Accepted the instance at https://app.crowdsec.net.

### Step 6: Enable console management (two-way sync)

By default, enrollment only sends alerts **to** the console. To also **receive** community blocklist decisions from the console:

```bash
cscli console enable console_management
systemctl reload crowdsec
```

Verified:
```bash
cscli console status
# All five options should show ✅
```

Without this step, the Decisions tab in the console shows "No Security Engine or Integration Installed" and community blocklists are not enforced on the server.

### Step 7: Log rotation

Created `/etc/logrotate.d/nginx-proxy`:
```
/opt/infra/proxy/nginx/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        docker exec proxy-nginx nginx -s reopen
    endscript
}
```
