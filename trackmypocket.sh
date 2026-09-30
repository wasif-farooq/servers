#!/bin/bash
#
# TrackMyPocket (staging) — 165.22.176.141 (shared with BipPass, ApplyBuddy, LinkedIn Poster)
#   https://trackmypocket.com (web)   https://api.trackmypocket.com (api)
#
#   ./trackmypocket.sh             ssh in
#   ./trackmypocket.sh provision   /srv/trackmypocket, a role + database inside BipPass's
#                                  postgres, and a generated .env  (ONCE, first run)
#   ./trackmypocket.sh build       build both images without shipping them
#   ./trackmypocket.sh deploy      rebuild locally, ship the images, migrate, restart
#   ./trackmypocket.sh expose      ship BipPass's Caddyfile (with our blocks) and reload Caddy
#   ./trackmypocket.sh status      containers, health (Cloudflare AND origin), noindex,
#                                  memory, deployed-vs-committed
#   ./trackmypocket.sh logs [svc]  tail the logs (tmp-api, tmp-web, tmp-migrate)
#   ./trackmypocket.sh paddle-key  prompt for the Paddle sandbox keys and store them
#   ./trackmypocket.sh ai-key      receipt-scanning provider: OpenRouter or OpenCode Zen key
#                                  (from this machine's env, or a hidden prompt), base URL, model
#   ./trackmypocket.sh mail-key    turn on real email: Resend SMTP, key from a hidden prompt
#                                  ON THE SERVER; reports length + prefix only
#   ./trackmypocket.sh google-key  Sign in with Google: client ids + the web client secret
#   ./trackmypocket.sh rates       fetch exchange rates once
#   ./trackmypocket.sh cron        install the server's rate schedule (crypto every 10 min,
#                                  fiat + crypto daily 02:15 UTC); `cron remove` uninstalls
#
# THIS DROPLET IS BIPPASS'S, and BipPass takes money. Read trackmypocket/docker-compose.yml
# next to this script for the three rules that keep one from taking down the other: a
# separate compose project on BipPass's network as EXTERNAL, prefixed SERVICE KEYS (tmp-*;
# compose puts the service key itself on the shared network's DNS, so a key called `api`
# would collide with BipPass's), and hard memory limits.
#
# Postgres, Redis, Caddy and the `bippass` network all belong to the BipPass compose
# project. This script never creates, restarts or removes any of them. It adds one role
# and one database to BipPass's postgres (provision), and its two site blocks must live in
# BipPass's Caddyfile — see `expose`.
#
# Only the API process runs: processes/api-gateway in direct mode, as `pnpm dev:api` does.
# No Kafka, no MinIO, no worker — see the .env written by `provision` for what that costs.
#
# Both names are Cloudflare-PROXIED. Cloudflare terminates the public TLS, so a green
# public check proves only that Cloudflare answered; `status` also asks the origin directly.
set -euo pipefail

# Absolute, because build cd's into the repos. A relative $0 stops resolving the moment
# the working directory changes — how bippass.sh once reported failure after a good deploy.
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
HERE=$(dirname "$SELF")

