#!/usr/bin/env bash
# Export the agent skills bundled with Xcode 27+ into .claude/skills so Claude Code
# (and any Agent-Skills-compatible tool) can load Apple's authoritative SwiftUI /
# Swift Testing guidance. Idempotent; re-exports when the Xcode build changes.
set -euo pipefail
cd "$(dirname "$0")/.."
quiet=${1:-}
dest=.claude/skills
stamp="$dest/.xcode-skills-version"
keep=(swiftui-specialist swiftui-whats-new-27 modernize-tests device-interaction audit-xcode-security-settings)

if ! xcrun --find agent >/dev/null 2>&1; then
  [[ "$quiet" == "--quiet" ]] || echo "xcrun agent not found (needs Xcode 27+); skipping skill export"
  exit 0
fi
version=$(xcodebuild -version 2>/dev/null | tr '\n' ' ')
if [[ -f "$stamp" && "$(cat "$stamp")" == "$version" ]]; then
  [[ "$quiet" == "--quiet" ]] || echo "Xcode skills up to date ($version)"
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xcrun agent skills export "$tmp" >/dev/null
mkdir -p "$dest"
for s in "${keep[@]}"; do
  if [[ -d "$tmp/$s" ]]; then
    rm -rf "${dest:?}/$s"
    cp -R "$tmp/$s" "$dest/$s"
  fi
done
echo "$version" > "$stamp"
[[ "$quiet" == "--quiet" ]] || echo "Exported Xcode skills: ${keep[*]} -> $dest"
