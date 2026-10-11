# Smarter highlight reel: orientation correction and a burned-in scoreboard

Status: built and proven on the simulator (October 2026); **not yet verified on a phone or on real match
footage**. Owner: the export pipeline (`MediaExportService`, `WatchConnectivityManager.exportMatchVideos`).

- Goal 1 (orientation): done. `exportMatchVideos` runs `VideoOrientationDetector` on every segment and
  `exportFullVideo(segments:corrections:)` folds the correction into each segment's transform. Vision's body
  pose request has no compute device on the simulator, so the Vision path was exercised on the Mac
  (`scripts/detect-orientation.sh`); the export geometry is proven by simulator tests on exported frames.
- Goal 2 (scoreboard): done. The real reel export burns the board in (`ReelScoreboardTimeline` ->
  `MediaExportService.scoreboardOverlays` -> `exportHighlightReel(scoreboard:)`, wired in
  `WatchConnectivityManager.exportHighlightReel`), proven by `ReelExportTests` on exported frames and visible
  in the app via `-seedSampleMatches -seedReel -openLatestMatch`.

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
at the exact pixel size `ReelScoreboardLayout` derives from the video's short side, so the design is
previewable and the export only deals in images. Rendering happens on the main actor before the
export starts (a few images per reel).

## Components

| File | Role |
|---|---|
| `score/ReelScoreboard.swift` | `ReelScoreboardState`, `ReelScoreboardLayout` (pixel geometry per video size), `ReelScoreboardView`, `ReelScoreboardRenderer` |
| `score/ReelOverlayComposer.swift` | `OverlayCue` (time range + bitmap + origin) and the Core Image video composition |
| `score/ReelScoreboardTimeline.swift` | Pure: clips + match data -> the board state(s) for each clip, with reel-time ranges (`ReelScoreboardCue`) |
| `score/VideoOrientationDetector.swift` | Samples frames, runs `DetectHumanBodyPoseRequest` at four orientations, scores them (`BodyPoseEvidence`) |
| `score/VideoRotationCorrection.swift` | The decision (`OrientationDecision.decide`), the correction enum and its transform |
| `MediaExportService` | `uprightGeometry` takes a correction; `exportHighlightReel` takes scoreboard cues; `scoreboardOverlays` renders them |
| `WatchConnectivityManager` | `exportMatchVideos` detects per segment before the full export; `exportHighlightReel` builds the scoreboard cues for the reel |

### Scoreboard timeline (pure)

Inputs: player names, finished games (`GameResult`: points with wall-clock `videoTimestamp`, `firstServer`),
the current game's points and first server, and the reel's clips in reel order (`HighlightClipInfo`
plus each clip's wall-clock start/end and `gameNumber`, `player`).

For each clip:
- Games: wins per player among games before `gameNumber`.
- Points at clip start: points of that game with `videoTimestamp <= clip wall start` (the clip starts
  at the last scored point, so that point counts).
- Server: `ServingLogic.serverForPoint(index: pointsPlayed, firstServer:)`.
- Celebration, from the game's own points: the rally's point is the game's first point with a `videoTimestamp`
  after the clip's start. If that point exists, was won by the clip's `player` and the clip is at least 3 s long,
  a second state for the last 1.2 s: the score after that point, `pointWonBy` set, server recomputed. Otherwise
  (no later point in that game, as when a forced End Game credits a still-pending highlight to the game winner;
  or the point went to the other player) the clip keeps its one state.
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
  microphone access) left `makeComposition`'s audio track empty, so every full-video and reel export of silent
  footage failed and the app fell back to the raw segment with no reel. Both agents hit it; `makeComposition` now
  drops the empty audio track, which covers the full video and the reel (`ReelManagerExportTests` and
  `VideoOrientationIntegrationTests` cover both paths).
- The Core Image composition shows frames as stored, so the board is only drawn over a source stored upright
  (identity preferredTransform). The exported full video always is; a raw camera file kept as the full video after
  a failed full export may not be, and then the reel is exported plain (upright, no board) and a warning is logged.
- Review fix: the celebration used to be `player`'s points + 1 whenever `player` was set. `finalizeGame` credits a
  still-pending highlight to the game winner when the user forces End Game, so the board celebrated a point nobody
  scored. It now follows the game's next recorded point (rule above); `ReelScoreboardTimelineTests` covers the
  forced End Game and the point won by the other player.
- Layout scales with the frame's short side, not its height, so the board also fits across portrait footage
  (unchanged for landscape).
- Design pass at 720p/1080p: the celebration is now the winner's points cell turned white (black digits) plus a
  brighter row (white 22 %), and the serve marker is 14 px at 720p (was 12).

### Orientation decision (pure core, Vision around it)

- Candidate orientations: `.up`, `.right` (needs 90° clockwise), `.down` (180°), `.left` (270°).
- Evidence per orientation: for each sampled frame (30 %, 40 %, 50 %, 60 %, 70 % of the segment; three
  frames under 5 s, the middle one under 2 s), scaled to fit 640x640,
  `DetectHumanBodyPoseRequest.perform(on:orientation:)`; per person, upper joint = neck (else nose), lower
  joint = root (else the surer hip), each with confidence >= 0.3; score = mean of the two confidences x
  the cosine of the torso's tilt from vertical (measured in pixels of the oriented picture), 0 unless the
  upper joint is above the lower one (Vision coordinates, origin bottom-left).
- `OrientationDecision.decide(scores:)` returns a correction only when the best score is at least
  `minimumScore` (1.0) and at least `margin` (1.5x) times the runner-up; ties and weak evidence keep the
  metadata orientation. The scores are logged (`Log.video`, public) so real-footage problems can be diagnosed.
