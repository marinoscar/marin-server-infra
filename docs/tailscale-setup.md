# Tailscale VPN Setup (Host-Level)

This document captures the setup of **Tailscale** on the Ubuntu VPS host. Tailscale provides a mesh VPN (based on WireGuard) that connects this server to other devices on the same tailnet, enabling secure private networking without opening additional public ports.

---

## 1. High-level architecture

**What runs where**

- **Tailscale**: installed on the **host OS** (systemd service)
- **Not containerized**: runs at the host level so all containers can reach tailnet IPs (100.x.x.x) directly

**Why host-level (not Docker)**

Tailscale manages a network interface (`tailscale0`) and routing table entries. Running it on the host means:
- All Docker containers (especially those using `network_mode: host`) can reach tailnet devices natively
- No privileged containers or complex Docker networking required
- Survives container restarts and recompositions

**Tailnet details**

| Property | Value |
|----------|-------|
| Hostname | `prod-server` |
| Tailnet domain | `tail60c35d.ts.net` |
| FQDN | `prod-server.tail60c35d.ts.net` |

---

## 2. Installation

Tailscale was installed using the official install script, which adds the Tailscale apt repository and installs the package:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

This installs:
- `tailscaled` — the background daemon (systemd service)
- `tailscale` — the CLI tool for status, configuration, and authentication

---

## 3. Authentication

After installation, the node was authenticated and joined to the tailnet:

```bash
tailscale up
```

This prints a URL to open in a browser for SSO authentication. Once approved in the Tailscale admin console, the node appears on the tailnet.

---

## 4. Service configuration

The Tailscale daemon runs as a systemd service and is **enabled** (starts on boot) and **active**:

```bash
# Check service status
systemctl is-enabled tailscaled   # → enabled
systemctl is-active tailscaled    # → active

# Full status
systemctl status tailscaled
```

State is persisted at `/var/lib/tailscale/tailscaled.state`.

---

## 5. Useful commands

```bash
# Check tailnet status and connected peers
tailscale status

# Show this node's tailnet IP
tailscale ip

# Check connectivity to a specific peer
tailscale ping <peer-hostname>

# Bring the connection up/down
tailscale up
tailscale down

# View daemon logs
journalctl -u tailscaled --no-pager --since "1 hour ago"
```

---

## 6. Firewall notes

Tailscale uses WireGuard under the hood and handles its own NAT traversal (UDP hole-punching). No additional UFW rules were needed — Tailscale traffic works over the existing outbound-allow policy.

The tailnet IP (100.x.x.x) assigned to this node is only reachable from other devices on the same tailnet, not from the public internet.

---

## 7. Intended use

Tailscale on this server enables **Apache Guacamole** (to be deployed as a Docker container) to reach devices on the operator's home network via tailnet IPs. The traffic flow will be:

```
Browser → https://guac.marin.cr → Nginx → Guacamole (container)
                                              ↓
                                     Tailscale (host) → 100.x.x.x home devices
                                              (RDP/VNC/SSH)
```

This avoids exposing home network devices to the public internet.
