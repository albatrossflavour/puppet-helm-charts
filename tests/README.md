# Install and login tests

These install each chart on a throwaway [kind](https://kind.sigs.k8s.io/) cluster and log in to the product. Several bugs in these charts passed lint and schema checks and only showed up on a real install, so this is the check to run before trusting a change.

You need docker, kind, kubectl, helm, curl, and python3, and about 10 GB of free disk for the images. `setup-cluster.sh` refuses to start with less than 20 GB free, because a full disk fails every pod with "No space left on device".

```bash
tests/setup-cluster.sh   # kind cluster plus ingress-nginx, on 127.0.0.1:8443
tests/test-cd4pe.sh
tests/test-scm.sh
tests/teardown.sh
```

Each test removes any earlier release, installs the chart, runs `helm test`, logs in through the ingress, upgrades the release, checks the generated Secret didn't change, and logs in again. The SCM test also goes through the forced password change on first login, and turns on the mTLS proxy with a throwaway CA to check it refuses a caller with no client certificate and routes one that has.

Set `BASE_CHART_DIR` to another checkout's `charts` directory and each test also installs that older chart and upgrades it to this one, which is how a release that needs a data migration gets caught.

The scripts only ever talk to the `kind-puppet-charts` context, whatever your kubeconfig points at.

Nothing here connects to PE, so pipelines and scans aren't covered.
