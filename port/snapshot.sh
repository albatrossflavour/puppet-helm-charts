#!/usr/bin/env bash
# Snapshot what a cd4peadm or complyadm release would deploy, as three JSON files:
#
#   <out>/<module>-<version>.config.json     the module's own config() evaluated
#                                            by Bolt against fixture data
#   <out>/<module>-<version>.resources.json  what each component manifest
#                                            declares, read from its source
#   <out>/<module>-<version>.rendered.json   the module's templates rendered
#                                            with the values in port/render
#
# usage: snapshot.sh <cd4peadm|complyadm> <dir holding that module and its dependencies> [out dir]
#
# Needs bolt, and ruby with the puppet gem (Bolt's own ruby has it).
set -euo pipefail

module="${1:?module name}"
moduleset="$(realpath "${2:?module directory}")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(realpath -m "${3:-$here/snapshots}")"
mkdir -p "$out"

[[ -f "$moduleset/$module/metadata.json" ]] || { echo "no $module under $moduleset" >&2; exit 1; }
version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$moduleset/$module/metadata.json")"
name="${module}-${version}"

proj="$(mktemp -d)"
trap 'rm -rf "$proj"' EXIT
mkdir -p "$proj/data"
cp "$here/bolt/inventory.yaml" "$here/bolt/hiera.yaml" "$proj/"
cat > "$proj/bolt-project.yaml" <<YAML
name: snapshotproject
modulepath:
  - $here/bolt/modules
  - $moduleset
analytics: false
YAML

# The settings a module requires change between releases, so there can be more
# than one fixture per module. Use the first one this release accepts. If none
# fits, the settings schema has changed and a fixture needs writing, which is
# itself something a person porting the release needs to know.
config_ok=""
for fixture in "$here"/fixtures/"${module}"*.yaml; do
  cp "$fixture" "$proj/data/common.yaml"
  # The modules read data/common.yaml relative to the working directory.
  if (cd "$proj" && BOLT_GEM=true ${BOLT:-bolt} plan run "snapshot::${module}" --project "$proj" --format json \
      > "$proj/config.json" 2> "$proj/bolt.err"); then
    config_ok="$(basename "$fixture")"
    break
  fi
done
if [[ -z "$config_ok" ]]; then
  echo "no fixture in port/fixtures satisfies ${name}. Last error:" >&2
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("msg", "")[-600:])' "$proj/config.json" >&2 || cat "$proj/bolt.err" >&2
  exit 2
fi
# config() stamps today's date into the backup file name. Take it out, so the
# same release always gives the same snapshot.
python3 - "$proj/config.json" "$out/${name}.config.json" <<'PY'
import json, re, sys
config = json.load(open(sys.argv[1]))
if isinstance(config.get("dump_filename"), str):
    config["dump_filename"] = re.sub(r"\d{4}-\d{2}-\d{2}", "<date>", config["dump_filename"])
with open(sys.argv[2], "w") as out:
    json.dump(config, out, indent=2, sort_keys=True)
    out.write("\n")
PY

ruby "$here/extract_resources.rb" "$moduleset/$module" > "$out/${name}.resources.json"

# The module's templates, rendered with the fixed values in port/render. The
# chart's config files are generated from these.
ruby "$here/render_templates.rb" "$moduleset/$module" "$here/render/${module}.yaml" > "$out/${name}.rendered.json"

echo "${name}: config (fixture ${config_ok}), resources and rendered templates written to ${out}"
