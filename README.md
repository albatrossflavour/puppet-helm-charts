# Helm charts for CD4PE and SCM

Unofficial Helm charts for two Puppet products: Continuous Delivery for Puppet Enterprise (CD4PE) and Security Compliance Management (SCM).

Puppet ships both products as containers run by a Bolt module (`cd4peadm` and `complyadm`) under docker or podman on a host, and that's the supported way to install them. These charts aren't supported by Puppet. They run the same containers with the same configuration on Kubernetes, for people who'd rather run them there.

| Chart | Product version | Ported from |
|---|---|---|
| [`cd4pe`](charts/cd4pe) | 5.19.0 | `cd4peadm` 5.19.0 |
| [`scm`](charts/scm) | 3.9.1 | `complyadm` 3.9.1 |

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

Each chart is a port of what the Bolt module renders, and only of module versions Puppet has released on the Forge. The config files under each chart's `files/` are generated from the module's templates, and the templates are written by hand and checked against the module. Release candidates and unreleased code aren't ported. A new product release means diffing the new module against the old one and carrying the differences across. In the module, the places that matter are `data/images.yaml`, `functions/config.pp`, `templates/`, `manifests/component/`, and `plans/upgrade.pp`.

Most releases are a version bump. About one release a year per product needs more, usually a base image swap or a database upgrade that needs a dump and restore, and the chart can't do either of those for you.

`Chart.yaml` records the module release each chart was last ported from. [`port/`](port) has scripts that snapshot a module release and diff two of them, which is how to find what a new release changed.

## Checking a change

```bash
helm lint charts/cd4pe --strict -f charts/cd4pe/ci/test-values.yaml
helm template t charts/cd4pe -f charts/cd4pe/ci/test-values.yaml | kubeconform -strict -summary
```

Several of the bugs found while writing the charts only showed up on a real install. [`tests/`](tests) installs each chart on a throwaway kind cluster and logs in to the product, and the same tests run in GitHub Actions on every change to a chart.

## Licence

Apache-2.0, the same licence as the two Puppet modules the charts are ported from. `NOTICE` lists what was derived from them.

The licence covers the charts, not the products. CD4PE and SCM are Puppet's, under Puppet's own terms.
