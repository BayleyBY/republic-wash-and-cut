import Foundation

/// Finds ARRI's `art-cmd` (ARRI Reference Tool, command-line version).
enum ARTCMDLocator {
    static let userDefaultsKey = "ARTCMDPath"

    /// ART CMD ships as a portable folder (`bin/`, `lib/`, `doc/`) with no installer, so the binary
    /// normally sits in a `bin` subdirectory wherever the user dropped it.
    static let defaultCandidates: [String] = [
        "/Applications/ART_CMD/bin/art-cmd",
        "/Applications/ART CMD/bin/art-cmd",
        "/Applications/art-cmd/bin/art-cmd",
        "/Applications/ARRI/ART_CMD/bin/art-cmd",
        "/Applications/ARRI/art-cmd/bin/art-cmd",
        "/usr/local/bin/art-cmd",
        "/opt/homebrew/bin/art-cmd",
        "/usr/local/ART_CMD/bin/art-cmd",
    ]

    /// A user who points at the install folder rather than the binary still gets a working path.
    static func resolve(_ url: URL) -> URL {
        if ExternalTool.isRunnable(url.path) { return url }
        let inBin = url.appendingPathComponent("bin/art-cmd")
        if ExternalTool.isRunnable(inBin.path) { return inBin }
        return url
    }

    static func locate(userPath: URL?) -> URL? {
        if let userPath {
            let resolved = resolve(userPath)
            if ExternalTool.isRunnable(resolved.path) { return resolved }
        }
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey) {
            let resolved = resolve(URL(fileURLWithPath: saved))
            if ExternalTool.isRunnable(resolved.path) { return resolved }
        }
        for path in defaultCandidates where ExternalTool.isRunnable(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// Trims ARRI MXF clips (ARRIRAW, HDE, ARRICORE, MXF/ProRes) with `art-cmd copy`.
///
/// Arguments were checked against `art-cmd --help` and the ART CMD 1.1.0 manual, with the metadata
/// shape read from a real ALEXA 35 ARRIRAW clip (schema `metadata_output/v2-2-0`): `copy` re-wraps
/// without touching video or audio data, and with `--start`/`--duration` it writes a trimmed
/// SMPTE RDD 44/54/55/61 conformant MXF. `--start` is zero-based.
///
/// Probing is deliberately split in two. A one-frame `export` is instant even on a 126 GB clip and
/// carries the rate and that frame's timecode; the frame count is *not* available from it, because
/// `clipDuration` reports the exported range rather than the clip, and a full export of that same
/// clip took 4m20s — far too slow per item. The count instead comes from a doubling search over
/// `--start N --duration 1` probes (~0.04s each), which exit 1 with "lies beyond the end" past the
/// last frame.
struct ARTCMDTrimEngine: TrimEngine {
    let kind: TrimSourceKind = .mxf
    let executable: URL

    // MARK: - Argument building (pure, unit-tested)

    /// art-cmd writes `art.log` into the working directory unless told otherwise, and the app's
    /// working directory is not ours to litter.
    static let noLogFile = ["--logpath", ""]

    /// Metadata-only export of one frame — rate and that frame's timecode, in well under a second.
    static func probeArguments(input: URL, outputJSON: URL, startFrame: Int = 0) -> [String] {
        var args = ["export", "--input", input.path]
        if startFrame > 0 { args += ["--start", String(startFrame)] }
        args += [
            "--duration", "1",
            "--skip-audio",
            "--skip-look",
            "--output", outputJSON.path,
        ]
        return args + noLogFile
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
        ] + noLogFile
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
        var dropFrame: Bool = false
        var videoCodec: String?
    }

    /// Reads ARRI's `metadata_output` JSON (v2-2-0): `clipBasedMetadataSets[]` are
    /// `{metadataSetName, metadataSetPayload}` pairs — "Project Rate" holds `timebase` as a rational
    /// string ("24000/1001") plus `dropframe`, "Clip Info" holds `videoCodec` — and
    /// `frameBasedMetadata.frames[]` are `{frameNo, timecode}`.
    static func parseProbeJSON(_ data: Data) -> ProbeFields {
        var fields = ProbeFields()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fields }

        let sets = (root["clipBasedMetadataSets"] as? [[String: Any]]) ?? []
        func payload(_ name: String) -> [String: Any]? {
            sets.first { ($0["metadataSetName"] as? String) == name }?["metadataSetPayload"] as? [String: Any]
        }

        if let rate = payload("Project Rate") {
            fields.fps = rational(rate["timebase"])
            fields.dropFrame = (rate["dropframe"] as? Bool) ?? false
        }
        if fields.fps == nil,
           let descriptor = payload("MXF Generic Data")?["nativePictureEssenceDescriptor"] as? [String: Any],
           let file = descriptor["file"] as? [String: Any] {
            fields.fps = rational(file["sampleRate"])
        }
        fields.videoCodec = payload("Clip Info")?["videoCodec"] as? String

        // The lowest frameNo in the export is the frame `--start` asked for.
        if let frameBased = root["frameBasedMetadata"] as? [String: Any],
           let frames = frameBased["frames"] as? [[String: Any]] {
            let first = frames.min { ($0["frameNo"] as? Int ?? 0) < ($1["frameNo"] as? Int ?? 0) }
            if let tc = first?["timecode"] as? String, !tc.isEmpty {
                fields.timecode = tc
            }
        }
        return fields
    }

