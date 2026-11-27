#!/usr/bin/env bash
set -euo pipefail

prototype_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$prototype_dir" rev-parse --show-toplevel)"
baseline=63a3bbc0e68a9e747d68a09ebfb3e7b6b7f12b23
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-picker-cli-prototype.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

git -C "$repo" archive "$baseline" Web | tar -xf - -C "$build_dir"
git -C "$build_dir" apply "$prototype_dir/test-preview.patch"
for web in "$repo/.worktrees/test/Web" "$repo/Web"; do
  if [[ -d "$web/node_modules/vite" ]] &&
     cmp -s "$web/package-lock.json" "$build_dir/Web/package-lock.json"; then
    ln -s "$web/node_modules" "$build_dir/Web/node_modules"
    break
  fi
done
(
  cd "$build_dir/Web"
  if [[ ! -d node_modules ]]; then
    npm ci
  fi
  npm run build
)
mkdir -p "$prototype_dir/dist"
cp -R "$build_dir/Web/dist/." "$prototype_dir/dist/"
if [[ "${1:-}" != "--build-only" ]]; then
  python3 -m http.server 5189 --bind 127.0.0.1 --directory "$prototype_dir/dist"
fi
