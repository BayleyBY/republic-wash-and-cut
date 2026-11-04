import XCTest
@testable import XML_Fixer

/// Runs the whole trim pipeline against a real folder of ARRI MXF clips when `XMLFIXER_MXF_DIR` is set
/// (pass `TEST_RUNNER_XMLFIXER_MXF_DIR=/path` to xcodebuild). Requires ARRI ART CMD. Reads the originals
/// only; writes to `$TMPDIR/mxf-trim-manual-out`.
///
/// This is the verification step for the art-cmd engine: it checks that the trimmed clip holds the
/// requested frame count and that its start timecode reflects the new in-point, which is what decides
/// whether the loaded XMLs still conform against the trimmed media.
final class MXFTrimManualTests: XCTestCase {

    func testTrimsFirstARRIClipThroughThePipeline() async throws {
        guard let dirPath = ProcessInfo.processInfo.environment["XMLFIXER_MXF_DIR"], !dirPath.isEmpty else {
            throw XCTSkip("XMLFIXER_MXF_DIR not set")
        }
        var options = TrimOptions()
        options.sourceRoot = URL(fileURLWithPath: dirPath, isDirectory: true)
        options.destinationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mxf-trim-manual-out", isDirectory: true)
        options.overwriteExisting = true
        try? FileManager.default.removeItem(at: options.destinationRoot!)
        let registry = TrimEngineRegistry(options: options, sandboxed: false)
        guard let artcmd = registry.artcmd else { throw XCTSkip("ART CMD not found") }

        let scanned = await FileScanner.scan(directory: options.sourceRoot!, extensionFilter: "mxf")
        let stems = scanned.filter { $0.value.contains { $0.fileExtension == "mxf" } }.keys.sorted()
        let stem = try XCTUnwrap(stems.first, "no MXF clips found")
        let clip = try XCTUnwrap(scanned[stem]?.first { $0.fileExtension == "mxf" }?.url)

        // Probe the real clip so the synthetic "edit" references its own timecode.
        let probe = await artcmd.probe(url: clip, fallbackTimebase: 24)
        print("MANUAL MXF probe:", clip.lastPathComponent,
              "tb=\(probe.timebase) ntsc=\(probe.ntsc) frames=\(probe.frameCount)",
              "tc=\(probe.startTimecode?.description ?? "-")", probe.notes)
        let startTC = try XCTUnwrap(probe.startTimecode, "art-cmd reported no start timecode: \(probe.notes)")
        try XCTSkipUnless(probe.frameCount > 120, "clip too short for a meaningful trim (\(probe.frameCount) frames)")

        // One used range, 48 frames in from the head, so in and out both differ from the original.
        var summary = MediaUsageSummary(
            filename: clip.lastPathComponent, pathURL: nil, sourceDuration: probe.frameCount,
            timebase: probe.timebase, ntsc: probe.ntsc, hasVideo: true, hasAudio: false, audioChannelCount: 0,
            timecodeString: startTC.description,
            rawRanges: [SourceRange(inPoint: 48, outPoint: 96)]
        )
        summary.mergeRanges(handles: 0)

        var items = OriginalMediaMatcher.match(summaries: [summary], scanned: scanned)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].selectedCandidate?.kind, .mxf)
        await TrimPlanner.resolve(item: &items[0], registry: registry)
        XCTAssertEqual(items[0].status, .ready, items[0].warnings.joined(separator: "; "))
        XCTAssertEqual(items[0].trimRanges.map { [$0.originalIn, $0.originalOut] }, [[48, 96]])

        let results = await TrimRunner.run(items: items, options: options, registry: registry, progress: { _ in })
        let result = try XCTUnwrap(results.first)
        print("MANUAL MXF cmd:", result.commandLine ?? "-")
        XCTAssertEqual(result.status, .trimmed, result.messages.joined(separator: "; "))

        let output = try XCTUnwrap(result.outputs.first { $0.pathExtension.lowercased() == "mxf" })
        print("MANUAL MXF output:", output.path)
        let outProbe = await artcmd.probe(url: output, fallbackTimebase: probe.timebase)
        XCTAssertEqual(outProbe.frameCount, 48, "trimmed clip frame count")
        XCTAssertEqual(
            outProbe.startTimecode?.totalFrames,
            startTC.totalFrames + 48,
            "trimmed clip should start 48 frames into the original"
        )

        // The trim must not re-encode: a 48-frame copy is far smaller than the original.
        let originalSize = (try? FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(result.bytesWritten, 0)
        if probe.frameCount > 480 {
            XCTAssertLessThan(result.bytesWritten, originalSize / 2, "output is suspiciously large for 48 frames")
        }
    }
}
