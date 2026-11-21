import SwiftUI
import SwiftData
import AppKit

@main
struct PrintVaultApp: App {
    let sharedModelContainer: ModelContainer

    init() {
        // Enforce single running instance BEFORE opening SwiftData SQLite store
        SingleInstanceGuard.shared.enforceSingleInstanceOrTerminate()
        self.sharedModelContainer = Self.makeModelContainer()
        NSApplication.shared.setActivationPolicy(.regular)
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            PrintFileItem.self,
            PrintCategory.self,
            WatchedFolder.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [fallbackConfig])
        }
    }

    var body: some Scene {
        Window("PrintVault — 3D Print Library & Slicer Hub", id: "main") {
            ContentView()
                .frame(minWidth: 1080, minHeight: 680)
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import 3D Files or Folder...") {
                    NotificationCenter.default.post(name: .printVaultImportFiles, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Scan Watched Folders & Spotlight") {
                    NotificationCenter.default.post(name: .printVaultScanFiles, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }

            CommandMenu("Model") {
                Button("Send Selected to Default Slicer") {
                    NotificationCenter.default.post(name: .printVaultSendSelectedToSlicer, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("Expand 3D Preview") {
                    NotificationCenter.default.post(name: .printVaultExpandPreview, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Settings {
            SlicerSettingsView(
                slicerService: SlicerService.shared,
                isEmbeddedInSettingsWindow: true
            )
        }
    }
}
