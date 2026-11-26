<div align="center">

<img src="macos-app/Resources/AppIcon-1024.png" width="128" alt="GitCraft app icon">

# GitCraft

**A fast, native Git client for macOS. Free and open source, with no subscription.**

Everything you'd pay a yearly fee for in Tower or Fork (a clear commit graph,
syntax-highlighted diffs, worktrees, stashes, rebase and cherry-pick) in a
lightweight app you never have to pay for.

[**Download for macOS**](https://github.com/goldspanlabs/gitcraft/releases/latest)
&nbsp;·&nbsp; [Features](#features) &nbsp;·&nbsp; [Install](#install) &nbsp;·&nbsp; [Build from source](#build-from-source)

[![Latest release](https://img.shields.io/github/v/release/goldspanlabs/gitcraft?label=release)](https://github.com/goldspanlabs/gitcraft/releases/latest)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/hero-graph-dark.png">
  <img src="docs/screenshots/hero-graph-light.png" alt="GitCraft showing a commit graph with branches, merges and tags, and the details of the selected commit">
</picture>

</div>

## Why GitCraft?

- **Free, for good.** No trial, no license key, no subscription. GitCraft is MIT licensed.
- **Truly native.** Built with SwiftUI and AppKit on a Rust core, so it opens instantly and stays
  responsive on big repositories.
- **Uses your existing setup.** GitCraft works with your system `git` config and SSH keys.
  There's no account to create and nothing to sign in to.
- **Open source.** Read the code, file an issue, or send a pull request.

## Features

### See your whole history at a glance

A clean commit graph with colour-coded lanes, branch and tag labels, author avatars, and
instant filtering. Select any commit to see its message, changed files and a
syntax-highlighted diff.

### Stage and commit with confidence

Staged, unstaged and untracked changes are clearly separated. Stage a single file or
everything at once, write your message and commit, or amend the last commit.

### Branches, worktrees, tags and stashes in one sidebar

- Create, check out, merge and delete branches. With Git 2.38 or later, GitCraft checks for
  conflicts *before* you merge.
- First-class **worktrees**: add, open, lock and prune them without the command line.
- Create annotated tags and push them to your remote.
- Stash work in progress (untracked files included), then apply or pop it later.
- See which branches are ahead of or behind their remote, with GitHub, GitLab, Bitbucket,
  Codeberg, Gitea and SourceHut remotes recognised automatically.

### Powerful history tools

Rebase, reset, cherry-pick and revert straight from the commit graph. When something stops
on a conflict, GitCraft tells you exactly where you are and lets you continue or abort.

### Stays out of your way

- Fetch, pull and push from the toolbar, with background auto-fetch on a schedule you choose.
- Pull with merge or rebase, or follow your own git config.
- Open several repositories as tabs in one window.
- Light, dark or system appearance.

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

### Updates

GitCraft checks GitHub for a new release when it opens, at most once a day, and shows a banner
when there is one. You can also choose **GitCraft → Check for Updates…**, skip a version, or turn
automatic checks off in **Settings**. It never installs anything itself: for a Homebrew install the
banner copies `brew upgrade --cask gitcraft` for you to run, and otherwise it downloads the new DMG
in your browser.

GitCraft needs macOS 14 Sonoma or later on an Apple Silicon Mac, and `git` 2.38 or later (installed
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
