#!/usr/bin/env bash
set -euo pipefail
PROTOTYPE="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -x "$PROTOTYPE/node_modules/.bin/vite" ]]; then
  npm ci --prefix "$PROTOTYPE" --no-audit --no-fund
fi
exec npm --prefix "$PROTOTYPE" run dev
