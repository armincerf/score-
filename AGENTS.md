# score — agent guide

Table-tennis scoring app: iPhone app (`score`) records the match on camera and keeps the
score; the paired Apple Watch app (`scorewatch Watch App`) is the remote for scoring points,
marking highlights and ending games. Matches are event-sourced into SwiftData and replayed
into a `ScoreState`. Highlight clips are cut from the recording; an on-device
FoundationModels summary is generated after each match.

## Facts

| | |
|---|---|
| Xcode / Swift | Xcode 27, Swift 6.4 compiler, **language mode 6** |
| Minimum OS | **iOS 27.0 / watchOS 27.0** (do not lower; iOS 26+ APIs are used unguarded) |
| Concurrency | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, strict concurrency |
| Bundle ids | `armincerf.score`, `armincerf.score.watchkitapp`, `armincerf.scoreTests` |
| Targets / schemes | `score` (iOS app, embeds the watch app), `scorewatch Watch App`, `scoreTests` (unit tests, run via the `score` scheme) |
| Dependencies | none (no SPM packages). Ask before adding one. |
| Project file | `score.xcodeproj` with **synchronized folders**: every file under `score/`, `scorewatch Watch App/`, `scoreTests/` is in its target automatically. |

## Commands (use `make`, never raw xcodebuild in prose or scripts)

```
make build        # iOS app + embedded watch app, generic simulator, warnings are errors
make build-watch  # watch app alone
make test         # unit tests on the simulator;  make test T=scoreTests/ServingLogicTests
make lint         # swiftlint --strict + swift-format lint (what CI runs)
make format       # swift-format + swiftlint --fix
make check        # lint + build + build-watch + test  (the gate before pushing)
make setup        # brew tools, git hooks, Apple's Xcode agent skills
make deploy       # Release build -> connected iPhone (+ paired watch) via devicectl
make testflight   # archive + upload + wait + send to the "Score testers" group (see TestFlight)
make testflight-status / make testers / make testflight-export
make screenshot   # build + launch on the simulator and save a PNG (see Screenshots)
```

Output is filtered through `xcbeautify --quiet`: only errors, warnings and test results are
printed; full logs are in `.build/logs/`. A green build prints just `BUILD SUCCEEDED`.
Builds need no booted simulator; `make test` needs an iOS 27 simulator runtime
(`xcodebuild -downloadPlatform iOS` if `xcrun simctl list runtimes` lacks it).

## Repo map

