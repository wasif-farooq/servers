#!/bin/bash
#
# ApplyBuddy — 165.22.176.141 (shared with BipPass)
#
#   ./applybuddy.sh            ssh in
#   ./applybuddy.sh provision  /srv/applybuddy, a database inside BipPass's postgres,
#                              and a generated .env  (ONCE, first run)
#   ./applybuddy.sh build      build the image without shipping it
#   ./applybuddy.sh deploy     rebuild locally, ship the image, restart
#   ./applybuddy.sh expose     put api.applybuddy.net on Caddy  (ONCE, after DNS)
#   ./applybuddy.sh status     containers, health, memory, deployed-vs-committed
#   ./applybuddy.sh logs       tail the logs
#   ./applybuddy.sh keys       prompt for AI_API_KEY / Google OAuth and store them
#   ./applybuddy.sh keys local copy those same values out of your backend/.env instead
#   ./applybuddy.sh admin      create a Django superuser
#   ./applybuddy.sh shell-py   a Django shell on the server
#
# UNLIKE bippass.sh AND evo.sh, THIS DROPLET IS NOT OURS ALONE. It is BipPass's box,
# and BipPass takes money. Read deploy/docker-compose.prod.yml in the repo for the
# three things that keep one from taking down the other: a separate compose project on
# BipPass's network as external, prefixed service names and network aliases (an
# unprefixed `api` alias would make Caddy's `reverse_proxy api:8080` ambiguous), and a
# hard memory limit so a runaway here is contained to this cgroup.
#
# Only the BACKEND is deployed here. The Next.js web app is on Cloudflare Pages and
# stays there: `pnpm --filter @applybuddy/frontend deploy`. It costs this box nothing.
#
# Caddy, postgres and the network all belong to the BipPass compose project. This
# script never creates or destroys any of them. The one file it needs in the BipPass
# repo is the api.applybuddy.net site block in its Caddyfile — see `expose`.
set -euo pipefail

# Absolute, because `deploy` calls back into $SELF for status after cd'ing into the
# repo to build. A relative $0 stops resolving the moment the directory changes; that
# is how bippass.sh used to report failure after a successful deploy.
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

HOST=root@165.22.176.141
REMOTE=/srv/applybuddy
REPO=${APPLYBUDDY_REPO:-$HOME/work/personal/job-applier}

# BipPass's compose project owns these. Named here so nothing has to guess.
BIPPASS_REMOTE=/srv/bippass
BIPPASS_REPO=${BIPPASS_REPO:-$HOME/work/personal/bippass}
PG=bippass-postgres-1

API_ORIGIN=${API_ORIGIN:-https://api.applybuddy.net}
FRONTEND_URL=${FRONTEND_URL:-https://applybuddy.net}
API_HOST=${API_ORIGIN#https://}

IMAGE=applybuddy-api

build() {
  local rev
  # Stamped as an OCI label so `status` can answer "is what is RUNNING what is
  # COMMITTED?" — the question every other health check fails to ask.
  rev=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)

  echo "==> $IMAGE ($rev)"
  # The build context is backend/, not the repo root: the Dockerfile is there and the
  # TypeScript half of the monorepo has no business in a Python image. .dockerignore
  # keeps venv/ (489 MB), credentials.json and resume.pdf out of it.
  docker build \
    --label "org.opencontainers.image.revision=$rev" \
    -t "$IMAGE:latest" "$REPO/backend"
}

require_provisioned() {
  ssh "$HOST" "test -f $REMOTE/.env" 2>/dev/null || {
    echo "not provisioned yet — run: $SELF provision" >&2
    exit 1
  }
}

case "${1:-shell}" in
  shell)
    exec ssh "$HOST"
    ;;

  provision)
    # BipPass's postgres must already be up: we are adding a database to it, not
    # standing one up. Fail clearly rather than half-provisioning.
    ssh "$HOST" "docker inspect -f '{{.State.Running}}' $PG" 2>/dev/null | grep -q true || {
      echo "$PG is not running. BipPass must be deployed before ApplyBuddy can borrow its postgres." >&2
      exit 1
    }

    ssh "$HOST" "mkdir -p $REMOTE"
    scp "$REPO/backend/deploy/docker-compose.prod.yml" "$HOST:$REMOTE/docker-compose.yml"

    # Secrets are generated ON THE SERVER and never printed here or passed as
    # arguments (which would be visible in ps). Same discipline as bippass.sh.
    ssh "$HOST" "REMOTE='$REMOTE' PG='$PG' API_ORIGIN='$API_ORIGIN' FRONTEND_URL='$FRONTEND_URL' API_HOST='$API_HOST' bash -s" <<'PROVISION'
