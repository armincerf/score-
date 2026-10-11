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
  HomeView.swift              Home screen: presentation state, sheets, alerts; New Match flow (active-match alert, name sheet); NavigationPath + StatsRoute destination
  HomeSections.swift          Home dashboard cards (active match / head-to-head with a Stats link, recent matches, watch status), empty state, New Match bar button
  MatchNameSheet.swift        New Match sheet: Form with the two player names, Cancel / Start
  HeadToHead.swift            Pure head-to-head of any two players (between(_:_:in:); from(history:) = latest match's pair): wins, draws, games, points, meetings + winner filter; AI previousMeetings extends it
  PlayerRecords.swift         Pure records for the Stats pages: PlayedMatch (resolved players), leaderboard, PlayerRecord (streak, form), per-opponent records, a player's matches
  StatsView.swift             Stats page (leaderboard + head-to-head with player choice), StatsModel, StatsRoute + StatsRouteView (the pages behind its rows)
  PlayerStatsView.swift       A player's page (record, opponents, matches) + LeaderboardRow, RecordText, FormMarks, OutcomeBadge
  HeadToHeadStatsView.swift   A pair's comparison and matches (All / A won / B won) as list sections, and as a page of its own
  GameView.swift              Live match: camera preview, RecordingStatusBar (capture state), ScoringPanel, alerts
  ExportProgressView.swift    Modal shown while finishActiveMatch() stops, exports and saves (Game + Home)
  MatchHistoryView.swift      List of finished matches (scoreState.matchHistory, reloaded from the store at launch)
  MatchDetailView.swift       One match: header, videos, AI summary, stats, games, highlights
  MatchVideosSection.swift    Detail screen's video card: Highlights / Full match picker, inline player, Full Screen + Share, empty states
  MatchVideoPlayback.swift    @Observable: the match's videos, selection (switching pauses), one lazy AVPlayer each, display sizes
  MatchVideoPlayer.swift      AVPlayerViewController representable (system controls) + full-screen presentation (header button, turn to landscape)
  InlinePlayerLayout.swift    Pure: video display size (uprightGeometry) + width + screen height -> inline player frame (16:9 fallback)
  CameraSettingsView.swift    Lens/quality/enabled prefs + live preview; CameraDeviceType, VideoQualityPreset
  CameraPreviewManager.swift  Settings preview session (serial session queue, permission state) + CameraPreviewUIView (horizon-level preview)
  WatchConnectivityManager.swift           Phone hub: match lifecycle, scoring, recording, export, AI (see "Known debt")
  WatchConnectivityManager+WCSession.swift WCSessionDelegate: actionId dedupe + command dispatch from the watch
  VideoRecordingManager.swift Capture session + movie output; CaptureState (interrupted/failed...), segment callbacks, rotation coordinator
  RecordingTimeline.swift     RecordingSegment + wall-clock offset -> concatenated-video time mapping (gaps clamp)
  VideoRotationCorrection.swift Extra clockwise turn a segment needs beyond its metadata (transform, EXIF orientation) + OrientationDecision
  VideoOrientationDetector.swift Samples frames, scores upright people per orientation with Vision body pose, decides; BodyPoseEvidence
  AudioSessionCoordinator.swift Owns AVAudioSession: a match (play-and-record to speaker; released at match end), else the detail player (.playback)
  MediaExportService.swift    Concatenates segments upright (per-track preferredTransform) + cuts the reel (scoreboard burned in); export(to:as:) with progress
  ReelScoreboard.swift        Broadcast-style scoreboard for the reel: state, pixel layout per video size, SwiftUI view, ImageRenderer
  ReelScoreboardTimeline.swift Pure: match data + reel clips -> board states with reel-time ranges (score at clip start, celebration)
  ReelOverlayComposer.swift   Burns time-ranged bitmaps (the scoreboard) into a video composition per frame with Core Image
  MockVideoGenerator.swift    Synthetic video for the simulator (no camera); 1280x720 unless given a size
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
                            testflight.sh (archive + upload), asc.py (App Store Connect API: testers, distribution),
                            detect-orientation.sh + orientation/ (the app's orientation detector as a Mac CLI)
docs/icons/                 Rendered icon previews (ictool exports)
docs/plans/                 Design notes for larger pieces of work (highlight-reel.md: orientation fix + scoreboard overlay)
docs/screenshots/           Home screen, Stats page and reel-player renders (make screenshot output, refresh when those screens change)
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
- **Stats** are derived, never stored: `PlayerRecords(history:)` recomputes every record from
  `scoreState.matchHistory` (`StatsModel` caches it per history change). Players are recognised as in
  the head-to-head and the AI summary (`MatchPlayers.names(of:)`/`key`: trimmed, case-insensitive,
  either order, names recovered from the "A vs B - date" match name); a match without two different
  players counts for nobody, and a player shows as most recently spelled. Leaderboard order: win rate
  (a match without a winner is played, not won), wins, fewer losses, name. The Stats pages are
  `StatsRoute` values on HomeView's `NavigationPath`, resolved at the stack's root: a value link on a
  page pushed with `navigationDestination(isPresented:)` does not push.
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
  `T=scoreTests/EventSourcingTests/undoDropsLastPoint()` (a Swift Testing function needs its `()`: without
  them xcodebuild runs 0 tests; a parameterized test can only be run through its suite).

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
make screenshot OUT=.build/shots/home.png ARGS="-seedEmpty"     # the app as a new user sees it
make screenshot OUT=.build/shots/home.png ARGS="-seedSampleMatches -seedActiveMatch"
make screenshot OUT=.build/shots/home-dark.png DARK=1 NO_BUILD=1 ARGS="-seedSampleMatches"
make screenshot OUT=.build/shots/sheet.png NO_BUILD=1 ARGS="-seedSampleMatches -showNewMatchSheet"
make screenshot OUT=.build/shots/home-ax.png NO_BUILD=1 \
  ARGS="-seedSampleMatches -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL"
# the Stats page: four players (leaderboard + player choice), or two (no choice), or none (empty state)
make screenshot OUT=.build/shots/stats.png NO_BUILD=1 ARGS="-seedLeague -openStats"
make screenshot OUT=.build/shots/stats-two.png NO_BUILD=1 ARGS="-seedSampleMatches -openStats"
# the newest match's detail screen with a real exported reel (mock footage + scoreboard); --wait covers the export
scripts/screenshot.sh --wait 15 --args "-seedSampleMatches -seedReel -openLatestMatch" .build/shots/reel-detail.png
# the same with a portrait (720x1280) recording, for the inline player's portrait shape
scripts/screenshot.sh --no-build --wait 20 --args "-seedSampleMatches -seedReelPortrait -openLatestMatch" .build/shots/portrait.png
# the same in landscape (the interface turns as the home screen appears; the player is below the fold there)
scripts/screenshot.sh --no-build --wait 20 --args "-seedSampleMatches -seedReel -openLatestMatch -landscapeAfter 0" .build/shots/landscape.png
```

- Launch arguments are read by `score/DebugSeed.swift` (DEBUG builds only): `-seedEmpty` removes
  every stored match (a launch without seed arguments keeps whatever the last run stored); `-seedSampleMatches`
  replaces every stored match with six finished Alex vs Lucio matches (one with no winner, each with
  points, highlights and game events); `-seedActiveMatch` adds a live match 14 minutes in (1-0 in
  games, 5-3 in game two), so the home screen shows its resume state; `-seedLeague` replaces every stored match
  with twelve finished matches between Alex, Lucio, Mia and Sam over the last three months (Alex vs Lucio in both
  name orders, one without a winner): the Stats page with a leaderboard and a choice of players; `-openStats`
  opens the Stats page as the home screen appears (the head-to-head's matches and the player pages are below
  it: scroll or tap with UI automation, e.g. the "Lucio won" segment); `-showNewMatchSheet` opens the
  new-match sheet on the home screen; `-seedReel` (with `-seedSampleMatches`) writes a 20 s mock recording
  as the newest match's full video and runs the real highlight reel export with the scoreboard (four 4.5 s
  clips scored from that match's highlights); `-seedReelPortrait` does the same with a 720x1280 recording;
  `-landscapeAfter <seconds>` turns the interface to landscape that long after the home screen first appears
  (`requestGeometryUpdate`; the simulator cannot be rotated from the shell): with 25, start the reel first to see
  the turn open the full-screen player. In landscape, xcodebuildmcp's ref taps land in the wrong place; `axe tap
  --label <label> --udid <udid>` works (show the controls with `axe tap --label Video` first);
  `-openLatestMatch` opens the newest match's detail screen once that export has finished (about 2 s on the
  simulator). A landscape reel's player is above the fold; a portrait one (420 pt tall) is not: scroll it into
  view with any UI automation (for example xcodebuildmcp's `ui-automation snapshot-ui` and `ui-automation swipe
  --within-element-ref <scroll ref> --direction up --distance 0.45`, if installed; `make setup` does not install
  it), then capture with `xcrun simctl io <udid> screenshot out.png`. To show the player's controls use a
  physical tap on the "Video" element (`axe tap --label Video --tap-style physical --udid <udid>`): xcodebuildmcp's
  `touch` on it only toggles playback. AVKit's controls auto-hide after ~3 s while playing, so read them
  (`axe describe-ui`) straight after the tap; a tap on the centre of the video also hits play/pause.
  The seed wipes the simulator's store and its videos: only ever pass it to `simctl`, never to a device. `-UIPreferredContentSizeCategoryName <UICTContentSizeCategory...>`
  is UIKit's own Dynamic Type override; check at least `AccessibilityL` for truncation.
- `scripts/screenshot.sh --udid <UDID> --no-build --wait 5 out.png` targets another simulator or
  reuses the last build; `--wait` lengthens the launch-to-capture delay for slow screens.
- `.build/shots/` is gitignored; the home screen's renders, the detail screen's player
  (`reel-detail-player.png`, from `-seedSampleMatches -seedReel -openLatestMatch`) and the Stats page
  (`stats.png`, from `-seedLeague -openStats`) live in `docs/screenshots/` (`sips -Z 1000` copies): refresh them
  when those screens change.

## Highlight reel

- **Orientation** comes from the pictures as well as the metadata: before the full export,
  `exportMatchVideos` runs `VideoOrientationDetector` on every segment (5 frames at 30-70 %, Vision
  `DetectHumanBodyPoseRequest` at the four EXIF orientations; a person counts by neck-over-root confidence
  weighted by how upright the torso is) and `OrientationDecision` turns a clear winner (>= 1.0 and >= 1.5x the
  runner-up) into a `VideoRotationCorrection` that `uprightGeometry` applies after the preferredTransform.
  Scores and decisions are logged (`Log.video` "Orientation <file>: none=... -> ...") for real-footage problems.
  Conventions are pinned by `OrientationConventionTests` (Vision as the oracle) and `VideoOrientationTests`.
- Segments **stored alike** (same video track `naturalSize` and `preferredTransform`) are decided together:
  `VideoOrientationDetector.corrections(for:)` sums their scores and `OrientationDecision.groups(pooling:)`
  decides once per group (logged "Orientation group [<files>] stored WxH [<transform>]: ... -> ..."), so a short,
  empty or failed segment follows its neighbours instead of keeping `.none` while they turn a quarter. As a
  safety net `makeComposition` scales a piece whose upright size differs from the render size (the first
  piece's) to fit and centres it (`MediaExportService.fitting`): a mismatch letterboxes, it never crops.
- When the full export fails for a one-segment match the raw segment is kept as the full video and the reel is
  cut from it with that segment's correction (`exportHighlightReel(..., correction:)`); a turned reel gets no
  board (the Core Image composition shows frames as stored; warning logged). If the reel export with the board
  throws, the manager retries once without it.
- Vision's body pose request has **no compute device on the iOS simulator** (it throws, the detector keeps
  `.none`). Check detection on the Mac instead: `scripts/detect-orientation.sh <video>...` prints the scores
  of any recording, and `--selftest <photo of people> <dir>` turns the photo each way and checks the decision.
  Orientation test frames land in `.build/shots/reel/orientation/`.
- The reel scoreboard is drawn per frame with Core Image (`ReelOverlayComposer`, iOS 26
  `AVVideoComposition(applyingFiltersTo:applier:)`): each frame is a pure function of its composition
  time, so it works for export and playback and is testable. Do not switch it to
  `AVVideoCompositionCoreAnimationTool` (export-only, begin-time quirks, custom layers never drawn).
- The board is SwiftUI (`ReelScoreboardView`, previewable) rasterised once per state with
  `ImageRenderer` at the pixel size `ReelScoreboardLayout` derives from the video's short side, on the main
  actor, before the export starts (`MediaExportService.scoreboardOverlays`; identical states share a bitmap).
  Type is sized for the reel watched inline on a phone (about 340 pt wide in MatchDetailView): at 720p rows
  50 px, digits 29 px, names 25 px heavy condensed capitals, in a panel 440 px wide (capped at the short side
  less both 32 px margins). Both names share one size: `ReelScoreboardView.nameFontSize` measures them with the
  font that draws them and `ReelScoreboardLayout.sharedNameFontSize` shrinks both until the wider fits
  `nameColumnWidth` (re-measuring, since SF tracks small sizes looser; floor 0.6), so a long name never shrinks
  only its own row. `ReelScoreboardLayoutTests` checks it on `board-long-name.png` / `board-full-names.png`.
- What the board shows is pure: `ReelScoreboardTimeline` turns the match (`scoreState`) and the reel's clips
  (each `HighlightClip` with its reel duration, in reel order) into `ReelScoreboardCue`s: the score as the
  clip starts (points with `videoTimestamp <= clip start`), who serves, and for clips of 3 s or more whose game
  recorded the rally's point (the first point after the clip start, won by the attributed player) the winner's
  row lit with that point for the last 1.2 s; a highlight credited by a forced End Game has no such point and
  gets no celebration. `WatchConnectivityManager.exportHighlightReel` passes the rendered
  cues to `MediaExportService.exportHighlightReel(..., scoreboard:)`.
- A source without sound (every mock video; a recording made without microphone access) leaves
  `makeComposition`'s audio track empty, and an empty track fails the export (AVError -11838) with or without
  the board, so `makeComposition` drops it: this covers the full video and the reel (`ReelManagerExportTests`
  and `VideoOrientationIntegrationTests` check both). The board is only drawn over a
  source stored upright (identity `preferredTransform`, as the exported full video is); otherwise the plain
  reel is exported and a warning logged. Keep an `AVURLAsset` alive while using its tracks (a track does not
  retain its asset; inserting a track of a released asset fails with -11800/-12780).
- Proof, all on exported frames: `scoreTests/ReelOverlayTests` (the composer: a 4 s mock with two cues),
  `ReelExportTests` (the real reel: a fabricated two-game match, two clips, frames at 1.0/2.5/4.0/6.5 s;
  plus sound, rotated and cue-less sources and the 1080p/4K/portrait layouts), `ReelManagerExportTests`
  (through `exportMatchVideos()`) and `ReelScoreboardTimelineTests` (the rules). `make test` sets
  `REEL_FRAMES_DIR` so frames land in `.build/shots/reel/` (`board.png`, `reel-*.png`, `scoreboard-reel-*.png`,
  `board-1080p.png`, `manager-reel-*.png`, ...); look at them with the Read tool whenever the board or the
  composer changes. When sampling pixels in tests, avoid glyphs (the digits are black on the gold box):
  sample corners or compare regions. Shared helpers: `scoreTests/ReelFrameSupport.swift`.
- **Playback** (match detail, `MatchVideosSection`, directly below the header card): one inline player with a
  segmented Highlights / Full match picker (when both exist; Highlights first). It is AVKit's
  `AVPlayerViewController` in a representable (`MatchVideoPlayer`), not SwiftUI's `VideoPlayer`, which showed no
  controls on this screen; Live Text (`allowsVideoFrameAnalysis`) is off because it took taps on paused frames.
  `InlinePlayerLayout` shapes the player like the video: the display size comes from the file's first video track
  (`naturalSize` + `preferredTransform` through `MediaExportService.uprightGeometry`), fitted into the card's width
  and a height cap of 420 pt, less on a short screen (landscape fills the width, portrait is as tall as the cap
  and centred, 16:9 until the size is read).
  Full screen: the system controls' expand button (AVKit's own full screen), or the header's Full Screen button,
  which presents a second `AVPlayerViewController` on the same `AVPlayer` modally (`.fullScreen`) from the inline
  one, so it continues at the same position; a request counter (not a flag) means nothing is reset on Done.
  Both rotate with the device (the plist allows landscape). Turning the phone to landscape while the inline video
  plays opens the modal full-screen player, as the system video apps do (paused, it only re-lays out the card);
  `LandscapeFullScreenTrigger` keeps a full-screen player closed in landscape from reopening when the screen
  learns of the turn afterwards. The player's height is capped at 80 % of the scroll view's visible height
  (`InlinePlayerLayout.maxHeight(forViewportHeight:)`, measured in `MatchDetailView`), so in landscape (about
  304 pt on an iPhone 17 Pro) the whole video and its scrubber fit on screen. Sound: outside a match the inline
  player sets the `.playback`/`.moviePlayback` category (`AudioSessionCoordinator.prepareForPlayback`; AVPlayer
  activates the session on play, so opening the screen leaves other apps' audio alone) and releases the session
  when removed; the default solo-ambient category would be muted by the Ring/Silent switch. A live match keeps
  its own session (`isMatchLive`). The inline player pauses in `dismantleUIViewController` (leaving the screen, switching video), never `onDisappear`,
  which also fires while a full-screen player covers the screen. `-seedReelPortrait` renders the portrait case.
- Design and remaining work: `docs/plans/highlight-reel.md`.

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
  rotates each segment by its own `preferredTransform`, then by the correction the orientation
  detector found in its pictures (see "Highlight reel").
- A `CGContext` over a pixel buffer has its origin bottom-left; UIKit drawing assumes top-left. `MockVideoGenerator`
  flips the CTM before `UIGraphicsPushContext`, so its clock reads normally and "MOCK MATCH VIDEO" sits along the
  top edge (before October 2026 both came out upside down and mirrored, the caption at the bottom).
- Mock footage has no audio track. `makeComposition` drops the composition's audio track when nothing
  was inserted into it; an empty one made every export of silent footage fail with -11838.
- Vision text recognition on iOS 27 reads text at any rotation, so "can it read it" is no orientation
  oracle; where it puts the text box (normalized, origin bottom-left) is.
- On a test failure xcodebuild collects simulator diagnostics (`simctl diagnose`, ~10 minutes) before it
  prints results; `make test` passes `-collect-test-diagnostics never`, so failures show at once (the result
  bundle still has every result). Keep that flag if you change the target.
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
- Export renders every segment at the first segment's size: a segment that comes out another shape (a
  mid-match orientation change, which is stored differently and so decided apart) is scaled to fit it
  between black bands, not cropped. Choosing the output shape from the longest stretch of footage would be
  better. Segments stored alike share one orientation decision, so a phone turned over mid-match without its
  capture metadata changing (e.g. lying flat) is not caught. `VideoRecordingManager` start/stop still use
  detached tasks.
- Legacy rows: matches tied on games that pre-date `MatchResult.noWinner` reload as player-2
  wins; an in-progress legacy match loses its tmp recording on upgrade.
- Several test comments in WatchCommandTests still describe the bugs they were written for.

## Skills

`make skills` (also run on every Claude Code session start) exports Apple's Xcode 27 agent
skills into `.claude/skills/` (gitignored): `swiftui-specialist`, `swiftui-whats-new-27`,
`modernize-tests`, `device-interaction`, `audit-xcode-security-settings`. Load
`swiftui-specialist` before writing or reviewing SwiftUI; `modernize-tests` for tests.
