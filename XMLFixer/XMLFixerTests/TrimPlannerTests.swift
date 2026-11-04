import XCTest
@testable import XML_Fixer

final class TrimPlannerTests: XCTestCase {

    // MARK: - Range mapping

    func testTimecodeBasisMapsThroughStartTimecodes() {
        // XML file starts at 01:00:00:00 @25, original starts at 00:59:50:00 @25 → shift +250 frames
        let probe = TrimSourceProbe(timebase: 25, ntsc: false, frameCount: 5000,
                                    startTimecode: Timecode.parse("00:59:50:00", timebase: 25))
        let mapped = TrimPlanner.mapRanges(
            mergedRanges: [SourceRange(inPoint: 100, outPoint: 200)],
            xmlTimebase: 25,
            xmlStartTimecode: Timecode.parse("01:00:00:00", timebase: 25),
            probe: probe
        )
        XCTAssertEqual(mapped.basis, .timecode)
        XCTAssertEqual(mapped.ranges, [TrimRange(originalIn: 350, originalOut: 450, xmlIn: 100, xmlOut: 200)])
        XCTAssertTrue(mapped.warnings.isEmpty)
    }

    func testTimecodeBasisConvertsFrameRates() {
        // Proxy at 25 fps, original at 50 fps, same start TC → frames double
        let probe = TrimSourceProbe(timebase: 50, ntsc: false, frameCount: 10_000,
                                    startTimecode: Timecode.parse("10:00:00:00", timebase: 50))
        let mapped = TrimPlanner.mapRanges(
            mergedRanges: [SourceRange(inPoint: 10, outPoint: 35)],
            xmlTimebase: 25,
            xmlStartTimecode: Timecode.parse("10:00:00:00", timebase: 25),
            probe: probe
        )
        XCTAssertEqual(mapped.ranges.first?.originalIn, 20)
        XCTAssertEqual(mapped.ranges.first?.originalOut, 70)
        XCTAssertTrue(mapped.warnings.contains { $0.contains("Rate differs") })
    }

    func testOffsetFallbackWhenOriginalHasNoTimecode() {
        let probe = TrimSourceProbe(timebase: 24, ntsc: false, frameCount: 1000, startTimecode: nil)
        let mapped = TrimPlanner.mapRanges(
            mergedRanges: [SourceRange(inPoint: 40, outPoint: 80)],
            xmlTimebase: 24,
            xmlStartTimecode: Timecode.parse("01:00:00:00", timebase: 24),
            probe: probe
        )
        XCTAssertEqual(mapped.basis, .offset)
        XCTAssertEqual(mapped.ranges, [TrimRange(originalIn: 40, originalOut: 80, xmlIn: 40, xmlOut: 80)])
        XCTAssertTrue(mapped.warnings.contains { $0.contains("no timecode") })
    }

    func testRangesOutsideOriginalAreDroppedAndClamped() {
        let probe = TrimSourceProbe(timebase: 25, ntsc: false, frameCount: 100,
                                    startTimecode: Timecode.parse("01:00:00:00", timebase: 25))
        let mapped = TrimPlanner.mapRanges(
            mergedRanges: [
                SourceRange(inPoint: 90, outPoint: 130),   // clipped to 90-100
                SourceRange(inPoint: 500, outPoint: 600),  // entirely outside → dropped
            ],
            xmlTimebase: 25,
            xmlStartTimecode: Timecode.parse("01:00:00:00", timebase: 25),
            probe: probe
        )
        XCTAssertEqual(mapped.ranges.count, 1)
        XCTAssertEqual(mapped.ranges[0].originalIn, 90)
        XCTAssertEqual(mapped.ranges[0].originalOut, 100)
        XCTAssertEqual(mapped.warnings.filter { $0.contains("outside") }.count, 1)
        XCTAssertEqual(mapped.warnings.filter { $0.contains("clipped") }.count, 1)
    }

    func testTimecodeWrapAcrossMidnight() {
        // Original starts 23:59:50:00, XML clip at 00:00:05:00 the next day
        let probe = TrimSourceProbe(timebase: 25, ntsc: false, frameCount: 1000,
                                    startTimecode: Timecode.parse("23:59:50:00", timebase: 25))
        let mapped = TrimPlanner.mapRanges(
            mergedRanges: [SourceRange(inPoint: 0, outPoint: 50)],
            xmlTimebase: 25,
            xmlStartTimecode: Timecode.parse("00:00:05:00", timebase: 25),
            probe: probe
        )
        XCTAssertEqual(mapped.ranges.first?.originalIn, 375)
        XCTAssertEqual(mapped.ranges.first?.originalOut, 425)
    }

