#!/bin/bash
# Work 领域回归：真实 SQLite + 临时 git 仓库 + 协议替身 CLI（Tests/WorkRegression/fake-claude.py）。
# 不访问网络、不调用真实 Claude、不碰正式版数据目录。
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-picker-work-tests.XXXXXX")"
trap '[ -n "${KEEP_CHECK:-}" ] || rm -rf "$test_dir"' EXIT
export CLAUDE_PICKER_DATA_DIR="$test_dir/data"
export WORK_TEST_DIR="$test_dir/scratch"
export FAKE_CLAUDE_LOG="$test_dir/fake-claude.log"
export FAKE_CLAUDE_STATE="$test_dir/fake-state"
export CLAUDE_PICKER_CLAUDE_BIN="$test_dir/claude"
mkdir -p "$WORK_TEST_DIR" "$FAKE_CLAUDE_STATE"
cp "$repo_dir/Tests/WorkRegression/fake-claude.py" "$CLAUDE_PICKER_CLAUDE_BIN"
chmod +x "$CLAUDE_PICKER_CLAUDE_BIN"
swiftc -swift-version 6 \
  "$repo_dir/Sources/ClaudeDeck/Models.swift" \
  "$repo_dir"/Sources/ClaudeDeck/Git/*.swift \
  "$repo_dir"/Sources/ClaudeDeck/Work/*.swift \
  "$repo_dir/Tests/WorkRegression/main.swift" -lsqlite3 -o "$test_dir/work-regression" 2> "$test_dir/build.log" \
  || { grep -n -A4 "error:" "$test_dir/build.log" | head -80; exit 1; }
cd "$repo_dir"
"$test_dir/work-regression"
