#!/usr/bin/env bash
# Install the cd4pe chart on the kind cluster and prove a root login works,
# before and after an upgrade. Run setup-cluster.sh first.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELEASE=cd4pe
HOST=cd4pe.kind.test
BACKEND_HOST=cd4pe-backend.kind.test
ROOT_EMAIL=root@kind.test
VALUES="${TESTS_DIR}/values/cd4pe-kind.yaml"
trap 'dump_state "$RELEASE"' ERR

# POST a login and print "<http code> <body>".
login() {
  local email="$1" password="$2" payload
  payload="$(python3 -c 'import json,sys; print(json.dumps({"op":"PfiLogin","content":{"email":sys.argv[1],"passwd":sys.argv[2]}}))' "$email" "$password")"
  ingress_curl -H 'Content-Type: application/json' -d "$payload" \
    -o /dev/stdout -w '\n%{http_code}' "https://${HOST}/cd4pe/login" | awk '{body=prev; prev=$0} END{print $0, body}'
}

root_password() {
  kubectl -n "$NAMESPACE" get secret "$RELEASE" -o jsonpath='{.data.root-password}' | base64 -d
}

check_login() {
  local result
  result="$(login "$ROOT_EMAIL" "$(root_password)")"
  [[ "$result" == 200\ * && "$result" == *'"success":true'* ]] \
    || fail "root login with the generated password: ${result}"
  pass "root login with the generated password"
}

# The HTTP code for a request, retried for up to a minute until it is the
# expected one, since the UI pod rolls over after a config change.
expect_code() {
  local want="$1" what="$2" code=""
  shift 2
  for _ in $(seq 1 12); do
    code="$(ingress_curl --path-as-is -o /dev/null -w '%{http_code}' "$@" || true)"
    [[ "$code" == "$want" ]] && return 0
    sleep 5
  done
  fail "${what} returned ${code}, not ${want}"
}

# A sign-up body the backend rejects (no username), so a request that gets
# through creates nothing.
SIGNUP_BODY='{"op":"PfiSignup","content":{}}'

# Every path that reaches the backend's sign-up handlers, including the ones
# nginx normalises into them, refused by the UI.
check_signup_closed() {
  local path
  for path in /signup /cd4pe/signup /cd4pe/signup/ /cd4pe/SignUp /cd4pe/api/v1/user/signup \
      /cd4pe/api/v1//user/signup /cd4pe/api/v1/user/sign%75p /cd4pe/x/../signup; do
    expect_code 403 "POST ${path}" -X POST -H 'Content-Type: application/json' -d "$SIGNUP_BODY" "https://${HOST}${path}"
  done
  expect_code 403 "GET /signup" "https://${HOST}/signup"
  expect_code 403 "GET /cd4pe/signup" "https://${HOST}/cd4pe/signup"
  pass "self sign-up is refused on every path"
}

# What has to keep working with sign-up closed. Login is check_login. The rest
# only have to reach the product rather than be refused by nginx: the reset
# calls get a 400 for an empty body, and adding a member to a workspace, which
# is how users join one (there are no invitations), gets a 401 with no login.
check_signup_neighbours() {
  local path
  for path in /login /root/login /forgot-password /reset-password /oauth/github /root/accounts; do
    expect_code 200 "GET ${path}" "https://${HOST}${path}"
  done
  for path in forgot-password reset-password; do
    expect_code 400 "POST /cd4pe/api/v1/user/${path}" \
      -X POST -H 'Content-Type: application/json' -d '{}' "https://${HOST}/cd4pe/api/v1/user/${path}"
  done
  expect_code 401 "POST /cd4pe/api/v1/workspaces/x/members" \
    -X POST -H 'Content-Type: application/json' -d '{}' "https://${HOST}/cd4pe/api/v1/workspaces/x/members"
  pass "login pages, password reset and workspace membership still reach the product"
}

reset_release "$RELEASE"

log "Installing ${RELEASE}"
helm install "$RELEASE" "${REPO_DIR}/charts/cd4pe" -n "$NAMESPACE" -f "$VALUES" \
  --wait --timeout "$INSTALL_TIMEOUT" >/dev/null
pass "helm install reached deployed"

log "helm test"
helm test "$RELEASE" -n "$NAMESPACE" --timeout 3m >/dev/null
pass "helm test"

log "Checks through the ingress"
code="$(ingress_curl -o /dev/null -w '%{http_code}' "https://${HOST}/status")"
[[ "$code" == 200 ]] || fail "UI /status returned ${code}"
pass "UI /status is 200"

# The backend endpoint has no page at /. Anything from the backend itself
# proves the route. A 404, 502 or 503 would be the ingress controller talking.
code="$(ingress_curl -o /dev/null -w '%{http_code}' "https://${BACKEND_HOST}/")"
[[ "$code" != 404 && "$code" != 502 && "$code" != 503 && "$code" != 000 ]] \
  || fail "backend hostname returned ${code}"
pass "backend hostname reaches pipelinesinfra (${code})"

check_login

result="$(login "$ROOT_EMAIL" "not-the-password")"
[[ "$result" == 401\ * ]] || fail "a wrong password was not rejected: ${result}"
pass "a wrong password is rejected"

check_signup_closed
check_signup_neighbours

log "Sign-up switched on"
helm upgrade "$RELEASE" "${REPO_DIR}/charts/cd4pe" -n "$NAMESPACE" -f "$VALUES" --set signup.enabled=true \
  --wait --timeout "$INSTALL_TIMEOUT" >/dev/null
# The backend's own validation answers, which proves nginx let it through.
expect_code 400 "POST /cd4pe/signup with sign-up on" \
  -X POST -H 'Content-Type: application/json' -d "$SIGNUP_BODY" "https://${HOST}/cd4pe/signup"
expect_code 400 "POST /cd4pe/api/v1/user/signup with sign-up on" \
  -X POST -H 'Content-Type: application/json' -d '{}' "https://${HOST}/cd4pe/api/v1/user/signup"
pass "signup.enabled=true lets sign-up through to the backend"

log "Upgrade"
before="$(secret_checksum "$RELEASE")"
helm upgrade "$RELEASE" "${REPO_DIR}/charts/cd4pe" -n "$NAMESPACE" -f "$VALUES" \
  --wait --timeout "$INSTALL_TIMEOUT" >/dev/null
[[ "$(secret_checksum "$RELEASE")" == "$before" ]] || fail "the generated Secret changed on upgrade"
pass "helm upgrade left the generated Secret unchanged"
check_login
check_signup_closed

# A release that needs a data migration installs cleanly from scratch and only
# breaks on upgrade. BASE_CHART_DIR points at the charts from the branch this
# change is going into, so that path gets tested too.
if [[ -n "${BASE_CHART_DIR:-}" ]]; then
  log "Upgrade from the base branch's chart"
  reset_release "$RELEASE"
  helm install "$RELEASE" "${BASE_CHART_DIR}/cd4pe" -n "$NAMESPACE" -f "$VALUES" \
    --wait --timeout "$INSTALL_TIMEOUT" >/dev/null
  check_login
  before="$(secret_checksum "$RELEASE")"
  helm upgrade "$RELEASE" "${REPO_DIR}/charts/cd4pe" -n "$NAMESPACE" -f "$VALUES" \
    --wait --timeout "$INSTALL_TIMEOUT" >/dev/null
  [[ "$(secret_checksum "$RELEASE")" == "$before" ]] || fail "the generated Secret changed on upgrade from the base chart"
  pass "upgrade from the base branch's chart reached deployed"
  check_login
  check_signup_closed
fi

log "cd4pe: all checks passed"