    // MARK: - Naming & destination

    func testOutputNamingSingleAndMultiRange() {
        let dir = URL(fileURLWithPath: "/out")
        let original = URL(fileURLWithPath: "/src/A001C002.mov")
        XCTAssertEqual(TrimNaming.outputURL(for: original, in: dir, rangeIndex: 0, rangeCount: 1).lastPathComponent, "A001C002.mov")
        XCTAssertEqual(TrimNaming.outputURL(for: original, in: dir, rangeIndex: 1, rangeCount: 3).lastPathComponent, "A001C002_trim02.mov")
    }

    func testMirroredDestinationDirectory() {
        var options = TrimOptions()
        options.sourceRoot = URL(fileURLWithPath: "/Volumes/Raw/Day01")
        options.destinationRoot = URL(fileURLWithPath: "/Volumes/Trimmed")
        let original = URL(fileURLWithPath: "/Volumes/Raw/Day01/A001/A001C002.mov")
        XCTAssertEqual(TrimNaming.destinationDirectory(for: original, options: options)?.path, "/Volumes/Trimmed/A001")

        options.mirrorFolders = false
        XCTAssertEqual(TrimNaming.destinationDirectory(for: original, options: options)?.path, "/Volumes/Trimmed")

        options.mirrorFolders = true
        let outside = URL(fileURLWithPath: "/Volumes/Other/B001.mov")
        XCTAssertEqual(TrimNaming.destinationDirectory(for: outside, options: options)?.path, "/Volumes/Trimmed")
    }

    // MARK: - Image sequence parsing

    func testSequenceFilenameParsing() {
        let parsed = ImageSequenceInfo.parse(filename: "A001C003_240101.0001001.exr")
        XCTAssertEqual(parsed?.prefix, "A001C003_240101.")
        XCTAssertEqual(parsed?.number, 1001)
        XCTAssertEqual(parsed?.padding, 7)
        XCTAssertEqual(parsed?.suffix, ".exr")
        XCTAssertNil(ImageSequenceInfo.parse(filename: "clip.mov"))
        XCTAssertNil(ImageSequenceInfo.parse(filename: "clip_v2.exr"))
    }

    func testSequenceKeyFromXMLNotations() {
        XCTAssertEqual(ImageSequenceInfo.sequenceKey(fromXMLFilename: "shot.[1001-1100].exr")?.prefix, "shot.")
        XCTAssertEqual(ImageSequenceInfo.sequenceKey(fromXMLFilename: "shot.%04d.dpx")?.suffix, ".dpx")
        XCTAssertEqual(ImageSequenceInfo.sequenceKey(fromXMLFilename: "shot.####.exr")?.prefix, "shot.")
        XCTAssertEqual(ImageSequenceInfo.sequenceKey(fromXMLFilename: "shot.1001.exr")?.prefix, "shot.")
        XCTAssertNil(ImageSequenceInfo.sequenceKey(fromXMLFilename: "shot.mov"))
    }

    // MARK: - Matching

