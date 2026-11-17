# How this repo works and how to maintain it

The charts are ports of two Bolt modules that Puppet publishes on the Forge.

| Chart | Product | Bolt module |
|---|---|---|
| `cd4pe` | Continuous Delivery for Puppet Enterprise (CD4PE) | `cd4peadm` |
| `scm` | Security Compliance Management (SCM) | `complyadm` |

Most of this repo exists to keep each chart in step with its module without anyone reading a module diff by hand. This page says what the automation does, what it leaves to a person, and what needs looking after.

## The parts

Each module has a function called `config()` that turns an installer's settings into everything the module deploys: images, env vars, commands, and settings. The automation leans on it.

A snapshot is a module release boiled down to three JSON files in `port/snapshots/`, written by `port/snapshot.sh`:

- `<module>-<version>.config.json` is the output of the module's `config()`, evaluated by Bolt against made-up settings.
- `<module>-<version>.resources.json` is what each of the module's component manifests declares (mounts, ports, files), read from the source, plus a checksum of every template and upgrade plan.
- `<module>-<version>.rendered.json` is the module's config templates rendered to text.

A fixture is one of those sets of made-up settings, in `port/fixtures/`. A render spec, in `port/render/`, lists the module templates to render and the fixed value for each template parameter.

A recipe is a function in `port/generate_files.py` that takes one rendered template and applies the edits that make it fit Kubernetes, such as removing TLS or swapping a docker hostname for a Service name. The recipes produce everything in a chart's `files/` directory.

A match file, `port/match/<chart>.yaml`, maps each module container to a chart container. It also holds two lists a maintainer edits. `chart-sets` names the env vars a template sets itself, because the value is a secret or a chart value:

```yaml
comply_graphql:
  workload: graphql
  container: graphql
  chart-sets: [HASURA_GRAPHQL_DATABASE_URL, HASURA_GRAPHQL_ADMIN_SECRET, HASURA_GRAPHQL_LOG_LEVEL]
```

An allowance records one place the chart differs from the module on purpose, with the reason and the module's value at the time:

```yaml
- container: comply_identity
  kind: env-omitted
  name: KC_TRUSTSTORE_PATHS
  module: /certs/cert_chain.pem
  reason: It makes Keycloak trust frontdoor's own certificate. The ingress serves the certificate here.
```

The kinds are `image`, `command`, `env-omitted`, `env-differs`, `env-chart-only`, `mount-omitted`, `mount-chart-only`, and `port-omitted`.

The assessor is the CIS-CAT scanner SCM hands out to nodes. Its version is a separate number from the SCM version, and `complyadm` names the one it treats as newest.

## What happens when Puppet releases a module

The `Check for module releases` workflow runs once a day (19:17 UTC) and can be started by hand from the Actions tab. For each chart it does this:

1. Reads the module version the chart was last ported from, which is the `puppet-helm-charts/ported-from` annotation in `Chart.yaml`.
2. Asks the Forge for the newest released version. It only counts a plain `x.y.z` version that the Forge hasn't marked deleted, so release candidates are never picked up.
3. If the two match, it stops.
4. Otherwise it downloads the new release and snapshots it.
5. It compares the new snapshot with the committed one and writes a report of what changed.
6. It bumps the chart: `appVersion`, the chart version, the annotation, the version mentions in the READMEs and `NOTICE`, and for SCM the assessor version.
7. It regenerates the chart's `files/` from the new release with `port/generate_files.py`.
8. It runs `port/check_match.py`, which checks the chart still deploys what the module does.
9. It pushes a branch called `port/<module>-<version>`, opens a pull request with the report as its description, and starts the lint and install tests on the branch.

Steps 7 and 8 can fail without stopping the run. The branch is still pushed, and what they printed is at the end of the report under "The chart after the bump".

The workflow never merges. A pull request for a drift port opens as a draft, so mark it ready once you've been through the list under "Drift" below. The workflow starts the tests against the branch, so if their results don't show on the pull request, find them on the Actions tab under the branch name.

A release is only raised once: if its branch already exists, the workflow leaves it alone. To redo a port after changing the tooling, delete the branch, which closes its pull request, and run the workflow again to get a new one.

## The four outcomes

The report starts with one of these.

### Version only

Nothing the chart mirrors changed, and the chart gets a patch version. If the checks on the branch pass, merge it.

### Drift

The module changed something the chart mirrors, and the chart gets a minor version. The report lists what `config()` now produces, what the manifests now declare, and a diff of each module file that changed.

Merge a drift branch when all of these are true:

