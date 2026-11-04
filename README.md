# Republic Wash & Cut

**A fast, native macOS workspace for repairing and preparing Final Cut Pro XML.**

Republic Wash & Cut helps post-production teams inspect, clean up, relink, and export
large batches of Final Cut Pro `xmeml` v4/v5 XML files. It keeps the original XML
structure in memory while giving you a practical visual workspace for media,
timelines, source timecode, and reference video.

Republic Wash & Cut is built on top of the ReplayBoys (RPB) XML Toolkit by
[dr1pvfx](https://github.com/dr1pvfx/xml-fixer), which it renames and extends.

> **Alpha software:** The current public build is intended for evaluation on
> copies of your project XML. Keep backups of original media and timelines.

## Download

Get the latest **Developer ID–signed and Apple-notarized** alpha build from the
[v1.0.0 Alpha 1 release](https://github.com/dr1pvfx/xml-fixer/releases/tag/v1.0.0-alpha.1).

**Requirements:** macOS 14 Sonoma or later.

## What it does

- Import individual XML files, folders, or drop files directly onto the app.
- Inspect media across all loaded XMLs in one deduplicated list.
- Browse timelines visually, scrub a frame-accurate playhead, and inspect clips
  and effects.
- Link reference videos and synchronize them with the active timeline using
  source timecode.
- Relink media paths to a new conform location and copy linked media into a
  collected delivery folder.
- Match reference videos to timelines, including review and manual overrides
  before applying matches.
- Edit filenames, paths, reel metadata, and timeline start timecode.
- Remove selected media, strip audio tracks, flatten nested sequences, and
  batch-rename timelines.
- Export updated XMLs, a concise media CSV, or a Sources Sequence XML containing
  the best-length source ranges for a conform workflow.
- Trim camera originals down to the used ranges (plus handles) without
  re-encoding, similar to DaVinci Resolve's Media Management trim mode.
- Calculate common scale and resize values without leaving the app.

## Typical workflow

1. **Import** the XML files or the containing folder.
2. **Review** the consolidated media list and timeline view.
3. **Repair** paths, names, timecode, reel metadata, or sequence structure.
4. **Relink or collect** media when preparing a handoff.
5. **Trim** camera originals to only the frames the edit uses.
6. **Export** revised XMLs, a Sources Sequence XML, and/or a CSV report.

All XML mutations are applied to an in-memory document and can be undone during
the session. The original files are not overwritten unless you explicitly choose
their location as the export destination.

## Built for post workflows

| Area | Capabilities |
| --- | --- |
| Media management | Consolidated media inspection, bulk edits, filename changes, relinking, and collection |
| Timeline cleanup | Batch timeline renaming, nested-sequence flattening, audio stripping, and clip removal |
| Timecode & review | Source-timecode display, timeline start-timecode editing, and synchronized reference playback |
| Delivery | Updated XML batch export, CSV media report, and Sources Sequence XML export |
| Camera originals | Lossless trimming of QuickTime (ProRes, DNx, H.264, HEVC) and image sequences (EXR, DPX, DNG, ARRIRAW .ari); R3D via REDline when installed; everything else copied whole |

## Trimming camera originals

The **Trim** toolbar action scans a folder of camera-original media, matches each
source used in the loaded XMLs by filename stem (proxies such as `A001C002.mov`
match `A001C002.R3D`, `A001C002.mxf`, or `A001C002.0001001.exr`), and writes
trimmed copies containing only the used ranges plus handles.

- Ranges are mapped through **source timecode**: the XML file's start timecode
  plus the clip in/out points is located in the original's embedded timecode
  track, so proxies that start at a different point or run at a different frame
  rate still map correctly. Files without timecode fall back to frame offsets
  and are flagged.
- Nothing is re-encoded. QuickTime files are rewritten with AVFoundation
  passthrough, so codec, bit depth, and metadata stay untouched. Cuts on
  long-GOP codecs (H.264, HEVC) snap outward to the nearest keyframes and the
  extra frames are reported.
- A new timecode track is written so the trimmed file starts at the correct
  source timecode. MP4 containers cannot carry one, which is reported.
- Image sequences are trimmed by copying only the frames in range.
- RED `.R3D` clips (including multi-segment `_001`, `_002` clips inside `.RDC`
  folders) are trimmed with REDline when REDCINE-X Pro is installed (a
  **Locate...** button lets you point at the executable). Output follows RED's
  `<clip>.RDC/<clip>_001.R3D` layout with audio, absolute and edge timecode, and
  reel ID preserved.
- ARRI `.mxf` clips (ARRIRAW, HDE, ARRICORE, MXF/ProRes) are trimmed with ARRI's
  ART CMD command-line tool when it is installed, which also has a **Locate...**
  button. Without either tool, and for BRAW, non-ARRI MXF, and other formats with
  no lossless trimmer, the whole clip is copied and flagged.
- Output keeps the original filename and mirrors the folder structure under the
  destination. When a source has several used ranges farther apart than the
  merge gap, they become `name_trim01.ext`, `name_trim02.ext`, and so on.

R3D trimming shells out to an external tool, so the direct-download build runs
without the macOS App Sandbox. The App Store build keeps the sandbox and copies
R3D clips whole.

## Build from source

The app has no external runtime dependencies. Open
`XMLFixer/XMLFixer.xcodeproj` in Xcode, select the `XMLFixer` scheme, and run it.

Or build and test from Terminal:

```bash
# Clone the project
git clone https://github.com/dr1pvfx/xml-fixer.git
cd xml-fixer

# Run the test suite without requiring local signing credentials
xcodebuild -project XMLFixer/XMLFixer.xcodeproj -scheme XMLFixer \
  -configuration Debug -derivedDataPath /tmp/xml-fixer-derived test \
  CODE_SIGNING_ALLOWED=NO

# Create a local release build
xcodebuild -project XMLFixer/XMLFixer.xcodeproj -scheme XMLFixer \
  -configuration Release -derivedDataPath /tmp/xml-fixer-derived build \
  CODE_SIGNING_ALLOWED=NO
```

To exercise the trimmer on your own media, drop QuickTime files into
`$TMPDIR/qt-trim-manual/` and run the `QuickTimeTrimManualMediaTests` test; it
trims each file and verifies codec, audio tracks, keyframe alignment, and timecode.

The local release app is written to:

```text
/tmp/xml-fixer-derived/Build/Products/Release/Republic Wash & Cut.app
```

## Project structure

```text
XMLFixer/
├── XMLFixer/          # SwiftUI app source
│   ├── Models/         # XML, timeline, media, and export types
│   ├── Services/       # Parsing, mutation, matching, relinking, and export
│   ├── ViewModels/     # Central AppState and application workflows
│   └── Views/          # Sidebar, media, timeline, player, and action sheets
├── XMLFixerTests/      # XCTest coverage and XML fixtures
└── project.yml         # XcodeGen project definition
```

## Development notes

`FCPXMLDocument.xmlDocument` is the source of truth for an imported document.
Changes operate directly on that XML document and are serialized only at export.
The detailed architecture and project conventions live in
[CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md).

## Feedback

This is an alpha release. If you encounter an XML structure, media format, or
workflow that needs better support, please [open an issue](https://github.com/dr1pvfx/xml-fixer/issues) with a reproducible description. Do not attach sensitive production media or client XML unless you are authorized to share it.
