#!/usr/bin/env bash
# Archive score (iOS app + embedded watch app) and upload it to App Store Connect / TestFlight.
#
#   scripts/testflight.sh                    # archive + upload (build number = UTC timestamp)
#   scripts/testflight.sh --version 1.1.0    # override MARKETING_VERSION (default: the project's)
#   scripts/testflight.sh --no-upload        # archive + export an .ipa only
#
# The App Store Connect API key signs and uploads: with -allowProvisioningUpdates xcodebuild
# registers bundle ids and creates the distribution certificate and profiles in the cloud
# when they are missing, so no local distribution certificate or Apple ID session is needed.
# The upload is the export itself (ExportOptions `destination` upload). `--no-upload` exports
# an .ipa instead; App Store Connect may still reserve the build number, which is harmless
# because every run takes a new one.
# After an upload, `python3 scripts/asc.py wait-build <n>` and `... distribute <n>` send the
# build to the "Score testers" group (`make testflight` runs all three).
#
# Env: ASC_KEY_ID (default 8QS8WXLS34), ASC_ISSUER_ID (default 69a6de79-...), ASC_KEY_PATH
#      (default ~/.appstoreconnect/private_keys/AuthKey_<id>.p8; never copy it into the repo),
#      BUILD_NUMBER (default UTC YYYYMMDD.HHMMSS).
# Logs: .build/logs/testflight-*.log (only their tails are printed on failure).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

log() { printf '\033[1;34m[testflight]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[testflight] %s\033[0m\n' "$*" >&2; }
fail() {
  printf '\033[1;31m[testflight] %s\033[0m\n' "$*" >&2
  exit 1
}

USAGE="usage: scripts/testflight.sh [--no-upload] [--version X.Y.Z]"
UPLOAD=1
VERSION_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-upload) UPLOAD=0; shift ;;
    --version)
      [[ $# -ge 2 ]] || fail "--version needs a value ($USAGE)"
      VERSION_OVERRIDE="$2"; shift 2 ;;
    --version=*) VERSION_OVERRIDE="${1#*=}"; shift ;;
    -h | --help) echo "$USAGE"; exit 0 ;;
    *) fail "unknown argument: $1 ($USAGE)" ;;
  esac
done

PROJECT=score.xcodeproj
SCHEME=score
TEAM_ID=4HNG7QE476
BUNDLE_ID=armincerf.score
WATCH_BUNDLE_ID=armincerf.score.watchkitapp
export ASC_KEY_ID="${ASC_KEY_ID:-8QS8WXLS34}"
export ASC_ISSUER_ID="${ASC_ISSUER_ID:-69a6de79-5ccb-47e3-e053-5b8c7c11a4d1}"
export ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[[ -f "$ASC_KEY_PATH" ]] || fail "no App Store Connect API key at $ASC_KEY_PATH (set ASC_KEY_PATH)"

WORK=.build/archive
ARCHIVE="$WORK/score.xcarchive"
EXPORT_DIR="$WORK/export"
LOG_DIR=.build/logs
mkdir -p "$WORK" "$LOG_DIR"

# xcodebuild runs with Apple's tools first: exportArchive shells out to rsync, and a Homebrew
# rsync on PATH breaks it ("Copy failed"). Only xcodebuild gets this PATH, so python3 below
# stays the user's (Homebrew's has the `cryptography` package that asc.py needs).
xcodebuild_apple() { PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild "$@"; }

run_logged() {
  local name="$1"; shift
  local logfile="$LOG_DIR/testflight-$name.log"
  if "$@" >"$logfile" 2>&1; then
    log "$name ok (log: $logfile)"
  else
    tail -n 40 "$logfile" >&2
    fail "$name failed (full log: $logfile)"
  fi
}

# 1. The upload needs an App Store Connect app record; the public API cannot create one.
asc_out="" asc_rc=0
asc_out="$(python3 scripts/asc.py status --brief 2>&1)" || asc_rc=$?
case "$asc_rc" in
  0) log "${asc_out}" ;;
  3)
    if [[ $UPLOAD -eq 1 ]]; then
      printf '%s\n' "$asc_out" >&2
      fail "no App Store Connect app record for $BUNDLE_ID: create it (see AGENTS.md, TestFlight) and re-run"
    fi
    warn "no App Store Connect app record for $BUNDLE_ID yet; continuing because of --no-upload" ;;
  *)
    printf '%s\n' "$asc_out" >&2
    [[ $UPLOAD -eq 0 ]] || fail "could not check the App Store Connect app record (scripts/asc.py status)"
    warn "could not check the App Store Connect app record; continuing because of --no-upload" ;;
esac

# 2. Versions. CFBundleVersion must grow with every upload: one `date` call, to the second.
if [[ -n "$VERSION_OVERRIDE" ]]; then
  MARKETING_VERSION="$VERSION_OVERRIDE"
