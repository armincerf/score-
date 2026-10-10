#!/usr/bin/env bash
# Filters xcodebuild output to what matters (errors, warnings, test results).
# Exit status is the upstream pipeline's thanks to `set -o pipefail` in callers.
set -u
if command -v xcbeautify >/dev/null 2>&1; then
  renderer=terminal
  [[ -n "${GITHUB_ACTIONS:-}" ]] && renderer=github-actions
  exec xcbeautify --quiet --renderer "$renderer" --disable-logging
fi
# Fallback: crude grep filter
grep -E --line-buffered "error:|warning:|BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|Executed|✘|✔|Test Suite|failed|passed" || true
