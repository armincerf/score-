#!/usr/bin/env bash
# Claude Code PreToolUse hook: block direct edits to project.pbxproj.
# Source files are picked up automatically (synchronized folders), so agents
# almost never need to touch the project file. Exit 2 = block + explain.
set -u
input=$(cat)
path=$(printf '%s' "$input" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null || true)
case "$path" in
  *.pbxproj)
    echo "Blocked: project.pbxproj is not edited directly. New .swift files under score/, 'scorewatch Watch App/' and scoreTests/ are picked up automatically. For new targets, packages or build settings follow AGENTS.md -> 'Project file changes' (or ask the human)." >&2
    exit 2 ;;
esac
exit 0
