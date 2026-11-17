#!/usr/bin/env python3
"""Check that a chart deploys what its module would deploy.

usage: check_match.py <cd4pe|scm>

For every container the module runs, this compares the image, the environment
and (where the module sets one) the command against what the chart renders.
The module side comes from the snapshot in port/snapshots for the release in
the chart's ported-from annotation, so no module download is needed.

A difference is an error unless port/match/<chart>.yaml allows it. Each
allowance records the module's value at the time it was written. If a later
module release changes that value, the allowance stops matching and the
difference is reported again, so a decision made about one release is never
silently carried to the next.

It checks images, environment variable names and values, and commands. It does
not check mounts, ports, or the contents of config files: port/generate_files.py
covers the config files, and the snapshot diff reports the rest.
"""
import json
import os
import re
import shlex
import subprocess
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = {"cd4pe": "cd4peadm", "scm": "complyadm"}
RELEASE = "t"
SECRET = object()


def text_of(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    return "" if value is None else str(value)


def parse_env_file(text):
    """KEY=VALUE lines from a rendered env file."""
    env = {}
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key] = value
    return env


def parse_env_list(items):
    """KEY=VALUE from a manifest's env list, where each item is quoted Puppet source."""
    env = {}
    for item in items or []:
        item = item.strip().strip("'\"")
        if "=" in item:
            key, value = item.split("=", 1)
            env[key] = value
    return env


def module_containers(chart, snapshots):
    """{module container name: {image, env, command}} as the module would run them."""
    config, resources, rendered = snapshots
    out = {}
    if chart == "scm":
        for role in config["roles"].values():
            for name, service in role["services"].items():
                container = service["container"]
                out[name] = {
                    "image": container.get("image"),
                    "env": {k: text_of(v) for k, v in (container.get("env_vars") or {}).items()},
                    "command": container.get("cmd"),
                }
        return out

    images = config["images"]
    components = resources["components"]

    def run_env(component):
        for title, attrs in components[component]["resources"].items():
            if "::runtime::run[" in title:
                return parse_env_list(attrs.get("env"))
        return {}

    backend = config["roles"]["backend"]["services"]
    pipelinesinfra_env = parse_env_file(rendered["templates/cd4pe_env.epp"])
    pipelinesinfra_env.update({k: text_of(v) for k, v in backend["pipelinesinfra"]["env_vars"].items() if v is not None})
    query_env = parse_env_file(rendered["templates/query_env.epp"])
    query_env.update({k: text_of(v) for k, v in backend["query"]["env_vars"].items() if v is not None})
    out["pipelinesinfra"] = {"image": images["pipelinesinfra"], "env": pipelinesinfra_env, "command": None}
    out["query"] = {"image": images["query"], "env": query_env, "command": None}
    out["ui"] = {"image": images["teams_ui"], "env": run_env("teams_ui"), "command": None,
                 "config": config["roles"]["ui"]["services"]["ui"]}
    out["postgres"] = {"image": images["postgres"], "env": run_env("postgres"), "command": None}
    return out


def chart_containers(chart):
    """{(workload component, container name): {image, env, command}} from helm template."""
    values = os.path.join(REPO, "charts", chart, "ci", "test-values.yaml")
    rendered = subprocess.run(
        ["helm", "template", RELEASE, os.path.join(REPO, "charts", chart), "-f", values],
        check=True, capture_output=True, text=True,
    ).stdout
    out = {}
    for doc in yaml.safe_load_all(rendered):
        if not isinstance(doc, dict) or doc.get("kind") not in ("Deployment", "StatefulSet", "Job"):
            continue
        component = doc["metadata"]["labels"].get("app.kubernetes.io/component")
        spec = doc["spec"]["template"]["spec"]
        for container in spec.get("initContainers", []) + spec["containers"]:
            env = {}
            for entry in container.get("env", []):
                env[entry["name"]] = SECRET if "valueFrom" in entry else text_of(entry.get("value"))
            out[(component, container["name"])] = {
                "image": container["image"],
                "env": env,
                "command": container.get("command", []) + container.get("args", []),
            }
    return out


# Where each host-published port in a cd4peadm install ends up in the chart.
# cd4peadm has the containers find each other on the host's own address.
CD4PE_PORTS = {"5432": "postgres:5432", "8080": "pipelinesinfra:8080", "8180": "query:8080", "8800": "pipelinesinfra:8000"}
HOST_ADDRESS = re.compile(r"(?:@@HOST_IP@@|\$\{facts\['networking'\]\['ip'\]\}):(\d+)")


def normalise(chart, value, hostname, app_version, service_config=None):
    """Rewrite a module value into what the chart should carry for it."""
    fullname = f"{RELEASE}-{chart}"
    if chart == "scm":
        value = re.sub(r"comply_(postgres|redis|graphql|identity|scarpy|ui|gatekeeper|frontdoor)\b", rf"{fullname}-\1", value)
        value = value.replace("scm.fixture.test", hostname)
    else:
        value = HOST_ADDRESS.sub(lambda m: f"{fullname}-{CD4PE_PORTS.get(m.group(1), 'unknown:' + m.group(1))}", value)
        value = value.replace("@@HOSTNAME@@", hostname).replace("cd4pe.fixture.test", hostname).replace("@@VERSION@@", app_version)
        # A manifest refers to a setting as ${config['name']}. Take its value from the snapshot.
        if service_config:
            value = re.sub(r"\$\{config\['(\w+)'\]\}", lambda m: text_of(service_config.get(m.group(1), m.group(0))), value)
    return value


