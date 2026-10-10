#!/usr/bin/env bash
# Print a one-line pass/fail summary (plus failures) for the last `make test` result bundle.
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
PY