HOST=root@165.22.176.141
ORIGIN_IP=${HOST#root@}
REMOTE=/srv/trackmypocket
COMPOSE_FILE=$HERE/trackmypocket/docker-compose.yml

SPENDWISE=${SPENDWISE_ROOT:-$HOME/work/personal/spendwise}
BE_REPO=$SPENDWISE/trackmypocket-backend
FE_REPO=$SPENDWISE/trackmypocket-web

# BipPass's compose project owns these. Named here so nothing has to guess.
BIPPASS_REMOTE=/srv/bippass
BIPPASS_REPO=${BIPPASS_REPO:-$HOME/work/personal/bippass}
BIPPASS_CADDYFILE=$BIPPASS_REPO/bippass-backend/deploy/Caddyfile
PG=bippass-postgres-1

WEB_HOST=trackmypocket.com
API_HOST=api.trackmypocket.com
WEB_ORIGIN=https://$WEB_HOST
API_ORIGIN=https://$API_HOST

IMAGES=(trackmypocket-api trackmypocket-web)

# Google OAuth clients in the "trackmypocket" Google Cloud project (wasiffarooq1122@gmail.com).
# Client ids are public; only the web client's SECRET is sensitive (see google-key).
#   web: authorization-code flow for trackmypocket.com (redirect /auth/google/callback)
#   ios: bundle com.trackmypocket.app. Android needs the signing cert's SHA-1, so it is
#        added once EAS/Play signing exists.
GOOGLE_WEB_CLIENT_ID=48929835109-0e9b61jmjvfphqmp438cs9p4onkbg13e.apps.googleusercontent.com
GOOGLE_IOS_CLIENT_ID=48929835109-c6kui8p0eqislorbq9rbktpa218ro6l7.apps.googleusercontent.com

# Refuse to ship unless the server keeps this much free after the load. Measured unpacked:
# api ~320 MB + web ~66 MB. The disk was 92% full (2.1 GB free) when this was written.
MIN_FREE_MB=800

# One multiplexed SSH connection for every ssh/scp below. The droplet rate-limits new SSH
# connections, and deploy + status open about ten in quick succession — without this the
# later ones are refused mid-deploy (found by linkedin.sh first).
SSH_CONTROL="${TMPDIR:-/tmp}/trackmypocket-sh-%C"
ssh() { command ssh -o ControlMaster=auto -o ControlPath="$SSH_CONTROL" -o ControlPersist=120s "$@"; }
scp() { command scp -o ControlMaster=auto -o ControlPath="$SSH_CONTROL" -o ControlPersist=120s "$@"; }

# Short SHA, +dirty when the tree has uncommitted changes: that is code baked into the
# image with no commit behind it, and nothing else here would say so.
revision() {
  local rev
  rev=$(git -C "$1" rev-parse --short HEAD 2>/dev/null || echo unknown)
  if [ -n "$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null)" ]; then rev="$rev+dirty"; fi
  echo "$rev"
}

build() {
  local be_rev fe_rev
  be_rev=$(revision "$BE_REPO")
  fe_rev=$(revision "$FE_REPO")

  # Stamped as OCI labels so `status` can answer "is what is RUNNING what is COMMITTED?"
  # — the question every health check fails to ask.
  echo "==> trackmypocket-api ($be_rev)"
  docker build --platform linux/amd64 \
    --label "org.opencontainers.image.revision=$be_rev" \
    -t trackmypocket-api:latest "$BE_REPO"

  # VITE_* are inlined at build time, so the droplet's URLs are fixed here and a restart
  # cannot change them. The Google client id is public (it ships in every bundle); without
  # it the web app hides "Continue with Google".
  #
  # @wasif-farooq/ui needs a GitHub Packages token. It goes in as a BuildKit SECRET read
  # from this one command's environment: never a build arg (those are in `docker history`),
  # never printed, never in a layer.
  echo "==> trackmypocket-web ($fe_rev)"
  NODE_AUTH_TOKEN=$(gh auth token) docker build --platform linux/amd64 \
    --secret id=node_auth_token,env=NODE_AUTH_TOKEN \
    --build-arg "VITE_API_URL=$API_ORIGIN/api/v1" \
    --build-arg "VITE_FRONTEND_URL=$WEB_ORIGIN" \
    --build-arg "VITE_GOOGLE_CLIENT_ID=$GOOGLE_WEB_CLIENT_ID" \
    --build-arg "VITE_GOOGLE_REDIRECT_URI=$WEB_ORIGIN/auth/google/callback" \
    --label "org.opencontainers.image.revision=$fe_rev" \
    -t trackmypocket-web:latest "$FE_REPO"
}

require_provisioned() {
  # -n: never read stdin. Without it this probe swallows input meant for the prompts that
  # follow (ai-key, paddle-key), and the next `read` hits EOF under set -e: exit 1, nothing stored.
  ssh -n "$HOST" "test -f $REMOTE/.env" || {
    echo "not provisioned yet — run: $SELF provision" >&2
    exit 1
  }
}

case "${1:-shell}" in
  shell)
    exec ssh "$HOST"
    ;;

  provision)
    # BipPass's postgres and network must already exist: we are adding to them, not
    # standing them up. Fail clearly rather than half-provision.
    ssh "$HOST" "docker inspect -f '{{.State.Running}}' $PG 2>/dev/null | grep -q true && docker network inspect bippass >/dev/null 2>&1" || {
      echo "$PG is not running or the 'bippass' network is missing." >&2
      echo "BipPass must be deployed before TrackMyPocket can borrow its postgres." >&2
      exit 1
    }

    ssh "$HOST" "mkdir -p $REMOTE"
    scp "$COMPOSE_FILE" "$HOST:$REMOTE/docker-compose.yml"

    # Secrets are generated ON THE SERVER and never printed here or passed as arguments
    # (ps would show them). Same discipline as bippass.sh.
    ssh "$HOST" "REMOTE='$REMOTE' PG='$PG' BIPPASS_REMOTE='$BIPPASS_REMOTE' WEB_ORIGIN='$WEB_ORIGIN' bash -s" <<'PROVISION'
set -euo pipefail

if [ -f "$REMOTE/.env" ]; then
  echo "$REMOTE/.env already exists — refusing to regenerate."
  echo "A new DB_PASSWORD would no longer match the role, and a new JWT_SECRET"
  echo "signs everyone out. Edit the file by hand if something must change."
  exit 0
fi

# The instance superuser is whatever BipPass's POSTGRES_USER is. Connecting as it over
# the container's local socket needs no password (the official image trusts local).
PGSU=$(sed -n 's/^DB_USERNAME=//p' "$BIPPASS_REMOTE/.env" 2>/dev/null | head -1)
PGSU=${PGSU:-bippass}

DB_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)

# A separate role and database inside BipPass's postgres. Not a second postgres: that
# would cost more memory than TrackMyPocket itself. The role owns only its own database
# and is not a superuser.
#
# CONNECTION LIMIT 15: BipPass runs max_connections=50. The API opens three pg pools of
# DB_POOL_MAX=4 each (bootstrap, activity routes, push-token routes), so 12 at most; 15
# leaves room for a migrate or a psql, and guarantees TrackMyPocket can never starve
# BipPass of connections however badly it misbehaves.
#
# Idempotent — provision must be safe to re-run after a partial failure. The password
# travels over psql's stdin, never an argument.
docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -U "$PGSU" -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'trackmypocket') THEN
    CREATE ROLE trackmypocket LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE CONNECTION LIMIT 15 PASSWORD '${DB_PASSWORD}';
  ELSE
    ALTER ROLE trackmypocket LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE CONNECTION LIMIT 15 PASSWORD '${DB_PASSWORD}';
  END IF;
