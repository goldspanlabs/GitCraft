#!/usr/bin/env python3
"""Generate THIRD_PARTY_LICENSES.txt from rust-core's resolved Cargo dependencies.

Usage:
  python3 scripts/generate_licenses.py --output build/GitCraft.app/Contents/Resources/THIRD_PARTY_LICENSES.txt
"""
import argparse
import json
import subprocess
import sys
from collections import deque
from pathlib import Path

LICENSE_PREFIXES = ("license", "licence", "copying", "notice", "copyright", "unlicense")


def collect_non_dev_packages(metadata: dict) -> list[dict]:
    """Return resolved non-dev dependency packages of gitcraft-core, sorted by name."""
    packages_by_id = {pkg["id"]: pkg for pkg in metadata["packages"]}
    nodes_by_id = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    root_id = metadata["resolve"]["root"]

    visited: set[str] = set()
    queue: deque[str] = deque([root_id])

    while queue:
        pkg_id = queue.popleft()
        node = nodes_by_id.get(pkg_id)
        if not node:
            continue
        for dep in node.get("deps", []):
            kinds = dep.get("dep_kinds", [])
            is_non_dev = not kinds or any(k.get("kind") != "dev" for k in kinds)
            if is_non_dev and dep["pkg"] not in visited:
                visited.add(dep["pkg"])
                queue.append(dep["pkg"])

    deps = [packages_by_id[pid] for pid in visited if pid != root_id and pid in packages_by_id]
    deps.sort(key=lambda p: (p["name"].lower(), p["version"]))
    return deps


def find_license_files(manifest_path: str) -> list[Path]:
    """Find license and notice files in a crate's root directory."""
    crate_dir = Path(manifest_path).parent
    if not crate_dir.is_dir():
        return []
    files = [
        p
        for p in sorted(crate_dir.iterdir())
        if p.is_file() and p.name.lower().startswith(LICENSE_PREFIXES)
    ]
    return files


def format_licenses(deps: list[dict]) -> str:
    """Format the third-party license bundle text."""
    lines = [
        "GitCraft Third-Party Open Source Licenses",
        "=========================================",
        "",
        "GitCraft includes the following third-party Rust crates:",
        "",
    ]

    for pkg in deps:
        name = pkg["name"]
        version = pkg["version"]
        spdx = pkg.get("license") or "Unknown"
        repo = pkg.get("repository") or ""

        lines.append("=" * 80)
        lines.append(f"{name} {version}")
        lines.append(f"License: {spdx}")
        if repo:
            lines.append(f"Repository: {repo}")
        lines.append("-" * 80)

        license_files = find_license_files(pkg["manifest_path"])
        if license_files:
            for lf in license_files:
                if len(license_files) > 1:
                    lines.append(f"[{lf.name}]")
                lines.append(lf.read_text(encoding="utf-8", errors="replace").strip())
                lines.append("")
        else:
            lines.append(f"(Licensed under {spdx}; no license text file found in crate root.)")
            lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate THIRD_PARTY_LICENSES.txt")
    parser.add_argument(
        "--manifest-path",
        default="rust-core/Cargo.toml",
        help="Path to Cargo.toml (default: rust-core/Cargo.toml)",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output file path for THIRD_PARTY_LICENSES.txt",
    )
    args = parser.parse_args()

    proc = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--manifest-path", args.manifest_path, "--locked"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        return proc.returncode

    metadata = json.loads(proc.stdout)
    deps = collect_non_dev_packages(metadata)
    content = format_licenses(deps)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(content, encoding="utf-8")
    print(f"Wrote {len(deps)} third-party licenses to {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
