#!/usr/bin/env bash
# End-to-end test of the whole product on the free Local Docker provider:
# real web server + real Sidekiq worker + real `docker build/run` + the real
# `anchor` CLI, driving a throwaway git repo through every lifecycle path.
#
#   deploy → broken release (health check fails, old version keeps serving)
#   → fixed release → rollback → preflight block → cancel mid-build
#   → signed GitHub webhook push
#
# No cloud account or AI key is used. Runs the same on a laptop and in CI:
#
#   DATABASE_URL=postgres://localhost/anchor_e2e REDIS_URL=redis://localhost:6379/9 script/e2e_local.sh
#
# Needs: Ruby + bundle, Postgres, Redis, Docker, Go, Node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export RAILS_ENV=development
export DATABASE_URL="${DATABASE_URL:-postgres://localhost/anchor_e2e}"
export REDIS_URL="${REDIS_URL:-redis://localhost:6379/9}"
export ENCRYPTION_KEY="${ENCRYPTION_KEY:-e2e00000000000000000000000000000}"
export GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-e2e}" GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:-e2e}"
export HEALTH_CHECK_ATTEMPTS=4 HEALTH_CHECK_BUDGET_SECONDS=25   # fail bad releases fast
unset ANTHROPIC_API_KEY OPENAI_API_KEY                           # never call a paid API

PORT="${E2E_PORT:-3997}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/anchor-e2e.XXXXXX")"
REPO="$WORK/app"
export ANCHOR_URL="http://127.0.0.1:$PORT" HOME="$WORK/home"
mkdir -p "$HOME"
PIDS=()

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pass() { printf '   \033[32m✔\033[0m %s\n' "$*"; }
fail() { printf '   \033[31m✘ %s\033[0m\n' "$*"; dump_logs; exit 1; }

dump_logs() {
  echo "---- web.log (tail) ----";    tail -n 40 "$WORK/web.log"    2>/dev/null || true
  echo "---- worker.log (tail) ----"; tail -n 60 "$WORK/worker.log" 2>/dev/null || true
}

cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  docker ps -aq --filter "name=anchor-cl-e2e-app" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker images -q "anchor-local/cl-e2e-app" | xargs -r docker rmi -f >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

rails_eval() {
  local out
  out=$(bin/rails runner "$1" 2>&1) || { echo "$out" >&2; fail "rails runner failed"; }
  printf '%s' "$out" | grep -v -e 'faraday-retry' || true
}
db()         { rails_eval "print($1)"; }
live_body()  { curl -fsS --max-time 5 "$(db 'Project.find_by!(slug: "e2e-app").latest_url')" 2>/dev/null || true; }
latest_id()  { db 'Project.find_by!(slug: "e2e-app").deployments.maximum(:id)'; }
status_of()  { db "Deployment.find($1).status"; }

commit() { # message, server.js body
  printf '%s\n' "$2" > "$REPO/server.js"
  git -C "$REPO" add -A && git -C "$REPO" -c user.email=e2e@anchor -c user.name=E2E commit -qm "$1"
}

server_js() { # status-code body host
  cat <<JS
const http = require("http");
http.createServer((q, r) => { r.writeHead($1); r.end("$2\\n"); })
  .listen(process.env.PORT || 8080, "$3");
JS
}

# ── Setup ─────────────────────────────────────────────────────────────── #
log "Preparing database, assets, CLI and sample repo"
docker info >/dev/null 2>&1 || fail "Docker is not running"
bin/rails db:drop db:create db:schema:load >/dev/null 2>&1
bin/rails tailwindcss:build >/dev/null 2>&1
redis-cli -u "$REDIS_URL" flushdb >/dev/null 2>&1 || true
(cd cli && go build -o "$WORK/anchor" .)
ANCHOR="$WORK/anchor"

mkdir -p "$REPO"
git -C "$REPO" init -q -b main
printf '{ "name": "e2e-app", "private": true, "scripts": { "start": "node server.js" } }\n' > "$REPO/package.json"
(cd "$REPO" && npm install --package-lock-only --silent >/dev/null 2>&1)
commit "v1" "$(server_js 200 'e2e v1' 0.0.0.0)"