END
\$\$;
SQL
# CREATE DATABASE cannot run inside a DO block, so it is guarded with \gexec: the SELECT
# yields the statement only when the database is absent. NOT `psql -tc … | grep -q ||
# createdb` — under pipefail, grep -q SIGPIPEs psql and the pipeline fails exactly when
# the database DOES exist (applybuddy.sh learned this).
docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -U "$PGSU" -d postgres <<'SQL'
SELECT 'CREATE DATABASE trackmypocket OWNER trackmypocket'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'trackmypocket')\gexec
SQL
# Postgres grants CONNECT to PUBLIC by default; close that. Isolation is one-way, as for
# ApplyBuddy: trackmypocket cannot read BipPass's tables, but BipPass's role is the
# instance superuser and can read everything here. Inherent to sharing one postgres.
#
# No -i, and stdin from /dev/null: this whole script arrives on `bash -s`'s stdin, and a
# `docker exec -i` without a heredoc of its own reads THE REST OF THIS SCRIPT as its
# input. bash then hits EOF and exits 0 — "success", and no .env. Caught in testing.
docker exec "$PG" psql -v ON_ERROR_STOP=1 -U "$PGSU" -d postgres \
  -c "REVOKE CONNECT ON DATABASE trackmypocket FROM PUBLIC" \
  -c "GRANT CONNECT ON DATABASE trackmypocket TO trackmypocket" </dev/null >/dev/null

echo "database 'trackmypocket' and role 'trackmypocket' ready inside $PG"

umask 077
cat > "$REMOTE/.env" <<EOF
# Generated by trackmypocket.sh provision. STAGING.
#
# ── generated ─────────────────────────────────────────────────────────────────
# JWT_SECRET signs every session; rotating it signs everyone out. DB_PASSWORD is the
# trackmypocket role's password inside BipPass's postgres — change both or neither.
JWT_SECRET=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 64)
DB_PASSWORD=${DB_PASSWORD}

# ── fixed ─────────────────────────────────────────────────────────────────────
NODE_ENV=production
PORT=3000
LOG_LEVEL=info

# Client → Cloudflare edge → Caddy → API. Two proxies: Express skips Caddy and the edge
# in X-Forwarded-For and lands on the real client, which the per-IP rate limits (10
# logins / 15 min) key on. With 1, every user behind one Cloudflare edge would share a
# bucket. This only works because Caddy's api block trusts Cloudflare's ranges and so
# keeps Cloudflare's X-Forwarded-For (by default Caddy replaces it). A request that
# bypasses Cloudflare reaches Caddy from an untrusted address and gets its real IP.
TRUST_PROXY=2

# postgres and redis are BipPass's services, by name, on the shared network.
DB_HOST=postgres
DB_PORT=5432
DB_NAME=trackmypocket
DB_USER=trackmypocket
# Traffic never leaves the host (a docker network between two containers), the same
# accepted gap BipPass documents. The production config defaults this to true.
DB_SSL=false
DB_POOL_MIN=0
DB_POOL_MAX=4

# DB index 1 of BipPass's redis; BipPass uses 0. No password on that redis. Its
# maxmemory (32mb, allkeys-lru) is shared by every index, so TrackMyPocket filling
# it would evict BipPass's keys — hence ACTIVITY_LOG_ENABLED=false below.
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_DB=1

# Direct mode: no Kafka, no RPC worker. BullMQ is the provider only because the code
# needs one; nothing consumes its queues here.
REPOSITORY_MODE=direct
MESSAGE_QUEUE_PROVIDER=bullmq

# Activity logs are written by processes/worker, which is not deployed. Enabled, every
# change would enqueue a job into Redis that nothing ever drains — unbounded growth in
# the redis BipPass depends on. The activity feed is empty on staging as a result.
ACTIVITY_LOG_ENABLED=false

CORS_ORIGINS=${WEB_ORIGIN}
# Links in emails and Stripe/Paddle return URLs.
FRONTEND_URL=${WEB_ORIGIN}

# Email. MAIL_PROVIDER=console sends nothing: every email (verification, password reset,
# 2FA, invitations, account deletion), codes included, is printed to the API log.
# Set by: trackmypocket.sh mail-key, which switches to Resend over SMTP
# (MAIL_PROVIDER=smtp, smtp.resend.com:465, MAIL_USERNAME=resend, MAIL_PASSWORD=the
# Resend API key). With smtp, codes go only to the inbox and never to the log.
# The API logs "[EMAIL] Mail provider: ..." at startup; the password is never printed.
MAIL_PROVIDER=console

# No object storage on staging. The production config refuses to boot without these,
# so they are placeholders that fail fast: .invalid never resolves (RFC 2606). Boot is
# unaffected (buckets are not touched at startup); receipt/attachment upload and download,
# and avatar upload, fail with an error.
STORAGE_PROVIDER=minio
STORAGE_ENDPOINT=http://storage.invalid
STORAGE_PUBLIC_URL=http://storage.invalid
STORAGE_ACCESS_KEY_ID=staging-no-storage
STORAGE_SECRET_ACCESS_KEY=staging-no-storage

# ── to be filled later ────────────────────────────────────────────────────────
# Paddle Billing, SANDBOX. Set by: trackmypocket.sh paddle-key. Empty = the Paddle
# gateway is not offered and upgrades are unavailable; the app still boots.
# Webhook URL to register in Paddle: https://api.trackmypocket.com/api/v1/payment/webhook/paddle
PADDLE_ENV=sandbox
PADDLE_API_KEY=
PADDLE_CLIENT_TOKEN=
PADDLE_WEBHOOK_SECRET=

