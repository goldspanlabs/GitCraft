#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

PATH_EXPORT='export PATH="$HOME/.local/bin:$PATH"'

if [ "$(uname -s)" = "Linux" ] && [ -f "$HOME/.bashrc" ]; then
  sed -i '/case \$- in/,/esac/d' "$HOME/.bashrc" || true
fi
grep -qxF "$PATH_EXPORT" "$HOME/.bashrc" 2>/dev/null || echo "$PATH_EXPORT" >> "$HOME/.bashrc"

if [ "$(uname -s)" = "Darwin" ] && [ -f "$HOME/.zshrc" ]; then
  grep -qxF "$PATH_EXPORT" "$HOME/.zshrc" 2>/dev/null || echo "$PATH_EXPORT" >> "$HOME/.zshrc"
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  grep -qxF "$PATH_EXPORT" "$CLAUDE_ENV_FILE" 2>/dev/null || echo "$PATH_EXPORT" >> "$CLAUDE_ENV_FILE"
fi

if command -v rustup >/dev/null 2>&1; then
  rustup component add rustfmt clippy llvm-tools-preview
fi

if ! command -v cargo-llvm-cov >/dev/null 2>&1; then
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os-$arch" in
    Linux-x86_64) target="x86_64-unknown-linux-gnu" ;;
    Linux-aarch64|Linux-arm64) target="aarch64-unknown-linux-gnu" ;;
    Darwin-arm64) target="aarch64-apple-darwin" ;;
    Darwin-x86_64) target="x86_64-apple-darwin" ;;
    *) target="" ;;
  esac
  if [ -n "$target" ]; then
    if ! curl -fsSL "https://github.com/taiki-e/cargo-llvm-cov/releases/latest/download/cargo-llvm-cov-${target}.tar.gz" | tar -xz -C "$HOME/.local/bin"; then
      echo "warning: could not download cargo-llvm-cov (network may be restricted); continuing without it" >&2
    fi
  fi
fi

cargo fetch --manifest-path "$REPO_ROOT/rust-core/Cargo.toml" --locked

if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO_ROOT" config core.hooksPath .githooks
fi