- the lint and install checks on the branch pass
- "The chart after the bump" shows the generator ran and the match check reports a match
- you've read the report, and anything it lists that the next section says isn't automatic has been dealt with on the branch
- the report doesn't say the upgrade plan changed, or you've read the plan and written down what an upgrade needs

### Needs a new fixture

The module now requires settings no fixture has, so there was nothing to compare. The workflow opens an issue titled `<module> <version> needs a new fixture` and pushes no branch. It won't open a second issue while that one is open.

### Could not be snapshotted

Something else stopped the snapshot, most often a module template that gained a parameter. The workflow opens an issue titled `<module> <version> could not be snapshotted` with the error, and pushes no branch.

For both of the last two, the fix goes on `main`. Run the workflow again afterwards and close the issue by hand.

## What is automatic and what isn't

| A module release changes | What happens | Where you fix it |
|---|---|---|
| Only the version | Bumped | Nothing to fix |
| A config template's content | `files/` is regenerated with the change in it | Nothing to fix |
| An env var with a plain value: added, removed, or changed | `files/module-env.yaml` is regenerated and the templates read it | Nothing to fix |
| The assessor version (SCM) | Bumped in `values.yaml` | Nothing to fix |
| A config template, in a way a recipe can't follow | The generator stops, and says so in the report | The recipe, on the port branch |
| An env var whose value is a secret | The generator stops, and says so in the report | A template and `chart-sets`, on the port branch |
| A mount, a port, a command, or an image name | The match check fails and names it | A template or an allowance, on the port branch |
| A container added or removed | The match check fails and names it | A template and the match file, on the port branch |
| A template's parameter list | No branch. "Could not be snapshotted" issue | The render spec, on `main` |
| The settings the module requires | No branch. "Needs a new fixture" issue | A new fixture, on `main` |
| The upgrade plan | The report says so in bold | Read the plan. It may mean a data migration |
| How an image behaves | Only the install tests can notice | See "When the install tests fail" |

## What each failure means and what to do

These are the messages you'll see, in an issue or in a failed check.

### A recipe no longer fits

```text
the recipe no longer fits <module> <version>: nothing matched for: <edit>
```

A module template changed so that one of the edits in a recipe no longer applies. Open `port/snapshots/<module>-<version>.rendered.json` on the port branch to see what the module now writes, fix that recipe's pattern in `port/generate_files.py`, and run `port/generate_files.py <chart>`.

### A template gained a parameter

```text
<template> now takes <parameter>, which port/render/<module>.yaml gives no value for
```

Add a fixed value for it to the render spec. Listing a parameter that an older release doesn't have is fine, because only the parameters a template declares are passed to it.

### An env var can't be generated

```text
<container> <name> looks like a secret or an unresolved setting
```

Set the variable in the chart template, from the Secret or a chart value, and add its name to that container's `chart-sets`.

### The chart and the module disagree

```text
<container>: the module sets <name>=<value> and the chart does not set it
```

The same kind of message appears for a mount, a port, a command, or an image. If the chart should follow the module, change the template. If the chart is right to differ, add an allowance with the reason.

### An allowance is stale

```text
the allowance for <kind> <name> was written against 'A', and the module now has 'B'
```

Somebody decided a difference was fine when the module had the old value. Look at the new value, decide again, and put the new value in the allowance's `module` field.

### An allowance is no longer needed

```text
the allowance for <kind> <name> is no longer needed, remove it
```

The chart and the module now agree on that point, so delete the allowance.

### Generated files are out of date

```text
charts/<chart>/files is out of date for <module> <version>
```

Someone edited a generated file by hand, or changed a recipe without regenerating. Run `port/generate_files.py <chart>` and commit the result. Changes to `files/` have to go through a recipe, because the next release overwrites the directory.

### No fixture fits

```text
no fixture in port/fixtures satisfies <module> <version>
```

Copy the newest fixture for that module to a new file whose name starts with the module name, such as `port/fixtures/cd4peadm-<what changed>.yaml`, and add the settings the error names. Fixtures are tried in alphabetical order and the first one the release accepts is used. Keep the old fixture, because older releases still need it.

### When the install tests fail

The test prints the state of the release and the last log lines of every pod that isn't ready. If the checks before it passed, the chart matches the module and the product itself is behaving differently in the new image. Find the cause in the pod logs, fix the template, and add a comment at the fix saying what the image does, as the existing workarounds do.

## The checks, and what each one proves

