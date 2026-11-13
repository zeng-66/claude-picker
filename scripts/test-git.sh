#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-picker-git-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$repo_dir/Sources/ClaudeDeck/Git.swift" \
  "$repo_dir/Tests/GitRegression.swift" -o "$test_dir/git-regression"
"$test_dir/git-regression"
