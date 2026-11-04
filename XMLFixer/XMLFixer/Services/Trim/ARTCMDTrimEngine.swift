import Foundation

/// Finds ARRI's `art-cmd` (ARRI Reference Tool, command-line version).
enum ARTCMDLocator {
    static let userDefaultsKey = "ARTCMDPath"

    static let defaultCandidates: [String] = [
        "/usr/local/bin/art-cmd",
        "/opt/homebrew/bin/art-cmd",
        "/Applications/ART_CMD/art-cmd",
        "/Applications/ART CMD/art-cmd",
        "/Applications/ARRI/ART_CMD/art-cmd",
        "/Applications/ARRI/art-cmd",
        "/Library/Application Support/ARRI/art-cmd",
    ]

    static func locate(userPath: URL?) -> URL? {
        let fm = FileManager.default
        if let userPath, fm.isExecutableFile(atPath: userPath.path) { return userPath }
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey), fm.isExecutableFile(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        for path in defaultCandidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// Trims ARRI MXF clips (ARRIRAW, HDE, ARRICORE, MXF/ProRes) with `art-cmd copy`.
///
/// Argument names come from the ARRI ART CMD 1.1.0 user manual (January 2026):
/// `copy` re-wraps without touching video or audio data, and combined with `--start`/`--duration`
/// it writes a trimmed SMPTE RDD 54/55-compliant MXF. `--start` is zero-based and the range is
/// `start … start + duration - 1` inclusive. `export` writes clip metadata as JSON.
///
/// The manual does not document the metadata JSON's key names, so `parseProbeJSON` searches for
/// any of several plausible keys at any depth and reports what it could not find. The first run
/// against real media should be treated as verification — check the reported command line and
/// whether the trimmed clip's start timecode matches the requested in-point.
struct ARTCMDTrimEngine: TrimEngine {
    let kind: TrimSourceKind = .mxf
    let executable: URL

    // MARK: - Argument building (pure, unit-tested)

    /// Metadata-only export of the first frame: everything the planner needs (fps, start TC, frame count)
    /// is static clip metadata, so one frame keeps it fast on a 20 GB ARRIRAW clip.
    static func probeArguments(input: URL, outputJSON: URL) -> [String] {
        [
            "export",
            "--input", input.path,
            "--duration", "1",
            "--skip-audio",
            "--skip-look",
            "--output", outputJSON.path,
        ]
    }

    /// `--start` is zero-based; `--duration` counts frames, so the end point needs no +/-1 reasoning.
    static func trimArguments(input: URL, output: URL, startFrame: Int, endFrameExclusive: Int) -> [String] {
        let start = max(0, startFrame)
        let count = max(1, endFrameExclusive - start)
        return [
            "copy",
            "--input", input.path,
            "--start", String(start),
            "--duration", String(count),
            "--output", output.path,
        ]
    }

    static func commandLine(executable: URL, arguments: [String]) -> String {
        ([executable.path] + arguments).map { arg in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }.joined(separator: " ")
    }

    // MARK: - Probe parsing (pure, unit-tested)

    struct ProbeFields: Equatable {
        var timecode: String?
        var fps: Double?
        var frameCount: Int?
        var recordingFormat: String?
    }

    private static let timecodeKeys = [
        "starttimecode", "timecode", "startts", "recordingtimecode", "firstframetimecode", "tc",
    ]
    private static let fpsKeys = [
        "projectframerate", "sensorfps", "framerate", "fps", "recordingframerate", "playbackframerate",
    ]
    private static let frameCountKeys = [
        "framecount", "totalframes", "numberofframes", "durationinframes", "clipduration", "frames",
    ]
    private static let formatKeys = [
        "recordingfileformat", "videocodec", "codec", "essencetype", "imagefileformat",
    ]

    /// Pull the fields the planner needs out of `art-cmd export` JSON without depending on its exact shape.
    static func parseProbeJSON(_ data: Data) -> ProbeFields {
        var fields = ProbeFields()
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return fields }

        var strings: [(key: String, value: String)] = []
        var numbers: [(key: String, value: Double)] = []
        collect(root, into: &strings, numbers: &numbers)

        let tcPattern = try! NSRegularExpression(pattern: "(\\d{2}:\\d{2}:\\d{2}[:;]\\d{2})")
        // Prefer a key that looks like a start timecode; fall back to any timecode-shaped string.
        for candidate in timecodeKeys {
            if let hit = strings.first(where: { $0.key == candidate }),
               let tc = firstTimecode(in: hit.value, pattern: tcPattern) {
                fields.timecode = tc
                break
            }
        }
        if fields.timecode == nil {
            for entry in strings where entry.key.contains("timecode") && !entry.key.contains("end") {
                if let tc = firstTimecode(in: entry.value, pattern: tcPattern) {
                    fields.timecode = tc
                    break
                }
            }
        }

        fields.fps = firstValue(for: fpsKeys, strings: strings, numbers: numbers)
        if let frames = firstValue(for: frameCountKeys, strings: strings, numbers: numbers) {
            fields.frameCount = Int(frames)
        }
        for candidate in formatKeys {
            if let hit = strings.first(where: { $0.key == candidate }) {
                fields.recordingFormat = hit.value
                break
            }
        }
        return fields
    }

    /// Numeric value for the first matching key, accepting both JSON numbers and numeric strings
    /// (ARRI writes rates as "23.976" in places and as a number in others).
    private static func firstValue(
        for keys: [String],
        strings: [(key: String, value: String)],
        numbers: [(key: String, value: Double)]
    ) -> Double? {
        for candidate in keys {
            if let hit = numbers.first(where: { $0.key == candidate }) { return hit.value }
            if let hit = strings.first(where: { $0.key == candidate }), let v = firstNumber(in: hit.value) { return v }
        }
        return nil
    }

    private static func firstTimecode(in value: String, pattern: NSRegularExpression) -> String? {
        guard let m = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let r = Range(m.range(at: 1), in: value) else { return nil }
        return String(value[r])
    }

    private static func firstNumber(in value: String) -> Double? {
        let pattern = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)")
        guard let m = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let r = Range(m.range(at: 1), in: value) else { return nil }
        return Double(value[r])
    }