```
score/                      iOS app target
  ScoreApp.swift              @main; builds the ModelContainer and WatchConnectivityManager
  ContentView.swift           Root view -> HomeView
  HomeView.swift              Start match (player-name sheet), resume, history, settings
  GameView.swift              Live match: camera preview, RecordingStatusBar (capture state), ScoringPanel, alerts
  ExportProgressView.swift    Modal shown while finishActiveMatch() stops, exports and saves (Game + Home)
  MatchHistoryView.swift      List of finished matches (scoreState.matchHistory, reloaded from the store at launch)
  MatchDetailView.swift       One match: videos, AI summary, stats, games, highlights
  CameraSettingsView.swift    Lens/quality/enabled prefs + live preview; CameraDeviceType, VideoQualityPreset
  CameraPreviewManager.swift  Settings preview session (serial session queue, permission state) + CameraPreviewUIView (horizon-level preview)
  WatchConnectivityManager.swift           Phone hub: match lifecycle, scoring, recording, export, AI (see "Known debt")
  WatchConnectivityManager+WCSession.swift WCSessionDelegate: actionId dedupe + command dispatch from the watch
  VideoRecordingManager.swift Capture session + movie output; CaptureState (interrupted/failed...), segment callbacks, rotation coordinator
  RecordingTimeline.swift     RecordingSegment + wall-clock offset -> concatenated-video time mapping (gaps clamp)
  AudioSessionCoordinator.swift Owns AVAudioSession for a match (play-and-record to speaker; released at match end)
  MediaExportService.swift    Concatenates segments upright (per-track preferredTransform) + cuts the reel; export(to:as:) with progress
  MockVideoGenerator.swift    Synthetic video for the simulator (no camera)
  VideoTransferable.swift     ShareLink/Transferable wrapper for exported videos
  VideoStore.swift            Application Support/Videos: per-match file names, stored references, legacy URL resolve
  ScoreState.swift            In-memory match state + PointEvent/GameResult/MatchResult/HighlightClip + watch dictionary codec
  ServingLogic.swift          Pure serving rules (first server, rotation, serve stats)
  ScoreAnnouncementUtils.swift Pure announcement text + game/match-point/won checks
  ScoreAnnouncer.swift        AVSpeechSynthesizer wrapper
  EventModels.swift           Event types (matchStarted, pointScored, highlightMarked/Attributed, gameEnded, matchEnded, eventUndone, recordingSegmentStarted)
  SwiftDataModels.swift       @Model StoredMatch, StoredMatchEvent (JSON event payload), UserPreferences
  EventStore.swift            Append/query events and matches on the main ModelContext
  StateProjector.swift        Replays events into ScoreState (one `apply` per event type)
  UndoService.swift           Soft-delete undo of the latest point or highlight mark in the current game
  UserPreferencesService.swift Names + camera prefs in SwiftData
  WatchSyncState.swift        Minimal sync payload (currently unused by the live protocol)
  Log.swift                   os.Logger categories: app, match, video, audio, store, ui, ai
  PreviewSupport.swift        In-memory SwiftData fixture for #Preview (DEBUG only)
  DebugSeed.swift             DEBUG-only sample matches / UI hooks driven by launch arguments (see Screenshots)
  AI/MatchSummaryModels.swift @Generable MatchAnalysis + Codable cache + MatchContext prompt builder
  AI/MatchSummaryService.swift FoundationModels session; availability + errors
  AI/MatchSummaryView.swift   Summary card, loading/error/unavailable states, container with cache
  AppIcon.icon/               App icon (Icon Composer document, see "Icon")
scorewatch Watch App/       watchOS target (no shared module: ScoreState.swift is a COPY of the phone's)
  ScoreWatchApp.swift, ContentView.swift (3-page TabView: end-game / scoring / highlight), WatchSessionManager.swift, ScoreState.swift, Log.swift
  AppIcon.icon/               Watch app icon (same artwork, circular)
scoreTests/                 Swift Testing suites (@testable import score)
scripts/                    xcb.sh (xcodebuild filter), deploy-device.sh (devicectl install), screenshot.sh, sync-xcode-skills.sh, hooks/,
                            testflight.sh (archive + upload), asc.py (App Store Connect API: testers, distribution)
docs/icons/                 Rendered icon previews (ictool exports)
.github/workflows/ci.yml    lint (macos-26) + build/test (xcode-27 image)
```

## Architecture in one minute

- **Phone is the source of truth.** The watch sends commands (`incrementP1`, `incrementP2`,
  `highlight`, `endGame`, `endMatch`, `requestSync`) as `["command", "actionId" (UUID
  string), "sentAt" (timeIntervalSince1970)]`. Reachable: `WCSession.sendMessage`, whose reply
  is the phone's full `ScoreState.toDictionary()`. Unreachable, or the live send failed:
  queued with `transferUserInfo` (FIFO, survives app exit); `requestSync` is live-only. A
  failed live send is re-queued only while it is the latest command and (score/highlight)
  still pending, so it can neither reorder nor double a re-tap after the timeout. The
  phone applies each `actionId` once across both paths (`receiveFromWatch`, last 200 ids)
  and drops commands whose `sentAt` predates the match's `recordingStartTime` (left in the
  queue from an earlier match); commands without them (older watch builds) are always
  applied. `updateApplicationContext`
  is phone -> watch only: the phone pushes the full state on every change (`sendScore()`),
  and `highlightConfirmed` immediately after a highlight.
- **Every scoring action is an event** appended through `EventStore` (sequence-numbered,
  JSON payload) *and* mirrored into `scoreState` for the UI. On launch, the active match is
  rebuilt by `StateProjector.project`, and `scoreState.matchHistory` is rebuilt (oldest
  first) from the finished `StoredMatch`es; anything that re-projects the active match must
  keep that history. Undo marks an event `isUndone` and appends an
  `eventUndone` event; projection skips undone events.
- **Match rules** live in `ScoreAnnouncementUtils`/`ServingLogic` and are applied by
  `WatchConnectivityManager`: a game ends itself at 11 with two clear; a game win that
  decides the best of five sets `matchWonBy` and GameView offers to end the match; End Game
  records only finished games (or, as an explicit user choice, awards an unfinished game to
  the leader) and never a tie; `endMatch` saves a finished unrecorded game, discards an
  unfinished one and records `MatchResult.noWinner` for a games tie. The '-' buttons undo
  that player's last point through the event log (`undoPoint(forPlayer:)`).
