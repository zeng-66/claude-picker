#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-picker-git-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
export CLAUDE_PICKER_DATA_DIR="$test_dir/data"
swiftc -swift-version 6 \
  "$repo_dir/Sources/ClaudeDeck/Models.swift" \
  "$repo_dir"/Sources/ClaudeDeck/Git/*.swift \
  "$repo_dir/Tests/GitServiceRegression/main.swift" -o "$test_dir/git-regression"
cd "$repo_dir"
"$test_dir/git-regression"