    /// Flatten the JSON tree into normalized key/value pairs. Keys lose case, spaces and underscores so
    /// "Start Timecode", "start_timecode" and "startTimecode" all compare equal. Only the first frame's
    /// dynamic metadata is exported, so arrays are shallow.
    private static func collect(
        _ node: Any,
        into strings: inout [(key: String, value: String)],
        numbers: inout [(key: String, value: Double)],
        key: String = ""
    ) {
        switch node {
        case let dict as [String: Any]:
            for (rawKey, value) in dict {
                collect(value, into: &strings, numbers: &numbers, key: normalize(rawKey))
            }
        case let array as [Any]:
            for value in array.prefix(32) {
                collect(value, into: &strings, numbers: &numbers, key: key)
            }
        case let string as String:
            guard !key.isEmpty else { return }
            strings.append((key, string))
        case let number as NSNumber:
            guard !key.isEmpty else { return }
            // Bool arrives as NSNumber too; it is never a value we want.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return }
            numbers.append((key, number.doubleValue))
        default:
            return
        }
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    // MARK: - Probe

    func probe(url: URL, fallbackTimebase: Int) async -> TrimSourceProbe {
        var probe = TrimSourceProbe(timebase: fallbackTimebase, ntsc: false, frameCount: 0, startTimecode: nil, isAllIntra: true)
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("art-cmd-probe-\(UUID().uuidString)", isDirectory: true)
        let json = scratch.appendingPathComponent("metadata.json")
        do {
            // `export` wants an empty output directory; the explicit .json names a metadata-only export.
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }

            let args = Self.probeArguments(input: url, outputJSON: json)
            let result = try await ExternalTool.run(executable: executable, arguments: args, toolName: "art-cmd")
            guard result.exitCode == 0 else {
                let tail = (result.stderr.isEmpty ? result.stdout : result.stderr).suffix(300)
                probe.notes.append("art-cmd export exited \(result.exitCode): \(tail)")
                return probe
            }
            guard let data = try? Data(contentsOf: json) else {
                probe.notes.append("art-cmd wrote no metadata JSON; MXF ranges are not clamped")
                return probe
            }

            let fields = Self.parseProbeJSON(data)
            if let fps = fields.fps {
                let (tb, ntsc) = QuickTimeTrimEngine.nominalTimebase(fps: fps)
                probe.timebase = tb
                probe.ntsc = ntsc
            } else {
                probe.notes.append("art-cmd reported no frame rate; using the XML's \(fallbackTimebase)")
            }
            if let frames = fields.frameCount {
                probe.frameCount = frames
            } else {
                probe.notes.append("art-cmd reported no frame count; ranges are not clamped")
            }
            if let tc = fields.timecode {
                probe.startTimecode = Timecode.parse(tc, timebase: probe.timebase, dropFrame: tc.contains(";"))
            } else {
                probe.notes.append("art-cmd reported no timecode; using frame offsets")
            }
            if let format = fields.recordingFormat {
                probe.notes.append("ARRI \(format)")
            }
        } catch {
            probe.notes.append("art-cmd probe failed: \(error.localizedDescription)")
        }
        return probe
    }

    // MARK: - Trim

    func trim(
        item: TrimPlanItem,
        candidate: TrimCandidate,
        range: TrimRange,
        rangeIndex: Int,
        rangeCount: Int,
        outputDirectory: URL,
        options: TrimOptions,
        progress: @escaping (Double) -> Void
    ) async throws -> TrimEngineOutput {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let destination = TrimNaming.outputURL(
            for: candidate.url,
            in: outputDirectory,
            rangeIndex: rangeIndex,
            rangeCount: rangeCount
        )
        if fm.fileExists(atPath: destination.path) {
            if options.overwriteExisting {
                try fm.removeItem(at: destination)
            } else {
                throw TrimEngineError.outputExists(destination)
            }
        }

        let args = Self.trimArguments(
            input: candidate.url,
            output: destination,
            startFrame: range.originalIn,
            endFrameExclusive: range.originalOut
        )
        var output = TrimEngineOutput()
        output.commandLine = Self.commandLine(executable: executable, arguments: args)

        let result = try await ExternalTool.run(executable: executable, arguments: args, toolName: "art-cmd")
        guard result.exitCode == 0 else {
            let tail = (result.stderr.isEmpty ? result.stdout : result.stderr).suffix(400)
            throw TrimEngineError.toolFailed("art-cmd exited \(result.exitCode): \(tail)")
        }
        guard fm.fileExists(atPath: destination.path) else {
            // A directory given as --output makes art-cmd write <directory>/<clip>.mxf; an explicit
            // filename should not, but recover the clip if it landed there anyway.
            let fallback = destination.appendingPathComponent(candidate.url.lastPathComponent)
            guard fm.fileExists(atPath: fallback.path) else {
                throw TrimEngineError.toolFailed("art-cmd produced no output at \(destination.lastPathComponent)")
            }
            output.outputs = [fallback]
            output.framesWritten = range.length
            output.bytesWritten = (try? fm.attributesOfItem(atPath: fallback.path)[.size] as? Int64) ?? 0
            progress(1)
            return output
        }

        output.outputs = [destination]
        output.framesWritten = range.length
        output.bytesWritten = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        progress(1)
        return output
    }
}