else
  settings="$(xcodebuild -showBuildSettings -project "$PROJECT" -target "$SCHEME" -configuration Release 2>/dev/null)" ||
    fail "xcodebuild -showBuildSettings failed"
  MARKETING_VERSION="$(awk -F' = ' '$1 ~ /^ *MARKETING_VERSION$/ && !seen { print $2; seen = 1 }' <<<"$settings")"
fi
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
  fail "marketing version '$MARKETING_VERSION' is not X, X.Y or X.Y.Z"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M%S)}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "build number '$BUILD_NUMBER' is not N, N.N or N.N.N"

# 3. Archive with cloud signing (isolated DerivedData, so a concurrent `make build` is not disturbed).
rm -rf "$ARCHIVE" "$EXPORT_DIR"
log "archive $MARKETING_VERSION ($BUILD_NUMBER)"
run_logged archive xcodebuild_apple archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK/DerivedData" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic

# 4. Check the archive before anything leaves this Mac: exactly one app, with the watch app
#    embedded, and both carrying the bundle ids and versions App Store Connect will expect.
shopt -s nullglob
apps=("$ARCHIVE"/Products/Applications/*.app)
[[ ${#apps[@]} -eq 1 ]] ||
  fail "expected exactly one app in $ARCHIVE/Products/Applications, found ${#apps[@]}; not uploading"
APP="${apps[0]}"
watches=("$APP"/Watch/*.app)
[[ ${#watches[@]} -eq 1 ]] ||
  fail "expected one embedded watch app at $APP/Watch/*.app, found ${#watches[@]}; not uploading"

check_bundle() {
  local bundle="$1" want_id="$2" id short build
  id="$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Info.plist" 2>/dev/null)" || id=""
  short="$(plutil -extract CFBundleShortVersionString raw -o - "$bundle/Info.plist" 2>/dev/null)" || short=""
  build="$(plutil -extract CFBundleVersion raw -o - "$bundle/Info.plist" 2>/dev/null)" || build=""
  [[ "$id" == "$want_id" ]] || fail "$bundle has bundle id '$id', expected $want_id; not uploading"
  [[ "$short" == "$MARKETING_VERSION" && "$build" == "$BUILD_NUMBER" ]] ||
    fail "$bundle is $short ($build), expected $MARKETING_VERSION ($BUILD_NUMBER); not uploading"
}
check_bundle "$APP" "$BUNDLE_ID"
check_bundle "${watches[0]}" "$WATCH_BUNDLE_ID"
log "archived $(basename "$APP") with $(basename "${watches[0]}") embedded"

# App Store Connect rejects an upload whose app or watch app has no icon. actool writes this
# key (iOS and watchOS alike) only when the AppIcon set or .icon file has artwork.
missing_icons=()
for bundle in "$APP" "${watches[0]}"; do
  plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName raw -o - "$bundle/Info.plist" >/dev/null 2>&1 ||
    missing_icons+=("$(basename "$bundle")")
done
if [[ ${#missing_icons[@]} -gt 0 ]]; then
  message="no app icon in: ${missing_icons[*]} (add artwork to the AppIcon sets in score/ and scorewatch Watch App/)"
  [[ $UPLOAD -eq 0 ]] || fail "$message; App Store Connect would reject the upload"
  warn "$message; fine for --no-upload, but an upload would be rejected"
fi

# 5. Export: `upload` sends the build to App Store Connect, `export` writes an .ipa.
if [[ $UPLOAD -eq 1 ]]; then DESTINATION="upload"; else DESTINATION="export"; fi
cat >"$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>destination</key><string>${DESTINATION}</string>
</dict>
</plist>
PLIST

log "$DESTINATION $MARKETING_VERSION ($BUILD_NUMBER)"
run_logged "$DESTINATION" xcodebuild_apple -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

if [[ $UPLOAD -eq 1 ]]; then
  log "uploaded $MARKETING_VERSION ($BUILD_NUMBER); App Store Connect processes it next. Then:"
  log "  python3 scripts/asc.py wait-build $BUILD_NUMBER && python3 scripts/asc.py distribute $BUILD_NUMBER"
  exit 0
fi

ipas=("$EXPORT_DIR"/*.ipa)
[[ ${#ipas[@]} -eq 1 ]] || fail "expected one .ipa in $EXPORT_DIR, found ${#ipas[@]}"
IPA="$REPO/${ipas[0]}"
entries="$(unzip -Z1 "$IPA")" || fail "cannot list $IPA"
grep -qE '^Payload/[^/]+\.app/Watch/[^/]+\.app/Info\.plist$' <<<"$entries" ||
  fail "$IPA has no embedded watch app"
log "--no-upload: exported $MARKETING_VERSION ($BUILD_NUMBER) to $IPA"