- The correction folds into the composition's layer transform (`uprightGeometry(naturalSize:
  preferredTransform:correction:)`), so no second export pass is needed.
- Simulator footage (`MockVideoGenerator`) has no people and must decide `.none`.

**Changed from the plan, and why**

- *Tilt weighting.* The plan counted a person in full whenever the neck was above the root. On a
  public-domain photo of a player reaching for the ball, run through the real detector on the Mac,
  Vision also found him in the picture turned a quarter clockwise with the neck slightly "above" the
  root: scores `none=2.14 clockwise90=1.66`, a 1.29x margin, and the same for each turn, so all three
  turned versions came out `.none` (1 of 4 right, and that one only by default). Weighting by the cosine
  of the torso's tilt gives `none=2.08 clockwise90=0.51` and 12 of 12 right over three photos (below).
- *Vision is not available on the simulator.* `DetectHumanBodyPoseRequest` throws "No available compute
  device for VNComputeStageMain" on the iOS 27 simulator, with the default device and with the CPU or the
  simulator GPU set explicitly (the legacy `VNDetectHumanBodyPoseRequest` fails too). On the simulator the
  detector therefore always takes its error path (`.none`, a logged warning). The detector's Vision code
  was exercised on the Mac instead: `scripts/detect-orientation.sh` compiles the app's own
  `VideoOrientationDetector.swift`, `VideoRotationCorrection.swift` and `Log.swift` unchanged into a CLI.
- *The text-recognition oracle.* The plan's convention test assumed Vision cannot read rotated text; on
  iOS 27 it reads it at every rotation. The test uses where Vision puts the text box instead (a wide box
  in the top-left of its normalized, bottom-left-origin coordinates only with the right orientation).
- *Silent footage did not export at all.* See the empty-track bullet under "Scoreboard: as built".

**Evidence (October 2026)**

| Check | Where | Result |
|---|---|---|
| EXIF convention: a picture needing C is upright to Vision only with `C.imageOrientation`, and `C.transform` turns it upright | `OrientationConventionTests` (simulator, text recognition) | 4 x 4 orientations + 4 transforms pass |
| Correction enum, transform corners, inverse, decision rule, tilt weighting, sampling, `uprightGeometry` (landscape and portrait input, all four corrections) | `VideoOrientationTests` | pass |
| Export with `.upsideDown180` / `.clockwise90`: frames read back from the file are the source turned (bright-pixel recall > 0.85 for the right mapping, < 0.5 for the opposite one), 1280x720 / 720x1280 | `VideoOrientationIntegrationTests`, PNGs in `.build/shots/reel/orientation/` | pass |
| `exportMatchVideos` on a 3 s mock segment: detects, exports `_full.mov` at 1280x720, removes the segment | `VideoOrientationIntegrationTests` | pass (about 1 s) |
| Detector on mock footage decides `.none` | simulator: error path in 5-105 ms; Mac: real detection, all scores 0 | `.none` |
| Detector on people, each of the four turns | Mac, `--selftest` on three public-domain US Navy table-tennis photos (Wikimedia Commons) | 12 / 12 correct, winner 3.7-34x the runner-up |
| Detection time, 60 s 720p mock (5 frames x 4 orientations) | Mac (M4 Max) | 332 ms cold, 113 ms warm |
| Detection on a real phone and on real match footage | device | **not verified** (TestFlight; read the `Orientation ...` lines in the logs) |

## Verification

- Unit: `OrientationDecision`, `uprightGeometry` with each correction (see "Evidence" above),
  `ReelScoreboardTimeline` (score at clip start across games, deuce serving, pending highlight, short
  clips without a celebration window, no celebration without the rally's point, reel-time ranges), layout maths.
- Integration, the composer (`scoreTests/ReelOverlayTests`): export a 4 s mock video with two cues, read
  frames at 1 s, 3 s and 3.9 s, check the gold games box, the player chips, an untouched region, the won point's
  cell turning white with its digit changing, and that the panel is gone after the last cue. Digit changes on
  the translucent panel are counted as changed ink pixels (`ReelPixels.inkChanges`: ink is the cell's minority
  colour against its own median), because a mean difference there also moves with the video behind the panel
  (an unchanged cell measured 4.4 and 3.9, over or near the old "> 4 means changed" threshold; ink changes: 0).
  `make test` sets `REEL_FRAMES_DIR` so every PNG lands in `.build/shots/reel/`.
- Integration, the real reel (`scoreTests/ReelExportTests`): a fabricated two-game match, two clips cut from
  a 12 s mock video through `exportHighlightReel` with the timeline's cues; frames at 1.0, 2.5, 4.0 and 6.5 s of
  the reel are checked (gold boxes, chips, serve marker row, the lit row, the games digit and the points digits
  changing, the cut matching the source's frame at 7.0 s) and written as `scoreboard-reel-*.png`. The same suite
  covers a source with sound (the reel keeps it), a source stored rotated (plain upright reel), the plain reel
  without cues, the board at 1080p and 4K (`board-1080p.png`, `board-2160p.png`) and portrait footage.
  `ReelManagerExportTests` runs `WatchConnectivityManager.exportMatchVideos()` on a mock recording and checks the
  board (and the lit point) in the reel it writes (`manager-reel-*.png`).
- Real app: `-seedSampleMatches -seedReel` writes a 20 s mock recording for the newest sample match and runs
  the real export (four 4.5 s clips scored from that match's highlights) so `MatchDetailView` plays a reel with the
  board; `-openLatestMatch` opens it once the export is done (see AGENTS.md, Screenshots).
- Real footage: checked on device through TestFlight (**not done yet**), with the detector's per-orientation
  scores in the logs (`Orientation <file>: none=... -> ...`).

## Non-goals (for now)

Overlay on the full match video; animated score transitions; slow motion; cloud models.