set -euo pipefail

if [ -f "$REMOTE/.env" ]; then
  echo "$REMOTE/.env already exists — refusing to regenerate."
  echo "A new JWT_SECRET invalidates every token in every installed extension."
  exit 0
fi

DB_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)

# A separate role and database inside BipPass's postgres. Not a second postgres: that
# would cost more memory than ApplyBuddy itself. The role owns only its own database
# and is not a superuser, so it cannot read BipPass's tables.
#
# Idempotent on purpose -- provision must be safe to re-run after a partial failure.
docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -U "${DB_USERNAME:-bippass}" -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'applybuddy') THEN
    CREATE ROLE applybuddy LOGIN PASSWORD '${DB_PASSWORD}';
  ELSE
    ALTER ROLE applybuddy LOGIN PASSWORD '${DB_PASSWORD}';
  END IF;
END
\$\$;
SQL
# CREATE DATABASE cannot run inside the DO block above -- it is not transactional --
# so it is guarded with \gexec instead: the SELECT produces the CREATE statement only
# when the database is absent, and \gexec runs whatever the query returned.
#
# NOT `psql -tc ... | grep -q 1 || createdb`. Under `set -o pipefail` that construct is
# actively wrong: grep -q exits at the first match and SIGPIPEs psql, so the pipeline
# reports failure exactly when the database DOES exist -- and the `||` then tries to
# create it again. It cost a confusing "already exists" to find.
docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -U "${DB_USERNAME:-bippass}" -d postgres <<'SQL'
SELECT 'CREATE DATABASE applybuddy OWNER applybuddy'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'applybuddy')\gexec
SQL
# Postgres grants CONNECT on every database to PUBLIC by default. This closes that for
# the applybuddy database against ordinary roles.
#
# Be clear about what it does NOT do. Isolation here is one-way, and measured:
#
#   applybuddy -> bippass data   BLOCKED. Verified: "permission denied for table
#                                devices". The role is not a superuser and holds no
#                                grants on bippass's tables.
#   bippass    -> applybuddy data  POSSIBLE. `bippass` is the instance SUPERUSER --
#                                initdb makes POSTGRES_USER one -- and a superuser
#                                bypasses every check, this REVOKE included.
#
# That asymmetry is inherent to sharing one postgres and cannot be fixed with grants;
# it would take a second instance, which is the memory this arrangement was avoiding.
# It is the right way round at least: the product that takes money cannot be read by
# the one that does not.
docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -U "${DB_USERNAME:-bippass}" -d postgres \
  -c "REVOKE CONNECT ON DATABASE applybuddy FROM PUBLIC" \
  -c "GRANT CONNECT ON DATABASE applybuddy TO applybuddy"

echo "database 'applybuddy' and role 'applybuddy' ready inside $PG"

umask 077
cat > "$REMOTE/.env" <<EOF
# Generated by applybuddy.sh provision.
#
# JWT_SECRET is the one value here that must never change: it signs the tokens sitting
# in chrome.storage.local in every installed extension, and rotating it logs all of
# them out with no way to tell them why. DJANGO_SECRET_KEY signs sessions only and
# rotates freely -- they are separate for exactly this reason.
DJANGO_SECRET_KEY=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
JWT_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

DJANGO_ENV=prod
DEBUG=false

# The public hostname. Django rejects any request whose Host is not listed -- with a
# 400, before any view runs, which reads as a dead app rather than a config error.
# localhost and 127.0.0.1 are appended in config/settings/base.py for the healthcheck,
# so they are deliberately not here.
ALLOWED_HOSTS=$API_HOST

# postgres is BipPass's container, reachable by service name on the shared network.
DATABASE_URL=postgresql://applybuddy:${DB_PASSWORD}@postgres:5432/applybuddy

FRONTEND_URL=$FRONTEND_URL
CORS_ORIGINS=$FRONTEND_URL

# Two gunicorn workers: /api/apply holds one for the whole ~41s pipeline, and with a
# single worker that would block /health too -- the healthcheck would fail and the
# container would restart itself mid-apply. Measured at 214 MB PSS for the pair,
# against a 512M cgroup limit. Drop to 1 only if the box gets tight.
WEB_CONCURRENCY=2

LOG_LEVEL=INFO
JSON_LOGS=false

