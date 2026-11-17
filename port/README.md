# Finding what a new module release changes

The charts are ports of `cd4peadm` and `complyadm`. These scripts turn a module release into two JSON snapshots, so the difference between two releases is a diff and not a read-through.

```bash
port/snapshot.sh cd4peadm /path/to/modules /tmp/new
port/diff_snapshots.py port/snapshots/cd4peadm-5.18.0.config.json /tmp/new/cd4peadm-5.19.0.config.json
```

`/path/to/modules` holds the module and its dependencies, as `bolt module install` lays them out.

`*.config.json` is the module's own `config()` evaluated by Bolt against the fixture data in `fixtures/`: images, env vars, commands, and the rendered realm and oauth2-proxy files. `*.resources.json` is what each component manifest declares, read from its source: mounts, ports, paths, and files. It also checksums every template, static file, and upgrade plan, so a changed file is named even when nothing else gives it away.

`snapshots/` holds the releases the charts were last ported from.

The diff shows what the module changed. It can't show behaviour that changed inside an image, which is what `tests/` is for.
