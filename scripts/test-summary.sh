#!/usr/bin/env bash
# Print a one-line pass/fail summary (plus failures) for the last `make test` result bundle; exits 1 on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."
bundle=${1:-.build/results/test.xcresult}
[[ -d "$bundle" ]] || { echo "no result bundle at $bundle (run make test)"; exit 1; }
summary=$(mktemp)
trap 'rm -f "$summary"' EXIT
xcrun xcresulttool get test-results summary --path "$bundle" --compact > "$summary"
python3 -I - "$summary" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"{d.get('result')}: {d.get('passedTests')} passed, {d.get('failedTests')} failed, "
      f"{d.get('skippedTests')} skipped, {d.get('expectedFailures')} expected failures")
for f in d.get("testFailures", [])[:30]:
    print(f"  ✘ {f.get('testName')}: {f.get('failureText')}")
# A failed test fails `make test` even if xcodebuild itself exited 0; so does a run of no tests at all (a T= filter
# that matches nothing, e.g. a file name instead of a suite name, or a function without its "()")
ran = (d.get("passedTests") or 0) + (d.get("failedTests") or 0)
if ran == 0:
    print("no tests ran: check the T= filter (suite names, not file names; a function needs its \"()\")")
sys.exit(1 if ran == 0 or (d.get("failedTests") or 0) > 0 or d.get("result") == "Failed" else 0)
PY