def mask_secrets(value):
    """The module side carries fixture secrets, the chart side $(VAR) references. Treat both as one token."""
    return re.sub(r"\$\([A-Z0-9_]+\)|fixture-[a-z0-9-]+", "<secret>", value)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in MODULES:
        sys.exit(__doc__)
    chart = sys.argv[1]
    module = MODULES[chart]
    chart_yaml = yaml.safe_load(open(os.path.join(REPO, "charts", chart, "Chart.yaml")))
    version = chart_yaml["annotations"]["puppet-helm-charts/ported-from"].split()[1]
    snapshots = []
    for kind in ("config", "resources", "rendered"):
        path = os.path.join(REPO, "port", "snapshots", f"{module}-{version}.{kind}.json")
        if not os.path.exists(path):
            sys.exit(f"no {kind} snapshot for {module} {version}: run port/snapshot.sh")
        snapshots.append(json.load(open(path)))

    match = yaml.safe_load(open(os.path.join(REPO, "port", "match", f"{chart}.yaml")))
    mapping = match["containers"]
    hostname = yaml.safe_load(open(os.path.join(REPO, "charts", chart, "ci", "test-values.yaml")))["hostname"]

    # Index the allowances, and track which ones get used.
    allowed = {}
    for entry in match.get("allow") or []:
        allowed[(entry["container"], entry["kind"], entry.get("name", ""))] = entry
    used = set()

    def allow(container, kind, name, module_value):
        entry = allowed.get((container, kind, name))
        if entry is None:
            return False
        if "module" in entry and text_of(entry["module"]) != text_of(module_value):
            problems.append(
                f"{container}: the allowance for {kind} {name or ''} was written against "
                f"{text_of(entry['module'])!r}, and the module now has {text_of(module_value)!r}"
            )
            used.add((container, kind, name))
            return True
        used.add((container, kind, name))
        return True

    problems = []
    module_side = module_containers(chart, snapshots)
    chart_side = chart_containers(chart)

    for name in sorted(set(module_side) - set(mapping)):
        problems.append(f"{name}: the module runs this container and port/match/{chart}.yaml does not mention it")
    seen_chart = set()

    for name, target in sorted(mapping.items()):
        if name not in module_side:
            problems.append(f"{name}: in port/match/{chart}.yaml but the module no longer runs it")
            continue
        theirs = module_side[name]
        if "omitted" in target:
            # Left out of the chart on purpose. Pin what the module did with it.
            if text_of(target.get("module-command")) != text_of(theirs["command"]):
                problems.append(
                    f"{name}: left out when its command was {text_of(target.get('module-command'))!r}, "
                    f"and the module now runs {text_of(theirs['command'])!r}"
                )
            continue
        key = (target["workload"], target["container"])
        seen_chart.add(key)
        if key not in chart_side:
            problems.append(f"{name}: the chart has no container {key[1]} in workload {key[0]}")
            continue
        ours = chart_side[key]

        if theirs["image"] != ours["image"] and not allow(name, "image", "", theirs["image"]):
            problems.append(f"{name}: image is {ours['image']} in the chart, {theirs['image']} in the module")

        for env_name in sorted(theirs["env"]):
            their_value = theirs["env"][env_name]
            if env_name not in ours["env"]:
                if not allow(name, "env-omitted", env_name, their_value):
                    problems.append(f"{name}: the module sets {env_name}={their_value!r} and the chart does not set it")
                continue
            our_value = ours["env"][env_name]
            if our_value is SECRET:
                continue
            expected = normalise(chart, their_value, hostname, chart_yaml["appVersion"], theirs.get("config"))
            if mask_secrets(our_value) != mask_secrets(expected) and not allow(name, "env-differs", env_name, their_value):
                problems.append(f"{name}: {env_name} is {our_value!r} in the chart, and the module's {their_value!r} would be {expected!r}")
        for env_name in sorted(set(ours["env"]) - set(theirs["env"])):
            if not allow(name, "env-chart-only", env_name, None):
                problems.append(f"{name}: the chart sets {env_name} and the module does not")

        if theirs["command"] is not None:
            # The module writes a command as one shell-quoted string, the chart as a list.
            expected = shlex.split(normalise(chart, theirs["command"], hostname, chart_yaml["appVersion"]))
            if ours["command"] != expected and not allow(name, "command", "", theirs["command"]):
                problems.append(f"{name}: command is {ours['command']!r} in the chart, {expected!r} in the module")

    # Chart containers with no counterpart in the module have to be declared.
    extra = set((item["workload"], item["container"]) for item in (match.get("chart-only-containers") or []))
    for key in sorted(set(chart_side) - seen_chart):
        if key not in extra:
            problems.append(f"the chart runs {key[1]} in workload {key[0]}, which maps to nothing in the module")
    for key in sorted(extra - set(chart_side)):
        problems.append(f"port/match/{chart}.yaml lists chart-only container {key[1]} in {key[0]}, which the chart no longer has")

    for key in sorted(set(allowed) - used):
        container, kind, name = key
        problems.append(f"{container}: the allowance for {kind} {name} is no longer needed, remove it")

    if problems:
        print(f"{chart}: {len(problems)} difference(s) from {module} {version}")
        for problem in problems:
            print(f"  {problem}")
        sys.exit(1)
    print(f"{chart}: matches {module} {version} ({len(mapping)} module containers, {len(used)} allowed differences)")


if __name__ == "__main__":
    main()
