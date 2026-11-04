import Foundation

/// What an engine produced for one range.
struct TrimEngineOutput {
    var outputs: [URL] = []
    var framesWritten: Int = 0
    var extraFrames: Int = 0
    var bytesWritten: Int64 = 0
    var messages: [String] = []
    var commandLine: String? = nil
}

/// A lossless trimmer for one family of camera-original formats.
protocol TrimEngine {
    var kind: TrimSourceKind { get }

    /// Cut `range` out of `candidate` into `outputDirectory` without re-encoding.
    /// `rangeIndex`/`rangeCount` drive output naming when a source yields several files.
    func trim(
        item: TrimPlanItem,
        candidate: TrimCandidate,
        range: TrimRange,
        rangeIndex: Int,
        rangeCount: Int,
        outputDirectory: URL,
        options: TrimOptions,
        progress: @escaping (Double) -> Void
    ) async throws -> TrimEngineOutput
}

enum TrimEngineError: LocalizedError {
    case noVideoTrack
    case unreadable(String)
    case writerFailed(String)
    case readerFailed(String)
    case outputExists(URL)
    case toolFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track found."
        case .unreadable(let why): return "Cannot read source: \(why)"
        case .writerFailed(let why): return "Writer failed: \(why)"
        case .readerFailed(let why): return "Reader failed: \(why)"
        case .outputExists(let url): return "Output already exists: \(url.lastPathComponent)"
        case .toolFailed(let why): return why
        case .cancelled: return "Cancelled."
        }
    }
}

// MARK: - Sandbox detection

enum AppSandbox {
    /// True when running inside the macOS App Sandbox (App Store builds).
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}

// MARK: - External command-line tools

/// Runs a vendor CLI (REDline, art-cmd) and collects its output.
enum ExternalTool {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// A runnable binary: `isExecutableFile` alone also says yes to directories, which have the
    /// execute bit, so an install folder would otherwise pass as its own tool.
    static func isRunnable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return fm.isExecutableFile(atPath: path)
    }

    static func run(executable: URL, arguments: [String], toolName: String) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: Result(exitCode: proc.terminationStatus, stdout: out, stderr: err))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TrimEngineError.toolFailed("Could not launch \(toolName): \(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - Naming & paths shared by engines

enum TrimNaming {
    /// Same filename as the original when a source yields one file; `_trim01`, `_trim02` … when it yields several.
    static func outputURL(for original: URL, in directory: URL, rangeIndex: Int, rangeCount: Int) -> URL {
        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        if rangeCount <= 1 {
            return directory.appendingPathComponent(original.lastPathComponent)
        }
        let name = String(format: "%@_trim%02d", stem, rangeIndex + 1)
        return directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
    }

    /// Destination directory for an original: mirrors its path relative to `sourceRoot`, or flat when mirroring is off
    /// or the original is not inside `sourceRoot`.
    static func destinationDirectory(for original: URL, options: TrimOptions) -> URL? {
        guard let destRoot = options.destinationRoot else { return nil }
        guard options.mirrorFolders, let sourceRoot = options.sourceRoot else { return destRoot }

        let originalDir = original.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let dirComponents = originalDir.pathComponents
        let rootComponents = root.pathComponents
        guard dirComponents.count >= rootComponents.count,
              Array(dirComponents.prefix(rootComponents.count)) == rootComponents
        else { return destRoot }

        var result = destRoot
        for comp in dirComponents.dropFirst(rootComponents.count) {
            result = result.appendingPathComponent(comp)
        }
        return result
    }
}

// MARK: - Registry

struct TrimEngineRegistry {
    let quickTime: QuickTimeTrimEngine
    let imageSequence: ImageSequenceTrimEngine
    let redline: REDlineTrimEngine?
    let artcmd: ARTCMDTrimEngine?

    init(options: TrimOptions, sandboxed: Bool = AppSandbox.isSandboxed) {
        quickTime = QuickTimeTrimEngine()
        imageSequence = ImageSequenceTrimEngine()
        if !sandboxed, let exe = REDlineLocator.locate(userPath: options.redlinePath) {
            redline = REDlineTrimEngine(executable: exe)
        } else {
            redline = nil
        }
        if !sandboxed, let exe = ARTCMDLocator.locate(userPath: options.artcmdPath) {
            artcmd = ARTCMDTrimEngine(executable: exe)
        } else {
            artcmd = nil
        }
    }

    /// The engine for a kind, or nil with a human-readable reason when the file must be copied whole.
    func engine(for kind: TrimSourceKind) -> (engine: TrimEngine?, reason: String?) {
        switch kind {
        case .quickTime:
            return (quickTime, nil)
        case .imageSequence:
            return (imageSequence, nil)
        case .r3d:
            if let redline { return (redline, nil) }
            return (nil, AppSandbox.isSandboxed
                    ? "R3D trimming needs REDline, which is unavailable in the sandboxed build"
                    : "REDline not found — install REDCINE-X Pro or set the REDline path")
        case .mxf:
            // AVFoundation cannot write MXF; ARRI's art-cmd can trim ARRI MXF losslessly.
            if let artcmd { return (artcmd, nil) }
            return (nil, AppSandbox.isSandboxed
                    ? "MXF trimming needs ARRI ART CMD, which is unavailable in the sandboxed build"
                    : "ART CMD not found — install ARRI ART CMD or set its path (non-ARRI MXF is copied whole)")
        case .stillImage:
            return (nil, "Still image")
        case .unsupported:
            return (nil, "No lossless trimmer for this format")
        }
    }
}
