#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap '[ -n "${KEEP_CHECK:-}" ] || rm -rf "$check_dir"' EXIT
# 测试会创建 Store 并落盘 tree.json / settings.json：一律写进临时数据目录，绝不碰正式版的数据。
export CLAUDE_PICKER_DATA_DIR="$check_dir/data"
swift build > "$check_dir/build.log" 2>&1 || { tail -20 "$check_dir/build.log"; exit 1; }
build_dir=$(swift build --show-bin-path)
swiftc Sources/ClaudeDeck/Models.swift Tests/SessionRegression/main.swift -o "$check_dir/session-checks"
# Replace only the child-process launcher so terminal callbacks exercise the real
# implementation without starting Claude or touching the user's conversations.
python3 - "$check_dir" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/ClaudeDeck/TerminalPane.swift').read_text()
assert source.count('executable: "/bin/zsh"') == 1, "Update the isolated test launcher before running checks"
source = source.replace('executable: "/bin/zsh"', 'executable: ProcessInfo.processInfo.environment["CLAUDE_PICKER_TEST_SHELL"]!')
check_dir = Path(sys.argv[1])
(check_dir / 'TerminalPane.swift').write_text(source)
source = Path('Sources/ClaudeDeck/main.swift').read_text()
start = source.index('let store = Store(buildProjects())')
end = source.index('app.run()', start) + len('app.run()')
tail = source[end:]
(check_dir / 'main.swift').write_text(source[:start] + Path('Tests/TerminalRegression/main.swift').read_text() + tail)
bridge = check_dir / 'bridge'
bridge.mkdir()
(bridge / 'main.swift').write_text(source[:start] + Path('Tests/BridgeRegression/main.swift').read_text() + tail)
PY
module_dir="$build_dir/Modules"
objects=("$build_dir"/SwiftTerm.build/*.o)
if [[ -f "$build_dir/SwiftTerm.o" ]]; then
    module_dir="$build_dir"
    objects=("$build_dir/SwiftTerm.o")
fi
swiftc -I "$module_dir" Sources/ClaudeDeck/Models.swift \
    Sources/ClaudeDeck/Git/*.swift Sources/ClaudeDeck/ThirdPane/*.swift Sources/ClaudeDeck/Chat*.swift \
    "$check_dir/TerminalPane.swift" \
    "$check_dir/main.swift" "${objects[@]}" -framework WebKit -o "$check_dir/terminal-checks" > "$check_dir/terminal-build.log" 2>&1 \
    || { (grep -n -C 3 "error:" "$check_dir/terminal-build.log" || tail -20 "$check_dir/terminal-build.log"); exit 1; }
swiftc -I "$module_dir" Sources/ClaudeDeck/Models.swift \
    Sources/ClaudeDeck/Git/*.swift Sources/ClaudeDeck/ThirdPane/*.swift Sources/ClaudeDeck/Chat*.swift \
    "$check_dir/TerminalPane.swift" \
    "$check_dir/bridge/main.swift" "${objects[@]}" -framework WebKit -o "$check_dir/bridge-checks" > "$check_dir/bridge-build.log" 2>&1 \
    || { (grep -n -C 3 "error:" "$check_dir/bridge-build.log" || tail -20 "$check_dir/bridge-build.log"); exit 1; }
result=0
"$check_dir/session-checks" || result=1
"$check_dir/terminal-checks" || result=1
"$check_dir/bridge-checks" || result=1
exit "$result"
