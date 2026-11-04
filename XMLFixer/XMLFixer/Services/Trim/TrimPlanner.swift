import Foundation

/// Turns usage summaries + matched originals into concrete frame ranges on the originals.
enum TrimPlanner {

    /// Timecode-first mapping of XML file-relative ranges onto the original's frames.
    /// Pure and unit-tested. Returns the ranges, the basis used and any warnings.
    static func mapRanges(
        mergedRanges: [SourceRange],
        xmlTimebase: Int,
        xmlStartTimecode: Timecode?,
        probe: TrimSourceProbe
    ) -> (ranges: [TrimRange], basis: TrimRangeBasis, warnings: [String]) {
        var warnings: [String] = []
        let xmlTB = max(1, xmlTimebase)
        let origTB = max(1, probe.timebase)
        let frameCount = probe.frameCount
        let basis: TrimRangeBasis
        let shift: Int  // in *original* frames, added after rate conversion

        if let xmlTC = xmlStartTimecode, let origTC = probe.startTimecode {
            basis = .timecode
            let xmlStartInOrig = QuickTimeTrimEngine.convertFrames(xmlTC.totalFrames, from: xmlTB, to: origTB)
            let origStart = QuickTimeTrimEngine.convertFrames(origTC.totalFrames, from: origTC.timebase, to: origTB)
            shift = xmlStartInOrig - origStart
        } else {
            basis = .offset
            shift = 0
            if probe.startTimecode == nil {
                warnings.append("Original has no timecode; mapped by frame offset")
            } else {
                warnings.append("XML has no source timecode; mapped by frame offset")
            }
        }
        if xmlTB != origTB {
            warnings.append("Rate differs (XML \(xmlTB) fps, original \(origTB) fps); frames converted")
        }

        let dayFrames = 24 * 3600 * origTB
        var ranges: [TrimRange] = []
        for r in mergedRanges {
            var inFrame = QuickTimeTrimEngine.convertFrames(r.inPoint, from: xmlTB, to: origTB) + shift
            var outFrame = QuickTimeTrimEngine.convertFrames(r.outPoint, from: xmlTB, to: origTB) + shift

            // Timecode wrapping across midnight
            if basis == .timecode, frameCount > 0 {
                if outFrame <= 0 && outFrame + dayFrames > 0 && inFrame + dayFrames < frameCount {
                    inFrame += dayFrames; outFrame += dayFrames
                } else if inFrame >= frameCount && inFrame - dayFrames >= 0 && inFrame - dayFrames < frameCount {
                    inFrame -= dayFrames; outFrame -= dayFrames
                }
            }

            let clampedIn = max(0, inFrame)
            let clampedOut = frameCount > 0 ? min(frameCount, outFrame) : outFrame
            if clampedOut <= clampedIn {
                warnings.append("Range \(r.inPoint)-\(r.outPoint) falls outside the original (mapped \(inFrame)-\(outFrame))")
                continue
            }
            if clampedIn != inFrame || clampedOut != outFrame {
                warnings.append("Range \(r.inPoint)-\(r.outPoint) clipped to the original's bounds")
            }
            ranges.append(TrimRange(originalIn: clampedIn, originalOut: clampedOut, xmlIn: r.inPoint, xmlOut: r.outPoint))
        }
        return (ranges, basis, warnings)
    }

