# Helm charts for CD4PE and SCM

Unofficial Helm charts for two Puppet products: Continuous Delivery for Puppet Enterprise (CD4PE) and Security Compliance Management (SCM).

Puppet ships both products as containers run by a Bolt module (`cd4peadm` and `complyadm`) under docker or podman on a host, and that's the supported way to install them. These charts aren't supported by Puppet. They run the same containers with the same configuration on Kubernetes, for people who'd rather run them there.

| Chart | Product version | Ported from |
|---|---|---|
| [`cd4pe`](charts/cd4pe) | 5.18.0 | `cd4peadm` 5.18.0 |
| [`scm`](charts/scm) | 3.9.0 | `complyadm` 3.9.0 |

## Status

Both charts have been installed from scratch, upgraded, and logged in to on one cluster so far, which is Talos with ingress-nginx and Rook-Ceph. Neither has been connected to a PE primary yet, so nobody has run a CD4PE pipeline or an SCM scan through them. Each chart's README lists what it doesn't do.

CD4PE needs a licence from Puppet, and the chart has no way to load one yet. The charts pull the product images straight from Puppet's registry and don't redistribute anything.

## Install

```bash
helm install cd4pe ./charts/cd4pe -n puppet --create-namespace \
  --set hostname=cd4pe.example.com \
  --set backendHostname=cd4pe-backend.example.com \
  --set rootUser.email=admin@example.com

helm install scm ./charts/scm -n puppet \
  --set hostname=scm.example.com
```

Both need an ingress controller and a default storage class. CD4PE also needs a `ReadWriteMany` storage class. Without one, set `queryToken.persistence.accessMode=ReadWriteOnce` and the chart pins two of its pods to one node.

The product images start as root and write to their own filesystems, so the namespace can enforce the `baseline` pod security standard but not `restricted`.

## How the charts follow product releases

Each chart is a hand-made port of what the Bolt module renders. A new product release means diffing the new module against the old one and carrying the differences across. In the module, the places that matter are `data/images.yaml`, `functions/config.pp`, `templates/`, `manifests/component/`, and `plans/upgrade.pp`.

Most releases are a version bump. About one release a year per product needs more, usually a base image swap or a database upgrade that needs a dump and restore, and the chart can't do either of those for you.

`Chart.yaml` records the module release each chart was last ported from.

## Checking a change

```bash
helm lint charts/cd4pe --strict -f charts/cd4pe/ci/test-values.yaml
helm template t charts/cd4pe -f charts/cd4pe/ci/test-values.yaml | kubeconform -strict -summary
```

Several of the bugs found while writing the charts only showed up on a real install, so install into a scratch namespace and run `helm test` before trusting a change.
