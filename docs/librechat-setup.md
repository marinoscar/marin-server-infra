# LibreChat Setup — `chat.marin.cr`

## Overview

LibreChat is an open-source AI chat interface supporting multiple providers (Anthropic, OpenAI, etc.). Users provide their own API keys. Files are stored in S3 (`marin-librechat` bucket). RAG (Retrieval-Augmented Generation) is enabled via pgvector.

## Architecture

```
chat.marin.cr (443) → Nginx → 127.0.0.1:3080 → LibreChat API container
```

Supporting services (internal network only):
- **MongoDB** — conversation and user data storage
- **MeiliSearch** — search indexing
- **pgvector (vectordb)** — RAG embeddings database
- **RAG API** — document processing for RAG

## File locations

```
/opt/infra/apps/librechat/
├── compose.yml          # Docker Compose definition
├── .env                 # Secrets and configuration (not committed)
├── librechat.yaml       # LibreChat app config (S3 file strategy)
├── images/              # User-uploaded images
├── uploads/             # File uploads
├── logs/                # Application logs
├── data-mongo/          # MongoDB data
└── data-meili/          # MeiliSearch data
```

Nginx config: `/opt/infra/proxy/nginx/conf.d/chat.marin.cr.conf`

## Container names

| Container | Purpose |
|-----------|---------|
| `infra-librechat` | Main application |
| `infra-librechat-mongo` | MongoDB |
| `infra-librechat-meili` | MeiliSearch |
| `infra-librechat-vectordb` | pgvector (RAG) |
| `infra-librechat-rag` | RAG API |

## Common operations

```bash
cd /opt/infra/apps/librechat

# Start/restart
docker compose up -d
docker compose restart

# View logs
docker logs --tail 100 infra-librechat

# Rebuild (after config changes)
docker compose down
docker compose up -d

# Pull latest images
docker compose pull
docker compose up -d
```

## Configuration

### AI Providers

API keys are set to `user_provided` in `.env`, meaning each user enters their own keys through the LibreChat UI settings.

### File Storage

Files are stored in AWS S3:
- Bucket: `marin-librechat`
- Region: `us-east-1`
- Configured via `fileStrategy: "s3"` in `librechat.yaml`

### Registration

Open registration is enabled (`ALLOW_REGISTRATION=true`). The first account created becomes the admin.

## Verification

```bash
# Container status
docker ps --format "table {{.Names}}\t{{.Status}}" | grep librechat

# Local connectivity
curl -I http://127.0.0.1:3080/

# Public HTTPS
curl -I https://chat.marin.cr/

# TLS certificate expiry
openssl x509 -enddate -noout -in /opt/infra/proxy/letsencrypt/live/chat.marin.cr/fullchain.pem
```

## Initial setup

After deployment, open https://chat.marin.cr in a browser and create the first user account. This account will be the admin.
