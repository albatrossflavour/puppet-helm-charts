# shellcheck shell=bash
# Shared settings and helpers for the chart tests. Sourced, not run.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-puppet-charts}"
NAMESPACE="${NAMESPACE:-e2e}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.15.1}"
INGRESS_HTTPS_PORT="${INGRESS_HTTPS_PORT:-8443}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-15m}"
# Both charts together pull about 10 GB of images into the kind node, which
# lives on the docker host's disk.
MIN_FREE_GB="${MIN_FREE_GB:-20}"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

# Never fall through to whatever cluster the caller's kubeconfig points at.
kubectl() { command kubectl --context "$KUBE_CONTEXT" "$@"; }
helm() { command helm --kube-context "$KUBE_CONTEXT" "$@"; }

log() { printf '\n==> %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
# An explicit exit never fires the ERR trap, so a failed check dumps the
# release's state itself. Without this, a check that fails with every pod
# Ready leaves nothing to diagnose it from.
fail() {
  printf 'FAIL  %s\n' "$*" >&2
  if [[ -n "${RELEASE:-}" ]]; then dump_state "$RELEASE" >&2; fi
  exit 1
}

# curl to a test hostname. Every request for <anything>:443 is sent to the
# ingress controller's published port, and its self-signed certificate is accepted.
ingress_curl() {
  curl --silent --show-error --insecure --max-time 60 \
    --connect-to "::127.0.0.1:${INGRESS_HTTPS_PORT}" "$@"
}

# The action URL of the first form in an HTML file.
form_action() {
  python3 - "$1" <<'PY'
import html, re, sys
match = re.search(r'<form[^>]*action="([^"]+)"', open(sys.argv[1]).read())
print(html.unescape(match.group(1)) if match else "")
PY
}

# Print pod state and recent logs for a release, for a failed run.
dump_state() {
  local release="$1"
  log "State of ${release} at failure"
  kubectl -n "$NAMESPACE" get pods,jobs,pvc -l "app.kubernetes.io/instance=${release}" -o wide || true
  for pod in $(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=${release}" \
      --field-selector=status.phase!=Succeeded -o name 2>/dev/null); do
    # Ready pods too: a check can fail against a release whose pods all look healthy.
    if kubectl -n "$NAMESPACE" wait --for=condition=Ready "$pod" --timeout=1s >/dev/null 2>&1; then
      echo "--- ${pod} (ready)"
    else
      echo "--- ${pod} (not ready)"
    fi
    kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail=30 2>&1 | cut -c1-300 || true
  done
  echo "--- recent events"
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -20 | cut -c1-300 || true
}

# A checksum of a Secret's data, to prove an upgrade left it alone.
secret_checksum() {
  kubectl -n "$NAMESPACE" get secret "$1" -o jsonpath='{.data}' | sha256sum | cut -d' ' -f1
}

# Remove a release and everything it leaves behind, so each run starts clean.
reset_release() {
  local release="$1"
  if helm status "$release" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Removing the existing ${release} release"
    helm uninstall "$release" -n "$NAMESPACE" --wait --timeout 5m >/dev/null
  fi
  kubectl -n "$NAMESPACE" delete pvc,job,secret -l "app.kubernetes.io/instance=${release}" \
    --ignore-not-found --wait=true >/dev/null
}
