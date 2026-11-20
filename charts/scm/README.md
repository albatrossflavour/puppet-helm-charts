# scm

Puppet Security Compliance Management 3.10.0 on Kubernetes. Unofficial, and not supported by Puppet.

It runs the containers `complyadm` runs, with the configuration that module renders: Postgres, Redis, Hasura (`graphql`), Keycloak (`identity`), `scarpy` (the SCM API), the UI, an oauth2-proxy (`gatekeeper`), and an nginx in front (`frontdoor`).

## Install

```bash
helm install scm oci://ghcr.io/albatrossflavour/charts/scm -n puppet --create-namespace --set hostname=scm.example.com
```

`hostname` is the only value without a default.

The first login is `comply` with the password `compliance`, and it makes you change it straight away.

A cold start takes a few minutes. `scarpy`, `graphql`, and `gatekeeper` each exit when something they depend on isn't up yet, so expect a few restarts.

## What you need

An ingress controller and a default storage class.

The hostname has to resolve from inside the cluster as well as from your browser. `gatekeeper` calls Keycloak on the public hostname, the same as it does on a `complyadm` install, so the request goes out to the ingress and back in. Until that works, logins fail with a 500 at `/oauth2/callback`. If your cluster DNS can't resolve it, point `gatekeeper.hostAliases` at the ingress controller.

`complyadm` puts no size limit on report uploads, so lift your ingress controller's body size limit in `ingress.annotations`.

The nginx, Redis, and Postgres images start as root. The namespace can enforce `baseline` pod security but not `restricted`.

If the namespace restricts egress, `gatekeeper` has to be able to reach the ingress controller on 443, and `scarpy` has to reach the PE primary once PE is connected.

The UI pod copies about 1 GB of CIS-CAT assessor archives into an `emptyDir` on every start, so nodes need that much ephemeral storage.

## Values

`values.yaml` documents every value. The ones you're most likely to touch:

| Value | Default | What it does |
|---|---|---|
| `hostname` | none | Hostname for users and PE. Required |
| `auth.existingSecret` | empty | Use your own Secret for the passwords and keys |
| `ingress.className` | empty | Ingress class |
| `ingress.annotations` | `{}` | Annotations for the Ingress |
| `assessor.version` | `4.65.0` | CIS-CAT assessor version |
| `gatekeeper.hostAliases` | `[]` | See above |
| `frontdoor.keycloakAdminConsole` | `false` | Expose `/auth/admin`, the `admin_console_enabled` setting |
| `pe.existingSecret` | empty | PE certificate and CA, for connecting PE |
| `mtlsProxy.enabled` | `false` | The port agents report to |
| `mtlsProxy.hostname` | empty | The name agents use for that port, when it isn't `hostname` |
| `keepOnUninstall` | `true` | Keep the Secret and PVCs on uninstall |

## Secrets

The chart generates one Secret on first install, with the same lengths and formats `complyadm` uses, and reads it back on every upgrade. With `auth.existingSecret`, supply all sixteen keys yourself:

`postgres-password`, `comply-db-password`, `keycloak-db-password`, `hasura-admin-secret`, `redis-password`, `db-encryption-key`, `keycloak-admin-username`, `keycloak-admin-password`, `client-secret`, `cookie-secret`, `kc-account-secret`, `kc-account-console-secret`, `kc-admin-cli-secret`, `kc-broker-secret`, `kc-realm-management-secret`, and `kc-security-admin-console-secret`.

`cookie-secret` has to be 16, 24, or 32 characters. Keep the database and Redis passwords to letters and digits, because they go into connection URLs as they are.

The database passwords are set when Postgres first starts and the client secrets are set when Keycloak first imports its realm. Changing them in the Secret later doesn't change them in the product.

## Connecting PE

Tested against PE 2025.11.3. SCM pulled the node inventory from PE, started a CIS scan on a node through the orchestrator, and took the report back through the mTLS proxy.

Agents send their reports to SCM on port 30303, with their own PE certificates. `complyadm` publishes that port on the same host as the UI. An ingress only carries 80 and 443, so on Kubernetes the proxy usually needs its own address. Give it a `LoadBalancer` Service and a DNS name of its own, and tell SCM that name with `mtlsProxy.hostname`:

```yaml
pe:
  existingSecret: scm-pe-certs
mtlsProxy:
  enabled: true
  hostname: scm-agents.example.com
  service:
    type: LoadBalancer
```

The proxy needs a certificate from the PE CA for the name agents use. On the PE primary:

```bash
puppetserver ca generate --certname scm-agents.example.com
```

Put the certificate, its key, and the CA certificate in a Secret with the keys `tls.crt`, `tls.key`, and `ca.crt`. On the primary they're `certs/<certname>.pem`, `private_keys/<certname>.pem`, and `certs/ca.pem` under `/etc/puppetlabs/puppet/ssl`.

Every node that will be scanned has to resolve that name and reach it on 30303, and `scarpy` has to reach the PE primary, so a namespace that restricts traffic needs a rule for each.

Then sign in to SCM, open Settings, and give it the PE primary's hostname and a PE login. The lab test used a PE administrator, because SCM creates its own roles in PE when it connects. A narrower role hasn't been tried.

Leave `mtlsProxy.hostname` empty and SCM tells agents to use `hostname`, which only works if port 30303 is reachable at that name. The Service defaults to a NodePort on 30303.

## Differences from a complyadm install

The `comply_*` container names became Service names, because Kubernetes doesn't allow underscores in them. Nothing in the images depends on the old names.

The ordering `complyadm` gets from systemd units and sentinel files is done with init containers on the `scarpy` and UI pods, and a Helm hook job for the Hasura metadata.

`comply_assessor_upgrade` is left out, because its command in `complyadm` 3.9.0 is `env`. All it does is print its environment to the log, database password included.

The Redis image drops to uid 999 but doesn't chown a fresh volume, so the chart sets `fsGroup: 1000` on that pod.

## What it doesn't do

- Backup, restore, and the support bundle, which are `complyadm` plans
- Moving an existing docker install onto the chart
- Scheduled scans, Windows nodes, and exports, which haven't been tried. One ad hoc scan of one Linux node has

## Uninstall

```bash
helm uninstall scm -n puppet
```

`keepOnUninstall` defaults to `true`, so that leaves the PVCs and the generated Secret in place. It also leaves the last post-install job behind, which is what Helm does with hooks. For a clean slate:

```bash
kubectl delete pvc,job,secret -n puppet -l app.kubernetes.io/instance=scm
```

A Secret you supplied through `auth.existingSecret` doesn't carry that label, so neither command touches it.

## Upgrades

A routine upgrade is a chart version bump. `scarp init` and `scarp upgrade-assessor` run in an init container on every start, and the Hasura metadata job runs again. Take a database backup first, because Helm can roll the images back but not the schema.

Keycloak only imports the realm file on first start, so a release that changes the realm may need the change made by hand in Keycloak.

A release that changes the Postgres major version needs a dump before and a restore after, and the chart can't do that.
