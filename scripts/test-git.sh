#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-picker-git-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
export CLAUDE_PICKER_DATA_DIR="$test_dir/data"
export GIT_EDITOR=true
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$test_dir/clang-cache}"
swiftc -swift-version 6 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$repo_dir/Sources/ClaudeDeck/Models.swift" \
  "$repo_dir/Sources/ClaudeDeck/AgentProviders.swift" \
  "$repo_dir"/Sources/ClaudeDeck/Git/*.swift \
  "$repo_dir/Tests/GitServiceRegression/main.swift" -lsqlite3 -o "$test_dir/git-regression"
cd "$repo_dir"
"$test_dir/git-regression"
