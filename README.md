<div align="center">

<img src="macos-app/Resources/AppIcon-1024.png" width="128" alt="GitCraft app icon">

# GitCraft

**A fast, lean, native Git client for macOS. Free and open source, with no subscription.**

[**Download for macOS**](https://github.com/goldspanlabs/gitcraft/releases/latest)
&nbsp;·&nbsp; [Features](#features) &nbsp;·&nbsp; [Performance](#performance) &nbsp;·&nbsp; [Install](#install) &nbsp;·&nbsp; [Build from source](#build-from-source)

[![Latest release](https://img.shields.io/github/v/release/goldspanlabs/gitcraft?label=release)](https://github.com/goldspanlabs/gitcraft/releases/latest)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-lightgrey?logo=apple)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/hero-graph-dark.png">
  <img src="docs/screenshots/hero-graph-light.png" alt="GitCraft showing a commit graph with branches, merges and tags, and the details of the selected commit">
</picture>

</div>

## Why GitCraft?

- **Free, for good.** No trial, no license key, no subscription. GitCraft is MIT licensed.
- **Truly native.** Built with SwiftUI and AppKit on a Rust core, so it opens fast, scrolls
  smoothly, and stays light on memory even on large repositories.
- **Uses your existing setup.** GitCraft works with your system `git` config and SSH keys.
  There's no account to create and nothing to sign in to.
- **Open source.** Read the code, file an issue, or send a pull request.

## Features

- **Undo & Redo for history actions:** Take back or redo resets, cherry-picks, reverts, and squashes (`⌘Z` / `⇧⌘Z`) with safety checks if the repository moved on.
- **First-class Git worktrees:** Create, lock, prune, and switch between linked worktrees with live dirty counts across sibling checkouts.
- **Markdown preview with rich diffs:** Toggle between raw diff and rendered Markdown in-place when inspecting `.md` files, with inline added/removed block highlights and relative image support.

## Performance

Most Git clients slow down or eat gigabytes of RAM as repositories grow. GitCraft is built
natively for macOS on a fast Rust engine, so opening large repositories, scrolling through tens
of thousands of commits, searching history, and switching between multiple tabs stay instant and
light on memory.

On a 65,000-commit repository:

- **Instant startup:** Opens the repository and loads branches in under a millisecond.
- **Fast history:** Loads the commit graph in ~3 ms and scrolls smoothly all the way down.
- **Light on RAM:** Indexes the entire 65K-commit history in ~1.5 MB, keeping multi-tab memory low.

## Install

### Homebrew

```sh
brew install --cask goldspanlabs/tap/gitcraft
```

Update with `brew upgrade --cask gitcraft`. GitCraft isn't notarized by Apple, so the first time you
open it macOS will say it can't verify the app. Open **System Settings → Privacy & Security** and
click **Open Anyway**. You only need to do this once per install.

### Download

1. Download the latest `GitCraft-<version>.dmg` from
   [Releases](https://github.com/goldspanlabs/gitcraft/releases/latest).
2. Open the DMG and drag **GitCraft** to your **Applications** folder.
3. The first time you open it, macOS may say the app can't be verified. Open
   **System Settings → Privacy & Security** and click **Open Anyway**.

GitCraft needs macOS 15 Sequoia or later on an Apple Silicon Mac, and `git` 2.39 or later (installed
with the Xcode Command Line Tools: `xcode-select --install`).

## Build from source

The macOS build requires SwiftPM, Rust, and `codesign`:

```sh
make
```

This produces `build/GitCraft.app`. The Rust core can be tested independently with:

```sh
cargo test --manifest-path rust-core/Cargo.toml
```

See [AGENTS.md](AGENTS.md) for the project layout and the full list of build and test commands.

## Contributing

Bug reports, feature ideas and pull requests are welcome. Please
[open an issue](https://github.com/goldspanlabs/gitcraft/issues) to discuss bigger changes first.

## License

GitCraft is released under the [MIT License](LICENSE).
