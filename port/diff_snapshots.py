#!/usr/bin/env python3
"""Report what changed between two module snapshots, in chart terms.

usage: diff_snapshots.py OLD.json NEW.json
"""
import json
import re
import sys


def flatten(node, path=""):
    """Yield (path, value) for every leaf."""
    if isinstance(node, dict):
        for key in sorted(node):
            yield from flatten(node[key], f"{path}.{key}" if path else key)
    elif isinstance(node, list):
        if all(not isinstance(item, (dict, list)) for item in node):
            yield path, node
        else:
            for index, item in enumerate(node):
                yield from flatten(item, f"{path}[{index}]")
    else:
        yield path, node


def strip_versions(value, versions):
    """Replace the module's own version strings, so a plain bump is not noise."""
    if isinstance(value, str):
        for version in versions:
            value = value.replace(version, "<version>")
    elif isinstance(value, list):
        value = [strip_versions(item, versions) for item in value]
    return value


def versions_in(snapshot):
    """Image tags and assessor versions this snapshot carries."""
    found = set()
    for image in (snapshot.get("images") or {}).values():
        if isinstance(image, str) and ":" in image:
            found.add(image.rsplit(":", 1)[1])
    if isinstance(snapshot.get("assessor_version"), str):
        found.add(snapshot["assessor_version"])
    # Longest first, so "v3.9.0" is replaced before "3.9.0".
    more = {tag.lstrip("v") for tag in found}
    return sorted(found | more, key=len, reverse=True)


def short(value, limit=110):
    text = json.dumps(value) if not isinstance(value, str) else value
    return text if len(text) <= limit else text[: limit - 3] + "..."


def main():
    old_raw, new_raw = (json.load(open(path)) for path in sys.argv[1:3])
    old_versions, new_versions = versions_in(old_raw), versions_in(new_raw)
    old = {path: strip_versions(value, old_versions) for path, value in flatten(old_raw)}
    new = {path: strip_versions(value, new_versions) for path, value in flatten(new_raw)}

    print(f"versions: {', '.join(old_versions) or '-'}  ->  {', '.join(new_versions) or '-'}")
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = sorted(path for path in set(old) & set(new) if old[path] != new[path])
    # A value of None is a setting the module knows about but the fixture leaves unset.
    def show_change(path):
        before, after = old[path], new[path]
        if isinstance(before, list) and isinstance(after, list):
            lines = [f"- {short(item)}" for item in before if item not in after]
            lines += [f"+ {short(item)}" for item in after if item not in before]
            return "\n      " + "\n      ".join(lines or ["(order only)"])
        if isinstance(before, str) and isinstance(after, str) and ("\n" in before or "\n" in after):
            import difflib
            lines = [
                line for line in difflib.unified_diff(before.splitlines(), after.splitlines(), lineterm="", n=0)
                if line[:1] in "+-" and line[:3] not in ("+++", "---")
            ]
            shown = [short(line) for line in lines[:12]]
            more = [f"... {len(lines) - 12} more changed lines"] if len(lines) > 12 else []
            return "\n      " + "\n      ".join(shown + more)
        return f"{short(before, 70)}  ->  {short(after, 70)}"

    for title, paths, show in (
        ("ADDED", added, lambda p: short(new[p])),
        ("REMOVED", removed, lambda p: short(old[p])),
        ("CHANGED", changed, show_change),
    ):
        print(f"\n{title} ({len(paths)})")
        for path in paths:
            print(f"  {path}: {show(path)}")
    return 1 if (added or removed or changed) else 0


if __name__ == "__main__":
    sys.exit(main())
