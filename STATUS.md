# Status

_Last updated: 2026-09-16 — fork `BayleyBY/republic-wash-and-cut`, branch `master` (merge of `feature/trim-camera-originals`)._

## Current build

| Item | Value |
| --- | --- |
| Build label | `V013-sources` (`XMLFixerApp.buildVersion`) |
| Marketing / bundle version | 1.2.0 / 13 |
| Upstream base | `dr1pvfx/xml-fixer` @ `82a54c4` (V011, 1.0.0 alpha 1) |
| Toolchain verified | Xcode 26.6, macOS 26.5, XcodeGen 2.46 |
| Test suite | 58 XCTest cases passing (plus 2 opt-in manual tests) |

The product is now named **Republic Wash & Cut**; it was built on top of the ReplayBoys (RPB) XML Toolkit, which supplies the upstream base below.

## What this fork adds over upstream

### Trim camera originals (new)
A **Trim** toolbar action that matches every source used across the loaded XMLs to a camera original on disk and writes trimmed copies covering only the used ranges plus handles, without re-encoding. Modeled on DaVinci Resolve's Media Management trim mode.

| Format | Engine | State |
| --- | --- | --- |
| QuickTime ProRes / DNx / H.264 / HEVC (.mov, .mp4) | AVFoundation passthrough, keyframe snap-outward, new `tmcd` track | Verified on synthetic and ffmpeg-generated media with audio |
| Image sequences (.exr, .dpx, .dng, .ari, .tif, .png …) | Per-frame file copies | Verified on synthetic sequences |
| RED .R3D (single or split segments in `.RDC`) | REDline `--format 102` (R3D Trim) when installed | Verified on real V-RAPTOR 8K footage (build 65.2.1) |
| MXF (incl. ARRIRAW MXF), BRAW, stills, other | Copied whole and flagged | By design for now |

Key behaviours:
- Ranges are mapped through **source timecode** (XML file start TC + clip in/out → original's TC track), converting frame rates; falls back to frame offsets with a warning. RED clips retry with Edge TC when Absolute TC does not contain the ranges.
- Output keeps the original filename under a mirrored folder structure; several used ranges farther apart than the merge gap become `_trim01`, `_trim02`, … (R3D: `<clip>_trimNN.RDC/`).
- Nothing is written next to the originals; existing outputs are skipped unless *Overwrite* is on.

### Fixes to existing code
- `AVAssetTimecodeReader` returned nil on many files because AVAssetReader emits an empty edit-boundary buffer first. This also affected the reference player.
- `FileScanner` hid split R3D clips whenever a same-stem sidecar (`.xml`, `.rtn`, `.rmd`) existed, which broke Relink on real RED folders.

### Build configuration
- Developer ID (`Release`) builds run **unsandboxed** so REDline can be launched. A new `AppStore` configuration keeps the App Sandbox with `XMLFixer.AppStore.entitlements`; `scripts/release_app_store.sh` uses it by default. `AppSandbox.isSandboxed` hides the REDline path at runtime.

## Known limitations / open items
- **MP4 outputs carry no timecode track** (the container cannot hold `tmcd`); reported per file. MOV outputs are fine.
- **ARRIRAW MXF is copied whole.** Trimming it needs an MXF writer or an ARRI CLI. `.ari` sequences trim fine.
- **REDline is the Intel build** (runs under Rosetta). Irrelevant for trimming, which is a frame-range copy; an Apple Silicon build would only matter for transcodes.
- `--trimAudio` is passed to REDline but the test footage had no camera audio, so audio-in-R3D is unexercised.
- R3D copy-whole fallback copies every segment but not `.rtn` / `ascmhl` sidecars.
- Drop-frame timecode arithmetic still uses the non-drop math in `Timecode`.
- Open-GOP HEVC: the exclusive out point is the next IDR's PTS, so a couple of trailing leading-pictures may be included but hidden by the edit list. Harmless, not exact.
- No updated XML/manifest is written after trimming (by decision). A "relink loaded XMLs to trimmed files" step is the obvious next feature.

## Verification log (2026-09-16)
- 58 unit/workflow tests pass; full pipeline test on the bundled fixture produces two split ProRes files with correct start TCs (01:00:01:16, 01:00:07:22).
- ffmpeg-generated ProRes+PCM, H.264+AAC (B-frames), HEVC+AAC: outputs start on keyframes, keep codec and audio, decode cleanly in ffmpeg.
- Real RED folder (23 V-RAPTOR clips): two-range trim produced `<clip>_trim01.RDC/…_001.R3D` and `_trim02`, each verified by REDline for frame count, Abs/Edge TC, and ReelID. A 48-frame 8K trim took ~1 s.
- UI driven end to end on the fixture: plan view, run, results view.

## Next steps (suggested)
1. Optional: rewrite loaded XMLs / Sources XML to point at trimmed files with recomputed in/out and start TC.
2. Copy RED sidecars alongside copy-whole and trimmed clips.
3. ARRIRAW MXF trimming once a suitable tool is chosen.
4. Upstream pull request from `feature/trim-camera-originals` (drop the `chore: bump build` commit first).
