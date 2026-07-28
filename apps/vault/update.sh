#!/usr/bin/env bash
#
# Vault updater
#
# Replaces the previous update.sh. Three behavioural changes, each fixing a
# failure that let a deploy report success while shipping nothing:
#
#   1. It BUILDS BY DEFAULT. The old script skipped the rebuild when the
#      working tree was already at the target commit -- but the tree being at a
#      commit says nothing about what the *image* was built from. A previous run
#      that pulled and then failed left the tree updated and the image stale,
#      and every subsequent run said "no code changes" forever. Docker layer
#      caching makes a redundant build cheap; a skipped build costs you a day.
#
#   2. It RUNS THE SEED. System secret types (including Card) live in the
#      database and are only updated by the seed. Migrating without seeding
#      leaves the new columns in place and the Card type on its old field set,
#      with no error anywhere.
#
#   3. It VERIFIES AFTER DEPLOYING, rather than trusting that the steps did what
#      they said. Migration count, seeded field count, and health are all read
#      back from the running system.
#
# Usage:
#   sudo ./update.sh                 normal update
#   sudo ./update.sh --skip-build    only if you know the image is current
#   sudo ./update.sh --no-pull       deploy the checkout as-is
#   sudo ./update.sh --check         diagnose only; change nothing
#
set -Eeuo pipefail

# --------------------------------------------------------------------------
# Configuration -- values taken from the real compose.yml and vault.conf,
# not guessed. Override via environment if the deployment moves.
# --------------------------------------------------------------------------
APP_DIR="${APP_DIR:-/opt/infra/apps/vault}"
REPO_DIR="${REPO_DIR:-$APP_DIR/repo}"          # compose builds from ./repo/apps/*
COMPOSE_FILE="${COMPOSE_FILE:-$APP_DIR/compose.yml}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"          # compose api.env_file
API_SERVICE="${API_SERVICE:-api}"              # container_name vault-api
WEB_SERVICE="${WEB_SERVICE:-web}"              # container_name vault-web
NGINX_SERVICE="${NGINX_SERVICE:-nginx}"        # container_name vault-nginx

# nginx publishes on 127.0.0.1:8322 -> container :80. The VPS proxy
# (vault.marin.cr) forwards both /api and / to that same port, so 8322 is the
# right place to health-check: it exercises the internal nginx routing too,
# not just the API in isolation.
INTERNAL_ORIGIN="${INTERNAL_ORIGIN:-http://127.0.0.1:8322}"
HEALTH_URL="${HEALTH_URL:-$INTERNAL_ORIGIN/api/health/ready}"
PUBLIC_URL="${PUBLIC_URL:-https://vault.marin.cr}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
BRANCH="${BRANCH:-main}"

SKIP_BUILD=0; NO_PULL=0; CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --no-pull)    NO_PULL=1 ;;
    --check)      CHECK_ONLY=1; NO_PULL=1 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
