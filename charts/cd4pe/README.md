# cd4pe

Continuous Delivery for Puppet Enterprise 5.19.1 on Kubernetes. Unofficial, and not supported by Puppet.

It runs the four containers `cd4peadm` runs (`ui`, `pipelinesinfra`, `query`, and `postgres`) with the configuration that module renders.

## Install

```bash
helm install cd4pe oci://ghcr.io/albatrossflavour/charts/cd4pe -n puppet --create-namespace \
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

## Licence

Put the licence file in a Secret under the key `license.lic` and name it in `license.existingSecret`:

```bash
kubectl -n puppet create secret generic cd4pe-licence --from-file=license.lic=./license.lic
```

`cd4peadm` copies the same file to `/etc/puppetlabs/cd4pe/license` on the host. Without one the backend starts, and logs that the file is missing.

## Connecting PE

Tested against PE 2025.11.3 as far as the integration: CD4PE discovered the primary from a PE login and listed its node groups and environments. No pipeline has run through the chart yet.

## Self sign-up

CD4PE lets anyone who can reach the UI create an account, and that account can create its own workspace. Neither the product nor `cd4peadm` has a setting to turn this off, so the chart closes it at the UI's nginx unless `signup.enabled` is `true`.

With it off, the UI answers 403 for the sign-up page (`/signup` and `/cd4pe/signup`), for `POST /cd4pe/signup` (the `PfiSignup` call the form makes), and for `POST /cd4pe/api/v1/user/signup`. The rule matches any path segment named `signup`, so a workspace, project, or repository called `signup` gets a 403 too.

Login, root login, password reset, and adding existing users to a workspace aren't affected. CD4PE has no invitations, and the root account's "add user" in the UI goes through the same sign-up handler, so with sign-up closed to everyone no local account can be made at all. A new local account then comes from LDAP or SAML, from `signup.allowedSources`, or from setting `signup.enabled=true` while that person signs up and turning it off again.

### Sign-up from a trusted network

`signup.allowedSources` keeps sign-up closed except to clients from the CIDRs listed, so an admin on the LAN can add users while the internet still gets a 403. Every other client gets the same 403 as before, on the same paths.

The address checked has to be one the client can't choose. By default it's the UI pod's TCP peer, which is fine if clients connect straight to the pod but behind an ingress is the controller. Behind a proxy, set `signup.clientAddress.header` to a header that proxy always overwrites with the address of the connection it received, and `signup.clientAddress.trustedProxies` to the proxy's addresses. The header is only believed from those peers, and a missing or malformed value is refused.

Don't use `X-Real-IP` or `X-Forwarded-For` from ingress-nginx if it has `enable-real-ip` or `use-forwarded-headers` on. The controller then takes the client address from the request's own `X-Forwarded-For`, trusting every source unless `proxy-real-ip-cidr` says otherwise, and passes that on, so a client can claim any address. `$realip_remote_addr` is the connection's address before that rewrite. Set your own header to it on the UI's Ingress, which needs snippet annotations allowed:

```yaml
# On the UI's Ingress
annotations:
  nginx.ingress.kubernetes.io/configuration-snippet: |
    proxy_set_header X-Ingress-Peer-Addr $realip_remote_addr;
```

```yaml
# In the chart's values
signup:
  allowedSources:
    - 192.168.0.0/16
  clientAddress:
    header: X-Ingress-Peer-Addr
    trustedProxies:
      - 10.42.0.0/16 # the pod network the controller runs in
```

`proxy_set_header` replaces any header of the same name the client sent. Check what the controller sees for each way in: with `externalTrafficPolicy: Cluster`, LAN clients usually arrive from a node's address rather than their own, and a tunnel such as `cloudflared` running in the cluster arrives from its pod's address, which must not be in `allowedSources`.

## Values

`values.yaml` documents every value. The ones you're most likely to touch:

| Value | Default | What it does |
|---|---|---|
| `hostname` | none | UI hostname. Required |
| `backendHostname` | none | Webhook and job hardware hostname. Required |
| `rootUser.email` | none | Root login. Required |
| `signup.enabled` | `false` | Allow self sign-up for everyone. See above |
| `signup.allowedSources` | `[]` | CIDRs that can still sign up with `signup.enabled` false |
| `signup.clientAddress.header` | empty | Header holding the true client address, set by the proxy in front |
| `signup.clientAddress.trustedProxies` | `[]` | Proxies whose `signup.clientAddress.header` is believed |
| `auth.existingSecret` | empty | Use your own Secret for the passwords and keys |
| `license.existingSecret` | empty | Secret holding `license.lic` |
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

Upgrading to 0.4.0 or later turns self sign-up off, because `signup.enabled` defaults to `false`. If an install relied on sign-up to create local accounts, set `signup.enabled: true` before upgrading.

A release that changes the Postgres major version, as 5.15.0 did, needs a dump before and a restore after, and the chart can't do that. Read the CD4PE release notes before every bump.
