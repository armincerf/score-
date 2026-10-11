# Smarter highlight reel: orientation correction and a burned-in scoreboard

Status: in progress (October 2026). Owner: the export pipeline (`MediaExportService`,
`WatchConnectivityManager.exportMatchVideos`).

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
| `score/ReelScoreboardTimeline.swift` (to do) | Pure: clips + match data -> the board state(s) for each clip, with reel-time ranges |
| `score/VideoOrientationDetector.swift` (to do) | Samples frames, runs `DetectHumanBodyPoseRequest` at four orientations, scores them |
| `score/VideoRotationCorrection.swift` (to do) | The decision (`OrientationDecision.decide`), the correction enum and its transform |
| `MediaExportService` | `uprightGeometry` gains a correction; `exportHighlightReel` gains scoreboard cues |
| `WatchConnectivityManager.exportMatchVideos` | Detects per segment before the full export; builds the scoreboard plan for the reel |

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
- Real app: `-seedSampleMatches -seedReel` (to do) generates a mock recording for the newest sample
  match and runs the real export so `MatchDetailView` plays a reel with the board; `make screenshot`
  with `-openLatestMatch` (to do) captures it. Real footage is checked on device through TestFlight,
  with the detector's per-orientation scores in the logs.

## Non-goals (for now)

Overlay on the full match video; animated score transitions; slow motion; cloud models.
