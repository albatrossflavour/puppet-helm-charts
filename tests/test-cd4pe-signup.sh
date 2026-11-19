#!/usr/bin/env bash
# Render the cd4pe chart's UI nginx config for each sign-up setting, run it in
# the real UI image, and check who it lets through to sign-up. No cluster: the
# backend is an address nothing listens on, so a request nginx lets through
# gets a 502 and one it refuses gets a 403. Needs docker and helm.
#
# Requests come from the host, so the peer the UI's nginx sees is the docker
# bridge gateway, which is in 172.16.0.0/12.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE="gcr.io/platform-services-297419/teams-ui:$(sed -n 's/^appVersion: *"\(.*\)"/\1/p' "${REPO_DIR}/charts/cd4pe/Chart.yaml")"
CHART="${REPO_DIR}/charts/cd4pe"
CI_VALUES="${CHART}/ci/test-values.yaml"
PEER_NET=172.16.0.0/12
WORK="$(mktemp -d)"
CONTAINER=""
cleanup() {
  [[ -n "$CONTAINER" ]] && docker rm -f "$CONTAINER" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# Render base.conf.template with the given --set flags and start the UI image
# on it, published on a free port on 127.0.0.1.
start_ui() {
  [[ -n "$CONTAINER" ]] && docker rm -f "$CONTAINER" >/dev/null
  helm template t "$CHART" -f "$CI_VALUES" "$@" --show-only templates/configmap.yaml \
    | python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["data"]["base.conf.template"], end="")' \
    > "${WORK}/base.conf.template"
  CONTAINER="$(docker run -d -p 127.0.0.1::3000 \
    -e CD4PE_SERVICE=http://127.0.0.1:9 -e QUERY_SERVICE=http://127.0.0.1:9 \
    -v "${WORK}/base.conf.template:/etc/nginx/templates/base.conf.template:ro" "$IMAGE")"
  PORT="$(docker port "$CONTAINER" 3000/tcp | head -1 | sed 's/.*://')"
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:${PORT}/login" && return 0
    sleep 1
  done
  docker logs "$CONTAINER" 2>&1 | tail -20
  fail "the UI's nginx did not start with: $*"
}

# Assert the HTTP code for a request to the running UI.
expect() {
  local want="$1" what="$2" code
  shift 2
  code="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$@")"
  [[ "$code" == "$want" ]] || fail "${what}: got ${code}, want ${want}"
}

signup_post() {
  expect "$1" "$2" -X POST -H 'Content-Type: application/json' -d '{"op":"PfiSignup","content":{}}' "${@:3}" \
    "http://127.0.0.1:${PORT}/cd4pe/signup"
}
api_signup_post() {
  expect "$1" "$2" -X POST -H 'Content-Type: application/json' -d '{}' "${@:3}" \
    "http://127.0.0.1:${PORT}/cd4pe/api/v1/user/signup"
}

SPOOF=192.0.2.7

log "Pulling ${IMAGE}"
docker pull -q "$IMAGE" >/dev/null

log "Default: sign-up closed to everyone"
start_ui
signup_post 403 "POST /cd4pe/signup"
api_signup_post 403 "POST /cd4pe/api/v1/user/signup"
expect 403 "GET /signup" "http://127.0.0.1:${PORT}/signup"
expect 200 "GET /login" "http://127.0.0.1:${PORT}/login"
pass "sign-up refused, login still served"

log "signup.enabled=true: sign-up open to everyone"
start_ui --set signup.enabled=true --set "signup.allowedSources={192.0.2.0/24}"
signup_post 502 "POST /cd4pe/signup"
api_signup_post 502 "POST /cd4pe/api/v1/user/signup"
pass "sign-up reaches the backend"

log "allowedSources without the peer: still closed, whatever the headers say"
start_ui --set "signup.allowedSources={192.0.2.0/24,198.51.100.0/24}"
signup_post 403 "POST /cd4pe/signup"
for h in X-Forwarded-For X-Real-IP CF-Connecting-IP; do
  signup_post 403 "POST /cd4pe/signup with ${h}: ${SPOOF}" -H "${h}: ${SPOOF}"
  api_signup_post 403 "POST /cd4pe/api/v1/user/signup with ${h}: ${SPOOF}" -H "${h}: ${SPOOF}"
done
expect 403 "GET /signup" "http://127.0.0.1:${PORT}/signup"
expect 200 "GET /login" "http://127.0.0.1:${PORT}/login"
pass "a peer outside allowedSources is refused, and forwarding headers don't change that"

log "allowedSources with the peer: open to it"
start_ui --set "signup.allowedSources={192.0.2.0/24,${PEER_NET}}"
signup_post 502 "POST /cd4pe/signup"
api_signup_post 502 "POST /cd4pe/api/v1/user/signup"
expect 200 "GET /signup" "http://127.0.0.1:${PORT}/signup"
pass "a peer inside allowedSources reaches sign-up"

log "clientAddress.header from a trusted proxy"
start_ui --set "signup.allowedSources={192.0.2.0/24}" \
  --set signup.clientAddress.header=X-Peer-Addr --set "signup.clientAddress.trustedProxies={${PEER_NET}}"
signup_post 502 "header in allowedSources" -H "X-Peer-Addr: ${SPOOF}"
api_signup_post 502 "header in allowedSources, API" -H "X-Peer-Addr: ${SPOOF}"
signup_post 403 "header outside allowedSources" -H "X-Peer-Addr: 203.0.113.1"
signup_post 403 "no header (the proxy itself isn't allowed)"
signup_post 403 "a list in the header" -H "X-Peer-Addr: ${SPOOF}, 203.0.113.1"
signup_post 403 "not an address in the header" -H "X-Peer-Addr: lan"
for h in X-Forwarded-For X-Real-IP CF-Connecting-IP; do
  signup_post 403 "${h} in place of the configured header" -H "${h}: ${SPOOF}"
done
pass "only the configured header from a trusted proxy counts"

log "clientAddress.header from a peer that isn't a trusted proxy"
start_ui --set "signup.allowedSources={192.0.2.0/24}" \
  --set signup.clientAddress.header=X-Peer-Addr --set "signup.clientAddress.trustedProxies={203.0.113.0/24}"
signup_post 403 "header from an untrusted peer" -H "X-Peer-Addr: ${SPOOF}"
pass "the header is ignored from an untrusted peer"

log "Values that must not render"
render_fails() {
  local what="$1"
  shift
  if helm template t "$CHART" -f "$CI_VALUES" "$@" >/dev/null 2>&1; then
    fail "rendered with ${what}"
  fi
}
render_fails "a header and no trusted proxies" --set signup.clientAddress.header=X-Peer-Addr
render_fails "trusted proxies and no header" --set "signup.clientAddress.trustedProxies={10.0.0.0/8}"
render_fails "nginx syntax in a CIDR" --set-json 'signup.allowedSources=["10.0.0.0/8; } server { listen 1"]'
render_fails "nginx syntax in a trusted proxy" --set signup.clientAddress.header=X-Peer-Addr \
  --set-json 'signup.clientAddress.trustedProxies=["10.0.0.0/8 1; default 1"]'
render_fails "nginx syntax in the header name" --set 'signup.clientAddress.header=X-Peer;' \
  --set "signup.clientAddress.trustedProxies={10.0.0.0/8}"
pass "bad sign-up values are refused at render"

log "cd4pe sign-up: all checks passed"
