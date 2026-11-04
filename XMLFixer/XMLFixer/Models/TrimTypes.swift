import Foundation

// MARK: - Source classification

/// What kind of camera-original media a matched file is, which decides the trim engine.
enum TrimSourceKind: String, CaseIterable {
    case quickTime        // .mov / .mp4 / .m4v — AVFoundation passthrough
    case mxf              // .mxf — readable by AVFoundation in some cases, but not writable; copied whole
    case r3d              // RED .R3D (single or split segments) — REDline
    case imageSequence    // .exr / .dpx / .dng / .ari / .tif / .png … — per-frame file copies
    case stillImage       // a lone image file with no frame numbering — copied whole
    case unsupported      // anything else (BRAW, CRM, …) — copied whole

    static func classify(extension ext: String) -> TrimSourceKind {
        switch ext.lowercased() {
        case "mov", "mp4", "m4v", "qt":
            return .quickTime
        case "mxf":
            return .mxf
        case "r3d":
            return .r3d
        case "exr", "dpx", "dng", "ari", "arx", "tif", "tiff", "png", "jpg", "jpeg", "cin", "sxr":
            return .imageSequence
        default:
            return .unsupported
        }
    }

    var displayName: String {
        switch self {
        case .quickTime: return "QuickTime"
        case .mxf: return "MXF"
        case .r3d: return "RED R3D"
        case .imageSequence: return "Image Sequence"
        case .stillImage: return "Still"
        case .unsupported: return "Unsupported"
        }
    }
}

/// How the XML's file-relative frame ranges were mapped onto the original.
enum TrimRangeBasis: String {
    case timecode   // XML file start TC → absolute TC → original's embedded TC
    case offset     // frame 0 of the XML file assumed to equal frame 0 of the original

    var displayName: String {
        switch self {
        case .timecode: return "TC"
        case .offset: return "Offset"
        }
    }
}

// MARK: - Image sequences

/// A numbered image sequence discovered on disk.
struct ImageSequenceInfo {
    struct Frame {
        let number: Int
        let url: URL
        let fileSize: Int64
    }

    let directory: URL
    let prefix: String        // everything before the frame number (including separator)
    let suffix: String        // "." + extension
    let frames: [Frame]       // sorted ascending by number

    var frameCount: Int { frames.count }
    var firstFrameNumber: Int? { frames.first?.number }
    var lastFrameNumber: Int? { frames.last?.number }
    var totalBytes: Int64 { frames.reduce(0) { $0 + $1.fileSize } }

    /// Index into `frames` of the given frame number, if present.
    func index(ofFrameNumber number: Int) -> Int? {
        frames.firstIndex { $0.number == number }
    }

    /// Parse "<prefix><digits>.<ext>" into its parts. Returns nil when the filename has no trailing frame number.
    static func parse(filename: String) -> (prefix: String, number: Int, padding: Int, suffix: String)? {
        let ns = filename as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        guard !ext.isEmpty else { return nil }
        // Trailing run of digits (at least 3) optionally preceded by a separator
        let pattern = "^(.*?)(\\d{3,})$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              let prefixRange = Range(match.range(at: 1), in: stem),
              let digitsRange = Range(match.range(at: 2), in: stem),
              let number = Int(stem[digitsRange])
        else { return nil }
        return (String(stem[prefixRange]), number, stem[digitsRange].count, "." + ext)
    }

    /// Normalise sequence notations found in XML filenames such as
    /// "clip.[1001-1100].exr", "clip.%04d.exr", "clip.####.exr", "clip.1001.exr"
    /// into a (prefix, suffix) key. Returns nil if it does not look like a sequence.
    static func sequenceKey(fromXMLFilename filename: String) -> (prefix: String, suffix: String)? {
        var name = filename
        // [1001-1100] or [1001,1100]
        if let regex = try? NSRegularExpression(pattern: "\\[\\d+[-,]\\d+\\]") {
            name = regex.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "0000")
        }
        // %04d / %d
        if let regex = try? NSRegularExpression(pattern: "%0?\\d*d") {
            name = regex.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "0000")
        }
        // #### 
        if let regex = try? NSRegularExpression(pattern: "#{2,}") {
            name = regex.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "0000")
        }
        guard let parsed = parse(filename: name) else { return nil }
        return (parsed.prefix.lowercased(), parsed.suffix.lowercased())
    }
}

// MARK: - Planning

/// A candidate camera-original file (or sequence) found on disk for one XML media item.
struct TrimCandidate: Identifiable {
    let id: UUID
    let url: URL                     // first segment / first frame for split R3D and sequences
    let kind: TrimSourceKind
    let fileSize: Int64              // total bytes (whole sequence for image sequences)
    let sequence: ImageSequenceInfo? // populated for image sequences
    let isR3DSplit: Bool

    init(id: UUID = UUID(), url: URL, kind: TrimSourceKind, fileSize: Int64, sequence: ImageSequenceInfo? = nil, isR3DSplit: Bool = false) {
        self.id = id
        self.url = url
        self.kind = kind
        self.fileSize = fileSize
        self.sequence = sequence
        self.isR3DSplit = isR3DSplit
    }

    var displayName: String {
        if let seq = sequence, let first = seq.firstFrameNumber, let last = seq.lastFrameNumber {
            return "\(seq.prefix)[\(first)-\(last)]\(seq.suffix)"
        }
        return url.lastPathComponent + (isR3DSplit ? " (R3D split)" : "")
    }

    var displaySize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}

