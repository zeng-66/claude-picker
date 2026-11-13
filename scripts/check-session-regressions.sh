#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
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
source = source[:start] + Path('Tests/TerminalRegression/main.swift').read_text() + source[end:]
(check_dir / 'main.swift').write_text(source)
PY
module_dir="$build_dir/Modules"
objects=("$build_dir"/SwiftTerm.build/*.o)
if [[ -f "$build_dir/SwiftTerm.o" ]]; then
    module_dir="$build_dir"
    objects=("$build_dir/SwiftTerm.o")
fi
swiftc -I "$module_dir" Sources/ClaudeDeck/Models.swift "$check_dir/TerminalPane.swift" \
    "$check_dir/main.swift" "${objects[@]}" -o "$check_dir/terminal-checks" > "$check_dir/terminal-build.log" 2>&1 \
    || { head -35 "$check_dir/terminal-build.log"; exit 1; }
result=0
"$check_dir/session-checks" || result=1
"$check_dir/terminal-checks" || result=1
exit "$result"
