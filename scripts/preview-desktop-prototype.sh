#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTOTYPE="$ROOT/docs/desktop-release-prototype/v001"
if [[ ! -x "$PROTOTYPE/node_modules/.bin/vite" ]]; then
  npm ci --prefix "$PROTOTYPE" --no-audit --no-fund
fi
exec npm --prefix "$PROTOTYPE" run dev
