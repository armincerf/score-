#!/usr/bin/env bash
# Claude Code PostToolUse hook: format the edited Swift file and feed lint
# violations straight back to the agent (exit 2 -> stderr is shown to Claude).
set -u
cd "${CLAUDE_PROJECT_DIR:-.}"
input=$(cat)
path=$(printf '%s' "$input" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)
[[ "$path" == *.swift && -f "$path" ]] || exit 0
command -v swift >/dev/null && swift format --in-place --configuration .swift-format "$path" 2>/dev/null || true
if command -v swiftlint >/dev/null; then
  swiftlint lint --fix --quiet --config .swiftlint.yml "$path" >/dev/null 2>&1 || true
  out=$(swiftlint lint --quiet --config .swiftlint.yml "$path" 2>/dev/null || true)
  if [[ -n "$out" ]]; then
    echo "SwiftLint violations in $path (fix before finishing):" >&2
    echo "$out" >&2
    exit 2
  fi
fi
exit 0