    func testMatcherPrefersCameraFormatsAndFindsSequences() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trim-match-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let raw = tmp.appendingPathComponent("RAW")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)

        func touch(_ name: String, bytes: Int = 10) throws {
            try Data(repeating: 0, count: bytes).write(to: raw.appendingPathComponent(name))
        }
        try touch("A001C001.mov", bytes: 100)
        try touch("A001C001.R3D", bytes: 50)
        for i in 1001...1010 { try touch("B001C002.\(i).exr", bytes: 5) }
        try touch("C001C003_001.R3D", bytes: 20)
        try touch("C001C003_002.R3D", bytes: 20)
        try touch("C001C003.rtn", bytes: 1)   // RED sidecar named after the clip must not hide the split clip
        try touch("C001C003.xml", bytes: 1)

        let scanned = runAsync { await FileScanner.scan(directory: raw, extensionFilter: nil) }

        func summary(_ name: String) -> MediaUsageSummary {
            var s = MediaUsageSummary(filename: name, pathURL: nil, sourceDuration: 100, timebase: 25, ntsc: false,
                                      hasVideo: true, hasAudio: false, audioChannelCount: 0,
                                      rawRanges: [SourceRange(inPoint: 0, outPoint: 10)])
            s.mergeRanges(handles: 0)
            return s
        }

        let items = OriginalMediaMatcher.match(
            summaries: [summary("A001C001.mov"), summary("B001C002.mov"), summary("B001C002.1003.exr"), summary("C001C003.mov"), summary("nope.mov")],
            scanned: scanned
        )

        XCTAssertEqual(items[0].candidates.count, 2)
        XCTAssertEqual(items[0].selectedCandidate?.kind, .r3d, "R3D should outrank the .mov proxy")

        XCTAssertEqual(items[1].selectedCandidate?.kind, .imageSequence)
        XCTAssertEqual(items[1].selectedCandidate?.sequence?.frameCount, 10)

        XCTAssertEqual(items[2].selectedCandidate?.kind, .imageSequence)
        XCTAssertEqual(items[2].candidates.count, 1, "single frame + sequence key must dedupe to one sequence candidate")

        XCTAssertEqual(items[3].selectedCandidate?.kind, .r3d)
        XCTAssertTrue(items[3].selectedCandidate?.isR3DSplit ?? false)
        XCTAssertEqual(items[3].selectedCandidate?.fileSize, 40, "split R3D size should cover every segment")

        XCTAssertEqual(items[4].status, .unmatched)
    }

    func testSequenceResolveUsesXMLFrameNumberAsOrigin() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trim-seq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for i in 995...1050 { try Data([0]).write(to: tmp.appendingPathComponent("shot.\(i).dpx")) }
        let scanned = runAsync { await FileScanner.scan(directory: tmp, extensionFilter: nil) }

        var s = MediaUsageSummary(filename: "shot.1001.dpx", pathURL: nil, sourceDuration: 50, timebase: 25, ntsc: false,
                                  hasVideo: true, hasAudio: false, audioChannelCount: 0,
                                  rawRanges: [SourceRange(inPoint: 10, outPoint: 20)])
        s.mergeRanges(handles: 0)
        var item = OriginalMediaMatcher.match(summaries: [s], scanned: scanned)[0]
        let registry = TrimEngineRegistry(options: TrimOptions(), sandboxed: true)
        runAsync { await TrimPlanner.resolve(item: &item, registry: registry) }

        XCTAssertEqual(item.status, .ready)
        // 1001 is index 6 in a sequence starting at 995 → XML 10-20 maps to indices 16-26
        XCTAssertEqual(item.trimRanges.first?.originalIn, 16)
        XCTAssertEqual(item.trimRanges.first?.originalOut, 26)
    }

    // MARK: - R3D helpers

    func testR3DSegmentDiscovery() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trim-r3d-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in ["A001_C001_001.R3D", "A001_C001_002.R3D", "A001_C001_003.R3D", "A001_C002_001.R3D", "A001_C001.rmd"] {
            try Data([0]).write(to: tmp.appendingPathComponent(name))
        }
        let segments = TrimRunner.r3dSegments(for: tmp.appendingPathComponent("A001_C001_001.R3D"))
        XCTAssertEqual(segments.map(\.lastPathComponent), ["A001_C001_001.R3D", "A001_C001_002.R3D", "A001_C001_003.R3D"])
    }

    func testREDlineArgumentsAndProbeParsing() {
        let args = REDlineTrimEngine.trimArguments(
            input: URL(fileURLWithPath: "/raw/A001_C001_001.R3D"),
            outputDirectory: URL(fileURLWithPath: "/out"),
            startFrame: 100, endFrameExclusive: 200
        )
        XCTAssertEqual(args, ["--i", "/raw/A001_C001_001.R3D", "--outDir", "/out", "--format", "102", "--start", "100", "--frameCount", "100", "--trimAudio"])

        // Real REDline 65.2.1 --printMeta 1 shape
        let fields = REDlineTrimEngine.parseProbeOutput("""
        [09-16-11-18-48-298824]<0x206134e40> REDline Build 65.2.1   64bit Public Release
        Clip Name:\tA001_A019_0630IJ_001.R3D
        Timestamp:\t120603
        FPS:\t23.976024627685547
        Record FPS:\t59.939998626708984
        Total Frames:\t1112
        Abs TC:\t12:05:19:21
        Edge TC:\t01:09:57:07
        End Abs TC:\t12:06:06:04
        End Edge TC:\t01:10:43:14
        """)
        XCTAssertEqual(fields.timecode, "12:05:19:21")
        XCTAssertEqual(fields.absTimecode, "12:05:19:21")
        XCTAssertEqual(fields.edgeTimecode, "01:09:57:07")
        XCTAssertEqual(fields.fps.map { ($0 * 1000).rounded() }, 23976)
        XCTAssertEqual(fields.frameCount, 1112)
    }

    func testREDlineOutputLayoutFollowsRDCConvention() {
        let clip = URL(fileURLWithPath: "/raw/A001_A019_0630IJ.RDC/A001_A019_0630IJ_001.R3D")
        XCTAssertEqual(REDlineTrimEngine.clipBaseName(for: clip), "A001_A019_0630IJ")

        // Mirrored: output dir is already the .RDC folder
        let mirrored = URL(fileURLWithPath: "/out/A001_A019_0630IJ.RDC")
        let single = REDlineTrimEngine.outputLayout(candidateURL: clip, outputDirectory: mirrored, rangeIndex: 0, rangeCount: 1)
        XCTAssertEqual(single.containerDirectory.path, "/out/A001_A019_0630IJ.RDC")
        XCTAssertEqual(REDlineTrimEngine.segmentFilename(clipName: single.clipName, segment: 1), "A001_A019_0630IJ_001.R3D")

        let multi = REDlineTrimEngine.outputLayout(candidateURL: clip, outputDirectory: mirrored, rangeIndex: 1, rangeCount: 2)
        XCTAssertEqual(multi.containerDirectory.path, "/out/A001_A019_0630IJ_trim02.RDC")
        XCTAssertEqual(REDlineTrimEngine.segmentFilename(clipName: multi.clipName, segment: 1), "A001_A019_0630IJ_trim02_001.R3D")

        // Flat: create the .RDC folder ourselves
        let flat = REDlineTrimEngine.outputLayout(candidateURL: clip, outputDirectory: URL(fileURLWithPath: "/out"), rangeIndex: 0, rangeCount: 1)
        XCTAssertEqual(flat.containerDirectory.path, "/out/A001_A019_0630IJ.RDC")
    }

    func testAlternateTimecodeFallback() async {
        // XML carries RED edge code; the probe's primary (absolute) TC is hours away.
        var item = TrimPlanItem(xmlFilename: "A001_A019_0630IJ.mov", xmlTimebase: 24, xmlNtsc: true,
                                xmlStartTimecode: "01:09:57:07", xmlSourceDuration: 1112,
                                mergedRanges: [SourceRange(inPoint: 100, outPoint: 148)])
        item.candidates = [TrimCandidate(url: URL(fileURLWithPath: "/raw/x.mov"), kind: .quickTime, fileSize: 1)]
        item.selectedCandidateIndex = 0
        var probe = TrimSourceProbe(timebase: 24, ntsc: true, frameCount: 1112, startTimecode: Timecode.parse("12:05:19:21", timebase: 24))
        probe.alternateStartTimecode = Timecode.parse("01:09:57:07", timebase: 24)
        probe.alternateTimecodeLabel = "Edge TC"

        let primary = TrimPlanner.mapRanges(mergedRanges: item.mergedRanges, xmlTimebase: 24, xmlStartTimecode: Timecode.parse("01:09:57:07", timebase: 24), probe: probe)
        XCTAssertTrue(primary.ranges.isEmpty)
        var alt = probe; alt.startTimecode = probe.alternateStartTimecode
        let secondary = TrimPlanner.mapRanges(mergedRanges: item.mergedRanges, xmlTimebase: 24, xmlStartTimecode: Timecode.parse("01:09:57:07", timebase: 24), probe: alt)
        XCTAssertEqual(secondary.ranges.first?.originalIn, 100)
        XCTAssertEqual(secondary.ranges.first?.originalOut, 148)
    }

    func testRegistryReportsWhyR3DIsCopiedWhole() {
        var options = TrimOptions()
        options.redlinePath = URL(fileURLWithPath: "/definitely/not/here/REDline")
        let registry = TrimEngineRegistry(options: options, sandboxed: false)
        let (engine, reason) = registry.engine(for: .r3d)
        if REDlineLocator.locate(userPath: nil) == nil {
            XCTAssertNil(engine)
            XCTAssertNotNil(reason)
        } else {
            XCTAssertNotNil(engine, "REDline is installed on this machine")
        }
        // MXF depends on ART CMD the same way R3D depends on REDline.
        let (mxfEngine, mxfReason) = registry.engine(for: .mxf)
        if ARTCMDLocator.locate(userPath: nil) == nil {
            XCTAssertNil(mxfEngine)
            XCTAssertNotNil(mxfReason)
        } else {
            XCTAssertNotNil(mxfEngine, "ART CMD is installed on this machine")
        }
        XCTAssertNotNil(registry.engine(for: .quickTime).engine)
    }

    // MARK: - Helpers

    private func runAsync<T>(_ work: @escaping () async -> T) -> T {
        let expectation = expectation(description: "async")
        var result: T?
        Task {
            result = await work()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30)
        return result!
    }
}
