# Finding what a new module release changes

The charts are ports of `cd4peadm` and `complyadm`. These scripts turn a module release into three JSON snapshots, so the difference between two releases is a diff and not a read-through. [`docs/maintaining.md`](../docs/maintaining.md) explains how they fit together and what to do when one of them fails. This page is the reference for running them by hand.

```bash
port/snapshot.sh cd4peadm /path/to/modules /tmp/new
port/diff_snapshots.py port/snapshots/cd4peadm-5.19.0.config.json /tmp/new/cd4peadm-5.20.0.config.json
```

`/path/to/modules` holds the module and its dependencies, as `bolt module install` lays them out.

`*.config.json` is the module's own `config()` evaluated by Bolt against the fixture data in `fixtures/`: images, env vars, commands, and the rendered realm and oauth2-proxy files. `*.resources.json` is what each component manifest declares, read from its source: mounts, ports, paths, and files. It also checksums every template, static file, and upgrade plan, so a changed file is named even when nothing else gives it away.

`*.rendered.json` is the module's templates rendered with the fixed values in `render/`.

`snapshots/` holds the releases the charts were last ported from.

`generate_files.py` builds each chart's `files/` from the rendered templates, applying the edits that make them fit Kubernetes. Don't edit those files by hand: change the recipe. `generate_files.py` also writes `module-env.yaml`, the environment the module gives each container. The templates read it, so a variable a release adds, drops, or changes reaches the chart without an edit. A template only sets a variable itself when the value is a secret or a chart value, and those are listed as `chart-sets` in `match/`.

`check_match.py` compares what the chart renders with what the module would run, container by container (image, environment, command, mounted paths, and published ports), and fails on any difference `match/` doesn't allow. Each allowance records the module value it was written against, so it stops applying when the module changes.

`check-release.sh` puts it together: it asks the Forge for the newest released version of a chart's module, snapshots and diffs it, writes a report, and with `--apply` bumps the chart. The `Check for module releases` workflow runs it daily and opens a pull request.

The diff shows what the module changed. It can't show behaviour that changed inside an image, which is what `tests/` is for.
