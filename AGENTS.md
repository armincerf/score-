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
  GameView.swift              Live match: camera preview, status bar, ScoringPanel, alerts, export sheet
  MatchHistoryView.swift      List of finished matches (@Query on StoredMatch)
  MatchDetailView.swift       One match: videos, AI summary, stats, games, highlights
  CameraSettingsView.swift    Lens/quality/enabled prefs + live preview; CameraDeviceType, VideoQualityPreset
  CameraPreviewManager.swift  AVCaptureSession for the settings preview only
  WatchConnectivityManager.swift           Phone hub: match lifecycle, scoring, recording, export, AI (see "Known debt")
  WatchConnectivityManager+WCSession.swift WCSessionDelegate: actionId dedupe + command dispatch from the watch
  VideoRecordingManager.swift AVCaptureMovieFileOutput recording; async stop waits for file finalization
  MediaExportService.swift    Full-video + highlight-reel export (AVVideoComposition.Configuration, export(to:as:))
  MockVideoGenerator.swift    Synthetic video for the simulator (no camera)
  VideoTransferable.swift     ShareLink/Transferable wrapper for exported videos
  ScoreState.swift            In-memory match state + PointEvent/GameResult/MatchResult/HighlightClip + watch dictionary codec
  ServingLogic.swift          Pure serving rules (first server, rotation, serve stats)
  ScoreAnnouncementUtils.swift Pure announcement text + game/match-point/won checks
  ScoreAnnouncer.swift        AVSpeechSynthesizer wrapper
  EventModels.swift           Event types (matchStarted, pointScored, highlightMarked/Attributed, gameEnded, matchEnded, eventUndone)
  SwiftDataModels.swift       @Model StoredMatch, StoredMatchEvent (JSON event payload), UserPreferences
  EventStore.swift            Append/query events and matches on the main ModelContext
  StateProjector.swift        Replays events into ScoreState (one `apply` per event type)
  UndoService.swift           Soft-delete undo of points/highlights in the current game (max depth 10)
  UserPreferencesService.swift Names + camera prefs in SwiftData
  WatchSyncState.swift        Minimal sync payload (currently unused by the live protocol)
  Log.swift                   os.Logger categories: app, match, video, audio, store, ui, ai
  PreviewSupport.swift        In-memory SwiftData fixture for #Preview (DEBUG only)
  AI/MatchSummaryModels.swift @Generable MatchAnalysis + Codable cache + MatchContext prompt builder
  AI/MatchSummaryService.swift FoundationModels session; availability + errors
  AI/MatchSummaryView.swift   Summary card, loading/error/unavailable states, container with cache
scorewatch Watch App/       watchOS target (no shared module: ScoreState.swift is a COPY of the phone's)
  ScoreWatchApp.swift, ContentView.swift (3-page TabView: end-game / scoring / highlight), WatchSessionManager.swift, ScoreState.swift, Log.swift
scoreTests/                 Swift Testing suites (@testable import score)
scripts/                    xcb.sh (xcodebuild filter), deploy-device.sh (devicectl install), sync-xcode-skills.sh, hooks/
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
  rebuilt by `StateProjector.project`. Undo marks an event `isUndone` and appends an
  `eventUndone` event; projection skips undone events.
- **Recording**: `startRecording()` arms a 0.5 s timer that drives `recordingDuration`;
  point/highlight video timestamps are read from it. `stopRecording()` is async and returns
  the finalized file. `exportMatchVideos` writes a re-oriented full video and, if highlights
  exist, a highlight reel; `endMatch` persists URLs and kicks off the AI summary.
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
    phone and watch copies of `ScoreState.swift`/`ServingLogic` in sync when touching either.
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
  `T=scoreTests/EventSourcingTests/undoDropsLastPoint`.

## Project file changes

The project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77), so adding or
renaming Swift files needs no project edit. For a new target, package dependency or build
setting: prefer doing it in Xcode; if you must edit `project.pbxproj`, do it with a script
from Bash, keep ids 24 hex chars and unique, then verify with
`plutil -lint score.xcodeproj/project.pbxproj && xcodebuild -list -project score.xcodeproj`
and a `make build`. Shared schemes live in `score.xcodeproj/xcshareddata/xcschemes/`.
`xcuserdata` is gitignored.

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
- `AVCaptureSession.startRunning()` blocks; it runs on a detached task, and recording
  starts ~0.5 s later, so early video timestamps are offset by the session start-up time.
- `UIDevice.current.orientation` can be `.faceUp`/`.unknown`; export orientation is
  captured at the first point and falls back to landscape.
- GitHub's `xcode-27` runner image is a preview; if it disappears, switch CI to
  `macos-26` + `xcode-select`.

## Known debt (good next tasks)

- `WatchConnectivityManager` is a god object (match lifecycle + scoring + recording +
  export + AI + transport). Split the match lifecycle into its own `@Observable` type.
- `scoreState.matchHistory` is in-memory only; `ServingLogic.determineInitialServer` and
  the AI head-to-head context therefore only see matches from the current app session.
- The watch target duplicates `ScoreState.swift`; a shared Swift package would remove the
  drift risk.
- `WatchSyncState` is unused by the live protocol (full `ScoreState` dictionaries are sent,
  including the whole match history, which grows without bound).

## Skills

`make skills` (also run on every Claude Code session start) exports Apple's Xcode 27 agent
skills into `.claude/skills/` (gitignored): `swiftui-specialist`, `swiftui-whats-new-27`,
`modernize-tests`, `device-interaction`, `audit-xcode-security-settings`. Load
`swiftui-specialist` before writing or reviewing SwiftUI; `modernize-tests` for tests.