rails_eval '
  user = User.create!(github_id: "e2e", github_login: "e2e", name: "E2E", email: "e2e@anchor.local", github_token: "")
  repo = Repository.create!(user: user, github_id: "e2e-repo", name: "e2e-app", full_name: "e2e/app", owner_login: "e2e",
                            default_branch: "main", clone_url: "file://'"$REPO"'", html_url: "https://example.invalid/e2e",
                            private: false, last_synced_at: Time.current)
  project = user.projects.create!(repository: repo, name: "e2e-app", production_branch: "main", provider: "local_docker",
                                  gcp_project_id: nil, draft: true)
  project.update_columns(draft: false)
  File.write("'"$WORK/token"'", ApiToken.generate!(user: user, name: "e2e").instance_variable_get(:@plaintext_token))
'
export ANCHOR_TOKEN; ANCHOR_TOKEN="$(cat "$WORK/token")"
pass "fixtures ready"

log "Starting web server and Sidekiq worker"
bin/rails server -p "$PORT" -b 127.0.0.1 >"$WORK/web.log" 2>&1 & PIDS+=($!)
bundle exec sidekiq -C config/sidekiq.yml >"$WORK/worker.log" 2>&1 & PIDS+=($!)
for _ in $(seq 1 60); do curl -fsS "$ANCHOR_URL/readyz" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "$ANCHOR_URL/readyz" >/dev/null || fail "/readyz never became healthy"
pass "/readyz ok (database, redis, sidekiq)"

# ── 1. First deploy (generated Dockerfile) ─────────────────────────────── #
log "1. Deploy v1 with a generated Dockerfile"
"$ANCHOR" deploy e2e-app --follow >"$WORK/d1.log" 2>&1 || { cat "$WORK/d1.log"; fail "deploy v1 failed"; }
[[ "$(live_body)" == "e2e v1" ]] || fail "live URL does not serve v1"
pass "v1 live"

# ── 2. Broken release must not take traffic ────────────────────────────── #
log "2. Broken release (HTTP 500) fails its health check; v1 keeps serving"
commit "v2 broken" "$(server_js 500 'e2e v2 broken' 0.0.0.0)"
if "$ANCHOR" deploy e2e-app --follow >"$WORK/d2.log" 2>&1; then fail "broken release reported success"; fi
id=$(latest_id)
[[ "$(status_of "$id")" == "failed" ]]                     || fail "broken release is not failed"
[[ "$(db "Deployment.find($id).error_category")" == "health_check" ]] || fail "wrong error category"
[[ "$(live_body)" == "e2e v1" ]]                            || fail "v1 stopped serving during a bad release"
pass "v2 rejected by health check, v1 still live"

# ── 3. Fixed release supersedes v1 ─────────────────────────────────────── #
log "3. Fixed release goes live and supersedes v1"
commit "v3" "$(server_js 200 'e2e v3' 0.0.0.0)"
"$ANCHOR" deploy e2e-app --follow >"$WORK/d3.log" 2>&1 || { cat "$WORK/d3.log"; fail "deploy v3 failed"; }
[[ "$(live_body)" == "e2e v3" ]] || fail "live URL does not serve v3"
[[ "$(db 'Project.find_by!(slug: "e2e-app").deployments.where(status: "running").count')" == "1" ]] \
  || fail "more than one deployment is marked running"
pass "v3 live, exactly one running deployment"

# ── 4. Rollback ────────────────────────────────────────────────────────── #
log "4. Rollback returns to v1 without a rebuild"
"$ANCHOR" rollback e2e-app >/dev/null 2>&1 || fail "rollback command failed"
id=$(latest_id)
for _ in $(seq 1 30); do [[ "$(status_of "$id")" == "running" ]] && break; sleep 1; done
[[ "$(status_of "$id")" == "running" ]] || fail "rollback deployment never reached running"
[[ "$(live_body)" == "e2e v1" ]]        || fail "rollback did not restore v1"
pass "rolled back to v1"

