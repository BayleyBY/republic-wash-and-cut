import XCTest
@testable import XML_Fixer

/// Unit tests for the pure parts of the ARRI `art-cmd` engine: argument building, metadata parsing
/// and the copy-whole fallbacks. The trim itself needs the real tool (see `MXFTrimManualTests`).
final class ARTCMDTrimEngineTests: XCTestCase {

    private let tool = URL(fileURLWithPath: "/usr/local/bin/art-cmd")

    // MARK: - Arguments

    func testTrimArgumentsUseZeroBasedStartAndDuration() {
        let args = ARTCMDTrimEngine.trimArguments(
            input: URL(fileURLWithPath: "/media/A_0001C001_261013_084123_a1CUY.mxf"),
            output: URL(fileURLWithPath: "/out/A_0001C001_261013_084123_a1CUY.mxf"),
            startFrame: 1800,
            endFrameExclusive: 10_800
        )
        XCTAssertEqual(args, [
            "copy",
            "--input", "/media/A_0001C001_261013_084123_a1CUY.mxf",
            "--start", "1800",
            "--duration", "9000",
            "--output", "/out/A_0001C001_261013_084123_a1CUY.mxf",
            "--logpath", "",
        ])
    }

    func testTrimArgumentsClampDegenerateRanges() {
        let args = ARTCMDTrimEngine.trimArguments(
            input: URL(fileURLWithPath: "/media/clip.mxf"),
            output: URL(fileURLWithPath: "/out/clip.mxf"),
            startFrame: -5,
            endFrameExclusive: -1
        )
        XCTAssertEqual(args[args.firstIndex(of: "--start")! + 1], "0")
        XCTAssertEqual(args[args.firstIndex(of: "--duration")! + 1], "1")
    }

    func testProbeArgumentsExportMetadataOnly() {
        let args = ARTCMDTrimEngine.probeArguments(
            input: URL(fileURLWithPath: "/media/clip.mxf"),
            outputJSON: URL(fileURLWithPath: "/tmp/probe/metadata.json")
        )
        XCTAssertEqual(args.first, "export")
        XCTAssertTrue(args.contains("--skip-audio"))
        XCTAssertTrue(args.contains("--skip-look"))
        XCTAssertEqual(args[args.firstIndex(of: "--output")! + 1], "/tmp/probe/metadata.json")
        // No art.log in whatever directory the app happens to be running from.
        XCTAssertEqual(args[args.firstIndex(of: "--logpath")! + 1], "")
    }

    func testCommandLineQuotesPathsWithSpaces() {
        let line = ARTCMDTrimEngine.commandLine(
            executable: tool,
            arguments: ["copy", "--input", "/Volumes/Footage Backup/clip.mxf"]
        )
        XCTAssertEqual(line, "/usr/local/bin/art-cmd copy --input \"/Volumes/Footage Backup/clip.mxf\"")
    }

    // MARK: - Metadata parsing

    /// Trimmed from a real ALEXA 35 ARRIRAW export (schema metadata_output/v2-2-0).
    private let realExport = """
    {
      "arriJsonHeader": { "softwareVersion": "1.1.0" },
      "clipBasedMetadataSets": [
        { "metadataSetName": "Clip Info",
          "metadataSetPayload": {
            "clipDuration": 1,
            "clipStartFrameNumber": 750729,
            "videoCodec": "ARRIRAW uncompressed" } },
        { "metadataSetName": "Project Rate",
          "metadataSetPayload": { "dropframe": false, "timebase": "24000/1001" } }
      ],
      "frameBasedMetadata": {
        "frames": [ { "frameBasedMetadataSets": {}, "frameNo": 0, "timecode": "08:41:59:11" } ]
      }
    }
    """

    func testParseProbeJSONReadsTheRealARRISchema() {
        let fields = ARTCMDTrimEngine.parseProbeJSON(Data(realExport.utf8))
        XCTAssertEqual(fields.timecode, "08:41:59:11")
        XCTAssertEqual(fields.fps ?? 0, 24000.0 / 1001.0, accuracy: 0.0001)
        XCTAssertFalse(fields.dropFrame)
        XCTAssertEqual(fields.videoCodec, "ARRIRAW uncompressed")
    }

    /// `--start N` exports one frame whose frameNo is 0 but whose timecode is that of frame N;
    /// several frames must still resolve to the lowest frameNo.
    func testParseProbeJSONTakesTheLowestFrameNumber() {
        let json = """
        { "frameBasedMetadata": { "frames": [
            { "frameNo": 7, "timecode": "10:00:00:07" },
            { "frameNo": 3, "timecode": "10:00:00:03" } ] } }
        """
        XCTAssertEqual(ARTCMDTrimEngine.parseProbeJSON(Data(json.utf8)).timecode, "10:00:00:03")
    }

