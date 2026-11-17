#!/usr/bin/env bash
# Delete the kind cluster and everything in it.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kind delete cluster --name "$CLUSTER_NAME"