# --- set by \`applybuddy.sh keys\` -------------------------------------------
# The app refuses to boot without AI_API_KEY, so this is not optional. It is left
# empty here rather than prompted mid-provision so that provision stays unattended.
AI_API_KEY=
AI_BASE_URL=https://opencode.ai/zen/v1
AI_MODEL=laguna-s-2.1-free

# Google OAuth. Two separate clients: the web app's and the extension's.
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_REDIRECT_URI=$FRONTEND_URL/auth/google/callback
EXTENSION_GOOGLE_CLIENT_ID=
EXTENSION_GOOGLE_CLIENT_SECRET=
GMAIL_SENDER_NAME=
EOF
chmod 600 "$REMOTE/.env"
echo "wrote $REMOTE/.env (0600)"
PROVISION
    # `set -e` in the outer script only catches this because ssh propagates the remote
    # exit status. Checked explicitly anyway: the first version of this script printed
    # "provisioned" after the remote half had died, which is the worst kind of green.
    ssh "$HOST" "test -s $REMOTE/.env" || {
      echo "provisioning did not write $REMOTE/.env — see the output above." >&2
      exit 1
    }
    echo
    echo "provisioned. now:"
    echo "  $SELF keys      # AI_API_KEY at minimum — the app will not boot without it"
    echo "  $SELF deploy"
    ;;

  keys)
    require_provisioned
    if [ "${2:-}" = local ]; then
      # Copy the app credentials out of the developer's own backend/.env instead of
      # retyping them. Values are piped straight from the local file into the remote
      # one -- never printed, never passed as an argument (ps would show it), never
      # expanded by either shell. Only the names and the resulting lengths appear.
      #
      # JWT_SECRET and DJANGO_SECRET_KEY are deliberately NOT in this list. The
      # server's were generated on the server by `provision` and belong to this
      # deployment; copying a laptop's JWT_SECRET here would silently make one machine
      # able to mint tokens for the other.
      LOCAL_ENV="$REPO/backend/.env"
      [ -f "$LOCAL_ENV" ] || { echo "no $LOCAL_ENV to copy from" >&2; exit 1; }
      echo "copying from $LOCAL_ENV (values are not printed):"

      # The merge script is base64'd into the ssh COMMAND, and the credentials go over
      # ssh's STDIN. They cannot share a channel: a `bash -s` fed by a heredoc puts the
      # script on stdin, so the `read` loop then consumes the script's own remaining
      # lines instead of the data -- which is how an earlier version of this appended
      # the literal text `chmod 600 .env` to the server's .env as if it were a variable.
      # Base64 rather than quoting because the awk program is full of quotes; it hides
      # nothing (the script carries no secrets) and just survives two shells intact.
      merge=$(base64 -w0 <<'MERGE'
set -euo pipefail
umask 077
while IFS= read -r line; do
  [ -z "$line" ] && continue
  name=${line%%=*}
  # Skip anything that is not a plain NAME=value line. Belt and braces after the
  # stdin mix-up above wrote a shell command into .env as though it were one.
  case "$name" in ''|*[!A-Za-z0-9_]*) continue ;; esac
  NAME="$name" LINE="$line" awk '
    BEGIN { n = ENVIRON["NAME"]; l = ENVIRON["LINE"] }
    $0 ~ "^" n "=" { print l; found = 1; next }
    { print }
    END { if (!found) print l }
  ' .env > .env.new && mv .env.new .env
  printf "  %-32s %d chars\n" "$name" "$(( ${#line} - ${#name} - 1 ))"
done
chmod 600 .env
MERGE
)
      grep -E '^(AI_API_KEY|AI_BASE_URL|AI_MODEL|AI_STRUCTURED_MODE|GOOGLE_CLIENT_ID|GOOGLE_CLIENT_SECRET|EXTENSION_GOOGLE_CLIENT_ID|EXTENSION_GOOGLE_CLIENT_SECRET|GMAIL_SENDER_NAME)=' "$LOCAL_ENV" \
        | ssh "$HOST" "cd $REMOTE && printf %s '$merge' | base64 -d > /tmp/ab-merge.\$\$ && bash /tmp/ab-merge.\$\$; rc=\$?; rm -f /tmp/ab-merge.\$\$; exit \$rc"
      echo "restart to pick them up: $SELF deploy"
      exit 0
    fi
    # Prompts on the SERVER and edits .env in place. The keys go from your keyboard to
    # the file: never through an argument (visible in ps), never through this shell's
    # history, never through a chat window. Prints stored LENGTHS as confirmation,
    # because an empty AI_API_KEY and a working one look identical until a boot fails.
    ssh -t "$HOST" "cd $REMOTE && bash -s" <<'KEYS'
