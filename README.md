# MiniGit

MiniGit is a native macOS Git client with a Rust core and a SwiftUI/AppKit
interface. It uses the system `git` configuration and SSH keys for local
repository operations.

## Build

The macOS build requires SwiftPM, Rust, and `codesign`:

```sh
make
```

The Rust core can be tested independently with:

```sh
cargo test --manifest-path rust-core/Cargo.toml
```