# ── 5. Preflight blocks an unreachable app before any build ────────────── #
log "5. Preflight blocks an app bound to 127.0.0.1"
commit "v4 localhost" "$(server_js 200 'e2e v4' 127.0.0.1)"
if "$ANCHOR" deploy e2e-app --follow >"$WORK/d5.log" 2>&1; then fail "preflight did not block"; fi
id=$(latest_id)
db "Deployment.find($id).error_message" | grep -q "Preflight" || fail "failure was not a preflight block"
[[ "$(db "Deployment.find($id).build_ref.to_s")" == "" ]] || fail "a build ran despite preflight errors"
[[ "$(live_body)" == "e2e v1" ]] || fail "v1 stopped serving"
pass "blocked before build, v1 still live"

# ── 6. Cancel mid-build ────────────────────────────────────────────────── #
log "6. Cancel a slow build"
cat > "$REPO/Dockerfile" <<'DOCKER'
FROM node:22-alpine
WORKDIR /app
RUN echo "slow step starting" && sleep 120
COPY . .
CMD ["node", "server.js"]
DOCKER
commit "v5 slow" "$(server_js 200 'e2e v5' 0.0.0.0)"
"$ANCHOR" deploy e2e-app >/dev/null 2>&1 || fail "could not start slow deploy"
id=$(latest_id)
for _ in $(seq 1 90); do
  db "Deployment.find($id).deployment_logs.where('message LIKE ?', '%slow step%').exists?" | grep -q true && break
  sleep 1
done
"$ANCHOR" cancel "$id" >/dev/null 2>&1 || fail "cancel command failed"
[[ "$(status_of "$id")" == "cancelled" ]] || fail "deployment is not cancelled"
[[ "$(live_body)" == "e2e v1" ]]           || fail "v1 stopped serving after cancel"
git -C "$REPO" rm -q Dockerfile
pass "cancelled mid-build, v1 still live"

# ── 7. Signed GitHub push webhook ──────────────────────────────────────── #
log "7. A signed push webhook deploys; a forged one is rejected"
commit "v6 via webhook" "$(server_js 200 'e2e v6' 0.0.0.0)"
rails_eval 'Project.find_by!(slug: "e2e-app").update!(auto_deploy: true)'
secret=$(db 'Project.find_by!(slug: "e2e-app").webhook_secret')
body="{\"ref\":\"refs/heads/main\",\"repository\":{\"full_name\":\"e2e/app\"},\"head_commit\":{\"id\":\"$(git -C "$REPO" rev-parse HEAD)\",\"message\":\"v6\",\"author\":{\"name\":\"E2E\"}}}"
sig() { printf 'sha256=%s' "$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$1" | awk '{print $NF}')"; }
hook() { curl -s -o /dev/null -w '%{http_code}' -X POST "$ANCHOR_URL/webhooks/github?project=e2e-app" \
           -H 'Content-Type: application/json' -H 'X-GitHub-Event: push' -H "X-GitHub-Delivery: $2" \
           -H "X-Hub-Signature-256: $1" --data-binary "$body"; }
[[ "$(hook "$(sig wrong-secret)" forged-1)" == "401" ]] || fail "forged webhook was not rejected"
[[ "$(hook "$(sig "$secret")" delivery-1)" == "200" ]]  || fail "signed webhook was not accepted"
id=$(latest_id)
[[ "$(db "Deployment.find($id).triggered_by")" == "webhook" ]] || fail "webhook did not create a deployment"
for _ in $(seq 1 120); do
  s=$(status_of "$id"); [[ "$s" == "running" || "$s" == "failed" ]] && break; sleep 1
done
[[ "$(live_body)" == "e2e v6" ]] || fail "webhook deploy did not go live"
pass "push deployed v6, forged delivery rejected"

log "All end-to-end scenarios passed"
