#!/usr/bin/env python3
"""Decide which CI jobs a change needs, so costly macOS runners only start when useful.

Writes these outputs to $GITHUB_OUTPUT:
  rust         'true' if the Linux Rust job should run
  macos        'true' if the macOS app build + UI tests should run
  swift_tests  'true' if Swift unit tests should run in the app build
  ui_matrix    JSON list of {"shard": n, "classes": "A B C"} for the UI test jobs ('[]' = none)

Environment:
  EVENT_NAME   github.event_name
  CHANGED      newline-separated changed file paths (pull requests only)
  TEST_CLASS   optional workflow_dispatch input: comma-separated UI test classes or Class/testMethod
"""
import glob
import json
import math
import os
import re
import sys

UI_DIR = "macos-app/UITests/GitCraftUITests"
UI_TEST_FILE = re.compile(re.escape(UI_DIR) + r"/[A-Za-z0-9_]+UITests\.swift$")
MAX_SHARDS = 3
TESTS_PER_SHARD = 10  # don't spin up another macOS runner for fewer tests than this

# Files that can never affect a build or test result.
IGNORED_PREFIXES = (
    "docs/",
    ".githooks/",
    ".github/workflows/coverage.yml",
    ".github/workflows/release.yml",
)
IGNORED_SUFFIXES = (".md",)
IGNORED_NAMES = {"LICENSE", ".gitignore"}
# Changes under rust-core/ that alter what the Swift app links against or generates.
RUST_FFI_FILES = {
    "rust-core/src/gitcraft_core.udl",
    "rust-core/Cargo.toml",
    "rust-core/Cargo.lock",
    "rust-core/build.rs",
}
# A change to the CI plumbing itself must exercise everything.
CI_FILES = {".github/workflows/ci.yml", "scripts/ci_plan.py"}


def ignored(path):
    return (
        path.startswith(IGNORED_PREFIXES)
        or path.endswith(IGNORED_SUFFIXES)
        or path in IGNORED_NAMES
    )


def test_counts():
    """Map every UI test class to its number of test methods."""
    counts = {}
    for path in sorted(glob.glob(f"{UI_DIR}/*UITests.swift")):
        name = os.path.basename(path).removesuffix(".swift")
        with open(path) as f:
            counts[name] = len(re.findall(r"\bfunc\s+test\w+\s*\(", f.read()))
    return counts


def balance(classes, counts, shard_count):
    """Greedy balance of classes over shards by test count."""
    buckets = [[] for _ in range(shard_count)]
    loads = [0] * shard_count
    for name in sorted(classes, key=lambda n: (-counts.get(n, 1), n)):
        target = min(range(shard_count), key=lambda i: (loads[i], i))
        buckets[target].append(name)
        loads[target] += counts.get(name, 1)
    return [
        {"shard": i, "classes": " ".join(sorted(b))} for i, b in enumerate(buckets) if b
    ]


def shard_count_for(classes, counts):
    total = sum(counts.get(c.split("/")[0], 1) for c in classes)
    return max(1, min(MAX_SHARDS, len(classes), math.ceil(total / TESTS_PER_SHARD)))


def plan():
    counts = test_counts()
    all_classes = sorted(counts)
    event = os.environ.get("EVENT_NAME", "")
    test_class = os.environ.get("TEST_CLASS", "").strip()

    if event == "workflow_dispatch" and test_class:
        requested = [c.strip() for c in test_class.split(",") if c.strip()]
        if not all(re.fullmatch(r"[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?", c) for c in requested):
            sys.exit(f"Invalid test_class input: {test_class!r}")
        unknown = [c for c in requested if c.split("/")[0] not in counts]
        if unknown:
            sys.exit(f"Unknown UI test class: {', '.join(unknown)}. Known: {', '.join(all_classes)}")
        matrix = balance(requested, counts, shard_count_for(requested, counts))
        return dict(rust=False, macos=True, swift_tests=False, matrix=matrix)

    changed = [p.strip() for p in os.environ.get("CHANGED", "").splitlines() if p.strip()]
    if event != "pull_request" or not changed or any(p in CI_FILES for p in changed):
        # Pushes to main, manual runs and CI changes always run everything.
        return dict(
            rust=True, macos=True, swift_tests=True, matrix=balance(all_classes, counts, MAX_SHARDS)
        )

    relevant = [p for p in changed if not ignored(p)]
    rust_only = [p for p in relevant if p.startswith("rust-core/") and p not in RUST_FFI_FILES]
    needs_app = [p for p in relevant if p not in rust_only]

    rust = any(p.startswith("rust-core/") for p in relevant)
    if not needs_app:
        return dict(rust=rust, macos=False, swift_tests=False, matrix=[])

    ui_only = all(UI_TEST_FILE.match(p) for p in needs_app)
    if ui_only:
        # Only the touched test classes need to run; app and Swift unit tests are unchanged.
        touched = [os.path.basename(p).removesuffix(".swift") for p in needs_app]
        existing = [c for c in touched if c in counts]
        matrix = balance(existing, counts, shard_count_for(existing, counts)) if existing else []
        return dict(rust=rust, macos=bool(matrix), swift_tests=False, matrix=matrix)

    return dict(
        rust=rust, macos=True, swift_tests=True, matrix=balance(all_classes, counts, MAX_SHARDS)
    )


def main():
    result = plan()
    outputs = {
        "rust": str(result["rust"]).lower(),
        "macos": str(result["macos"]).lower(),
        "swift_tests": str(result["swift_tests"]).lower(),
        "ui_matrix": json.dumps(result["matrix"], separators=(",", ":")),
    }
    for key, value in outputs.items():
        print(f"{key}={value}")
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as f:
            for key, value in outputs.items():
                f.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
