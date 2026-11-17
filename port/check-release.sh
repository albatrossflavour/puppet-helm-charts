#!/usr/bin/env bash
# Check whether the Bolt module behind a chart has a newer release on the
# Forge, and if it has, work out what that release changes and bump the chart.
#
# usage: check-release.sh <cd4pe|scm> [--apply]
#
# Without --apply nothing in the repo changes: it reports and stops.
# With --apply it bumps the chart's versions and replaces the baseline
# snapshots, ready to be committed on a branch.
#
# It writes a Markdown report to $REPORT_DIR/<chart>.md and, under GitHub
# Actions, sets these step outputs:
#
#   status   current | version-only | drift | schema-change
#   module   cd4peadm | complyadm
#   from     the module version the chart was ported from
#   to       the newest released module version
#
# Needs FORGE_TOKEN, bolt, ruby with the puppet gem, python3 and curl.
set -euo pipefail

chart="${1:?chart name: cd4pe or scm}"
apply="${2:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
report_dir="$(realpath -m "${REPORT_DIR:-$repo/rendered/port}")"
forge="${FORGE_BASE_URL:-https://forgeapi.puppet.com}"
export PORT_DIR="$here"

case "$chart" in
  cd4pe) module=cd4peadm ;;
  scm) module=complyadm ;;
  *) echo "unknown chart: $chart" >&2; exit 64 ;;
esac
chart_yaml="$repo/charts/$chart/Chart.yaml"

emit() {
  echo "$1=$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
}

from="$(sed -n "s/^ *puppet-helm-charts\/ported-from: *${module} *//p" "$chart_yaml")"
[[ -n "$from" ]] || { echo "no ported-from annotation for ${module} in ${chart_yaml}" >&2; exit 65; }

# Released versions only: a plain x.y.z that the Forge has not marked deleted.
# The newest is picked by version number, not by upload date.
to="$(curl --silent --show-error --fail --max-time 60 -A puppet-helm-charts \
  "${forge}/v3/releases?module=puppetlabs-${module}&limit=100&sort_by=release_date" |
  python3 -c '
import json, re, sys
versions = [
    r["version"] for r in json.load(sys.stdin)["results"]
    if re.fullmatch(r"\d+\.\d+\.\d+", r["version"]) and not r.get("deleted_at")
]
print(max(versions, key=lambda v: tuple(int(part) for part in v.split("."))))
')"

emit module "$module"
emit from "$from"
emit to "$to"

if [[ "$from" == "$to" ]]; then
  emit status current
  exit 0
fi

: "${FORGE_TOKEN:?FORGE_TOKEN is needed to download ${module} from the Forge}"
mkdir -p "$report_dir"
report="$report_dir/$chart.md"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The new release, with the modules it depends on, laid out the way Bolt does it.
mkdir -p "$work/install"
cat > "$work/install/bolt-project.yaml" <<YAML
name: fetchproject
modules:
  - name: puppetlabs-${module}
    version_requirement: "${to}"
module-install:
  forge:
    baseurl: ${forge}
    authorization_token: "Bearer ${FORGE_TOKEN}"
analytics: false
YAML
(cd "$work/install" && BOLT_GEM=true ${BOLT:-bolt} module install --project "$work/install" > "$work/install.log" 2>&1) ||
  { echo "bolt module install failed:" >&2; sed -E 's/Bearer [A-Za-z0-9]+/Bearer <token>/g' "$work/install.log" >&2; exit 66; }
new_modules="$work/install/.modules"

# The release the chart was ported from, for line-level diffs of changed files.
mkdir -p "$work/old"
curl --silent --show-error --fail --max-time 120 -A puppet-helm-charts \
  -H "Authorization: Bearer ${FORGE_TOKEN}" -o "$work/old.tgz" \
  "${forge}/v3/files/puppetlabs-${module}-${from}.tar.gz"
tar -xzf "$work/old.tgz" --no-same-owner -C "$work/old" --strip-components=1

old_config="$here/snapshots/${module}-${from}.config.json"
old_resources="$here/snapshots/${module}-${from}.resources.json"
[[ -f "$old_config" && -f "$old_resources" ]] ||
  { echo "no baseline snapshot for ${module} ${from} in port/snapshots" >&2; exit 67; }

mkdir -p "$work/new-snapshots"
set +e
"$here/snapshot.sh" "$module" "$new_modules" "$work/new-snapshots" > "$work/snapshot.log" 2>&1
snapshot_rc=$?
set -e

{
  echo "## ${module} ${from} to ${to}"
  echo
} > "$report"

if (( snapshot_rc == 2 )); then
  {
    echo "No fixture in \`port/fixtures\` satisfies ${module} ${to}, so the settings the module requires have changed and there is nothing to diff yet. Write a fixture for the new schema, then run this again."
    echo
    echo '```text'
    tail -n 12 "$work/snapshot.log"
    echo '```'
  } >> "$report"
  emit status schema-change
  exit 0
elif (( snapshot_rc != 0 )); then
  cat "$work/snapshot.log" >&2
  exit 68
fi

new_config="$work/new-snapshots/${module}-${to}.config.json"
new_resources="$work/new-snapshots/${module}-${to}.resources.json"

"$here/diff_snapshots.py" "$old_config" "$new_config" > "$work/config.diff" || true
"$here/diff_snapshots.py" "$old_resources" "$new_resources" > "$work/resources.diff" || true

# Classify, list the changed module files, and write the report body.
status="$(python3 - "$old_config" "$new_config" "$old_resources" "$new_resources" \
  "$work/config.diff" "$work/resources.diff" "$work/old" "$new_modules/$module" "$report" <<'PY'
