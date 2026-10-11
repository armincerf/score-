# Smarter highlight reel: orientation correction and a burned-in scoreboard

Status: in progress (October 2026). Owner: the export pipeline (`MediaExportService`,
`WatchConnectivityManager.exportMatchVideos`).

- Goal 2 (scoreboard): **done** on the simulator. The real reel export burns the board in
  (`ReelScoreboardTimeline` -> `MediaExportService.scoreboardOverlays` -> `exportHighlightReel(scoreboard:)`,
  wired in `WatchConnectivityManager.exportHighlightReel`), proven by `ReelExportTests` on exported frames and
  visible in the app via `-seedSampleMatches -seedReel -openLatestMatch`. Not yet seen on real footage (device).
- Goal 1 (orientation): built separately (see the components marked to do below).

## Goals

1. **Right way up.** Footage recorded with the phone upside down or sideways is exported upright. The
   decision comes from the pictures, not only from the capture metadata: sample frames around the
   middle of each recorded segment, run Apple's on-device human body pose model at the four candidate
   orientations and keep the one in which people stand upright. If the evidence is weak, keep the
   metadata orientation (today's behaviour).
2. **Broadcast scoreboard on the reel.** Every highlight clip in the reel carries a lower-third panel
   like a televised match: colour chip, player name, serve marker, games (gold box) and points. The
   board shows the score as the rally starts and, for clips long enough, lights up the winner's row
   with the new score for the last second of the clip.
3. **Provable.** Each piece is a pure function with Swift Testing coverage, and the two end-to-end
   paths (overlay burn-in, orientation decision) are integration tests on the simulator that export a
   synthetic video, read frames back out of the file and check pixels. Frames are also written as PNGs
   so a person can look at them.

## How the overlay is drawn (decided by the spike in `scoreTests/ReelOverlayTests.swift`)

Per-frame Core Image compositing through `AVVideoComposition(applyingFiltersTo:applier:)` (iOS 26).
The applier is a pure function of `compositionTime`: it composites the pre-rendered board bitmap for
the cue whose time range contains the frame. This works for export and playback, needs no Core
Animation timing (`AVVideoCompositionCoreAnimationTool` has documented export pitfalls: begin-time
quirks, custom layers never drawn, random freezes) and is deterministic to test.

The board itself is SwiftUI (`ReelScoreboardView`), rasterised once per state with `ImageRenderer`
at the exact pixel size `ReelScoreboardLayout` derives from the video height, so the design is
previewable and the export only deals in images. Rendering happens on the main actor before the
export starts (a few images per reel).

## Components

| File | Role |
|---|---|
| `score/ReelScoreboard.swift` | `ReelScoreboardState`, `ReelScoreboardLayout` (pixel geometry per video size), `ReelScoreboardView`, `ReelScoreboardRenderer` |
| `score/ReelOverlayComposer.swift` | `OverlayCue` (time range + bitmap + origin) and the Core Image video composition |
| `score/ReelScoreboardTimeline.swift` (done) | Pure: clips + match data -> the board state(s) for each clip, with reel-time ranges (`ReelScoreboardCue`) |
| `score/VideoOrientationDetector.swift` (to do) | Samples frames, runs `DetectHumanBodyPoseRequest` at four orientations, scores them |
| `score/VideoRotationCorrection.swift` (to do) | The decision (`OrientationDecision.decide`), the correction enum and its transform |
| `MediaExportService` | `uprightGeometry` gains a correction; `exportHighlightReel` gains scoreboard cues (done) |
| `WatchConnectivityManager.exportMatchVideos` | Detects per segment before the full export; `exportHighlightReel` builds the scoreboard cues for the reel (done) |

### Scoreboard timeline (pure)

Inputs: player names, finished games (`GameResult`: points with wall-clock `videoTimestamp`, `firstServer`),
the current game's points and first server, and the reel's clips in reel order (`HighlightClipInfo`
plus each clip's wall-clock start/end and `gameNumber`, `player`).

For each clip:
- Games: wins per player among games before `gameNumber`.
- Points at clip start: points of that game with `videoTimestamp <= clip wall start` (the clip starts
  at the last scored point, so that point counts).
- Server: `ServingLogic.serverForPoint(index: pointsPlayed, firstServer:)`.
- If `player` is set and the clip is at least 3 s long, a second state for the last 1.2 s: that
  player's points + 1, `pointWonBy` set, server recomputed.
- Reel time ranges: cumulative clip durations, in clip order.

### Scoreboard: as built (and what changed from the plan)

- `ReelScoreboardTimeline(scoreState:)` takes the live match; `cues(for: [ReelClip])` takes each clip's
  `HighlightClip` (wall clock) and its reel duration (`RecordingTimeline.videoRange` length, which is what
  `clipTimeRanges` cuts unless the full video is shorter than the timeline; an overrun is logged). Points without
  a `videoTimestamp` are not counted. A clip whose game is beyond the data shows the games so far, 0-0, no server
  and no celebration. Times are CMTime at timescale 600, like the composition, so cues line up with the cuts.
- `MediaExportService.scoreboardOverlays(_:videoSize:)` renders each distinct state once (identical states share a
  bitmap); `scoreboardOverlays(_:forReelFrom:)` sizes them for the source's upright frame.
  `exportHighlightReel(..., scoreboard:)` swaps the composition's layer-instruction video composition for
  `ReelOverlayComposer`'s when cues are given.
- Found while proving it: **an empty track fails the export** (AVError -11838, MediaValidator -12783 on the iOS 27
  simulator), with or without the scoreboard. A source without sound (every mock video; a recording made without
  microphone access) leaves `makeComposition`'s audio track empty, so the reel export drops empty tracks before
  exporting. `exportFullVideo` builds the same empty track and fails the same way (seen in
  `ReelManagerExportTests`, kept as a `.disabled("BUG: ...")` test); it was not changed here because the full
  export belongs to the orientation work. `exportMatchVideos` then keeps a single raw segment as the full video,
  which is why the simulator path still gets a reel; with several silent segments there is no full video and no reel.
- The Core Image composition shows frames as stored, so the board is only drawn over a source stored upright
  (identity preferredTransform). The exported full video always is; a raw camera file kept as the full video after
  a failed full export may not be, and then the reel is exported plain (upright, no board) and a warning is logged.
- Layout scales with the frame's short side, not its height, so the board also fits across portrait footage
  (unchanged for landscape).
- Design pass at 720p/1080p: the celebration is now the winner's points cell turned white (black digits) plus a
  brighter row (white 22 %), and the serve marker is 14 px at 720p (was 12).

### Orientation decision (pure core, Vision around it)

- Candidate orientations: `.up`, `.right` (needs 90° clockwise), `.down` (180°), `.left` (270°).
- Evidence per orientation: for each sampled frame (30 %, 40 %, 50 %, 60 %, 70 % of the segment),
  `DetectHumanBodyPoseRequest.perform(on:orientation:)`; score = sum over observations with neck and
  root joints of (mean joint confidence) when the neck is above the root (Vision coordinates, origin
  bottom-left), 0 otherwise.
- `OrientationDecision.decide(scores:)` returns a correction only when the best score is at least
  `minimumScore` and at least `margin` (1.5x) times the runner-up; ties and weak evidence keep the
  metadata orientation. The scores are logged so real-footage problems can be diagnosed.
- The correction folds into the composition's layer transform (`uprightGeometry(naturalSize:
  preferredTransform:correction:)`), so no second export pass is needed.
- Simulator footage (`MockVideoGenerator`) has no people and must decide `.none`.

## Verification

- Unit: `OrientationDecision`, `uprightGeometry` with each correction, `ReelScoreboardTimeline`
  (score at clip start across games, deuce serving, pending highlight, short clips without a
  celebration window, reel-time ranges), layout maths.
- Integration (simulator, `make test T=scoreTests/ReelOverlayTests` and the detector suite): export a
  4 s mock video with two cues, read frames at 1 s, 3 s and 3.9 s, check the gold games box, the
  player chips, an untouched region and that the panel is gone after the last cue; PNGs land in the
  test host's tmp directory (`xcrun simctl get_app_container <udid> armincerf.score data` + `/tmp/reel-overlay`).
- Integration, the real reel (done, `scoreTests/ReelExportTests`): a fabricated two-game match, two clips cut from
  a 12 s mock video through `exportHighlightReel` with the timeline's cues; frames at 1.0, 2.5, 4.0 and 6.5 s of
  the reel are checked (gold boxes, chips, serve marker row, the lit row, the games digit and points cells
  changing, the cut matching the source's frame at 7.0 s) and written as `scoreboard-reel-*.png`. The same suite
  covers a source with sound (the reel keeps it), a source stored rotated (plain upright reel), the plain reel
  without cues, the board at 1080p and 4K (`board-1080p.png`, `board-2160p.png`) and portrait footage.
  `ReelManagerExportTests` runs `WatchConnectivityManager.exportMatchVideos()` on a mock recording and checks the
  board (and the lit point) in the reel it writes (`manager-reel-*.png`).
- Real app (done): `-seedSampleMatches -seedReel` writes a 20 s mock recording for the newest sample match and runs
  the real export (four 4.5 s clips scored from that match's highlights) so `MatchDetailView` plays a reel with the
  board; `-openLatestMatch` opens it once the export is done (see AGENTS.md, Screenshots). Real footage is checked
  on device through TestFlight (not done yet), with the detector's per-orientation scores in the logs.

## Non-goals (for now)

Overlay on the full match video; animated score transitions; slow motion; cloud models.