- **Recording**: `startRecording()` marks the match live (watch scoring, timestamps,
  highlights work with the camera off), arms the 0.5 s wall-clock timer behind
  `recordingDuration`, activates the audio session and, with the camera on, starts capture.
  Every event stores wall-clock offsets. Each movie file the camera starts is persisted as a
  `recordingSegmentStarted` event (file reference + offset); interruptions (screen lock,
  calls, relaunch) end a segment and `resumeVideoRecordingIfNeeded()` / the
  interruption-ended callback start the next. `finishActiveMatch()` stops capture, builds a
  `RecordingTimeline` from the segments on disk, exports the concatenated full video, maps
  highlight ranges through the timeline into the reel, deletes the raw segments, then
  `endMatch` persists `VideoStore` references and kicks off the AI summary.
- **Isolation model**: everything is main-actor by default. Pure value types that cross
  into WCSession/AVFoundation callbacks are declared `nonisolated struct/enum`. Delegate
  callbacks are `nonisolated` and hop with `Task { @MainActor in ... }`.

## Rules

1. **Swift 6 strict concurrency stays on.** New types are main-actor by default; make pure
   models `nonisolated`. No `@unchecked Sendable` without a comment explaining why.
2. **No `print`.** Use `Log.<category>.debug/info/warning/error` (`score/Log.swift`,
   watch: `Log.session`/`Log.ui`). Inside a `Logger` interpolation you must write `self.`
   for instance properties (it is an autoclosure).
3. **`@Observable`, not `ObservableObject`**; `@Environment(Type.self)` / `@State`, not
   `@EnvironmentObject` / `@StateObject`. No Combine.
4. **Native Liquid Glass** (`.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`);
   never re-implement SwiftUI APIs with local shims.
5. No force unwraps/casts/`try!` outside `PreviewSupport` (SwiftLint errors). No
   `DispatchQueue.main` — use `Task { @MainActor in }`.
6. Add `import os` (and any module whose members you use) to each file: the project has
   `MemberImportVisibility` on.
7. Every file needs the `SwiftUI`/`Foundation` import it uses; swift-format orders imports.
8. **Don't edit `project.pbxproj`** (a hook blocks it). New files are picked up
   automatically. For targets/settings see "Project file changes".
9. Don't change deployment targets, bundle ids, signing or entitlements unless asked.
10. Logic changes come with Swift Testing tests in `scoreTests/` (not XCTest). Keep the
    phone and watch copies of `ScoreState.swift` in sync when touching either (the watch has
    no ServingLogic; it only mirrors state).
11. Run `make check` before declaring work done; CI runs the same gates.

## Testing

- Swift Testing (`@Suite`, `@Test`, `#expect`, parameterized tests). Tests run on the main
  actor and can use SwiftData directly with an in-memory container (see `PreviewSupport`
  for the wiring: `EventStore` + `StateProjector` + `UndoService` + `WatchConnectivityManager`).
- `WCSession.isSupported()` is false under test on the simulator host, so
  `WatchConnectivityManager` works without a session; drive it via `handleMessageData`.
- A known-bug test is written for the correct behaviour and marked
  `.disabled("BUG: ...")` so it documents the defect without failing CI.
- Run one suite/test: `make test T=scoreTests/EventSourcingTests` or
  `T=scoreTests/EventSourcingTests/undoDropsLastPoint` (no parentheses).

## Project file changes

The project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77), so adding or
renaming Swift files needs no project edit. For a new target, package dependency or build
setting: prefer doing it in Xcode; if you must edit `project.pbxproj`, do it with a script
from Bash, keep ids 24 hex chars and unique, then verify with
`plutil -lint score.xcodeproj/project.pbxproj && xcodebuild -list -project score.xcodeproj`
and a `make build`. Shared schemes live in `score.xcodeproj/xcshareddata/xcschemes/`.
`xcuserdata` is gitignored.

## Screenshots

Look at UI work before declaring it done. `make screenshot` builds a Debug simulator build into
`.build/sim`, installs and launches it on `SIM_NAME` (status bar overridden to 9:41) and saves a
PNG you can open with the Read tool:

