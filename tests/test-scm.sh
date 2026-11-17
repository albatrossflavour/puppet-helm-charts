#!/usr/bin/env bash
# Install the scm chart on the kind cluster and prove the first login, the
# forced password change, and a normal login work, before and after an
# upgrade. Run setup-cluster.sh first.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELEASE=scm
HOST=scm.kind.test
BASE="https://${HOST}"
VALUES="${TESTS_DIR}/values/scm-kind.yaml"
# Throwaway password for a throwaway cluster. Keycloak wants 12 or more characters.
NEW_PASSWORD='Kind-test-Passw0rd'
WORK="$(mktemp -d)"
trap 'dump_state "$RELEASE"' ERR
trap 'rm -rf "$WORK"' EXIT

# gatekeeper calls Keycloak on the public hostname, so that name has to
# resolve inside the cluster. Point it at the ingress controller.
ingress_ip="$(kubectl -n ingress-nginx get service ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')"
host_aliases="[{\"ip\":\"${ingress_ip}\",\"hostnames\":[\"${HOST}\"]}]"

# install_or_upgrade <install|upgrade> [chart dir]
install_or_upgrade() {
  helm "$1" "$RELEASE" "${2:-${REPO_DIR}/charts/scm}" -n "$NAMESPACE" -f "$VALUES" \
    --set-json "gatekeeper.hostAliases=${host_aliases}" \
    --wait --timeout "$INSTALL_TIMEOUT" >/dev/null
}

# Fetch the front page with an empty cookie jar and follow it to the Keycloak
# sign-in form. Leaves the form in $WORK/signin.html and cookies in $1.
open_signin() {
  local jar="$1"
  : > "$jar"
  ingress_curl -L -c "$jar" -b "$jar" -o "${WORK}/signin.html" "${BASE}/"
  grep -q 'name="username"' "${WORK}/signin.html" || fail "the front page did not lead to the Keycloak sign-in form"
}

# Sign in with a password that needs no change and check the session works.
check_login() {
  local jar="${WORK}/login.jar" final body code
  open_signin "$jar"
  final="$(ingress_curl -L -c "$jar" -b "$jar" -o "${WORK}/home.html" -w '%{url_effective}' \
    --data-urlencode 'username=comply' --data-urlencode "password=${NEW_PASSWORD}" \
    "$(form_action "${WORK}/signin.html")")"
  [[ "$final" == "${BASE}/" ]] || fail "login ended at ${final}, not the UI"
  grep -qi '<title>Security Compliance Management</title>' "${WORK}/home.html" || fail "login did not reach the SCM UI"
  pass "login as comply reaches the UI"

  body="$(ingress_curl -b "$jar" -H 'Content-Type: application/json' -d '{"query":"{ __typename }"}' "${BASE}/v1/graphql")"
  [[ "$body" == *query_root* ]] || fail "GraphQL through the gatekeeper returned: ${body:0:200}"
  pass "GraphQL answers for the logged-in session"

  code="$(ingress_curl -b "$jar" -o /dev/null -r 0-1023 -w '%{http_code}' \
    "${BASE}/files/Assessor-CLI-linux-v$(helm get values "$RELEASE" -n "$NAMESPACE" -a -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["assessor"]["version"])').zip")"
  [[ "$code" == 206 || "$code" == 200 ]] || fail "the assessor download returned ${code}"
  pass "the assessor archive downloads"
}

# Log in with the default credentials and get through the forced password change.
first_login() {
  local jar="${WORK}/first.jar" next final
  open_signin "$jar"
  pass "the front page redirects to the Keycloak sign-in form"

  next="$(ingress_curl -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' \
    --data-urlencode 'username=comply' --data-urlencode 'password=compliance' \
    "$(form_action "${WORK}/signin.html")")"
  [[ -n "$next" ]] || fail "the default login comply/compliance was not accepted"
  ingress_curl -c "$jar" -b "$jar" -o "${WORK}/change.html" "$next"
  grep -q 'name="password-new"' "${WORK}/change.html" || fail "the default login did not force a password change"
  pass "the default login forces a password change"

  final="$(ingress_curl -L -c "$jar" -b "$jar" -o "${WORK}/home.html" -w '%{url_effective}' \
    --data-urlencode "password-new=${NEW_PASSWORD}" --data-urlencode "password-confirm=${NEW_PASSWORD}" \
    "$(form_action "${WORK}/change.html")")"
  [[ "$final" == "${BASE}/" ]] || fail "after the password change the browser ended at ${final}, not the UI"
  pass "the password change completes the OAuth round trip to the UI"

}

reset_release "$RELEASE"

log "Installing ${RELEASE}"
install_or_upgrade install
pass "helm install reached deployed"

log "helm test"
helm test "$RELEASE" -n "$NAMESPACE" --timeout 3m >/dev/null
pass "helm test"

log "First login and forced password change"
first_login

code="$(ingress_curl -o /dev/null -w '%{http_code}' "${BASE}/auth/admin/")"
[[ "$code" == 403 ]] || fail "the Keycloak admin console returned ${code}, expected 403"
pass "the Keycloak admin console is blocked"

log "Login with the new password"
check_login

log "Upgrade"
before="$(secret_checksum "$RELEASE")"
install_or_upgrade upgrade
[[ "$(secret_checksum "$RELEASE")" == "$before" ]] || fail "the generated Secret changed on upgrade"
pass "helm upgrade left the generated Secret unchanged"
check_login

# A release that needs a data migration installs cleanly from scratch and only
# breaks on upgrade. BASE_CHART_DIR points at the charts from the branch this
# change is going into, so that path gets tested too.
if [[ -n "${BASE_CHART_DIR:-}" ]]; then
  log "Upgrade from the base branch's chart"
  reset_release "$RELEASE"
  install_or_upgrade install "${BASE_CHART_DIR}/scm"
  first_login
  before="$(secret_checksum "$RELEASE")"
  install_or_upgrade upgrade
  [[ "$(secret_checksum "$RELEASE")" == "$before" ]] || fail "the generated Secret changed on upgrade from the base chart"
  pass "upgrade from the base branch's chart reached deployed"
  check_login
fi

log "scm: all checks passed"
