#!/usr/bin/env bash
# Create the kind cluster and install ingress-nginx in it. Safe to run twice.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Refuse to start on a nearly full disk. A full disk fails every pod on the
# node with "No space left on device", and everything else on the machine with it.
docker_root="$(docker info --format '{{.DockerRootDir}}')"
free_gb="$(df --output=avail -BG "$docker_root" | tail -1 | tr -dc '0-9')"
if (( free_gb < MIN_FREE_GB )); then
  fail "only ${free_gb} GB free under ${docker_root}, need ${MIN_FREE_GB} GB (set MIN_FREE_GB to override)"
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster ${CLUSTER_NAME} already exists"
else
  log "Creating kind cluster ${CLUSTER_NAME}"
  kind create cluster --name "$CLUSTER_NAME" --config "${TESTS_DIR}/kind-cluster.yaml" --wait 120s
fi

log "Installing ingress-nginx ${INGRESS_NGINX_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml" >/dev/null
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s
kubectl -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller --timeout=300s >/dev/null

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# A Ready controller pod is not enough: the admission webhook can still refuse
# connections for a few seconds, and an install that creates an Ingress in that
# window fails. Wait until the API server can really get an Ingress validated.
log "Waiting for the ingress admission webhook"
probe_ingress() {
  kubectl -n "$NAMESPACE" apply --dry-run=server -f - >/dev/null 2>&1 <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webhook-probe
spec:
  ingressClassName: nginx
  rules:
    - host: webhook-probe.kind.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: webhook-probe
                port:
                  number: 80
YAML
}
for attempt in $(seq 1 60); do
  if probe_ingress; then
    break
  fi
  if (( attempt == 60 )); then
    fail "the ingress admission webhook did not start answering within two minutes"
  fi
  sleep 2
done

pass "cluster ${CLUSTER_NAME} is ready, ingress on 127.0.0.1:${INGRESS_HTTPS_PORT}"