```
make screenshot OUT=.build/shots/home.png                       # the app as a new user sees it
make screenshot OUT=.build/shots/home.png ARGS="-seedSampleMatches -seedActiveMatch"
make screenshot OUT=.build/shots/home-dark.png DARK=1 NO_BUILD=1 ARGS="-seedSampleMatches"
make screenshot OUT=.build/shots/sheet.png NO_BUILD=1 ARGS="-seedSampleMatches -showNewMatchSheet"
make screenshot OUT=.build/shots/home-ax.png NO_BUILD=1 \
  ARGS="-seedSampleMatches -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL"
```

- Launch arguments are read by `score/DebugSeed.swift` (DEBUG builds only): `-seedSampleMatches`
  replaces every stored match with six finished Alex vs Lucio matches (one with no winner, each with
  points, highlights and game events); `-seedActiveMatch` adds a live match 14 minutes in (1-0 in
  games, 5-3 in game two), so the home screen shows its resume state; `-showNewMatchSheet` opens the
  new-match sheet on the home screen. The seed wipes the simulator's store: only ever pass it to
  `simctl`, never to a device. `-UIPreferredContentSizeCategoryName <UICTContentSizeCategory...>`
  is UIKit's own Dynamic Type override; check at least `AccessibilityL` for truncation.
- `scripts/screenshot.sh --udid <UDID> --no-build --wait 5 out.png` targets another simulator or
  reuses the last build; `--wait` lengthens the launch-to-capture delay for slow screens.
- `.build/shots/` is gitignored; copy anything worth keeping into `docs/`.

## Icon

- Both app icons are Icon Composer documents (Liquid Glass): `score/AppIcon.icon` and
  `scorewatch Watch App/AppIcon.icon`. They are the targets' `AppIcon`
  (`ASSETCATALOG_COMPILER_APPICON_NAME`); the synchronized folders pick them up and actool
  compiles them into `Assets.car`. There is no `AppIcon.appiconset` in either asset catalog
  any more; don't add one back.
- Each document is `icon.json` plus white 1024x1024 SVG layers in `Assets/` (`rubber`, `wood`,
  `ball`, `trail`). Colours, the background gradient, glass, shadows and the light, dark and
  tinted variants all live in `icon.json` (`fill-specializations`, `opacity-specializations`).
  The first group in `groups` is drawn on top.
- The iOS document has `"supported-platforms": {"squares": "shared"}`; the watch document has
  `{"circles": ["watchOS"]}` and scales every layer to 0.92 (`position.scale`) so the artwork
  stays inside the circular mask. The SVGs are identical copies: change both documents together.
- Edit in Icon Composer (Xcode > Open Developer Tool > Icon Composer) or by hand, then preview
  every rendition and refresh `docs/icons/`:

  ```
  ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
  size=(--width 512 --height 512 --scale 1)   # 1024 to inspect detail
  "$ictool" score/AppIcon.icon --export-image --output-file docs/icons/ios-default.png \
    --platform iOS --rendition Default "${size[@]}"
  "$ictool" score/AppIcon.icon --export-image --output-file docs/icons/ios-dark.png \
    --platform iOS --rendition Dark "${size[@]}"
  "$ictool" score/AppIcon.icon --export-image --output-file docs/icons/ios-tinted-dark.png \
    --platform iOS --rendition TintedDark --tint-color 0.25 --tint-strength 0.75 "${size[@]}"
  "$ictool" "scorewatch Watch App/AppIcon.icon" --export-image \
    --output-file docs/icons/watch-default.png --platform watchOS --rendition Default "${size[@]}"
  ```

  Run `ictool` by its full path (it finds its helper `icrtool` next to itself). After a build,
  `xcrun assetutil --info <app>/Assets.car | grep '"Name" : "AppIcon"'` shows the compiled icon
  and the built `Info.plist` has `CFBundleIcons` / `CFBundleIconName = AppIcon`.
## TestFlight

`scripts/testflight.sh` archives and uploads; `scripts/asc.py` (Python 3 stdlib +
`cryptography`, no other packages) talks to the App Store Connect API for everything after
the upload. Both authenticate with the team's App Store Connect API key, so no Apple ID
session, local distribution certificate or app-specific password is involved.

**Prerequisites**

