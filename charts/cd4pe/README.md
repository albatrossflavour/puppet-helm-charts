# cd4pe

Continuous Delivery for Puppet Enterprise 5.19.0 on Kubernetes. Unofficial, and not supported by Puppet.

It runs the four containers `cd4peadm` 5.18.0 runs (`ui`, `pipelinesinfra`, `query`, and `postgres`) with the configuration that module renders.

## Install

```bash
helm install cd4pe . -n puppet --create-namespace \
  --set hostname=cd4pe.example.com \
  --set backendHostname=cd4pe-backend.example.com \
  --set rootUser.email=admin@example.com
```

Those three values have no default. `hostname` is the web UI, and `backendHostname` is the endpoint VCS webhooks and job hardware (the hosts that run pipeline jobs) call (what `cd4peadm` publishes as `http://<host>:8000`).

A post-install job sets the root email and password. The password is generated, and you can read it with:

```bash
kubectl get secret cd4pe -n puppet -o jsonpath='{.data.root-password}' | base64 -d
```

If you set `auth.existingSecret`, the password is whatever you put in that Secret, and there's no Secret called `cd4pe`.

A cold start takes a few minutes. `pipelinesinfra` restarts until Postgres is up, and `query` isn't Ready until `pipelinesinfra` has written its token.

## What you need

An ingress controller, and a default storage class for the database and the backend's file storage (`/disk`).

`pipelinesinfra` writes a token file that `query` reads, and they're separate pods, so the token volume defaults to `ReadWriteMany`. Set `queryToken.persistence.storageClass` to a class that supports it. If you don't have one, set `queryToken.persistence.accessMode=ReadWriteOnce` and the chart pins `query` to the same node as `pipelinesinfra`.

The `ui`, `pipelinesinfra`, and `postgres` images start as root and write to their root filesystems. The namespace can enforce `baseline` pod security but not `restricted`.

If the namespace restricts egress, `pipelinesinfra` has to be able to reach the PE primary and your VCS.

## Values

`values.yaml` documents every value. The ones you're most likely to touch:

| Value | Default | What it does |
|---|---|---|
| `hostname` | none | UI hostname. Required |
| `backendHostname` | none | Webhook and job hardware hostname. Required |
| `rootUser.email` | none | Root login. Required |
| `auth.existingSecret` | empty | Use your own Secret for the passwords and keys |
| `ingress.className` | empty | Ingress class |
| `ingress.annotations` | `{}` | Annotations for both Ingress resources |
| `pipelinesinfra.javaArgs` | `-Xmx1024M -Xms1024M` | JVM heap, the `java_args` setting |
| `pipelinesinfra.extraEnv` | `[]` | The optional `cd4peadm` settings, as `CD4PE_*` variables |
| `queryToken.persistence.accessMode` | `ReadWriteMany` | See above |
| `keepOnUninstall` | `true` | Keep the Secret and PVCs on uninstall |
| `image.tag` | chart `appVersion` | Tag for all four images |

## Secrets

The chart generates one Secret on first install and reads it back on every upgrade. With `auth.existingSecret`, supply these keys yourself:

| Key | What it is |
|---|---|
| `root-password` | Root account password |
| `secret-key` | Encrypts secrets in the database. Exactly 16 bytes, base64 encoded |
| `postgres-password` | Postgres superuser |
| `cd4pe-db-password` | The `cd4pe` database role |
| `query-db-password` | The `query` database role |

Keep the database passwords to letters and digits. They go into a JSON file and a connection URL as they are.

The database passwords are set in the Postgres volume the first time it starts, and `secret-key` encrypts data at rest. Changing any of them later locks the product out of its own data, so the Secret and the PVCs are kept on uninstall by default.

## Things the product does that the chart works around

The 5.18.0 backend still carries code from when 4.x ran on Kubernetes. If a service account token is mounted in the pod, it tries to keep the query service token in a Kubernetes Secret, fails, and `query` never starts. The chart sets `automountServiceAccountToken: false` on every pod and doesn't offer a value to change it.

The root password has to be 12 or more characters with upper case, lower case, a digit, and a special character. If it isn't, the post-install job exits 0, sets the email, and leaves the old password in place. A generated password always passes, but check one you supply yourself against that rule.

A Service named `<release>-postgres` makes Kubernetes inject `CD4PE_POSTGRES_PORT` into every pod, and the backend reads `CD4PE_*` for its own settings, so `enableServiceLinks` is off.

## What it doesn't do

- Licence upload. The backend starts without one and logs that `license.lic` is missing
- Trusted certificates and `job-certs.pem`, so job hardware hasn't been tested
- Backup, restore, and the support bundle, which are `cd4peadm` plans
- External database mode, which `cd4peadm` has had since 5.16.0. The chart always runs the product's own Postgres image
- Moving an existing docker install onto the chart

## Uninstall

```bash
helm uninstall cd4pe -n puppet
```

`keepOnUninstall` defaults to `true`, so that leaves the PVCs and the generated Secret in place. It also leaves the last post-install job behind, which is what Helm does with hooks. For a clean slate:

```bash
kubectl delete pvc,job,secret -n puppet -l app.kubernetes.io/instance=cd4pe
```

A Secret you supplied through `auth.existingSecret` doesn't carry that label, so neither command touches it.

## Upgrades

A routine upgrade is a chart version bump. Liquibase migrates the schema when `pipelinesinfra` starts, and the credentials job runs again. Take a database backup first, because Helm can roll the images back but not the schema.

A release that changes the Postgres major version, as 5.15.0 did, needs a dump before and a restore after, and the chart can't do that. Read the CD4PE release notes before every bump.