set -euo pipefail
set_var() {
  local name=$1 prompt=$2 hidden=$3 val
  # </dev/tty, not plain stdin: this whole script arrives on bash's stdin as a
  # heredoc, so an unredirected `read` would silently eat the next LINE OF THIS
  # SCRIPT as the answer and store it as your API key. ssh -t gives us the pty.
  if [ "$hidden" = yes ]; then read -rsp "$prompt (hidden, blank = keep): " val </dev/tty; echo
  else read -rp "$prompt (blank = keep): " val </dev/tty; fi
  [ -z "$val" ] && return 0
  # The value can contain / and &, so sed's s/// is the wrong tool. Rewrite the line
  # with awk, passing the value through the environment rather than the program text.
  VAL="$val" NAME="$name" awk '
    BEGIN { n = ENVIRON["NAME"]; v = ENVIRON["VAL"] }
    $0 ~ "^" n "=" { print n "=" v; found = 1; next }
    { print }
    END { if (!found) print n "=" v }
  ' .env > .env.new && mv .env.new .env && chmod 600 .env
}
set_var AI_API_KEY                    "AI_API_KEY"                    yes
set_var GOOGLE_CLIENT_ID              "GOOGLE_CLIENT_ID"              no
set_var GOOGLE_CLIENT_SECRET          "GOOGLE_CLIENT_SECRET"          yes
set_var EXTENSION_GOOGLE_CLIENT_ID    "EXTENSION_GOOGLE_CLIENT_ID"    no
set_var EXTENSION_GOOGLE_CLIENT_SECRET "EXTENSION_GOOGLE_CLIENT_SECRET" yes
set_var GMAIL_SENDER_NAME             "GMAIL_SENDER_NAME"             no
echo
echo "stored (lengths only):"
grep -E '^(AI_API_KEY|GOOGLE_CLIENT_ID|GOOGLE_CLIENT_SECRET|EXTENSION_GOOGLE_CLIENT_ID|EXTENSION_GOOGLE_CLIENT_SECRET|GMAIL_SENDER_NAME)=' .env \
  | awk -F= '{ printf "  %-32s %d chars\n", $1, length($2) }'
