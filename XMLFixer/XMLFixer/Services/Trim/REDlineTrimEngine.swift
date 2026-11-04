import Foundation

/// Finds the REDline command-line tool that ships with REDCINE-X Pro.
enum REDlineLocator {
    static let userDefaultsKey = "REDlinePath"

    static let defaultCandidates: [String] = [
        "/Applications/REDCINE-X PRO/REDCINE-X PRO.app/Contents/MacOS/REDline",
        "/Applications/REDCINE-X PRO.app/Contents/MacOS/REDline",
        "/Applications/REDCINE-X PRO/REDline",
        "/Applications/RED/REDline",
        "/usr/local/bin/REDline",
        "/opt/homebrew/bin/REDline",
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

/// Trims RED .R3D clips by invoking REDline's R3D-trim export.
///
/// Argument names and the R3D-Trim format code were checked against `REDline --help`
/// (REDline build 65.2.1, R3D SDK 9.2.1). The trim itself has not yet been run on a real clip,
/// so treat the first production run as a verification step and inspect the reported command line.
struct REDlineTrimEngine: TrimEngine {
    let kind: TrimSourceKind = .r3d
    let executable: URL

    /// REDline `--format` code for "R3D Trim" output (`--help`: "R3D Trim = 102").
    static var trimFormatCode = 102

    // MARK: - Argument building (pure, unit-tested)

    static func probeArguments(input: URL) -> [String] {
        ["--i", input.path, "--printMeta", "1"]
    }

    /// `startFrame`/`endFrameExclusive` are frame indices into the clip. `--frameCount` is used instead of
    /// `--end` so the inclusive/exclusive question never arises. Audio is kept in the trimmed clip.
    static func trimArguments(input: URL, outputDirectory: URL, startFrame: Int, endFrameExclusive: Int) -> [String] {
        let start = max(0, startFrame)
        let count = max(1, endFrameExclusive - start)
        return [
            "--i", input.path,
            "--outDir", outputDirectory.path,
            "--format", String(trimFormatCode),
            "--start", String(start),
            "--frameCount", String(count),
            "--trimAudio",
        ]
    }

    static func commandLine(executable: URL, arguments: [String]) -> String {
        ([executable.path] + arguments).map { arg in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }.joined(separator: " ")
    }

    struct ProbeFields: Equatable {
        var timecode: String?        // preferred: absolute (time-of-day) TC
        var absTimecode: String?
        var edgeTimecode: String?
        var fps: Double?             // playback FPS ("FPS:"), not "Record FPS"
        var frameCount: Int?
    }

    /// Parse of `--printMeta 1` output (REDline 65.x prints `Key:<tab>Value` lines such as
    /// "FPS:", "Record FPS:", "Total Frames:", "Abs TC:", "Edge TC:", "End Abs TC:").
    static func parseProbeOutput(_ text: String) -> ProbeFields {
        var fields = ProbeFields()
        let tcPattern = try! NSRegularExpression(pattern: "(\\d{2}:\\d{2}:\\d{2}[:;]\\d{2})")
        var anyTC: String? = nil

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("[") else { continue }   // skip REDline log lines
            let key: String
            let value: String
            if let sep = line.firstIndex(of: ":") {
                key = line[line.startIndex..<sep].trimmingCharacters(in: .whitespaces).lowercased()
                value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            } else {
                key = line.lowercased(); value = line
            }
            let keyIsTC = key.contains("timecode") || key.contains("time code") || key.hasSuffix(" tc") || key == "tc"
            if keyIsTC, !key.hasPrefix("end"),
               let m = tcPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
               let r = Range(m.range(at: 1), in: value) {
                let tc = String(value[r])
                if key.contains("abs") || key.contains("tod") || key.contains("time of day") {
                    if fields.absTimecode == nil { fields.absTimecode = tc }
                } else if key.contains("edge") {
                    if fields.edgeTimecode == nil { fields.edgeTimecode = tc }
                } else if anyTC == nil {
                    anyTC = tc
                }
            }
            if fields.fps == nil, key == "fps" || key == "frame rate" || key == "framerate" {
                if let v = firstNumber(in: value) { fields.fps = v }
            }
            if fields.frameCount == nil, key == "total frames" || key == "frame count" || key == "frames" {
                if let v = firstNumber(in: value) { fields.frameCount = Int(v) }
            }
        }
        fields.timecode = fields.absTimecode ?? fields.edgeTimecode ?? anyTC
        return fields
    }

    // MARK: - Output layout (pure, unit-tested)

    /// Base clip name without RED's segment suffix: "A001_A019_0630IJ_001" → "A001_A019_0630IJ".
    static func clipBaseName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let regex = try? NSRegularExpression(pattern: "_\\d{3}$"),
           let m = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
           let r = Range(m.range, in: stem) {
            return String(stem[..<r.lowerBound])
        }
        return stem
    }

    /// Where a trimmed clip goes, following RED's `<clip>.RDC/<clip>_001.R3D` convention.
    /// - single range: `<outputDirectory or outputDirectory/<base>.RDC>/<base>_001.R3D`
    /// - several ranges: sibling folders `<base>_trimNN.RDC/<base>_trimNN_001.R3D`
    static func outputLayout(candidateURL: URL, outputDirectory: URL, rangeIndex: Int, rangeCount: Int) -> (containerDirectory: URL, clipName: String) {
        let base = clipBaseName(for: candidateURL)
        let outputIsRDC = outputDirectory.pathExtension.lowercased() == "rdc"
        let rdcParent = outputIsRDC ? outputDirectory.deletingLastPathComponent() : outputDirectory
        if rangeCount <= 1 {
            let container = outputIsRDC ? outputDirectory : outputDirectory.appendingPathComponent("\(base).RDC", isDirectory: true)
            return (container, base)
        }
        let name = String(format: "%@_trim%02d", base, rangeIndex + 1)
        return (rdcParent.appendingPathComponent("\(name).RDC", isDirectory: true), name)
    }

