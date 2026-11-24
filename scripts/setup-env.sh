#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

PATH_EXPORT='export PATH="$HOME/.local/bin:$PATH"'

prepend_line() {
  local file="$1"
  local line="$2"
  if grep -qxF "$line" "$file" 2>/dev/null; then
    return 0
  fi
  local tmp
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN
  printf '%s\n' "$line" > "$tmp"
  if [ -f "$file" ]; then
    cat "$file" >> "$tmp"
  fi
  cat "$tmp" > "$file"
  rm -f "$tmp"
  trap - RETURN
}

append_line() {
  local file="$1"
  local line="$2"
  if grep -qxF "$line" "$file" 2>/dev/null; then
    return 0
  fi
  if [ -s "$file" ] && [ -n "$(tail -c 1 "$file" 2>/dev/null || true)" ]; then
    printf '\n' >> "$file"
  fi
  printf '%s\n' "$line" >> "$file"
}

prepend_line "$HOME/.bashrc" "$PATH_EXPORT"

if [ "$(uname -s)" = "Darwin" ]; then
  append_line "$HOME/.zshrc" "$PATH_EXPORT"
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  append_line "$CLAUDE_ENV_FILE" "$PATH_EXPORT"
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