log()  { printf '[vault-update] %s %s\n' "$(date +%H:%M:%S)" "$*"; }
step() { printf '\n[vault-update] %s \033[1m%s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '[vault-update] %s   \033[32m✓\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[vault-update] %s   \033[33m!\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
err()  { printf '[vault-update] %s   \033[31m✗\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

trap 'err "Failed at line $LINENO (exit $?). Nothing further was attempted."; \
      echo; echo "Recent API logs:"; \
      dc logs --tail=40 "$API_SERVICE" 2>/dev/null || true' ERR

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

# Run a read-only query inside the api container via the Prisma client.
#
# DATABASE_URL is deliberately NOT in the environment -- apps/api/scripts/
# prisma-env.js builds it from the POSTGRES_* vars at runtime, which is why a
# naive `new PrismaClient()` fails here with an unhelpful empty error. We
# reconstruct it the same way and pass it explicitly.
#
# stderr is folded into stdout on purpose: the first version of this helper
# swallowed it, so a failure reported "DBERR" with no cause. A diagnostic that
# hides the diagnosis is worse than none.
db_query() {
  dc run --rm --no-deps -T "$API_SERVICE" \
    node -e '
      const e = process.env;
      const pw = encodeURIComponent(e.POSTGRES_PASSWORD || "postgres");
      const ssl = e.POSTGRES_SSL === "true" ? "?sslmode=require" : "";
      const url = e.DATABASE_URL ||
        `postgresql://${e.POSTGRES_USER || "postgres"}:${pw}@${e.POSTGRES_HOST || "localhost"}:${e.POSTGRES_PORT || "5432"}/${e.POSTGRES_DB || "appdb"}${ssl}`;
      const { PrismaClient } = require("@prisma/client");
      const p = new PrismaClient({ datasources: { db: { url } } });
      p.$queryRawUnsafe(process.argv[1])
        .then(rows => console.log("QRESULT " + JSON.stringify(rows, (k, v) =>
          typeof v === "bigint" ? Number(v) : v)))
        .catch(err => { console.log("DBERR " + (err && err.message ? err.message.split("\n")[0] : String(err))); process.exitCode = 9; })
        .finally(() => p.$disconnect());
    ' "$1" 2>&1 | grep -E '^(QRESULT|DBERR)' | tail -1
}

# --------------------------------------------------------------------------
step "============================================"
log  " Vault Updater"
log  "============================================"

# --------------------------------------------------------------------------
step "[1/8] Preflight"
# --------------------------------------------------------------------------
command -v docker >/dev/null || { err "docker not found"; exit 1; }
docker info >/dev/null 2>&1  || { err "cannot talk to the docker daemon (run with sudo?)"; exit 1; }
[[ -f "$COMPOSE_FILE" ]]     || { err "compose file not found: $COMPOSE_FILE"; exit 1; }
[[ -d "$REPO_DIR/.git" ]]    || { err "no git checkout at $REPO_DIR -- set REPO_DIR"; exit 1; }
ok "docker reachable, compose file present"

# Required secrets. Blank values here are the most common cause of an API that
# builds fine and then refuses to boot -- VAULT_ENCRYPTION_KEY is validated at
# startup and hard-fails, which looks identical to a hung health check.
if [[ -f "$ENV_FILE" ]]; then
  missing=()
  for v in JWT_SECRET VAULT_ENCRYPTION_KEY COOKIE_SECRET POSTGRES_HOST POSTGRES_DB; do
    val=$(grep -E "^${v}=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
    [[ -z "${val//\"/}" ]] && missing+=("$v")
  done
  if (( ${#missing[@]} )); then
    err "these are unset or blank in $ENV_FILE: ${missing[*]}"
    err "VAULT_ENCRYPTION_KEY in particular is validated at boot; the API will not start without it."
    exit 1
  fi
  ok "required environment variables present"
else
  warn "no .env at $ENV_FILE -- relying on the environment"
fi

# --------------------------------------------------------------------------
step "[2/8] Source code"
# --------------------------------------------------------------------------
cd "$REPO_DIR"
BEFORE=$(git rev-parse --short HEAD)
if (( NO_PULL )); then
  log "  --no-pull: deploying the checkout as-is"
else
  git fetch --quiet origin "$BRANCH"
  git checkout --quiet "$BRANCH" 2>/dev/null || true
  git reset --hard --quiet "origin/$BRANCH"
fi
AFTER=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --pretty=%s)

if [[ "$BEFORE" == "$AFTER" ]]; then
  log "  Checkout already at $AFTER"
else
  ok "Updated $BEFORE -> $AFTER"
fi
log "  $SUBJECT"

# What the running image was actually built from -- the number the old updater
# never looked at.
#
# Everything here is diagnostic and must NEVER abort the run. It is wrapped in a
# function called with `|| true` for that reason: an earlier version piped
# `docker compose images` into `head -1`, and under `set -o pipefail` the SIGPIPE
# from head closing the pipe early made the whole pipeline fail. That is a race,
# so it survived two runs and then killed a deploy at the one step that cannot
# affect correctness. No pipes into short-circuiting readers below.
report_image_age() {
  local imgs deployed created img_epoch commit_epoch age_days
  imgs=$(dc images -q "$API_SERVICE" 2>/dev/null) || return 0
  deployed=${imgs%%$'\n'*}
  [[ -n "$deployed" ]] || return 0

  created=$(docker image inspect "$deployed" --format '{{.Created}}' 2>/dev/null) || return 0
  log "  Running API image: ${deployed:0:12} (built ${created%%T*})"

  img_epoch=$(date -d "$created" +%s 2>/dev/null) || return 0
  commit_epoch=$(git log -1 --format=%ct 2>/dev/null) || return 0
  if (( img_epoch > 0 && img_epoch < commit_epoch )); then
    age_days=$(( (commit_epoch - img_epoch) / 86400 ))
    warn "the running image predates this commit by ~${age_days} days -- it is serving OLD code"
    warn "this is the condition the previous updater mistook for 'no code changes'"
  fi
  return 0
}
report_image_age || true

MIGRATIONS_IN_REPO=$(find apps/api/prisma/migrations -mindepth 1 -maxdepth 1 -type d | wc -l)
log "  Migrations in this checkout: $MIGRATIONS_IN_REPO"

# --------------------------------------------------------------------------
step "[3/8] Pre-migration safety check"
# --------------------------------------------------------------------------
# 20260727120000_version_scoped_attachments backfills secret_version_id, then
# DELETEs any row it could not backfill. That delete is expected to affect zero
# rows -- every secret gets a version in the same transaction it is created in.
# If it is ever non-zero, those rows' storage objects would be orphaned in S3,
# so we refuse rather than find out afterwards.
if [[ -d "apps/api/prisma/migrations/20260727120000_version_scoped_attachments" ]]; then
  ORPHANS=$(db_query "SELECT count(*)::int AS n FROM secret_attachments sa WHERE NOT EXISTS (SELECT 1 FROM secret_versions sv WHERE sv.secret_id = sa.secret_id)" || echo "")
  ALREADY_SCOPED=$(db_query "SELECT count(*)::int AS n FROM information_schema.columns WHERE table_name='secret_attachments' AND column_name='secret_version_id'" || echo "")

  if [[ "$ALREADY_SCOPED" == *'"n":1'* ]]; then
    ok "version-scoping already applied; backfill will not run again"
  elif [[ "$ORPHANS" == *'"n":0'* ]]; then
    ok "no orphaned attachments; the version backfill is safe"
  elif [[ "$ORPHANS" == QRESULT* ]]; then
    err "orphaned secret_attachments rows found: $ORPHANS"
    err "The version-scoping migration would DELETE these and orphan their S3 objects."
    err "Stop here, back up, and resolve them before continuing."
    exit 1
  else
    # Fail closed. This check exists to prevent irreversible data loss, so an
    # inability to run it is a reason to stop, not a reason to shrug.
    err "Could not run the orphan pre-check: ${ORPHANS:-no output}"
    err "Refusing to apply the version-scoping migration unverified."
    err "Investigate, or override deliberately with: SKIP_ORPHAN_CHECK=1 $0"
    [[ "${SKIP_ORPHAN_CHECK:-0}" == "1" ]] || exit 1
    warn "SKIP_ORPHAN_CHECK=1 set -- proceeding without verification"
  fi
else
  log "  (migration not present in this checkout; skipping)"
fi

if (( CHECK_ONLY )); then
  step "--check: stopping before any change"
  dc ps
  exit 0
fi

# --------------------------------------------------------------------------
step "[4/8] Building images"
# --------------------------------------------------------------------------
# Deliberately unconditional. A skipped build is invisible until someone
# notices the UI never changed; a redundant build is a cached no-op.
if (( SKIP_BUILD )); then
  warn "--skip-build: using existing images (only do this if you just built them)"
else
  log "  Building $API_SERVICE and $WEB_SERVICE (cached layers reused)..."
  dc build "$API_SERVICE" "$WEB_SERVICE"
  ok "images built from $AFTER"
fi

# --------------------------------------------------------------------------
step "[5/8] Database migrations"
# --------------------------------------------------------------------------
MIG_OUT=$(dc run --rm --no-deps -T "$API_SERVICE" npm run prisma:migrate 2>&1 || true)
echo "$MIG_OUT" | sed 's/^/[vault-update]     /'

# No `head` here: it would SIGPIPE the upstream greps and, under pipefail, turn
# a successful parse into a failed pipeline. Trim to the first match in bash.
FOUND=$(echo "$MIG_OUT" | grep -oE '[0-9]+ migrations? found' | grep -oE '^[0-9]+' || echo "?")
FOUND=${FOUND%%$'\n'*}
[[ -n "$FOUND" ]] || FOUND="?"
if [[ "$FOUND" != "?" && "$FOUND" -lt "$MIGRATIONS_IN_REPO" ]]; then
  err "The container sees $FOUND migrations but this checkout has $MIGRATIONS_IN_REPO."
  err "That means the image is older than the code -- the build did not take effect."
  err "Re-run without --skip-build, or force it: docker compose -f $COMPOSE_FILE build --no-cache $API_SERVICE"
  exit 1
fi
ok "migrations applied ($FOUND found, matching the checkout)"

# --------------------------------------------------------------------------
step "[6/8] Seeding system data"
# --------------------------------------------------------------------------
# The step the old script never had. Roles, permissions and system secret types
# live in the database. The Card type's fields -- card_network, card_kind,
# security_code_2, issuing_bank -- arrive here, not in the migration. Idempotent.
dc run --rm --no-deps -T "$API_SERVICE" npm run prisma:seed 2>&1 | sed 's/^/[vault-update]     /'
ok "seed complete"

# --------------------------------------------------------------------------
step "[7/8] Restarting services"
# --------------------------------------------------------------------------
dc up -d --remove-orphans
ok "containers up"

# nginx.prod.conf is bind-mounted read-only from ./repo/infra/nginx/, so a pull
# that changes routing takes effect only on restart -- `up -d` sees an unchanged
# image and leaves the container alone. Cheap to do unconditionally.
dc restart "$NGINX_SERVICE" >/dev/null 2>&1 && ok "nginx restarted (config is bind-mounted from the repo)" \
                                            || warn "could not restart $NGINX_SERVICE"

log "  Waiting for the API (up to ${HEALTH_TIMEOUT}s)..."
deadline=$(( SECONDS + HEALTH_TIMEOUT ))
healthy=0
while (( SECONDS < deadline )); do
  if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then healthy=1; break; fi
  sleep 3
done

if (( healthy )); then
  ok "API healthy at $HEALTH_URL"
else
  err "API did not become healthy within ${HEALTH_TIMEOUT}s."
  err "This is almost always a startup crash rather than slowness. Logs:"
  echo
  dc logs --tail=60 "$API_SERVICE" | sed 's/^/    /'
  echo
  err "Common causes: blank VAULT_ENCRYPTION_KEY (must be 64 hex chars),"
  err "unreachable POSTGRES_HOST, or a migration that failed above."
  exit 1
fi

# --------------------------------------------------------------------------
step "[8/8] Verifying the deploy"
# --------------------------------------------------------------------------
# Read the result back rather than assuming the steps worked.
CARD_FIELDS=$(db_query "SELECT jsonb_array_length(fields)::int AS n FROM secret_types WHERE name = 'Card' AND is_system = true LIMIT 1" || echo "")
if [[ "$CARD_FIELDS" == *'"n":10'* ]]; then
  ok "Card secret type has 10 fields -- the new card data model is live"
elif [[ "$CARD_FIELDS" == *'"n":6'* ]]; then
  err "Card type still has 6 fields. The seed did not update it."
  err "Run manually and read the output: docker compose -f $COMPOSE_FILE run --rm $API_SERVICE npm run prisma:seed"
  exit 1
elif [[ -n "$CARD_FIELDS" && "$CARD_FIELDS" != *DBERR* ]]; then
  warn "Card type field count unexpected: $CARD_FIELDS"
else
  warn "could not verify the Card type (query failed) -- check manually"
fi

ATTACH_COL=$(db_query "SELECT count(*)::int AS n FROM information_schema.columns WHERE table_name='secret_attachments' AND column_name='secret_version_id'" || echo "")
[[ "$ATTACH_COL" == *'"n":1'* ]] && ok "attachments are version-scoped" \
                                 || warn "secret_version_id column not found on secret_attachments"

# The check that would have caught the original symptom directly. The web image
# bakes the Vite bundle at BUILD time, so a stale image serves the old UI no
# matter how healthy the API is. Grep the actual served assets for a string that
# only exists in the new frontend.
BUNDLE_HIT=$(dc exec -T "$WEB_SERVICE" sh -c \
  "grep -rl 'Import credit card' /usr/share/nginx/html 2>/dev/null | head -1" 2>/dev/null || true)
if [[ -n "$BUNDLE_HIT" ]]; then
  ok "served web bundle contains the card UI"
else
  err "The served web bundle does NOT contain the card UI."
  err "The web image is stale -- this is exactly the symptom of a skipped rebuild."
  err "Force it:  docker compose -f $COMPOSE_FILE build --no-cache $WEB_SERVICE && docker compose -f $COMPOSE_FILE up -d $WEB_SERVICE"
  exit 1
fi

# Prove the public path works end to end, not just the container.
if curl -fsS --max-time 10 "$PUBLIC_URL/api/health/live" >/dev/null 2>&1; then
  ok "public origin responding at $PUBLIC_URL"
else
  warn "could not reach $PUBLIC_URL from this host (may be DNS/firewall, not the app)"
fi

echo
log "============================================"
ok  "Deployed $AFTER"
log "  $SUBJECT"
log "============================================"
echo
log "Next, at $PUBLIC_URL:"
log "  • Hard-reload (Ctrl/Cmd+Shift+R) -- the old JS bundle is cached by filename hash"
log "  • A 'Cards' entry should appear in the sidebar"
log "  • System Settings should show an AI section with a Test connection button"
log "  • AI is disabled by default; nothing reaches OpenAI until you enable it"
log ""
log "Rollback, if needed:"
log "  cd $REPO_DIR && git reset --hard $BEFORE && sudo $0 --no-pull"
log "  (note: applied migrations do NOT roll back -- restore the database for that)"