# AI receipt scanning. Set by: trackmypocket.sh ai-key. No key = the scan endpoints
# answer 503 and the apps fall back to manual entry; the app still boots.
# Free models may log inputs (receipts are personal data): staging/testing only.
AI_BASE_URL=https://openrouter.ai/api/v1
AI_RECEIPT_MODEL=nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free
OPENROUTER_API_KEY=
EOF
chmod 600 "$REMOTE/.env"
echo "wrote $REMOTE/.env (0600)"
PROVISION
    # set -e only catches a remote failure because ssh propagates the exit status. Checked
    # explicitly anyway: printing "provisioned" after the remote half died is the worst
    # kind of green.
    ssh "$HOST" "test -s $REMOTE/.env" || {
      echo "provisioning did not write $REMOTE/.env — see the output above." >&2
      exit 1
    }
    echo
    echo "provisioned. next:"
    echo "  $SELF deploy"
    echo "  $SELF paddle-key     # when the sandbox keys are to hand"
    echo "  $SELF ai-key         # to turn on receipt scanning"
    echo "  $SELF mail-key       # to send real email (Resend) once the domain is verified"
    ;;

  paddle-key)
    require_provisioned
    # Prompts on the SERVER and writes straight to .env: each value goes from your keyboard
    # into the file, never through an argument (visible in ps), never through the local
    # shell's history, never through a chat window. Like bippass.sh stripe-key.
    #
    # All three are read by the API at runtime — the client token too, which the API hands
    # to the browser per checkout rather than the web bundle baking it in. So none of this
    # needs a rebuild, only a restart of tmp-api.
    #
    # Blank input leaves a value untouched, so one key can be rotated alone.
    ssh -t "$HOST" "cd $REMOTE || exit 1
      # Rewrite rather than sed-substitute: a sed replacement breaks on any delimiter in
      # the value. Writing through cat keeps the inode and its 600 permissions.
      upsert() {
        tmp=\$(mktemp) || return 1
        grep -v \"^\$1=\" .env > \"\$tmp\"
        printf '%s=%s\n' \"\$1\" \"\$2\" >> \"\$tmp\"
        cat \"\$tmp\" > .env
        rc=\$?; rm -f \"\$tmp\"; return \$rc
      }
      changed=0
      env_now=\$(sed -n 's/^PADDLE_ENV=//p' .env | head -1)
      echo \"PADDLE_ENV is '\${env_now:-unset}' (anything but exactly 'sandbox' means LIVE).\"
      echo

      read -rsp 'Paddle API key  pdl_sdbx_apikey_… (blank = leave unchanged): ' AK && echo
      if [ -n \"\$AK\" ]; then
        case \"\$AK\" in
          pdl_sdbx_*) echo '  → sandbox key.' ;;
          pdl_live_*) echo '  ! LIVE key on a staging deployment. Storing anyway — check PADDLE_ENV.' ;;
          *)          echo '  ! does not look like a Paddle API key (pdl_sdbx_… / pdl_live_…). Storing anyway.' ;;
        esac
        upsert PADDLE_API_KEY \"\$AK\" && changed=1
      fi
      unset AK

      read -rsp 'Webhook secret key  pdl_ntfset_… (blank = leave unchanged): ' WH && echo
      if [ -n \"\$WH\" ]; then
        upsert PADDLE_WEBHOOK_SECRET \"\$WH\" && changed=1
      fi
      unset WH

      # Not secret — it ships to every browser that opens checkout — so it is visible
      # while typing and echoed back in full for checking.
      read -rp 'Client-side token  test_… (blank = leave unchanged): ' CT
      if [ -n \"\$CT\" ]; then
        case \"\$CT\" in
          test_*) : ;;
          live_*) echo '  ! LIVE client token on a staging deployment.' ;;
          *)      echo '  ! does not look like a Paddle client token (test_… / live_…). Storing anyway.' ;;
        esac
        upsert PADDLE_CLIENT_TOKEN \"\$CT\" && changed=1
      fi

      echo
      # Length and prefix only: enough to catch the two real mistakes, an empty value and
      # sandbox/live confusion. Every name is reported, including absent ones — silence for
      # a missing key reads exactly like success.
      report() {
        line=\$(grep \"^\$1=\" .env | head -1)
        if [ -z \"\$line\" ]; then printf '  %-24s not set\n' \"\$1\"; return; fi
        val=\${line#*=}
        if [ -z \"\$val\" ]; then printf '  %-24s EMPTY\n' \"\$1\"; return; fi
        if [ \"\$2\" = public ]; then printf '  %-24s %s\n' \"\$1\" \"\$val\"
        else printf '  %-24s %s… (%d chars)\n' \"\$1\" \"\$(printf %s \"\$val\" | cut -c1-12)\" \"\${#val}\"; fi
      }
      report PADDLE_API_KEY
      report PADDLE_WEBHOOK_SECRET
      report PADDLE_CLIENT_TOKEN public

      if [ \"\$changed\" = 1 ]; then
        echo
        # up -d, not restart: compose recreates the container because its env changed.
        echo 'restarting tmp-api…'
        docker compose up -d tmp-api >/dev/null 2>&1 && echo '  done'
      else
        echo 'nothing changed'
      fi"
    ;;

  ai-key)
    require_provisioned
    # Receipt scanning provider. Asks which provider, then:
    #   - the key: this machine's env var for that provider is offered and piped over ssh
    #     STDIN (never an argument, visible in ps on either machine); otherwise a hidden
    #     prompt on the SERVER, as paddle-key does;
    #   - AI_BASE_URL and AI_RECEIPT_MODEL (not secret, shown and confirmable).
    # All are upserted into .env and only the key's length is reported. The API reads them
    # at runtime, so tmp-api is recreated; no rebuild.
    echo "Receipt scanning provider:"
    echo "  1) OpenRouter    (default model: nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free — testing only)"
    echo "  2) OpenCode Zen  (needs a funded balance; its free models refuse server calls)"
    read -rp "Provider [1]: " choice
    case "${choice:-1}" in
      2) key_var=OPENCODE_API_KEY; base_url=https://opencode.ai/zen/v1; model=gemini-3-flash ;;
      *) key_var=OPENROUTER_API_KEY; base_url=https://openrouter.ai/api/v1
         model=nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free ;;
    esac
    read -rp "Model [$model]: " model_in
    model=${model_in:-$model}
    case "$model$base_url" in
      *[[:space:]\'\"\$\`\\]*) echo "! model or URL contains characters that are not allowed" >&2; exit 1 ;;
    esac

    AI_REMOTE="cd $REMOTE || exit 1
      upsert() {
        tmp=\$(mktemp) || return 1
        grep -v \"^\$1=\" .env > \"\$tmp\"
        printf '%s=%s\n' \"\$1\" \"\$2\" >> \"\$tmp\"
        cat \"\$tmp\" > .env
        rc=\$?; rm -f \"\$tmp\"; return \$rc
      }
      store() {
        upsert AI_BASE_URL '$base_url' && upsert AI_RECEIPT_MODEL '$model' || return 1
        if [ -n \"\$KEY\" ]; then
          case \"\$KEY\" in
            *[[:space:]]*) echo '! the key contains whitespace — not stored' >&2; return 1 ;;
          esac
          upsert $key_var \"\$KEY\" || return 1
        else
          echo '  no key entered — $key_var unchanged'
        fi
        unset KEY
        line=\$(grep '^$key_var=' .env | head -1); val=\${line#*=}
        if [ -n \"\$val\" ]; then printf '  %-19s stored (%d chars)\n' $key_var \"\${#val}\"
        else printf '  %-19s EMPTY — scanning answers 503 until it is set\n' $key_var; fi
        unset val line
        printf '  %-19s %s\n' AI_BASE_URL '$base_url' AI_RECEIPT_MODEL '$model'
        if grep -q '^AI_API_KEY=.' .env; then echo '  ! AI_API_KEY is set and wins over $key_var'; fi
        echo 'restarting tmp-api…'
        docker compose up -d tmp-api >/dev/null 2>&1 && echo '  done'
      }"

    use_local=n
    if [ -n "${!key_var:-}" ]; then
      read -rp "Use $key_var from this machine? [Y/n] " answer
      case "${answer:-y}" in [Yy]*) use_local=y ;; esac
    fi
    if [ "$use_local" = y ]; then
      printf '%s\n' "${!key_var}" | ssh "$HOST" "$AI_REMOTE
        IFS= read -r KEY
        store"
    else
      ssh -t "$HOST" "$AI_REMOTE
        read -rsp '$key_var (blank = leave unchanged): ' KEY && echo
        store"
    fi
    echo
    echo "receipt scanning needs migration 032 on the database: run $SELF deploy if the"
    echo "deployed backend predates it (status shows deployed-vs-committed)."
    ;;

  mail-key)
    require_provisioned
    # Real email through Resend's SMTP relay. The API key is typed into a hidden prompt ON
    # THE SERVER and written straight to .env: never an argument (visible in ps), never
    # this machine's env or shell history, never a chat window. Only its length and
    # whether it starts with re_ are reported.
    #
    # Upserts the whole Resend block (implicit TLS on 465; the username is literally
    # "resend") so a half-configured .env cannot linger, then recreates tmp-api (env is
    # read at runtime, no rebuild) and shows the API's own "[EMAIL] Mail provider" line.
    #
    # Blank input keeps an existing MAIL_PASSWORD (e.g. to re-apply the settings); with no
    # key stored yet, nothing changes. The sending domain must be verified in Resend first,
    # or every send fails (logged by the API with the SMTP error, never the message).
    ssh -t "$HOST" "cd $REMOTE || exit 1
      upsert() {
        tmp=\$(mktemp) || return 1
        grep -v \"^\$1=\" .env > \"\$tmp\"
        printf '%s=%s\n' \"\$1\" \"\$2\" >> \"\$tmp\"
        cat \"\$tmp\" > .env
        rc=\$?; rm -f \"\$tmp\"; return \$rc
      }
      current=\$(sed -n 's/^MAIL_PROVIDER=//p' .env | head -1)
      echo \"MAIL_PROVIDER is '\${current:-unset}'.\"
      echo

      read -rsp 'Resend API key  re_… (blank = keep the stored key): ' KEY && echo
      if [ -z \"\$KEY\" ]; then
        if ! grep -q '^MAIL_PASSWORD=.' .env; then
          echo 'no key entered and none stored — nothing changed'
          exit 1
        fi
        echo '  keeping the stored MAIL_PASSWORD'
      else
        case \"\$KEY\" in
          *[[:space:]]*) echo '! the key contains whitespace — nothing stored' >&2; unset KEY; exit 1 ;;
        esac
        upsert MAIL_PASSWORD \"\$KEY\" || { unset KEY; exit 1; }
      fi
      unset KEY

      upsert MAIL_PROVIDER smtp &&
      upsert MAIL_HOST smtp.resend.com &&
      upsert MAIL_PORT 465 &&
      upsert MAIL_SMTP_SECURE true &&
      upsert MAIL_USERNAME resend &&
      upsert MAIL_FROM_ADDRESS noreply@trackmypocket.com &&
      upsert MAIL_FROM_NAME TrackMyPocket || exit 1

      echo
      line=\$(grep '^MAIL_PASSWORD=' .env | head -1); val=\${line#*=}
      case \"\$val\" in
        re_*) prefix='starts with re_' ;;
        *)    prefix='! does NOT start with re_ — not a Resend API key?' ;;
      esac
      printf '  %-18s %d chars, %s\n' MAIL_PASSWORD \"\${#val}\" \"\$prefix\"
      unset val line prefix
      for k in MAIL_PROVIDER MAIL_HOST MAIL_PORT MAIL_SMTP_SECURE MAIL_USERNAME MAIL_FROM_ADDRESS MAIL_FROM_NAME; do
        printf '  %-18s %s\n' \"\$k\" \"\$(sed -n \"s/^\$k=//p\" .env | head -1)\"
      done

      echo
      # up -d, not restart: compose recreates the container because its env changed.
      echo 'recreating tmp-api…'
      docker compose up -d tmp-api >/dev/null 2>&1 && echo '  done' || { echo '! docker compose up failed' >&2; exit 1; }
      # The API's own startup line: provider, host, user, 'password set' (never the value).
      for i in \$(seq 1 20); do
        seen=\$(docker compose logs --since 2m tmp-api 2>/dev/null | grep -o '\[EMAIL\] Mail provider:.*' | tail -1)
        [ -n \"\$seen\" ] && break
        sleep 3
      done
      echo \"  \${seen:-no '[EMAIL] Mail provider' line yet — check: $SELF logs tmp-api}\""
    echo
    echo "to test: register with an address you can read, or use 'Forgot password' on"
    echo "$WEB_ORIGIN. A failed send appears in '$SELF logs tmp-api' as '[EMAIL] ... not sent: <reason>'."
    ;;

  google-key)
    require_provisioned
    # Sign in with Google. Writes the web client id, its redirect URI and the mobile client
    # ids (all public) plus the web client SECRET into .env, then recreates tmp-api.
    #
    # The secret comes from GOOGLE_CLIENT_SECRET in the backend repo's local .env (the same
    # web client is used for local dev) or, failing that, a hidden prompt ON THE SERVER. It
    # travels over ssh STDIN, never as an argument, and only its length is reported. Google
    # no longer shows existing secrets; if it is lost, add a new one on the client in the
    # Cloud console and paste it at the prompt.
    #
    # The web image must be built with VITE_GOOGLE_CLIENT_ID for the button to show: that
    # is what `deploy` does (see build()).
    local_secret=$(sed -n 's/^GOOGLE_CLIENT_SECRET=//p' "$BE_REPO/.env" 2>/dev/null | head -1 | tr -d "\"'" || true)
    GOOGLE_REMOTE="cd $REMOTE || exit 1
      upsert() {
        tmp=\$(mktemp) || return 1
        grep -v \"^\$1=\" .env > \"\$tmp\"
        printf '%s=%s\n' \"\$1\" \"\$2\" >> \"\$tmp\"
        cat \"\$tmp\" > .env
        rc=\$?; rm -f \"\$tmp\"; return \$rc
      }
      store() {
        if [ -n \"\$SECRET\" ]; then
          case \"\$SECRET\" in *[[:space:]]*) echo '! the secret contains whitespace — not stored' >&2; return 1 ;; esac
          upsert GOOGLE_CLIENT_SECRET \"\$SECRET\" || return 1
        elif ! grep -q '^GOOGLE_CLIENT_SECRET=.' .env; then
          echo 'no secret given and none stored — nothing changed' >&2; return 1
        fi
        unset SECRET
        upsert GOOGLE_CLIENT_ID '$GOOGLE_WEB_CLIENT_ID' &&
        upsert GOOGLE_REDIRECT_URI '$WEB_ORIGIN/auth/google/callback' &&
        upsert GOOGLE_MOBILE_CLIENT_IDS '$GOOGLE_IOS_CLIENT_ID' || return 1
        line=\$(grep '^GOOGLE_CLIENT_SECRET=' .env | head -1); val=\${line#*=}
        printf '  %-25s %d chars\n' GOOGLE_CLIENT_SECRET \"\${#val}\"
        unset val line
        for k in GOOGLE_CLIENT_ID GOOGLE_REDIRECT_URI GOOGLE_MOBILE_CLIENT_IDS; do
          printf '  %-25s %s\n' \"\$k\" \"\$(sed -n \"s/^\$k=//p\" .env | head -1)\"
        done
        echo 'recreating tmp-api…'
        docker compose up -d tmp-api >/dev/null 2>&1 && echo '  done'
      }"
    if [ -n "$local_secret" ]; then
      echo "using GOOGLE_CLIENT_SECRET from $BE_REPO/.env (${#local_secret} chars)"
      printf '%s\n' "$local_secret" | ssh "$HOST" "$GOOGLE_REMOTE
        IFS= read -r SECRET
        store"
    else
      ssh -t "$HOST" "$GOOGLE_REMOTE
        read -rsp 'Google web client secret (blank = keep the stored one): ' SECRET && echo
        store"
    fi
    unset local_secret
    ;;

  build)
    build
    docker images --filter=reference='trackmypocket-*' --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'
    ;;

  deploy)
    require_provisioned
    build

    # The disk was 92% full when this was written. Show it, drop dangling images (the
    # previous :latest layers left behind by the last load), and refuse to ship into a
    # disk that would be left nearly full — a full disk takes BipPass's postgres with it.
    echo
    echo "server disk, before:"
    ssh "$HOST" "df -h / | tail -1; docker image prune -f >/dev/null && echo '  pruned dangling images'"
    free_mb=$(ssh "$HOST" "df -Pm / | awk 'NR==2{print \$4}'")
    if [ "$free_mb" -lt "$MIN_FREE_MB" ]; then
      echo "only ${free_mb} MB free on the server; need ${MIN_FREE_MB}. Not shipping." >&2
      exit 1
    fi

    # Ship the compose file too, so the server's copy is never ahead of this one.
    scp "$COMPOSE_FILE" "$HOST:$REMOTE/docker-compose.yml"

    echo "shipping images (~97 MB gzipped in flight)…"
    docker save "${IMAGES[@]/%/:latest}" | gzip -1 | ssh "$HOST" 'gunzip | docker load'

    # `up -d`, not `restart`: tmp-migrate is a dependency with
    # condition: service_completed_successfully, and only `up` evaluates that.
    echo "migrating and restarting…"
    ssh "$HOST" "cd $REMOTE && docker compose up -d"

    # The images just replaced are dangling now; this is where their space comes back.
    ssh "$HOST" "docker image prune -f >/dev/null; echo; echo 'server disk, after:'; df -h / | tail -1"

    sleep 10
    "$SELF" status
    ;;

  expose)
    # Put both names on BipPass's Caddy. Separate from deploy and run once (and again
    # whenever the blocks change).
    #
    # The Caddyfile lives in the BIPPASS repo — bippass.sh deploy scp's it over the
    # server's copy, so a block added anywhere else disappears at the next BipPass deploy.
    # This ships that WHOLE file, so it refuses while it has uncommitted changes: whatever
    # is shipped should be what bippass.sh would ship too.
    for h in "$WEB_HOST" "$API_HOST"; do
      grep -q "^$h {" "$BIPPASS_CADDYFILE" || {
        echo "no '$h {' block in $BIPPASS_CADDYFILE" >&2
        echo "add the blocks from $HERE/trackmypocket/Caddyfile.snippet first." >&2
        exit 1
      }
    done
    if [ -n "$(git -C "$(dirname "$BIPPASS_CADDYFILE")" status --porcelain -- Caddyfile)" ]; then
      echo "$BIPPASS_CADDYFILE has uncommitted changes — commit them first." >&2
      exit 1
    fi
    # No DNS check like applybuddy.sh's: both names are Cloudflare-proxied, so they
    # resolve to Cloudflare, never to this droplet, whether or not the records are right.
    scp "$BIPPASS_CADDYFILE" "$HOST:$BIPPASS_REMOTE/Caddyfile"
    # Graceful: Caddy validates the new config first and keeps serving the old one if it
    # does not parse, so a bad Caddyfile cannot take bippass.com down here.
    ssh "$HOST" "cd $BIPPASS_REMOTE && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile" \
      2>&1 | grep -viE '"level":"(info|warn)"' || true
    echo "reloaded. certificate issuance takes a few seconds…"
    sleep 15
    "$SELF" status
    ;;

  rates)
    # Exchange rates are refreshed by the worker's cron, which is not deployed, so the
    # table starts empty and cross-currency conversion fails until this has run. One-shot
    # with the API's image, .env and network; --no-deps skips re-running migrate.
    require_provisioned
    ssh "$HOST" "cd $REMOTE && docker compose run --rm --no-deps tmp-api node dist/src/cli/exchange-rates.cli.js fetch"
    ;;

  cron)
    # The worker (whose scheduler refreshes rates) is not deployed: the droplet has no
    # memory to spare. Host cron runs the rates CLI instead. `docker exec` into the running
    # tmp-api rather than `compose run`, so no container is created every 10 minutes; the
    # CLI shares tmp-api's cgroup (API ~65 MB of 256 MB). Output goes to journald
    # (`journalctl -t tmp-rates`), which rotates it. A stopped tmp-api just skips a run.
    require_provisioned
    if [ "${2:-}" = remove ]; then
      ssh "$HOST" "rm -f /etc/cron.d/trackmypocket-rates && echo 'removed /etc/cron.d/trackmypocket-rates'"
      exit 0
    fi
    ssh "$HOST" "cat > /etc/cron.d/trackmypocket-rates && chmod 644 /etc/cron.d/trackmypocket-rates && echo 'installed /etc/cron.d/trackmypocket-rates:' && cat /etc/cron.d/trackmypocket-rates" <<'CRON'