/// Probed facts about the original media needed to map ranges.
struct TrimSourceProbe {
    var timebase: Int            // nominal frames per second (24, 25, 30, 50, 60 …)
    var ntsc: Bool
    var frameCount: Int          // total frames in the original
    var startTimecode: Timecode? // nil when the original carries no readable TC
    var isAllIntra: Bool?        // nil when unknown
    var notes: [String] = []
    /// A second timecode track some formats carry (RED edge code next to absolute/TOD). Tried when the
    /// primary one does not contain the XML's ranges.
    var alternateStartTimecode: Timecode? = nil
    var alternateTimecodeLabel: String = "alternate TC"
}

/// One contiguous range to trim, expressed in the original's frames.
struct TrimRange: Equatable {
    let originalIn: Int          // inclusive, frame index into the original
    let originalOut: Int         // exclusive
    let xmlIn: Int               // the XML-side merged range this came from
    let xmlOut: Int
    var length: Int { originalOut - originalIn }
}

enum TrimPlanStatus: Equatable {
    case ready                 // will be trimmed
    case copyWhole(String)     // will be copied untrimmed, with a reason
    case unmatched             // no original found
    case invalid(String)       // ranges fall outside the original etc.

    var isActionable: Bool {
        switch self {
        case .ready, .copyWhole: return true
        case .unmatched, .invalid: return false
        }
    }
}

/// Everything decided about one XML source before any I/O happens.
struct TrimPlanItem: Identifiable {
    let id: UUID
    let xmlFilename: String
    let xmlTimebase: Int
    let xmlNtsc: Bool
    let xmlStartTimecode: String?
    let xmlSourceDuration: Int
    let mergedRanges: [SourceRange]          // XML file frames

    var candidates: [TrimCandidate] = []
    var selectedCandidateIndex: Int? = nil
    var userConfirmed: Bool = false

    var probe: TrimSourceProbe? = nil
    var basis: TrimRangeBasis = .offset
    var trimRanges: [TrimRange] = []
    var status: TrimPlanStatus = .unmatched
    var warnings: [String] = []

    init(id: UUID = UUID(), xmlFilename: String, xmlTimebase: Int, xmlNtsc: Bool, xmlStartTimecode: String?, xmlSourceDuration: Int, mergedRanges: [SourceRange]) {
        self.id = id
        self.xmlFilename = xmlFilename
        self.xmlTimebase = xmlTimebase
        self.xmlNtsc = xmlNtsc
        self.xmlStartTimecode = xmlStartTimecode
        self.xmlSourceDuration = xmlSourceDuration
        self.mergedRanges = mergedRanges
    }

    var selectedCandidate: TrimCandidate? {
        guard let idx = selectedCandidateIndex, idx < candidates.count else { return nil }
        return candidates[idx]
    }

    var trimmedFrameCount: Int { trimRanges.reduce(0) { $0 + $1.length } }

    /// Rough output size: proportional to the trimmed fraction, or exact for sequences.
    var estimatedOutputBytes: Int64 {
        guard let candidate = selectedCandidate else { return 0 }
        switch status {
        case .copyWhole:
            return candidate.fileSize
        case .ready:
            if let seq = candidate.sequence {
                var total: Int64 = 0
                for range in trimRanges {
                    let lo = max(0, range.originalIn)
                    let hi = min(seq.frames.count, range.originalOut)
                    if hi > lo {
                        total += seq.frames[lo..<hi].reduce(0) { $0 + $1.fileSize }
                    }
                }
                return total
            }
            guard let frames = probe?.frameCount, frames > 0 else { return candidate.fileSize }
            let fraction = min(1.0, Double(trimmedFrameCount) / Double(frames))
            return Int64(Double(candidate.fileSize) * fraction)
        default:
            return 0
        }
    }
}

// MARK: - Options & results

struct TrimOptions {
    var sourceRoot: URL?
    var destinationRoot: URL?
    var mirrorFolders: Bool = true       // recreate the path relative to sourceRoot under destinationRoot
    var overwriteExisting: Bool = false
    var handles: Int = 10
    var mergeThreshold: Int = 0
    var redlinePath: URL? = nil
    var artcmdPath: URL? = nil
}

enum TrimResultStatus: Equatable {
    case trimmed
    case copiedWhole
    case skippedExisting
    case skipped(String)
    case failed(String)

    var label: String {
        switch self {
        case .trimmed: return "Trimmed"
        case .copiedWhole: return "Copied whole"
        case .skippedExisting: return "Exists, skipped"
        case .skipped(let why): return "Skipped: \(why)"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct TrimResultItem: Identifiable {
    let id: UUID
    let planItemID: UUID
    let xmlFilename: String
    let originalURL: URL?
    var outputs: [URL] = []
    var framesWritten: Int = 0
    var extraFrames: Int = 0          // frames added by keyframe snapping
    var bytesWritten: Int64 = 0
    var status: TrimResultStatus
    var messages: [String] = []
    var commandLine: String? = nil    // for vendor CLI engines

    init(id: UUID = UUID(), planItemID: UUID, xmlFilename: String, originalURL: URL?, status: TrimResultStatus) {
        self.id = id
        self.planItemID = planItemID
        self.xmlFilename = xmlFilename
        self.originalURL = originalURL
        self.status = status
    }
}

struct TrimProgress {
    var itemIndex: Int = 0
    var itemCount: Int = 0
    var currentFilename: String = ""
    var currentFraction: Double = 0    // 0…1 within the current item
    var overallFraction: Double {
        guard itemCount > 0 else { return 0 }
        return (Double(itemIndex) + currentFraction) / Double(itemCount)
    }
}