    /// Probe the selected candidate and compute its trim ranges. Mutates `item` in place.
    static func resolve(item: inout TrimPlanItem, registry: TrimEngineRegistry) async {
        item.warnings = []
        item.trimRanges = []
        item.probe = nil

        guard let candidate = item.selectedCandidate else {
            item.status = .unmatched
            return
        }
        guard !item.mergedRanges.isEmpty else {
            item.status = .invalid("No used ranges")
            return
        }

        let (engine, reason) = registry.engine(for: candidate.kind)
        guard engine != nil else {
            item.status = .copyWhole(reason ?? "Unsupported")
            return
        }

        let xmlTC = item.xmlStartTimecode.flatMap { Timecode.parse($0, timebase: item.xmlTimebase) }
        var probe: TrimSourceProbe

        switch candidate.kind {
        case .quickTime:
            do {
                probe = try await registry.quickTime.probe(url: candidate.url)
            } catch {
                item.status = .copyWhole("Unreadable by AVFoundation: \(error.localizedDescription)")
                return
            }
        case .imageSequence:
            guard let seq = candidate.sequence else {
                item.status = .invalid("Sequence not enumerated")
                return
            }
            probe = TrimSourceProbe(timebase: item.xmlTimebase, ntsc: item.xmlNtsc, frameCount: seq.frameCount, startTimecode: nil, isAllIntra: true)
            // If the XML names a frame that exists in the sequence, treat it as the XML's frame 0.
            if let parsed = ImageSequenceInfo.parse(filename: item.xmlFilename),
               let idx = seq.index(ofFrameNumber: parsed.number), idx > 0 {
                let shifted = item.mergedRanges.map {
                    SourceRange(inPoint: $0.inPoint + idx, outPoint: $0.outPoint + idx, speedFactor: $0.speedFactor)
                }
                let mapped = mapRanges(mergedRanges: shifted, xmlTimebase: item.xmlTimebase, xmlStartTimecode: nil, probe: probe)
                item.probe = probe
                item.basis = .offset
                item.trimRanges = mapped.ranges
                item.warnings = ["XML starts at frame \(parsed.number) (index \(idx) of the sequence)"] + mapped.warnings.filter { !$0.contains("no timecode") }
                item.status = mapped.ranges.isEmpty ? .invalid("Ranges outside sequence") : .ready
                return
            }
            probe.notes.append("Image sequences are mapped by frame index from the first file")
        case .r3d:
            guard let redline = registry.redline else {
                item.status = .copyWhole(reason ?? "REDline unavailable")
                return
            }
            probe = await redline.probe(url: candidate.url, fallbackTimebase: item.xmlTimebase)
        case .mxf:
            guard let artcmd = registry.artcmd else {
                item.status = .copyWhole(reason ?? "ART CMD unavailable")
                return
            }
            probe = await artcmd.probe(url: candidate.url, fallbackTimebase: item.xmlTimebase)
            if probe.frameCount == 0 && probe.startTimecode == nil {
                // Not an ARRI MXF, or art-cmd could not read it: copying whole beats a bad trim.
                item.status = .copyWhole("art-cmd could not read this MXF")
                return
            }
        case .stillImage, .unsupported:
            item.status = .copyWhole(reason ?? "Unsupported")
            return
        }

        var mapped = mapRanges(mergedRanges: item.mergedRanges, xmlTimebase: item.xmlTimebase, xmlStartTimecode: xmlTC, probe: probe)
        if mapped.basis == .timecode, mapped.ranges.count < item.mergedRanges.count,
           let alternate = probe.alternateStartTimecode {
            // e.g. the edit referenced RED edge code rather than absolute TC
            var altProbe = probe
            altProbe.startTimecode = alternate
            let altMapped = mapRanges(mergedRanges: item.mergedRanges, xmlTimebase: item.xmlTimebase, xmlStartTimecode: xmlTC, probe: altProbe)
            if altMapped.ranges.count > mapped.ranges.count {
                mapped = altMapped
                mapped.warnings.append("Mapped with \(probe.alternateTimecodeLabel); the primary timecode did not contain the XML ranges")
                probe = altProbe
            }
        }
        item.probe = probe
        item.basis = mapped.basis
        item.trimRanges = mapped.ranges
        item.warnings = probe.notes + mapped.warnings
        if mapped.ranges.isEmpty {
            item.status = .invalid("All ranges fall outside the original")
        } else if probe.frameCount > 0 && item.trimmedFrameCount >= probe.frameCount {
            item.status = .copyWhole("Entire clip is used")
        } else {
            item.status = .ready
        }
    }
}
