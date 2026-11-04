import SwiftUI
import AppKit

/// Trim camera originals down to the ranges actually used across the loaded XMLs (plus handles),
/// without re-encoding. Modeled on DaVinci Resolve's Media Management "trim" mode.
struct TrimMediaSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var sourceRoot: URL? = nil
    @State private var destinationRoot: URL? = nil
    @State private var mirrorFolders = true
    @State private var overwriteExisting = false
    @State private var redlinePath: URL? = UserDefaults.standard.string(forKey: REDlineLocator.userDefaultsKey).map { URL(fileURLWithPath: $0) }
    @State private var artcmdPath: URL? = UserDefaults.standard.string(forKey: ARTCMDLocator.userDefaultsKey).map { URL(fileURLWithPath: $0) }

    @State private var rawSummaries: [MediaUsageSummary] = []
    @State private var scannedFiles: [String: [ScannedFile]] = [:]
    @State private var planItems: [TrimPlanItem] = []
    @State private var isScanning = false
    @State private var isResolving = false
    @State private var isRunning = false
    @State private var progress = TrimProgress()
    @State private var results: [TrimResultItem] = []
    @State private var showResults = false
    @State private var scanTask: Task<Void, Never>? = nil
    @State private var resolveTask: Task<Void, Never>? = nil
    @State private var runTask: Task<Void, Never>? = nil

    private var options: TrimOptions {
        TrimOptions(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            mirrorFolders: mirrorFolders,
            overwriteExisting: overwriteExisting,
            handles: appState.sourcesExportOptions.handles,
            mergeThreshold: appState.sourcesExportOptions.mergeThreshold,
            redlinePath: redlinePath,
            artcmdPath: artcmdPath
        )
    }

    private var registry: TrimEngineRegistry { TrimEngineRegistry(options: options) }

    private var readyCount: Int { planItems.filter { $0.status == .ready }.count }
    private var copyWholeCount: Int { planItems.filter { if case .copyWhole = $0.status { return true }; return false }.count }
    private var unmatchedCount: Int { planItems.filter { $0.status == .unmatched }.count }
    private var invalidCount: Int { planItems.filter { if case .invalid = $0.status { return true }; return false }.count }
    private var originalBytes: Int64 { planItems.compactMap { $0.selectedCandidate?.fileSize }.reduce(0, +) }
    private var estimatedBytes: Int64 { planItems.reduce(0) { $0 + $1.estimatedOutputBytes } }
    private var canRun: Bool {
        destinationRoot != nil && !isScanning && !isResolving && !isRunning && planItems.contains { $0.status.isActionable }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Trim Camera Originals")
                .font(.headline)
                .padding(.top, 4)

            folderRow(label: "Camera originals:", url: sourceRoot, placeholder: "Select the folder containing the RAW camera files") {
                browse(message: "Select the folder containing the camera-original media", canCreate: false) { url in
                    sourceRoot = url
                    triggerRescan()
                }
            }
            folderRow(label: "Trimmed output:", url: destinationRoot, placeholder: "Select a destination folder") {
                browse(message: "Select the destination folder for trimmed media", canCreate: true) { url in
                    destinationRoot = url
                }
            }

            optionsBox

            if showResults {
                resultsList
            } else {
                planList
            }

            summaryBar

            if isRunning {
                VStack(spacing: 4) {
                    ProgressView(value: progress.overallFraction)
                    Text("\(progress.itemIndex + 1) of \(progress.itemCount): \(progress.currentFilename)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack {
                Button(showResults ? "Close" : "Cancel") {
                    runTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if showResults {
                    Button("Copy Report") { copyReport() }
                    Button("Back to Plan") { showResults = false }
                }

                Spacer()

                if isRunning {
                    Button("Stop") { runTask?.cancel() }
                } else if !showResults {
                    Button("Trim Media") { startRun() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canRun)
                }
            }
        }
        .padding()
        .frame(minWidth: 940, idealWidth: 940, maxWidth: .infinity,
               minHeight: 680, idealHeight: 680, maxHeight: .infinity)
        .resizableSheet(minSize: CGSize(width: 940, height: 680))
        .onAppear {
            rawSummaries = SourcesSequenceBuilder.collectUsages(from: appState.documents)
            rebuildPlan()
        }
        .onChange(of: appState.sourcesExportOptions.handles) { rebuildPlan() }
        .onChange(of: appState.sourcesExportOptions.mergeThreshold) { rebuildPlan() }
        .onChange(of: redlinePath) { rebuildPlan() }
        .onChange(of: artcmdPath) { rebuildPlan() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func folderRow(label: String, url: URL?, placeholder: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            if let url {
                Text(url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(url.path)
            } else {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Browse...", action: action)
        }
    }

    private var optionsBox: some View {
        @Bindable var appState = appState
        return GroupBox {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Handles")
                        Slider(
                            value: Binding(
                                get: { Double(appState.sourcesExportOptions.handles) },
                                set: { appState.sourcesExportOptions.handles = Int($0) }
                            ),
                            in: 0...200, step: 1
                        )
                        Text("\(appState.sourcesExportOptions.handles) fr")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Merge gap")
                        Slider(
                            value: Binding(
                                get: { Double(appState.sourcesExportOptions.mergeThreshold) },
                                set: { appState.sourcesExportOptions.mergeThreshold = Int($0) }
                            ),
                            in: 0...500, step: 1
                        )
                        Text("\(appState.sourcesExportOptions.mergeThreshold) fr")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                    Text("Used ranges closer than the merge gap become one file; farther apart become separate _trimNN files.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Mirror folder structure", isOn: $mirrorFolders)
                        .toggleStyle(.checkbox)
                    Toggle("Overwrite existing files", isOn: $overwriteExisting)
                        .toggleStyle(.checkbox)
                    redlineRow
                    artcmdRow
                }
                .frame(width: 330, alignment: .leading)
            }
            .padding(4)
        }
    }

    private var redlineRow: some View {
        HStack(spacing: 6) {
            let located = AppSandbox.isSandboxed ? nil : REDlineLocator.locate(userPath: redlinePath)
            Image(systemName: located != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(located != nil ? .green : .orange)
            if AppSandbox.isSandboxed {
                Text("R3D trimming unavailable in the sandboxed build")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let located {
                Text("REDline: \(located.path)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(located.path)
            } else {
                Text("REDline not found (R3D will be copied whole)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Locate...") { locateREDline() }
                .controlSize(.small)
                .disabled(AppSandbox.isSandboxed)
        }
    }

    private var artcmdRow: some View {
        HStack(spacing: 6) {
            let located = AppSandbox.isSandboxed ? nil : ARTCMDLocator.locate(userPath: artcmdPath)
            Image(systemName: located != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(located != nil ? .green : .orange)
            if AppSandbox.isSandboxed {
                Text("ARRI MXF trimming unavailable in the sandboxed build")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let located {
                Text("ART CMD: \(located.path)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(located.path)
            } else {
                Text("ART CMD not found (MXF will be copied whole)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Locate...") { locateARTCMD() }
                .controlSize(.small)
                .disabled(AppSandbox.isSandboxed)
        }
    }

    private var planList: some View {
        Group {
            if isScanning {
                ProgressView("Scanning camera originals...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rawSummaries.isEmpty {
                Text("No media with usable source ranges in the loaded XMLs.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sourceRoot == nil {
                Text("Select the camera-originals folder to match sources.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(planItems.enumerated()), id: \.element.id) { index, item in
                        TrimPlanRow(item: item, isResolving: isResolving) { candidateIndex in
                            planItems[index].selectedCandidateIndex = candidateIndex
                            planItems[index].userConfirmed = true
                            resolveItems()
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private var resultsList: some View {
        List {
            ForEach(results) { result in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(result.status.isFailure ? Color.red : (result.status == .trimmed ? Color.green : Color.orange))
                            .frame(width: 8, height: 8)
                        Text(result.xmlFilename)
                            .frame(width: 220, alignment: .leading)
                            .lineLimit(1)
                        Text(result.status.label)
                            .font(.caption)
                            .foregroundStyle(result.status.isFailure ? .red : .secondary)
                        Spacer()
                        if result.framesWritten > 0 {
                            Text("\(result.framesWritten) fr" + (result.extraFrames > 0 ? " (+\(result.extraFrames) snap)" : ""))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(formatBytes(result.bytesWritten))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    ForEach(result.outputs, id: \.self) { url in
                        Text(url.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.leading, 16)
                    }
                    ForEach(Array(result.messages.enumerated()), id: \.offset) { _, msg in
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                    }
                    if let cmd = result.commandLine {
                        Text(cmd)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .padding(.leading, 16)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            if showResults {
                let trimmed = results.filter { $0.status == .trimmed }.count
                let copied = results.filter { $0.status == .copiedWhole }.count
                let failed = results.filter { $0.status.isFailure }.count
                let skipped = results.count - trimmed - copied - failed
                Label("\(trimmed) trimmed", systemImage: "scissors").foregroundStyle(.green)
                if copied > 0 { Label("\(copied) copied whole", systemImage: "doc.on.doc").foregroundStyle(.orange) }
                if skipped > 0 { Label("\(skipped) skipped", systemImage: "minus.circle").foregroundStyle(.secondary) }
                if failed > 0 { Label("\(failed) failed", systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                Spacer()
                Text("Written: \(formatBytes(results.reduce(0) { $0 + $1.bytesWritten }))")
                    .foregroundStyle(.secondary)
            } else if !planItems.isEmpty {
                Label("\(readyCount) to trim", systemImage: "scissors").foregroundStyle(.green)
                if copyWholeCount > 0 { Label("\(copyWholeCount) copy whole", systemImage: "doc.on.doc").foregroundStyle(.orange) }
                if unmatchedCount > 0 { Label("\(unmatchedCount) unmatched", systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                if invalidCount > 0 { Label("\(invalidCount) invalid", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                if isResolving { ProgressView().controlSize(.small) }
                Spacer()
                Text("Est. \(formatBytes(estimatedBytes)) of \(formatBytes(originalBytes))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
    }

    // MARK: - Actions

    private func browse(message: String, canCreate: Bool, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreate
        panel.message = message
        panel.prompt = "Select Folder"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    private func locateREDline() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Select the REDline executable (inside REDCINE-X PRO.app/Contents/MacOS)"
        panel.prompt = "Use REDline"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            redlinePath = url
            UserDefaults.standard.set(url.path, forKey: REDlineLocator.userDefaultsKey)
        }
    }

    private func locateARTCMD() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Select the art-cmd executable (ARRI Reference Tool, command line)"
        panel.prompt = "Use ART CMD"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            artcmdPath = url
            UserDefaults.standard.set(url.path, forKey: ARTCMDLocator.userDefaultsKey)
        }
    }

    private func triggerRescan() {
        guard let root = sourceRoot else { return }
        scanTask?.cancel()
        scanTask = Task {
            isScanning = true
            let files = await FileScanner.scan(directory: root, extensionFilter: nil)
            guard !Task.isCancelled else { return }
            scannedFiles = files
            isScanning = false
            rebuildPlan()
        }
    }

    /// Re-merge ranges with the current handles/threshold, re-match originals, keep user picks, then probe.
    private func rebuildPlan() {
        guard !scannedFiles.isEmpty else {
            planItems = []
            return
        }
        var summaries = rawSummaries
        SourcesSequenceBuilder.applyHandlesAndMerge(
            summaries: &summaries,
            handles: appState.sourcesExportOptions.handles,
            mergeThreshold: appState.sourcesExportOptions.mergeThreshold
        )
        let confirmed: [String: URL] = Dictionary(
            planItems.filter { $0.userConfirmed }.compactMap { item in
                item.selectedCandidate.map { (item.xmlFilename, $0.url) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        var items = OriginalMediaMatcher.match(summaries: summaries, scanned: scannedFiles)
        for i in items.indices {
            if let url = confirmed[items[i].xmlFilename],
               let idx = items[i].candidates.firstIndex(where: { $0.url == url }) {
                items[i].selectedCandidateIndex = idx
                items[i].userConfirmed = true
            }
        }
        planItems = items
        resolveItems()
    }

    private func resolveItems() {
        resolveTask?.cancel()
        let registry = self.registry
        let snapshot = planItems
        resolveTask = Task {
            isResolving = true
            var resolved = snapshot
            for i in resolved.indices {
                if Task.isCancelled { return }
                await TrimPlanner.resolve(item: &resolved[i], registry: registry)
            }
            guard !Task.isCancelled else { return }
            planItems = resolved
            isResolving = false
        }
    }

    private func startRun() {
        guard destinationRoot != nil else { return }
        let items = planItems
        let opts = options
        let registry = self.registry
        let sourceAccess = sourceRoot?.startAccessingSecurityScopedResource() ?? false
        let destAccess = destinationRoot?.startAccessingSecurityScopedResource() ?? false

        isRunning = true
        results = []
        progress = TrimProgress(itemIndex: 0, itemCount: items.filter { $0.status.isActionable }.count)

        runTask = Task {
            let output = await TrimRunner.run(items: items, options: opts, registry: registry) { p in
                Task { @MainActor in progress = p }
            }
            await MainActor.run {
                if sourceAccess { sourceRoot?.stopAccessingSecurityScopedResource() }
                if destAccess { destinationRoot?.stopAccessingSecurityScopedResource() }
                results = output
                isRunning = false
                showResults = true
                let trimmed = output.filter { $0.status == .trimmed }.count
                let failed = output.filter { $0.status.isFailure }.count
                appState.statusMessage = failed == 0
                    ? "Trimmed \(trimmed) of \(output.count) sources"
                    : "Trimmed \(trimmed) sources, \(failed) failed"
            }
        }
    }

    private func copyReport() {
        var lines: [String] = ["Trim report", "Source: \(sourceRoot?.path ?? "-")", "Destination: \(destinationRoot?.path ?? "-")", ""]
        for r in results {
            lines.append("\(r.xmlFilename)\t\(r.status.label)\t\(r.framesWritten) frames\t\(formatBytes(r.bytesWritten))")
            lines.append("  original: \(r.originalURL?.path ?? "-")")
            for url in r.outputs { lines.append("  output: \(url.path)") }
            for m in r.messages { lines.append("  note: \(m)") }
            if let cmd = r.commandLine { lines.append("  cmd: \(cmd)") }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        appState.statusMessage = "Trim report copied to clipboard"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Row

struct TrimPlanRow: View {
    let item: TrimPlanItem
    let isResolving: Bool
    let onSelectCandidate: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(item.xmlFilename)
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)
                .help(item.xmlFilename)

            candidateView
                .frame(maxWidth: .infinity, alignment: .leading)

            if let candidate = item.selectedCandidate {
                badge(candidate.kind.displayName, color: .secondary)
                badge(item.basis.displayName, color: item.basis == .timecode ? .green : .orange)
                    .help(item.basis == .timecode ? "Mapped by source timecode" : "Mapped by frame offset from the file start")
            }

            Text(rangeSummary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
                .help(rangeDetail)

            Text(sizeSummary)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            if !item.warnings.isEmpty {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(item.warnings.joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder
    private var candidateView: some View {
        if item.candidates.count > 1 {
            Menu {
                ForEach(Array(item.candidates.enumerated()), id: \.element.id) { index, candidate in
                    Button {
                        onSelectCandidate(index)
                    } label: {
                        HStack {
                            if index == item.selectedCandidateIndex { Image(systemName: "checkmark") }
                            Text("\(candidate.displayName) — \(candidate.kind.displayName), \(candidate.displaySize)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(item.selectedCandidate?.displayName ?? "Pick original")
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundStyle(item.userConfirmed ? .green : .orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill((item.userConfirmed ? Color.green : Color.orange).opacity(0.1)))
            }
            .menuStyle(.borderlessButton)
        } else if let candidate = item.selectedCandidate {
            Text(candidate.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(candidate.url.path)
        } else {
            Text("No original found")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var rangeSummary: String {
        switch item.status {
        case .ready:
            let frames = item.trimmedFrameCount
            let total = item.probe?.frameCount ?? 0
            let pct = total > 0 ? Int((Double(frames) / Double(total) * 100).rounded()) : 0
            return "\(item.trimRanges.count) rng · \(frames) fr" + (total > 0 ? " (\(pct)%)" : "")
        case .copyWhole:
            return "copy whole"
        case .unmatched:
            return "—"
        case .invalid:
            return "invalid"
        }
    }

    private var rangeDetail: String {
        var lines: [String] = []
        if case .copyWhole(let why) = item.status { lines.append(why) }
        if case .invalid(let why) = item.status { lines.append(why) }
        for r in item.trimRanges {
            lines.append("XML \(r.xmlIn)-\(r.xmlOut) → original \(r.originalIn)-\(r.originalOut) (\(r.length) fr)")
        }
        return lines.joined(separator: "\n")
    }

    private var sizeSummary: String {
        guard item.selectedCandidate != nil, item.status.isActionable else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "≈" + formatter.string(fromByteCount: item.estimatedOutputBytes)
    }

    private var statusColor: Color {
        switch item.status {
        case .ready: return isResolving ? .gray : .green
        case .copyWhole: return .orange
        case .unmatched, .invalid: return .red
        }
    }
}