KEYS
    echo "restart to pick them up: $SELF deploy"
    ;;

  build)
    build
    docker images --filter=reference="$IMAGE" --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'
    ;;

  deploy)
    require_provisioned
    build

    # Ship the compose file too, so the server's copy is never ahead of the repo's.
    scp "$REPO/backend/deploy/docker-compose.prod.yml" "$HOST:$REMOTE/docker-compose.yml"

    echo "shipping the image (gzipped in flight; it carries Chromium, so this is the slow part)…"
    docker save "$IMAGE:latest" | gzip -1 | ssh "$HOST" 'gunzip | docker load'

    echo "restarting…"
    ssh "$HOST" "cd $REMOTE && docker compose up -d"

    sleep 10
    "$SELF" status
    ;;

  expose)
    # Putting api.applybuddy.net on Caddy. Separate from `deploy` and run once, because
    # it depends on DNS that this script cannot change, and because getting it wrong
    # burns Let's Encrypt's failed-validation budget.
    #
    # The Caddyfile lives in the BIPPASS repo — bippass.sh deploy scp's it over the
    # server's copy, so a block added anywhere else disappears at the next BipPass
    # deploy. That coupling is unavoidable while Caddy is the only thing on 443.
    resolved=$(dig +short "$API_HOST" A | tail -1)
    want=${HOST#root@}
    if [ "$resolved" != "$want" ]; then
      echo "$API_HOST resolves to '${resolved:-nothing}', not $want." >&2
      echo >&2
      echo "Point it at the droplet first, DNS-only (grey cloud) — Caddy's HTTP-01" >&2
      echo "challenge has to reach this origin, and Cloudflare's proxy intercepts it." >&2
      echo "Re-run this once it resolves. Deploying the site block before then just" >&2
      echo "spends Let's Encrypt's failed-validation allowance." >&2
      exit 1
    fi
    echo "$API_HOST -> $want, good."
    scp "$BIPPASS_REPO/bippass-backend/deploy/Caddyfile" "$HOST:$BIPPASS_REMOTE/Caddyfile"
    # Graceful: Caddy validates the new config first and keeps serving the old one if
    # it does not parse, so a bad Caddyfile cannot take bippass.com down here.
    ssh "$HOST" "cd $BIPPASS_REMOTE && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile" \
      2>&1 | grep -viE '"level":"(info|warn)"' || true
    echo "reloaded. certificate issuance takes a few seconds:"
    sleep 10
    curl -sS -m 20 -o /dev/null -w "  %{http_code}  cert verify=%{ssl_verify_result} (0 = trusted)\n" "$API_ORIGIN/health" || echo "  not answering yet — check: $SELF logs"
    ;;

  admin)
    require_provisioned
    ssh -t "$HOST" "cd $REMOTE && docker compose exec api python manage.py createsuperuser"
    ;;

  shell-py)
    require_provisioned
    ssh -t "$HOST" "cd $REMOTE && docker compose exec api python manage.py shell"
    ;;

  logs)
    ssh "$HOST" "cd $REMOTE && docker compose logs -f --tail=200 ${2:-}"
    ;;

  status)
    echo "containers:"
    ssh "$HOST" "cd $REMOTE && docker compose ps --format 'table {{.Name}}\t{{.Status}}'"

    echo
    echo "health, from inside the compose network (works with or without DNS):"
    ssh "$HOST" "docker exec applybuddy-api curl -sS -m 10 -o /dev/null -w '  /health  %{http_code}\n' http://127.0.0.1:8000/health" 2>/dev/null \
      || echo "  container not answering"

    echo
    echo "through Caddy:"
    curl -sS -m 20 -o /dev/null -w "  $API_ORIGIN/health  %{http_code}  cert verify=%{ssl_verify_result}\n" "$API_ORIGIN/health" 2>/dev/null \
      || echo "  no route yet — DNS, then: $SELF expose"

    # Google OAuth, end to end rather than "the endpoint returned 200".
    #
    # /api/auth/login returning 200 proves nothing: it only means the app formatted a
    # URL. Whether Google ACCEPTS that URL depends on the redirect_uri being registered
    # against the client id, which lives in the .env and is exactly the kind of thing a
    # deploy gets wrong. This deployment shipped with a dev client whose only registered
    # callback was http://localhost:3000/... -- green everywhere above, and login 100%
    # broken. Follow the redirect and let Google answer.
    echo
    echo "google oauth:"
    authurl=$(curl -sS -m 20 "$API_ORIGIN/api/auth/login" 2>/dev/null \
      | sed -n 's/.*"authorization_url":"\([^"]*\)".*/\1/p')
    if [ -z "$authurl" ]; then
      echo "  could not get an authorization_url from $API_ORIGIN/api/auth/login"
    else
      loc=$(curl -sS -m 20 -o /dev/null -w '%{redirect_url}' "$authurl" 2>/dev/null)
      case "$loc" in
        *signin/oauth/error*)
          echo "  BROKEN — Google rejected the request (usually redirect_uri_mismatch)."
          echo "           GOOGLE_CLIENT_ID in $REMOTE/.env must be a client that has"
          echo "           $FRONTEND_URL/auth/google/callback registered. Fix: $SELF keys" ;;
        *accountchooser*|*ServiceLogin*|*consent*|*signin/v2*|*signin/v3*)
          echo "  ok — Google accepted the redirect_uri" ;;
        "") echo "  no redirect from Google; check connectivity" ;;
        *)  echo "  unrecognised response: ${loc%%\?*}" ;;
      esac
    fi

    # The whole point of the memory limit is that ApplyBuddy cannot take BipPass with
    # it, so BipPass's numbers belong in ApplyBuddy's status output.
    echo
    ssh "$HOST" "free -m | awk 'NR==1||/Mem:|Swap:/'; echo; docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}'"

    echo
    echo "deployed vs committed:"
    deployed=$(ssh "$HOST" "docker inspect applybuddy-api --format '{{index .Config.Labels \"org.opencontainers.image.revision\"}}'" 2>/dev/null || true)
    local_head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "?")
    if [ -z "$deployed" ] || [ "$deployed" = "<no value>" ]; then
      printf '  backend   running image predates provenance labels — redeploy to start tracking\n'
    elif [ "$deployed" = "$local_head" ]; then
      printf '  backend   %s — current\n' "$deployed"
    else
      behind=$(git -C "$REPO" rev-list --count "$deployed..HEAD" 2>/dev/null || echo "?")
      printf '  backend   %s — STALE, %s commit(s) behind %s · run: %s deploy\n' \
        "$deployed" "$behind" "$local_head" "$SELF"
    fi
    ;;

  *)
    echo "usage: $SELF [shell|provision|keys [local]|build|deploy|expose|admin|shell-py|logs [service]|status]" >&2
    exit 2
    ;;
esac