# Managed by ~/servers/trackmypocket.sh cron — edits here are overwritten.
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CLI="node dist/src/cli/exchange-rates.cli.js"
# Crypto prices (CoinGecko, one call for all coins).
*/10 * * * * root docker exec tmp-api $CLI fetch:crypto 2>&1 | logger -t tmp-rates
# Fiat for USD/EUR/GBP bases (plus crypto), once a day.
15 2 * * * root docker exec tmp-api $CLI fetch 2>&1 | logger -t tmp-rates
CRON
    ;;

  logs)
    ssh "$HOST" "cd $REMOTE && docker compose logs -f --tail=200 ${2:-}"
    ;;

  status)
    echo "containers:"
    ssh "$HOST" "cd $REMOTE && docker compose ps -a --format 'table {{.Service}}\t{{.Status}}'" || true

    echo
    echo "inside the network (no DNS, Cloudflare or Caddy involved):"
    ssh "$HOST" "docker exec tmp-api wget -qO- -T 5 http://127.0.0.1:3000/health >/dev/null 2>&1 && echo '  tmp-api  ok' || echo '  tmp-api  NOT ANSWERING'
                 docker exec tmp-web wget -qO- -T 5 http://127.0.0.1/healthz  >/dev/null 2>&1 && echo '  tmp-web  ok' || echo '  tmp-web  NOT ANSWERING'"

    # Two views, because Cloudflare proxies both names. The public request is answered by
    # Cloudflare with Cloudflare's certificate, so a trusted cert there says nothing about
    # the origin — and Cloudflare can serve its own error page with a 5xx that still looks
    # like "an answer". --resolve sends the same request straight to the droplet, where
    # Caddy's own Let's Encrypt certificate has to verify.
    probe() {
      local label="$1" url="$2"; shift 2
      local out code verify robots
      out=$(curl -sS -m 15 -o /dev/null -D - -w '\n%{http_code} %{ssl_verify_result}' "$@" "$url" 2>/dev/null) || {
        printf '  %-8s %-44s DOWN\n' "$label" "$url"; return
      }
      read -r code verify <<<"$(printf '%s\n' "$out" | tail -1)"
      robots=$(printf '%s\n' "$out" | tr -d '\r' | sed -n 's/^[Xx]-[Rr]obots-[Tt]ag: *//p' | head -1)
      printf '  %-8s %-44s %s  cert=%s  noindex=%s\n' "$label" "$url" "$code" \
        "$([ "$verify" = 0 ] && echo trusted || echo "FAIL($verify)")" \
        "$(case "$robots" in *noindex*) echo yes ;; *) echo MISSING ;; esac)"
    }
    echo
    echo "public, via Cloudflare:"
    probe web "$WEB_ORIGIN/healthz"
    probe api "$API_ORIGIN/health"
    echo "origin, straight to $ORIGIN_IP (Caddy's own certificate):"
    probe web "$WEB_ORIGIN/healthz" --resolve "$WEB_HOST:443:$ORIGIN_IP"
    probe api "$API_ORIGIN/health" --resolve "$API_HOST:443:$ORIGIN_IP"

    # The whole point of the memory limits is that TrackMyPocket cannot take BipPass with
    # it, so BipPass's numbers belong in this output. Redis too: its 32 MB is shared.
    echo
    ssh "$HOST" "free -m | awk 'NR==1||/Mem:|Swap:/'; echo; df -h / | tail -1; echo
                 docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}'
                 echo; printf 'redis: used %s of maxmemory %s; evicted_keys %s; db1 %s\n' \
                   \"\$(docker exec bippass-redis-1 redis-cli info memory | sed -n 's/^used_memory_human://p' | tr -d '\r')\" \
                   \"\$(docker exec bippass-redis-1 redis-cli info memory | sed -n 's/^maxmemory_human://p' | tr -d '\r')\" \
                   \"\$(docker exec bippass-redis-1 redis-cli info stats | sed -n 's/^evicted_keys://p' | tr -d '\r')\" \
                   \"\$(docker exec bippass-redis-1 redis-cli info keyspace | sed -n 's/^db1://p' | tr -d '\r')\"" || true

    # Is what is RUNNING what is COMMITTED? Healthy and current are different questions.
    echo
    echo "deployed vs committed:"
    check_rev() {
      local label="$1" repo="$2" container="$3" deployed local_head behind
      deployed=$(ssh "$HOST" "docker inspect $container --format '{{index .Config.Labels \"org.opencontainers.image.revision\"}}'" 2>/dev/null || true)
      local_head=$(revision "$repo")
      if [ -z "$deployed" ] || [ "$deployed" = "<no value>" ]; then
        printf '  %-9s not running, or no revision label\n' "$label"
      elif [ "$deployed" = "$local_head" ]; then
        printf '  %-9s %s — current\n' "$label" "$deployed"
      else
        behind=$(git -C "$repo" rev-list --count "${deployed%+dirty}..HEAD" 2>/dev/null || echo "?")
        printf '  %-9s %s — STALE, %s commit(s) behind %s · run: %s deploy\n' \
          "$label" "$deployed" "$behind" "$local_head" "$SELF"
      fi
    }
    check_rev backend "$BE_REPO" tmp-api
    check_rev frontend "$FE_REPO" tmp-web
    ;;

  *)
    echo "usage: $SELF [shell|provision|build|deploy|expose|status|logs [service]|paddle-key|ai-key|mail-key|google-key|rates|cron [remove]]" >&2
    exit 2
    ;;
esac
