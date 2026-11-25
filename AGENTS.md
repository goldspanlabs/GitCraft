# AGENTS.md

Guidance for coding agents working in this repository.

## Project layout

GitCraft is a native macOS Git client. Git work happens in a Rust core; the UI is SwiftUI/AppKit.

- `rust-core/` — Rust library (`gitcraft_core`). Git operations live here.
  - `src/lib.rs`, `models.rs`, `status.rs`, `validation.rs`, `git_cli.rs`, `diff.rs`, `highlight.rs`, `watcher.rs` — core session, FFI models, CLI wrapper, status, diff, syntax highlighting, and watcher.
  - `src/ops/` — mutating Git operations (`branches.rs`, `working.rs`, `sync.rs`, `tags_stash.rs`).
  - `src/graph/` — commit graph traversal, lane layout, ref/branch/tag queries, and commit detail (`mod.rs`, `lanes.rs`, `refs.rs`, `detail.rs`).
  - `src/gitcraft_core.udl` — UniFFI interface definition. The Swift bindings are generated from it.
  - `src/bin/uniffi-bindgen` — binary used to generate the bindings.
  - `tests/` — Rust integration tests (with shared helpers in `tests/common/mod.rs`).
- `macos-app/` — Swift package for the app.
  - `Sources/` — UI and state organized by feature (`App/`, `State/`, `Graph/`, `Sidebar/`, `Inspector/`, `Sheets/`, `Components/`, `Settings/`).
  - `Sources/Generated/` — **generated, gitignored. Do not edit or commit.** Regenerate with `make bindings`.
  - `Tests/` — Swift unit tests. `UITests/` — XcodeGen project for UI tests.
- `.githooks/` — local git hooks (see below).

The Swift side should reach Git only through the Rust core's exported API, not by shelling out to `git` itself.

## Build and test

Run from the repository root.

| Task | Command | Notes |
|---|---|---|
| Rust tests | `cargo test --manifest-path rust-core/Cargo.toml` | Runs on any platform |
| Rust format check | `cargo fmt --manifest-path rust-core/Cargo.toml --check` | |
| Rust lint | `cargo clippy --manifest-path rust-core/Cargo.toml --all-targets -- -D warnings` | Warnings are errors |
| Regenerate bindings | `make bindings` | Required after changing `gitcraft_core.udl` |
| Swift tests | `make test-swift` | Builds Rust and regenerates bindings first. macOS only |
| Full app bundle | `make` | Produces `build/GitCraft.app`. macOS only |
| UI tests | `make ui-tests` | Needs `xcodegen` and `xcodebuild`. macOS only |

CI (`.github/workflows/ci.yml`) is built around saving macOS runner minutes. A planning job (`scripts/ci_plan.py`) decides what runs. The macOS build and tests run on pushes to `main` (fmt, clippy, Rust tests, `make test-swift`, the sharded UI tests) and on manual runs; the `coverage.yml` workflow is on demand. A plain pull request only runs the Linux Rust job (fmt, clippy, Rust tests), and only when it touches `rust-core/`. Adding the `run-ui-tests` label to a PR opts it into the macOS build and tests: docs-only changes still run nothing, Rust-only changes skip macOS, a change touching only `*UITests.swift` files runs just those classes, and any app code, helper (`UITestHelpers.swift`, `FixtureRepository.swift`) or `project.yml` change runs everything. Changes to the CI files themselves always run everything. To run chosen UI test classes by hand, use the CI workflow's `test_class` input. Because PRs don't run the Swift or UI tests by default, run the checks that apply locally. Before reporting a change as done, run the checks that apply to what you touched. If you can't run them here, say so and don't claim they pass.

## Git hooks

`.githooks/` contains:

- `pre-commit` — runs `cargo fmt --check` when staged files include Rust.
- `pre-push` — runs `cargo fmt --check` and `cargo clippy -D warnings`.

These only run after you enable them with `git config core.hooksPath .githooks`. This isn't set up automatically, so check it before assuming the hooks are active. Don't bypass hooks with `--no-verify`.

## Conventions

- **Commit messages:** a short imperative subject, for example `Keep the commit summary to one line`. Add a PR number in parentheses when merging a PR, as in `(#12)`. Add a body only when the reason isn't obvious from the subject.
- **Branches:** work on the feature branch you were given, not on `main`. Don't push to any other branch without permission.
- **Pull requests:** only open one when asked. Mirror the repository's PR template if one exists.
- **Rust:** keep fmt and clippy clean (CI and the hooks enforce both).
- **Swift:** match the existing patterns in the file you're editing.

## Things to be careful about

- Don't edit `Sources/Generated/` by hand. Change the UDL or the Rust code and regenerate.
- Destructive Git operations (discard, hard reset, force push, amend on pushed commits) need explicit user confirmation and a clear test. Check the flow end to end, including staged and untracked state.
- macOS-only tooling (Xcode, `codesign`, `actool`, `xcodegen`) isn't available on Linux. Don't assume a Swift build or UI test passed unless you ran it on macOS.