    /// ARRI writes rates as rational strings ("24000/1001" → 23.976); plain numbers are accepted too.
    static func rational(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        guard let text = value as? String else { return nil }
        let parts = text.split(separator: "/", maxSplits: 1)
        if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 {
            return num / den
        }
        return Double(text)
    }

    /// True when `art-cmd` refused a `--start` past the last frame, which is how the frame count is found.
    static func isBeyondEnd(_ result: ExternalTool.Result) -> Bool {
        let text = result.stdout + result.stderr
        return result.exitCode != 0 && text.contains("lies beyond the end")
    }

    // MARK: - Probe

    func probe(url: URL, fallbackTimebase: Int) async -> TrimSourceProbe {
        var probe = TrimSourceProbe(timebase: fallbackTimebase, ntsc: false, frameCount: 0, startTimecode: nil, isAllIntra: true)
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("art-cmd-probe-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil else {
            probe.notes.append("art-cmd probe failed: could not create a scratch directory")
            return probe
        }
        defer { try? fm.removeItem(at: scratch) }

        let json = scratch.appendingPathComponent("metadata.json")
        do {
            let result = try await ExternalTool.run(
                executable: executable,
                arguments: Self.probeArguments(input: url, outputJSON: json),
                toolName: "art-cmd"
            )
            guard result.exitCode == 0, let data = try? Data(contentsOf: json) else {
                let tail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
                probe.notes.append("art-cmd could not read this clip: \(tail)")
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
            if let tc = fields.timecode {
                probe.startTimecode = Timecode.parse(tc, timebase: probe.timebase, dropFrame: fields.dropFrame)
            } else {
                probe.notes.append("art-cmd reported no timecode; using frame offsets")
            }
            if let codec = fields.videoCodec { probe.notes.append(codec) }

            probe.frameCount = await frameCount(url: url, scratch: scratch)
            if probe.frameCount == 0 {
                probe.notes.append("art-cmd reported no frame count; ranges are not clamped")
            }
        } catch {
            probe.notes.append("art-cmd probe failed: \(error.localizedDescription)")
        }
        return probe
    }

    /// Frame count by doubling then bisecting `--start N --duration 1`: each probe costs about 0.04s,
    /// against minutes for a full metadata export of a long clip.
    private func frameCount(url: URL, scratch: URL) async -> Int {
        let json = scratch.appendingPathComponent("seek.json")
        let ceiling = 4_000_000            // ~46 hours at 24 fps

        func exists(_ frame: Int) async -> Bool {
            guard let result = try? await ExternalTool.run(
                executable: executable,
                arguments: Self.probeArguments(input: url, outputJSON: json, startFrame: frame),
                toolName: "art-cmd"
            ) else { return false }
            try? FileManager.default.removeItem(at: json)
            return result.exitCode == 0
        }

        guard await exists(0) else { return 0 }

        var low = 0                        // known to exist
        var high = 1                       // candidate past the end
        while high < ceiling, await exists(high) {
            low = high
            high *= 2
        }
        if high >= ceiling { return 0 }    // implausible; report unknown rather than a wrong count

        while high - low > 1 {
            let mid = low + (high - low) / 2
            if await exists(mid) { low = mid } else { high = mid }
        }
        return low + 1
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