import difflib
import json
import os
import sys

sys.path.insert(0, os.environ["PORT_DIR"])
from diff_snapshots import flatten, strip_versions, versions_in

old_config, new_config, old_res, new_res, config_diff, res_diff, old_dir, new_dir, report = sys.argv[1:10]


def changes(old_path, new_path):
    old_raw, new_raw = json.load(open(old_path)), json.load(open(new_path))
    old_versions, new_versions = versions_in(old_raw), versions_in(new_raw)
    old = {p: strip_versions(v, old_versions) for p, v in flatten(old_raw)}
    new = {p: strip_versions(v, new_versions) for p, v in flatten(new_raw)}
    return {p for p in set(old) | set(new) if old.get(p) != new.get(p)}


config_changes = changes(old_config, new_config)
resource_changes = changes(old_res, new_res)
# data/images.yaml carries the version numbers, so it changes on every release.
resource_changes.discard("files.data/images.yaml")
changed_files = sorted(p[len("files."):] for p in resource_changes if p.startswith("files."))
drift = bool(config_changes or resource_changes)

with open(report, "a") as out:
    if not drift:
        out.write(
            "Nothing the chart mirrors changed. The module's `config()` output, its component "
            "manifests, its templates and static files, and its upgrade plans are the same once "
            "the version numbers are masked. This is a version-only bump.\n"
        )
    else:
        out.write(
            "The module changed in ways the chart mirrors. The versions are bumped so the tests "
            "run against the new images, but the changes below still have to be ported by hand.\n"
        )
        if any(f.startswith("plans/upgrade") for f in changed_files):
            out.write(
                "\n**The upgrade plan changed.** Read it before merging: that is where a data "
                "migration, such as a dump and restore, shows up.\n"
            )
        for title, path in (("What `config()` produces", config_diff), ("What the component manifests declare", res_diff)):
            body = open(path).read().strip()
            out.write(f"\n### {title}\n\n```text\n{body}\n```\n")
        if changed_files:
            out.write("\n### Changed module files\n")
            for name in changed_files:
                old_file, new_file = os.path.join(old_dir, name), os.path.join(new_dir, name)
                old_lines = open(old_file).read().splitlines() if os.path.exists(old_file) else []
                new_lines = open(new_file).read().splitlines() if os.path.exists(new_file) else []
                lines = list(difflib.unified_diff(old_lines, new_lines, f"a/{name}", f"b/{name}", lineterm="", n=2))
                shown = lines[:120]
                more = [f"... {len(lines) - 120} more lines"] if len(lines) > 120 else []
                out.write(f"\n`{name}`\n\n```diff\n" + "\n".join(shown + more) + "\n```\n")

print("drift" if drift else "version-only")
PY
)"

if [[ "$apply" == "--apply" ]]; then
  python3 - "$repo" "$chart" "$module" "$from" "$to" "$status" "$new_config" <<'PY'
import json
import re
import sys

repo, chart, module, old, new, status, new_config = sys.argv[1:8]


def rewrite(path, edits):
    text = open(path).read()
    for pattern, replacement in edits:
        text, count = re.subn(pattern, replacement, text, flags=re.M)
        if count == 0:
            sys.exit(f"{path}: nothing matched {pattern!r}")
    open(path, "w").write(text)


chart_yaml = f"{repo}/charts/{chart}/Chart.yaml"
major, minor, patch = (int(n) for n in re.search(r"^version: *(\d+)\.(\d+)\.(\d+)", open(chart_yaml).read(), re.M).groups())
# A plain version bump is a patch release of the chart. Anything that needs
# porting is a minor release.
chart_version = f"{major}.{minor}.{patch + 1}" if status == "version-only" else f"{major}.{minor + 1}.0"
rewrite(chart_yaml, [
    (r"^version: .*$", f"version: {chart_version}"),
    (r'^appVersion: .*$', f'appVersion: "{new}"'),
    (rf"^( *puppet-helm-charts/ported-from: *{module}) .*$", rf"\g<1> {new}"),
])
old_re = re.escape(old)
rewrite(f"{repo}/README.md", [(rf"(\| \[`{chart}`\]\(charts/{chart}\) \| ){old_re}( \| `{module}` ){old_re}( \|)", rf"\g<1>{new}\g<2>{new}\g<3>")])
rewrite(f"{repo}/charts/{chart}/README.md", [(rf"^(.*) {old_re} on Kubernetes\.", rf"\g<1> {new} on Kubernetes.")])
rewrite(f"{repo}/NOTICE", [(rf"^( *puppetlabs-{module} +){old_re}$", rf"\g<1>{new}")])

# SCM pins the assessor version the module treats as newest.
assessor = json.load(open(new_config)).get("assessor_version")
if chart == "scm" and assessor:
    rewrite(f"{repo}/charts/scm/values.yaml", [(r'^(  version: )"[\d.]+"$', rf'\g<1>"{assessor}"')])
PY
  rm -f "$here/snapshots/${module}-${from}".*.json
  cp "$work/new-snapshots/${module}-${to}".*.json "$here/snapshots/"

  # Regenerate the chart's config files from the new release, then check the
  # chart still deploys what the module does. Both results go in the report:
  # a recipe that no longer fits, or a difference the match file does not
  # allow, is work for a person.
  {
    echo
    echo "### The chart after the bump"
    echo
    echo '```text'
    "$here/generate_files.py" "$chart" 2>&1 || true
    git -C "$repo" status --short -- "charts/$chart/files" | sed 's/^/changed: /'
    "$here/check_match.py" "$chart" 2>&1 || true
    echo '```'
  } >> "$report"
fi

emit status "$status"