| Check | Runs in | What it proves | What it doesn't |
|---|---|---|---|
| `helm lint` and kubeconform | Lint workflow | The chart renders valid Kubernetes objects | That anything starts |
| `generate_files.py --check` | Lint workflow | `files/` is exactly what the recipes produce | That the recipes are right |
| `check_match.py` | Lint workflow | Each container's image, env, command, mounts, and published ports match the module, apart from the allowances | Config file contents, and behaviour inside the image |
| Install and login | Install tests | The product starts on a kind cluster and a real login works | Anything involving PE |
| Upgrade from `main` | Install tests, on any branch other than `main` | An install of the chart on `main` survives the upgrade | A migration that only shows up with real data |
| mTLS proxy (SCM) | Install tests | The proxy starts, refuses a caller with no client certificate, and routes one that has | That PE and SCM talk to each other |

A branch can pass every install test and still not match the module, which is why the match check exists.

## Publishing

The `Publish charts` workflow runs when the install tests pass on `main`. It packages each chart and pushes it to `ghcr.io/albatrossflavour/charts/<chart>` as an OCI artefact, at the version in `Chart.yaml`.

It never overwrites a version that's already there. A change to a chart only reaches users when its `version` goes up, so bump it in the same pull request as the change. A port from the release workflow bumps it for you.

A chart change with no version bump still merges and still passes its tests, and nothing is published. If a fix doesn't seem to have reached anyone, check the version first.

## What needs looking after

### The Forge key

The release workflow uses the `FORGE_TOKEN` repository secret to download the modules and to install the private Bolt gem. If the key expires or is revoked, the workflow fails at the "Install Bolt" step with a 401. Replace it with `gh secret set FORGE_TOKEN`.

The key is an API key from a Forge account. Not every key will do: it has to be able to read `rubygems-puppetcore.puppet.com`, which is where the private Bolt comes from, and a key that can only download modules gets a 401 there.

### The Bolt version

`BOLT_VERSION` in `module-release.yaml` is pinned at 5.2.0. If a module release needs a newer Bolt, the "Check for a newer release" step fails with a Bolt error, or the release is reported as "could not be snapshotted". Raise the pin to a version the private gem source has.

### The scheduled workflow

GitHub turns off scheduled workflows in a repo with no activity for 60 days. If no release has needed porting for a while, check on the Actions tab that the workflow is still enabled.

### Pull requests

The workflow can only open a pull request while the repo setting "Allow GitHub Actions to create and approve pull requests" is on (Settings, Actions, General). It is on. If it gets turned off, the workflow falls back to opening an issue that holds the report and a compare link for the branch, and you merge the branch and close the issue by hand.

The same setting lets a workflow approve a pull request. That doesn't matter while `main` has no rule requiring an approval. If you add one, require a code owner's review so a workflow can't satisfy it.

### Pinned tools

The ingress-nginx version in `tests/lib.sh`, the kubeconform version in `lint.yaml`, and the busybox tag in each chart's `values.yaml` are fixed. Nothing forces a bump. Raise one when a test starts failing because of it, and run the lint and install workflows to check the new version.

### The match files

Each allowance records a decision that a difference from the module is fine. Read the ones a port touches, because an allowance whose reason no longer holds lets a real difference through.

## Doing a port by hand

For the snapshot and the checks you need Bolt, Ruby with the puppet gem, Python 3 with PyYAML, helm, and a Forge key in `FORGE_TOKEN`. For the install tests you also need docker, kind, and kubectl.

```bash
port/check-release.sh cd4pe            # report only, changes nothing
port/check-release.sh cd4pe --apply    # bump the chart, regenerate, check
port/generate_files.py cd4pe --check
port/check_match.py cd4pe
tests/setup-cluster.sh && tests/test-cd4pe.sh
```

Use `scm` and `tests/test-scm.sh` for the other chart. The report is written to `rendered/port/<chart>.md`. The install tests pull about 10 GB of images, and [`tests/README.md`](../tests/README.md) has the detail.

## What this repo does not do

Nothing here migrates data. The report says when a release changed the upgrade plan, and the upgrade test may fail on such a release. Moving a database between Postgres versions is still a runbook someone writes for that release.

The automated tests don't touch PE. Both charts have been connected to a PE install by hand, and SCM has run a scan through one, but no pipeline has run through the CD4PE chart. Each chart's README says how far that went.

There are no backups, and no way to move an existing docker install onto a chart.

## Where things live

| Path | What it is | Edited by |
|---|---|---|
| `charts/<chart>/templates/` | The Kubernetes objects | A person |
| `charts/<chart>/files/` | Config files and `module-env.yaml` | `generate_files.py` only |
| `port/snapshots/` | The module release each chart was ported from | `snapshot.sh` only |
| `port/render/` | The render specs | A person, when a template gains a parameter |
| `port/fixtures/` | The fixtures | A person, when the settings a module requires change |
| `port/match/` | The match files | A person |
| `tests/` | The kind install and login tests | A person |
