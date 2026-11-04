import SwiftUI

@main
struct XMLFixerApp: App {
    @State private var appState = AppState()

    static let buildVersion = "V014-mxf"
    static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Republic Wash & Cut") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Republic Wash & Cut",
                        .applicationVersion: Self.appVersion,
                        .version: Self.buildVersion,
                        .credits: NSAttributedString(
                            string: "Build \(Self.buildVersion)\nFCP XML batch processing tool",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 11),
                                .foregroundColor: NSColor.secondaryLabelColor
                            ]
                        )
                    ])
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    appState.undo()
                }
                .keyboardShortcut("z")
                .disabled(!appState.canUndo)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open XML Files...") {
                    appState.isShowingImportPanel = true
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Select All Media") {
                    appState.selectAllVisibleMedia()
                }
                .keyboardShortcut("a")
                .disabled(!appState.hasDocuments)

                Button("Deselect All") {
                    appState.deselectAllMedia()
                }
                .keyboardShortcut("d")
                .disabled(appState.selectedMediaIDs.isEmpty)
            }
        }
        .defaultSize(width: 1000, height: 650)
    }
}
