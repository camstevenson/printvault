import SwiftUI
import SwiftData
import AppKit
import os

final class PrintVaultAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PrintVaultApp: App {
    private static let logger = Logger(subsystem: "com.printvault.PrintVault", category: "App")

    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(PrintVaultAppDelegate.self) private var appDelegate
    let sharedModelContainer: ModelContainer
    let persistenceWarning: String?

    init() {
        // Enforce single running instance BEFORE opening SwiftData SQLite store
        SingleInstanceGuard.shared.enforceSingleInstanceOrTerminate()
        let (container, warning) = Self.makeModelContainer()
        self.sharedModelContainer = container
        self.persistenceWarning = warning
        NSApplication.shared.setActivationPolicy(.regular)
        #if SWIFT_PACKAGE
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
        #endif
    }

    private static func makeModelContainer() -> (ModelContainer, String?) {
        let schema = Schema([
            PrintFileItem.self,
            PrintCategory.self,
            WatchedFolder.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            return (container, nil)
        } catch {
            logger.fault("Failed to open persistent SwiftData store: \(error.localizedDescription, privacy: .public). Falling back to temporary in-memory store.")
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                let container = try ModelContainer(for: schema, configurations: [fallbackConfig])
                let warning = "Library database could not be opened (\(error.localizedDescription)). Running in temporary in-memory mode — changes will not be saved when you quit."
                return (container, warning)
            } catch let fallbackError {
                fatalError("Unable to initialize SwiftData ModelContainer (persistent: \(error), fallback: \(fallbackError))")
            }
        }
    }

    var body: some Scene {
        Window("PrintVault — 3D Print Library & Slicer Hub", id: "main") {
            ContentView(persistenceWarning: persistenceWarning)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About PrintVault") {
                    openWindow(id: "about")
                }
            }

            CommandGroup(replacing: .saveItem) {}

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

        Window("About PrintVault", id: "about") {
            AboutView()
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            SlicerSettingsView(
                slicerService: SlicerService.shared,
                isEmbeddedInSettingsWindow: true
            )
        }
    }
}
