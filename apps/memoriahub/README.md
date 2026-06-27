# MemoriaHub

Production deployment of [MemoriaHub](https://github.com/marinoscar/MemoriaHub)
(NestJS + React + Prisma media-management app) on the `/opt/infra` VPS, served at
**https://memoriahub.marin.cr** via the shared Nginx proxy (internal port
`127.0.0.1:8328`). The database is the VPS PostgreSQL at `pgadmin.marin.cr`
(SSL); object storage is S3/R2.

## Commands

```bash
cd /opt/infra/apps/memoriahub

# Install or update — auto-detects which is needed
./install-memoriahub.sh        # first run: clones, .env wizard, build, migrate+seed, start
                               # later runs: delegates to update.sh

# Update directly
./update.sh                    # pull, rebuild, migrate, restart, reload proxy
./update.sh --no-cache         # force a full rebuild
```

On a first run with no `.env`, `install-memoriahub.sh` launches an interactive
wizard that collects the required values, writes `.env`, and validates them
(live Postgres connect test, S3 bucket check, secret-length checks) before
building anything.

## Files

| File | Purpose |
|------|---------|
| `install-memoriahub.sh` | Smart entry point — installs or updates (auto-detected) |
| `update.sh` | Pull / rebuild / migrate / restart / reload proxy |
| `compose.yml` | Generated production compose (nginx + api + web) |
| `memoriahub.conf` | Generated VPS reverse-proxy config for `memoriahub.marin.cr` |
| `DEPLOY.md` | Full runbook: prerequisites, steps, **how it works**, troubleshooting |

See **[DEPLOY.md](./DEPLOY.md)** for prerequisites, the install-vs-update decision
tree, the `.env` wizard walkthrough, the validation reference, and
troubleshooting.