- **App Store Connect app record**: exists. "Score: Table Tennis", app id `6821574624`, bundle
  id `armincerf.score`, SKU `armincerf.score`, primary language en-GB (the public API cannot
  create app records; this one was made in the web UI). `make testflight` stops before
  archiving if it ever goes missing. The bundle ids `armincerf.score` and
  `armincerf.score.watchkitapp` are registered; cloud signing re-registers them if needed.
- **API key** `~/.appstoreconnect/private_keys/AuthKey_8QS8WXLS34.p8`. It never goes in the
  repo (`*.p8` is gitignored). Defaults: `ASC_KEY_ID=8QS8WXLS34`,
  `ASC_ISSUER_ID=69a6de79-5ccb-47e3-e053-5b8c7c11a4d1`, `ASC_KEY_PATH` as above; override by env.
- **App icons**: the upload is refused while the iOS or watch `AppIcon` has no artwork
  (App Store Connect rejects such builds); `--no-upload` only warns.
- `python3` with `cryptography` (Homebrew's has it; `/usr/bin/python3` does not).

**Steps**

```
make testflight [VERSION=1.1.0] [NOTES="What to test"]   # archive, upload, wait, distribute
make testflight-status                    # app record, latest builds + states, groups
make testers                              # "Score testers" group + testers (idempotent)
make testflight-export                    # optional: archive + export an .ipa, no upload
python3 scripts/asc.py testers            # group members and their state
```

`make testflight` = `asc.py preflight` (app record, and the review phone only for an external
group; read-only) + `scripts/testflight.sh` (archive with `-allowProvisioningUpdates`, check
the archive, export with `destination` upload) + `asc.py wait-build <n>` (polls until
`VALID`, 30 min timeout) + `asc.py distribute <n>`. If the wait times out, re-run those two
`asc.py` commands with the printed build number; every step is idempotent.

**Testers**: "Score testers" is an *internal* group with access to all builds (Alex Davis,
alexanderdavis95@gmail.com, and Lucio D'Alessandro, lucio.dalessa@gmail.com, both team
members). Every processed build reaches them at once, with no beta review; TestFlight emails
them and the build appears in the TestFlight app (the watch app installs from the iPhone's
Watch app, or automatically). To add an internal tester, put the email in `TESTERS` in
`scripts/asc.py` and run `make testers`: the person must be a team member (App Store Connect >
Users and Access) and `ensure-testers` adds this app to their visible apps when their role
limits them to specific apps (that was the 409 "Tester(s) cannot be assigned" case). Builds
expire after 90 days.

**Automatic**: build number (UTC `YYYYMMDD.HHMMSS`, both apps), marketing version (the
project's `MARKETING_VERSION` unless `VERSION=`), bundle id registration, the cloud-managed
distribution certificate and App Store profiles, symbol upload, archive checks (one app,
embedded watch app, bundle ids, versions, icons), processing wait, What to Test text, test
information (beta description and feedback email, written in the app record's primary
language, en-GB), export compliance (`ITSAppUsesNonExemptEncryption = NO` in both
Info.plists; `distribute` sets `usesNonExemptEncryption=false` only if the API reports it
unset, then waits up to 10 min for the build's internal testing state to leave
`PROCESSING`/`MISSING_EXPORT_COMPLIANCE`), and auto-notify. `distribute` exits non-zero if
the build does not end up `READY_FOR_BETA_TESTING`/`IN_BETA_TESTING`.

**Manual**: icon artwork, adding people to the team, and anything for the App Store itself
(screenshots, privacy, release).

**External testers (not used)**: `ASC_EXTERNAL_GROUP=1 make testers` creates an *external*
"Score testers" group instead (only if none exists yet), for people outside the team: they
are invited by email, Apple reviews the first build of each version before they can install
it (later builds are usually quick), and `distribute` then also needs the beta review contact
(`ASC_REVIEW_PHONE` once; `ASC_REVIEW_FIRST_NAME`/`LAST_NAME`/`EMAIL` default to Alex / Davis /
alexanderdavis95@gmail.com; `ASC_FEEDBACK_EMAIL` defaults to the review email), adds the build
to the group and submits it for beta review. A rejected review makes `distribute` exit
non-zero with a pointer to App Store Connect.

Notes: `testflight.sh` runs xcodebuild with `/usr/bin` first on `PATH` (Homebrew's rsync breaks
`exportArchive`) and its own DerivedData in `.build/archive/`; logs are
`.build/logs/testflight-{archive,upload,export}.log` and only their tails are printed on
failure. `--no-upload` may still reserve the build number on App Store Connect; every run takes
a new one, so that is harmless.

## Gotchas

- **Case-insensitive filesystem**: renaming `fooApp.swift` to `FooApp.swift` by writing the
  new name and deleting the old one deletes the file. Use `git mv`.
- The simulator runtime must be >= the deployment target; otherwise xcodebuild reports
  "doesn't match deployment target" for every device. Builds use `generic/platform=iOS
  Simulator` so they work without a runtime; tests do not.
- FoundationModels: `SystemLanguageModel.default.availability` is `.unavailable` on the
  simulator and on devices without Apple Intelligence; the UI shows the unavailable card.
- The watch app shows the scoring UI only while `scoreState.isRecording` is true (the
  phone sets it in `startRecording()`).
- `AVCaptureSession.startRunning()` blocks; it runs on a detached task and the first file
  starts ~0.5 s later. That is fine: the segment's `startOffset` records when footage really
  began, and `RecordingTimeline` maps event offsets onto it.
- iOS mutes system sounds and haptics while the microphone is recording, so the phone's
  highlight "tink"/haptic are inaudible during a recorded match; the watch's haptic is the
  real confirmation.
- A game-winning point can be undone: `UndoService` treats a `gameEnded` that directly follows
  a point as part of that point and reopens the game (`undoLastAction`/`undoLastPoint`); the
  '-' button does the same via `lastPointPlayer`.
- GameView disables the idle timer while on screen (the phone sits on a stand); without it
  the device locks after 30-60 s and the capture session is interrupted. The status bar
  shows REC only while `videoManager.state == .recording`.
- `AVCaptureDevice.RotationCoordinator` reports 0 degrees while its preview layer is not in a
  window, so `CameraPreviewUIView` rebuilds it in `didMoveToWindow` (and per device change).
- Orientation comes from `AVCaptureDevice.RotationCoordinator` (capture and preview), never
  `UIDevice.current.orientation`, which is `.faceUp`/`.unknown` for a phone lying flat. Export
  rotates each segment by its own `preferredTransform`.
- If `make test` reports "Failed to install or launch the test runner ... No such process" for
  every test, the simulator is in a bad state (typically after a killed xcodebuild): run
  `make sim-reset`, or add `-parallel-testing-enabled NO` to the xcodebuild test command.
- GitHub's `xcode-27` runner image is a preview; if it disappears, switch CI to
  `macos-26` + `xcode-select`.

## Known debt (good next tasks)

- `WatchConnectivityManager` is a god object (match lifecycle + scoring + recording +
  export + AI + transport). Split the match lifecycle into its own `@Observable` type.
- The watch target duplicates `ScoreState.swift`; a shared Swift package would remove the
  drift risk.
- `WatchSyncState` is unused by the live protocol (full `ScoreState` dictionaries are sent;
  match history is no longer included, so the payload is bounded by the current match).
- `loadMatchHistory()` re-projects every finished match's events on the main actor at launch;
  cache the projected games on `StoredMatch` once history grows into the hundreds.
- Recording segments are concatenated at export; there is no UI to review or trim them.
- Watch protocol: a late live reply or applicationContext is applied unconditionally (the next
  `sendScore()` corrects it); the 2 s pending timeout plays an error haptic while a slow live
  send may still land; a tied-score End Game is dropped silently by the phone after the watch
  haptic; `RecentActionIDs` is in-memory only. Fix together with a watch test target.
- Export renders every segment at the first segment's size (a mid-match orientation change
  letterboxes); `VideoRecordingManager` start/stop still use detached tasks.
- Legacy rows: matches tied on games that pre-date `MatchResult.noWinner` reload as player-2
  wins; an in-progress legacy match loses its tmp recording on upgrade.
- Several test comments in WatchCommandTests still describe the bugs they were written for.

## Skills

`make skills` (also run on every Claude Code session start) exports Apple's Xcode 27 agent
skills into `.claude/skills/` (gitignored): `swiftui-specialist`, `swiftui-whats-new-27`,
`modernize-tests`, `device-interaction`, `audit-xcode-security-settings`. Load
`swiftui-specialist` before writing or reviewing SwiftUI; `modernize-tests` for tests.