    func testParseProbeJSONFallsBackToTheEssenceDescriptorRate() {
        let json = """
        { "clipBasedMetadataSets": [
            { "metadataSetName": "MXF Generic Data",
              "metadataSetPayload": { "nativePictureEssenceDescriptor": {
                  "file": { "sampleRate": "25/1" } } } } ] }
        """
        XCTAssertEqual(ARTCMDTrimEngine.parseProbeJSON(Data(json.utf8)).fps ?? 0, 25, accuracy: 0.0001)
    }

    func testRationalParsesRatesAndPlainNumbers() {
        XCTAssertEqual(ARTCMDTrimEngine.rational("30000/1001") ?? 0, 29.97, accuracy: 0.001)
        XCTAssertEqual(ARTCMDTrimEngine.rational("48") ?? 0, 48, accuracy: 0.0001)
        XCTAssertEqual(ARTCMDTrimEngine.rational(NSNumber(value: 23.976)) ?? 0, 23.976, accuracy: 0.0001)
        XCTAssertNil(ARTCMDTrimEngine.rational("24000/0"))
        XCTAssertNil(ARTCMDTrimEngine.rational(NSNumber(value: true)))
        XCTAssertNil(ARTCMDTrimEngine.rational(nil))
    }

    func testParseProbeJSONSurvivesGarbage() {
        XCTAssertEqual(ARTCMDTrimEngine.parseProbeJSON(Data("not json".utf8)), ARTCMDTrimEngine.ProbeFields())
    }

    /// The frame-count search depends on this exact refusal, so pin the message art-cmd 1.1.0 prints.
    func testBeyondEndIsRecognisedFromTheToolsRefusal() {
        let refusal = ExternalTool.Result(
            exitCode: 1,
            stdout: "No clip was processed: '--start 5702' lies beyond the end of every clip that could be set up",
            stderr: ""
        )
        XCTAssertTrue(ARTCMDTrimEngine.isBeyondEnd(refusal))
        XCTAssertFalse(ARTCMDTrimEngine.isBeyondEnd(ExternalTool.Result(exitCode: 0, stdout: "", stderr: "")))
        XCTAssertFalse(ARTCMDTrimEngine.isBeyondEnd(ExternalTool.Result(exitCode: 1, stdout: "disk full", stderr: "")))
    }

    func testProbeArgumentsSeekWithoutStartForFrameZero() {
        let first = ARTCMDTrimEngine.probeArguments(
            input: URL(fileURLWithPath: "/media/clip.mxf"),
            outputJSON: URL(fileURLWithPath: "/tmp/m.json")
        )
        XCTAssertFalse(first.contains("--start"))
        let seek = ARTCMDTrimEngine.probeArguments(
            input: URL(fileURLWithPath: "/media/clip.mxf"),
            outputJSON: URL(fileURLWithPath: "/tmp/m.json"),
            startFrame: 5701
        )
        XCTAssertEqual(seek[seek.firstIndex(of: "--start")! + 1], "5701")
        XCTAssertEqual(seek[seek.firstIndex(of: "--duration")! + 1], "1")
    }

    // MARK: - Registry wiring

    func testMXFCopiesWholeWithoutTheTool() {
        var options = TrimOptions()
        options.artcmdPath = URL(fileURLWithPath: "/nonexistent/art-cmd")
        let registry = TrimEngineRegistry(options: options, sandboxed: false)
        guard registry.artcmd == nil else {
            // A real art-cmd on PATH wins over the bogus override; nothing to assert then.
            return
        }
        let (engine, reason) = registry.engine(for: .mxf)
        XCTAssertNil(engine)
        XCTAssertEqual(reason, "ART CMD not found — install ARRI ART CMD or set its path (non-ARRI MXF is copied whole)")
    }

    func testSandboxedBuildNeverGetsTheTool() {
        let registry = TrimEngineRegistry(options: TrimOptions(), sandboxed: true)
        XCTAssertNil(registry.artcmd)
    }

    /// ART CMD ships as a folder, so pointing at the folder must resolve to <folder>/bin/art-cmd.
    func testLocatorResolvesAnInstallFolderToItsBinary() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("art-cmd-fake-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let binary = bin.appendingPathComponent("art-cmd")
        fm.createFile(atPath: binary.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        XCTAssertEqual(ARTCMDLocator.resolve(root).path, binary.path)
        XCTAssertEqual(ARTCMDLocator.resolve(binary).path, binary.path)
        XCTAssertEqual(ARTCMDLocator.locate(userPath: root)?.path, binary.path)
    }
}
