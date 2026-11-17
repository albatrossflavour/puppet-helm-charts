# scm

Puppet Security Compliance Management 3.9.0 on Kubernetes. Unofficial, and not supported by Puppet.

It runs the containers `complyadm` 3.9.0 runs, with the configuration that module renders: Postgres, Redis, Hasura (`graphql`), Keycloak (`identity`), `scarpy` (the SCM API), the UI, an oauth2-proxy (`gatekeeper`), and an nginx in front (`frontdoor`).

## Install

```bash
helm install scm . -n puppet --create-namespace --set hostname=scm.example.com
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
| `mtlsProxy.enabled` | `false` | The port PE and agents report to |
| `keepOnUninstall` | `true` | Keep the Secret and PVCs on uninstall |

## Secrets

The chart generates one Secret on first install, with the same lengths and formats `complyadm` uses, and reads it back on every upgrade. With `auth.existingSecret`, supply all sixteen keys yourself:

`postgres-password`, `comply-db-password`, `keycloak-db-password`, `hasura-admin-secret`, `redis-password`, `db-encryption-key`, `keycloak-admin-username`, `keycloak-admin-password`, `client-secret`, `cookie-secret`, `kc-account-secret`, `kc-account-console-secret`, `kc-admin-cli-secret`, `kc-broker-secret`, `kc-realm-management-secret`, and `kc-security-admin-console-secret`.

`cookie-secret` has to be 16, 24, or 32 characters. Keep the database and Redis passwords to letters and digits, because they go into connection URLs as they are.

The database passwords are set when Postgres first starts and the client secrets are set when Keycloak first imports its realm. Changing them in the Secret later doesn't change them in the product.

## Connecting PE

The proxy is tested with a throwaway CA standing in for the PE CA: it starts, refuses a caller with no client certificate, and routes one that has a certificate to `scarpy`. It hasn't been run against a real PE install.

SCM needs a certificate signed by the PE CA. On the PE primary:

```bash
puppetserver ca generate --certname scm.example.com
```

Put the certificate, its key, and the CA certificate in a Secret with the keys `tls.crt`, `tls.key`, and `ca.crt`, then set `pe.existingSecret` and `mtlsProxy.enabled=true`. The proxy is published as a NodePort on 30303 by default, which is the port `complyadm` uses.

## Differences from a complyadm install

The `comply_*` container names became Service names, because Kubernetes doesn't allow underscores in them. Nothing in the images depends on the old names.

The ordering `complyadm` gets from systemd units and sentinel files is done with init containers on the `scarpy` and UI pods, and a Helm hook job for the Hasura metadata.

`comply_assessor_upgrade` is left out, because its command in `complyadm` 3.9.0 is `env`. All it does is print its environment to the log, database password included.

The Redis image drops to uid 999 but doesn't chown a fresh volume, so the chart sets `fsGroup: 1000` on that pod.

## What it doesn't do

- Backup, restore, and the support bundle, which are `complyadm` plans
- Moving an existing docker install onto the chart
- Anything proven end to end with PE. Nothing has been scanned through it yet, so the report upload path is untested

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
