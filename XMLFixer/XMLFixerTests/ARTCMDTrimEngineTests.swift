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

    func testProbeArgumentsExportMetadataOnlyForOneFrame() {
        let args = ARTCMDTrimEngine.probeArguments(
            input: URL(fileURLWithPath: "/media/clip.mxf"),
            outputJSON: URL(fileURLWithPath: "/tmp/probe/metadata.json")
        )
        XCTAssertEqual(args.first, "export")
        XCTAssertTrue(args.contains("--skip-audio"))
        XCTAssertTrue(args.contains("--skip-look"))
        XCTAssertEqual(args[args.firstIndex(of: "--duration")! + 1], "1")
        XCTAssertEqual(args[args.firstIndex(of: "--output")! + 1], "/tmp/probe/metadata.json")
    }

    func testCommandLineQuotesPathsWithSpaces() {
        let line = ARTCMDTrimEngine.commandLine(
            executable: tool,
            arguments: ["copy", "--input", "/Volumes/Footage Backup/clip.mxf"]
        )
        XCTAssertEqual(line, "/usr/local/bin/art-cmd copy --input \"/Volumes/Footage Backup/clip.mxf\"")
    }

    // MARK: - Metadata parsing

    func testParseProbeJSONReadsCamelCaseKeys() throws {
        let json = """
        {
          "staticMetadata": {
            "cameraModel": "ARRI ALEXA 35",
            "recordingFileFormat": "ARRIRAW",
            "startTimecode": "08:41:23:00",
            "projectFrameRate": 23.976,
            "frameCount": 4512
          }
        }
        """
        let fields = ARTCMDTrimEngine.parseProbeJSON(Data(json.utf8))
        XCTAssertEqual(fields.timecode, "08:41:23:00")
        XCTAssertEqual(fields.fps ?? 0, 23.976, accuracy: 0.0001)
        XCTAssertEqual(fields.frameCount, 4512)
        XCTAssertEqual(fields.recordingFormat, "ARRIRAW")
    }

    /// Keys are matched case-insensitively and ignoring spaces, underscores and hyphens, and numbers
    /// written as strings still parse, since the manual does not pin the JSON's spelling down.
    func testParseProbeJSONToleratesOtherSpellingsAndNesting() throws {
        let json = """
        {
          "clip": {
            "Start Timecode": "10:00:00:12",
            "sensor_fps": "24.000",
            "frames": [ { "Total Frames": 240 } ]
          }
        }
        """
        let fields = ARTCMDTrimEngine.parseProbeJSON(Data(json.utf8))
        XCTAssertEqual(fields.timecode, "10:00:00:12")
        XCTAssertEqual(fields.fps ?? 0, 24.0, accuracy: 0.0001)
        XCTAssertEqual(fields.frameCount, 240)
    }

    func testParseProbeJSONIgnoresEndTimecodeAndBooleans() throws {
        let json = """
        { "endTimecode": "09:00:00:00", "someFlag": true, "timecodeOfFirstFrame": "08:00:00:00" }
        """
        let fields = ARTCMDTrimEngine.parseProbeJSON(Data(json.utf8))
        XCTAssertEqual(fields.timecode, "08:00:00:00")
        XCTAssertNil(fields.fps)
        XCTAssertNil(fields.frameCount)
    }

    func testParseProbeJSONSurvivesGarbage() {
        XCTAssertEqual(ARTCMDTrimEngine.parseProbeJSON(Data("not json".utf8)), ARTCMDTrimEngine.ProbeFields())
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

    func testLocatorPrefersAnExecutableUserPath() {
        XCTAssertNil(ARTCMDLocator.locate(userPath: URL(fileURLWithPath: "/nonexistent/art-cmd")).flatMap {
            $0.path == "/nonexistent/art-cmd" ? $0 : nil
        })
    }
}