    static func segmentFilename(clipName: String, segment: Int) -> String {
        String(format: "%@_%03d.R3D", clipName, segment)
    }

    private static func firstNumber(in line: String) -> Double? {
        // Skip the label part (before ':' or '=') when present
        var body = line
        if let idx = line.firstIndex(where: { $0 == ":" || $0 == "=" }) {
            body = String(line[line.index(after: idx)...])
        }
        let pattern = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)")
        guard let m = pattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let r = Range(m.range(at: 1), in: body) else { return nil }
        return Double(body[r])
    }

    // MARK: - Process execution

    typealias ProcessResult = ExternalTool.Result

    static func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        try await ExternalTool.run(executable: executable, arguments: arguments, toolName: "REDline")
    }

    // MARK: - Probe

    func probe(url: URL, fallbackTimebase: Int) async -> TrimSourceProbe {
        var probe = TrimSourceProbe(timebase: fallbackTimebase, ntsc: false, frameCount: 0, startTimecode: nil)
        do {
            let result = try await Self.run(executable: executable, arguments: Self.probeArguments(input: url))
            let fields = Self.parseProbeOutput(result.stdout + "\n" + result.stderr)
            if let fps = fields.fps {
                let (tb, ntsc) = QuickTimeTrimEngine.nominalTimebase(fps: fps)
                probe.timebase = tb
                probe.ntsc = ntsc
            }
            if let frames = fields.frameCount { probe.frameCount = frames }
            if let tc = fields.timecode {
                probe.startTimecode = Timecode.parse(tc, timebase: probe.timebase, dropFrame: tc.contains(";"))
            }
            if let abs = fields.absTimecode, let edge = fields.edgeTimecode, abs != edge {
                probe.alternateStartTimecode = Timecode.parse(edge, timebase: probe.timebase, dropFrame: edge.contains(";"))
                probe.alternateTimecodeLabel = "Edge TC"
                probe.notes.append("Abs TC \(abs), Edge TC \(edge)")
            }
            if probe.startTimecode == nil { probe.notes.append("REDline reported no timecode; using frame offsets") }
            if probe.frameCount == 0 { probe.notes.append("REDline reported no frame count; ranges are not clamped") }
        } catch {
            probe.notes.append("REDline probe failed: \(error.localizedDescription)")
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
        let layout = Self.outputLayout(candidateURL: candidate.url, outputDirectory: outputDirectory, rangeIndex: rangeIndex, rangeCount: rangeCount)
        try fm.createDirectory(at: layout.containerDirectory, withIntermediateDirectories: true)
        let firstSegmentURL = layout.containerDirectory.appendingPathComponent(Self.segmentFilename(clipName: layout.clipName, segment: 1))
        if fm.fileExists(atPath: firstSegmentURL.path) {
            if options.overwriteExisting {
                for existing in TrimRunner.r3dSegments(for: firstSegmentURL) { try? fm.removeItem(at: existing) }
            } else {
                throw TrimEngineError.outputExists(firstSegmentURL)
            }
        }

        // REDline writes `<input>.RDC/<input>.R3D` inside --outDir; use a scratch dir then move/rename.
        let scratch = layout.containerDirectory.deletingLastPathComponent()
            .appendingPathComponent(".redline-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let args = Self.trimArguments(input: candidate.url, outputDirectory: scratch, startFrame: range.originalIn, endFrameExclusive: range.originalOut)
        var output = TrimEngineOutput()
        output.commandLine = Self.commandLine(executable: executable, arguments: args)

        let result = try await Self.run(executable: executable, arguments: args)
        guard result.exitCode == 0 else {
            let tail = (result.stderr.isEmpty ? result.stdout : result.stderr).suffix(400)
            throw TrimEngineError.toolFailed("REDline exited \(result.exitCode): \(tail)")
        }

        var produced: [URL] = []
        if let enumerator = fm.enumerator(at: scratch, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "r3d" {
                produced.append(url)
            }
        }
        produced.sort { $0.lastPathComponent < $1.lastPathComponent }
        guard !produced.isEmpty else {
            throw TrimEngineError.toolFailed("REDline produced no .R3D output. Check the command line against `REDline --help`.")
        }

        // Rename to <clip>_001.R3D, <clip>_002.R3D … inside the .RDC container
        for (i, url) in produced.enumerated() {
            let dest = layout.containerDirectory.appendingPathComponent(Self.segmentFilename(clipName: layout.clipName, segment: i + 1))
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: url, to: dest)
            output.outputs.append(dest)
        }
        // Keep any RMD sidecar REDline wrote alongside
        if let enumerator = fm.enumerator(at: scratch, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "rmd" {
                let dest = layout.containerDirectory.appendingPathComponent(layout.clipName + ".rmd")
                try? fm.removeItem(at: dest)
                if (try? fm.moveItem(at: url, to: dest)) != nil { output.outputs.append(dest) }
            }
        }
        for url in output.outputs {
            output.bytesWritten += (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        output.framesWritten = range.length
        progress(1)
        return output
    }
}
