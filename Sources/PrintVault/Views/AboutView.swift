import SwiftUI
import SwiftData
import AppKit
import Metal

// MARK: - About Tab

private enum AboutTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case shortcuts = "Shortcuts"
    case system = "System"
    case license = "License"

    var id: String { rawValue }
}

// MARK: - AboutView

struct AboutView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [PrintFileItem]
    @Query private var categories: [PrintCategory]
    @Query private var watchedFolders: [WatchedFolder]

    private let slicerService = SlicerService.shared

    @State private var selectedTab: AboutTab = .overview
    @State private var copiedVersion = false
    @State private var copiedDiagnostics = false
    @State private var databaseSizeBytes: Int64?
    @State private var thumbnailCacheBytes: Int64?

    private static let repoURL = URL(string: "https://github.com/camstevenson/printvault")!
    private static let issuesURL = URL(string: "https://github.com/camstevenson/printvault/issues")!

    // MARK: - App & System Metadata

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }

    private var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    private var launchEnvironment: String {
        #if SWIFT_PACKAGE
        return "Swift Package Manager"
        #else
        return "macOS Application Bundle"
        #endif
    }

    private var cpuArchitecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "Intel (x86_64)"
        #else
        return "Unknown"
        #endif
    }

    private var shortArchBadge: String {
        #if arch(arm64)
        return "Apple Silicon"
        #elseif arch(x86_64)
        return "Intel"
        #else
        return "macOS"
        #endif
    }

    private var macOSVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private var metalGPUName: String {
        MTLCreateSystemDefaultDevice()?.name ?? "Unavailable"
    }

    private var physicalMemoryString: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
            countStyle: .memory
        )
    }

    private var installedSlicers: [SlicerProfile] {
        slicerService.profiles.filter { slicerService.isInstalled($0) }
    }

    private var totalIndexedBytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.fileSize }
    }

    private var totalLibrarySizeString: String {
        ByteCountFormatter.string(fromByteCount: totalIndexedBytes, countStyle: .file)
    }

    private var databaseSizeString: String {
        guard let bytes = databaseSizeBytes else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var thumbnailCacheSizeString: String {
        guard let bytes = thumbnailCacheBytes else { return "Calculating…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var stlCount: Int {
        items.filter { $0.format == .stl }.count
    }

    private var threeMFCount: Int {
        items.filter { $0.format == .threemf }.count
    }

    private var printedCount: Int {
        items.filter { $0.printStatus == .printed }.count
    }

    private var appIconImage: NSImage {
        NSApplication.shared.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            heroHeader

            Divider()

            Group {
                switch selectedTab {
                case .overview:
                    overviewTab
                case .shortcuts:
                    shortcutsTab
                case .system:
                    systemTab
                case .license:
                    licenseTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footerBar
        }
        .frame(width: 600, height: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            let storeURL = modelContext.container.configurations.first?.url
            let sizes = await Self.computeAppStorageSizes(storeURL: storeURL)
            databaseSizeBytes = sizes.databaseBytes
            thumbnailCacheBytes = sizes.cacheBytes
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Image(nsImage: appIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("PrintVault")
                            .font(.system(size: 26, weight: .bold, design: .rounded))

                        Button {
                            copyToPasteboard("PrintVault \(appVersion) (Build \(buildNumber))")
                            withAnimation(.easeInOut(duration: 0.15)) {
                                copiedVersion = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    copiedVersion = false
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(copiedVersion ? "Copied!" : "v\(appVersion) (\(buildNumber))")
                                    .font(.caption.monospaced().weight(.medium))
                                Image(systemName: copiedVersion ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(copiedVersion ? Color.green.opacity(0.18) : Color.secondary.opacity(0.14))
                            )
                            .foregroundStyle(copiedVersion ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Click to copy version and build number")
                    }

                    Text("Native macOS 3D Print Library, Preview & Slicer Hub")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        AboutBadge(text: shortArchBadge, systemImage: "cpu", tint: .blue)
                        AboutBadge(text: "Swift 6 & Metal", systemImage: "cube.transparent.fill", tint: Color(red: 0.16, green: 0.72, blue: 0.46))
                        AboutBadge(text: "STL & 3MF", systemImage: "doc.zipper", tint: .orange)
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }

            Picker("About Section", selection: $selectedTab) {
                ForEach(AboutTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.72, blue: 0.46).opacity(0.10),
                    Color(nsColor: .windowBackgroundColor).opacity(0.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Overview Tab

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PrintVault discovers, indexes, previews, and organizes your local .stl and .3mf 3D printing library with hardware-accelerated Metal rendering, local VLM auto-categorization, native Finder tag sync, and an extensible send-to-slicer hook pipeline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Live Library Snapshot
                VStack(alignment: .leading, spacing: 8) {
                    Text("YOUR LIBRARY SNAPSHOT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.6)

                    HStack(spacing: 10) {
                        LibraryStatCard(
                            title: "Models",
                            value: "\(items.count)",
                            subtitle: "",
                            systemImage: "cube.fill",
                            tint: Color(red: 0.16, green: 0.72, blue: 0.46)
                        )
                        LibraryStatCard(
                            title: "Indexed on Disk",
                            value: totalLibrarySizeString,
                            subtitle: "Including model files",
                            systemImage: "doc.on.doc.fill",
                            tint: .blue
                        )
                        .help("Combined size of your indexed .stl and .3mf files in their original locations on disk. PrintVault only indexes references and never duplicates your models.")
                        LibraryStatCard(
                            title: "Printed",
                            value: "\(printedCount)",
                            subtitle: "",
                            systemImage: "checkmark.seal.fill",
                            tint: .orange
                        )
                        LibraryStatCard(
                            title: "Slicers",
                            value: "\(installedSlicers.count)",
                            subtitle: "",
                            systemImage: "printer.fill",
                            tint: .purple
                        )
                    }
                }

                // Core Capabilities Grid
                VStack(alignment: .leading, spacing: 8) {
                    Text("CORE CAPABILITIES")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.6)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        FeatureHighlightCard(
                            icon: "magnifyingglass.circle.fill",
                            tint: .blue,
                            title: "Spotlight & Folder Discovery",
                            detail: "Indexes .stl and .3mf files across watched folders and Spotlight with project-aware grouping."
                        )
                        FeatureHighlightCard(
                            icon: "view.3d",
                            tint: Color(red: 0.16, green: 0.72, blue: 0.46),
                            title: "Interactive Metal 3D Preview",
                            detail: "Orbit, pan, zoom, switch filament shaders, inspect wireframes, and expand full-window previews."
                        )
                        FeatureHighlightCard(
                            icon: "scalemass.fill",
                            tint: .orange,
                            title: "Mesh & Filament Estimates",
                            detail: "Native binary/ASCII STL & 3MF parsers compute dimensions, volume, PLA weight, and filament length."
                        )
                        FeatureHighlightCard(
                            icon: "sparkles",
                            tint: .purple,
                            title: "Local AI Categorization",
                            detail: "Classifies models privately via Ollama, LM Studio, or MLX-VLM using neutral studio 3D renders."
                        )
                        FeatureHighlightCard(
                            icon: "bolt.horizontal.circle.fill",
                            tint: .teal,
                            title: "Slicer Profiles & Hooks",
                            detail: "Direct send to Bambu, Orca, Prusa, Cura, or Lychee with pre/post shell scripts and Shortcuts hooks."
                        )
                        FeatureHighlightCard(
                            icon: "tag.fill",
                            tint: .pink,
                            title: "Native Finder Tag Sync",
                            detail: "Two-way synchronization with macOS Finder tags alongside print status, ratings, and notes."
                        )
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(spacing: 0) {
                        ShortcutRow(action: "Send Selected Model(s) to Default Slicer", keys: ["⌘", "↩"])
                        Divider().padding(.vertical, 6)
                        ShortcutRow(action: "Scan Watched Folders & Spotlight", keys: ["⌘", "R"])
                        Divider().padding(.vertical, 6)
                        ShortcutRow(action: "Import 3D Files or Folder", keys: ["⌘", "I"])
                        Divider().padding(.vertical, 6)
                        ShortcutRow(action: "Expand Interactive 3D Preview", keys: ["⇧", "⌘", "P"])
                        Divider().padding(.vertical, 6)
                        ShortcutRow(action: "Slicer Integrations & Hooks Settings", keys: ["⌘", ","])
                    }
                    .padding(6)
                } label: {
                    Label("Keyboard Shortcuts", systemImage: "keyboard.fill")
                        .font(.subheadline.weight(.semibold))
                }

                GroupBox {
                    VStack(spacing: 0) {
                        ControlRow(gesture: "Left-Click + Drag", description: "Orbit camera around the 3D model")
                        Divider().padding(.vertical, 6)
                        ControlRow(gesture: "Right-Click or ⌥ + Left-Drag", description: "Pan / move model 1:1 with cursor")
                        Divider().padding(.vertical, 6)
                        ControlRow(gesture: "Scroll Wheel or Pinch", description: "Smooth zoom in and out")
                        Divider().padding(.vertical, 6)
                        ControlRow(gesture: "Double-Click Model Card", description: "Open expanded 3D preview sheet")
                        Divider().padding(.vertical, 6)
                        ControlRow(gesture: "⌘-Click Cards or Rows", description: "Multi-select for batch categorize or slice")
                    }
                    .padding(6)
                } label: {
                    Label("3D Viewport & Browser Controls", systemImage: "cursorarrow.motionlines")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(20)
        }
    }

    // MARK: - System Tab

    private var systemTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(spacing: 0) {
                        SystemInfoRow(label: "App Version", value: "\(appVersion) (Build \(buildNumber))")
                        Divider().padding(.vertical, 6)
                        SystemInfoRow(label: "Runtime", value: launchEnvironment)
                        Divider().padding(.vertical, 6)
                        SystemInfoRow(label: "Operating System", value: macOSVersionString)
                        Divider().padding(.vertical, 6)
                        SystemInfoRow(label: "Architecture", value: cpuArchitecture)
                        Divider().padding(.vertical, 6)
                        SystemInfoRow(label: "Metal GPU", value: metalGPUName)
                        Divider().padding(.vertical, 6)
                        SystemInfoRow(label: "System Memory", value: physicalMemoryString)
                        Divider().padding(.vertical, 6)
                        SystemInfoRow(label: "Library Database", value: databaseSizeString)
                        Divider().padding(.vertical, 6)
                        SystemInfoRow(label: "Thumbnail Cache", value: thumbnailCacheSizeString)
                    }
                    .padding(6)
                } label: {
                    Label("Environment & Engine", systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.semibold))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if installedSlicers.isEmpty {
                            Text("No supported slicers were auto-detected. You can add custom .app bundles or CLI executables in Settings (⌘,).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            FlowChipRow(items: installedSlicers.map { profile in
                                let isDefault = profile.id == slicerService.defaultSlicerId
                                return isDefault ? "\(profile.name) (Default)" : profile.name
                            }, tint: Color(red: 0.16, green: 0.72, blue: 0.46))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: {
                    Label("Detected Slicers (\(installedSlicers.count))", systemImage: "printer.fill")
                        .font(.subheadline.weight(.semibold))
                }

                GroupBox {
                    FlowChipRow(
                        items: ["Swift 6", "SwiftUI", "SwiftData", "SceneKit", "Metal", "ImageIO", "Spotlight"],
                        tint: .blue
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: {
                    Label("Built With Native Apple Frameworks", systemImage: "hammer.fill")
                        .font(.subheadline.weight(.semibold))
                }

                HStack(spacing: 10) {
                    Button {
                        copyDiagnostics()
                    } label: {
                        Label(
                            copiedDiagnostics ? "Diagnostics Copied" : "Copy Diagnostics for Bug Report",
                            systemImage: copiedDiagnostics ? "checkmark.circle.fill" : "doc.on.clipboard"
                        )
                    }
                    .controlSize(.regular)

                    Button {
                        revealAppSupportFolder()
                    } label: {
                        Label("Reveal Data Folder", systemImage: "folder")
                    }
                    .controlSize(.regular)

                    Spacer()
                }
            }
            .padding(20)
        }
    }

    // MARK: - License Tab

    private var licenseTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MIT License")
                                    .font(.headline)
                                Text("Copyright © 2026 otherslikeyou.com Inc.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Link(destination: Self.repoURL) {
                                Label("Source on GitHub", systemImage: "arrow.up.right.square")
                                    .font(.caption.weight(.medium))
                            }
                        }

                        Divider()

                        Text(Self.mitLicenseText)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PrintVault integrates with your local 3D printing tools and open-weight vision models:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Bambu Studio · OrcaSlicer · PrusaSlicer · SuperSlicer · UltiMaker Cura · LycheeSlicer · Ollama · LM Studio · MLX-VLM")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("All third-party product names and trademarks remain the property of their respective owners.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: {
                    Label("Supported Ecosystem", systemImage: "sparkles.rectangle.stack")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(20)
        }
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: 12) {
            Text("© 2026 otherslikeyou.com Inc. · MIT License")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Link(destination: Self.repoURL) {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.link)

            Link(destination: Self.issuesURL) {
                Label("Report Issue", systemImage: "exclamationmark.bubble")
                    .font(.caption)
            }
            .buttonStyle(.link)

            Button {
                copyDiagnostics()
            } label: {
                Image(systemName: copiedDiagnostics ? "checkmark" : "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(copiedDiagnostics ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy system diagnostics")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    // MARK: - Actions

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func copyDiagnostics() {
        let slicerList = installedSlicers.isEmpty
            ? "None detected"
            : installedSlicers.map(\.name).joined(separator: ", ")

        let summary = """
        ### PrintVault Diagnostics
        - **Version:** \(appVersion) (Build \(buildNumber))
        - **Runtime:** \(launchEnvironment)
        - **OS:** \(macOSVersionString) (\(cpuArchitecture))
        - **Metal GPU:** \(metalGPUName)
        - **Memory:** \(physicalMemoryString)
        - **Library:** \(items.count) models (\(stlCount) STL, \(threeMFCount) 3MF, \(totalLibrarySizeString) indexed on disk), \(categories.count) categories, \(watchedFolders.count) watched folders
        - **App Storage:** Database \(databaseSizeString), Thumbnail Cache \(thumbnailCacheSizeString)
        - **Detected Slicers:** \(slicerList)
        """
        copyToPasteboard(summary)
        withAnimation(.easeInOut(duration: 0.15)) {
            copiedDiagnostics = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeInOut(duration: 0.2)) {
                copiedDiagnostics = false
            }
        }
    }

    private func revealAppSupportFolder() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let printVaultDir = appSupport.appendingPathComponent("PrintVault", isDirectory: true)
        if fm.fileExists(atPath: printVaultDir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([printVaultDir])
        } else {
            NSWorkspace.shared.open(appSupport)
        }
    }

    private nonisolated static func computeAppStorageSizes(storeURL: URL?) async -> (databaseBytes: Int64, cacheBytes: Int64) {
        await Task.detached(priority: .utility) {
            Self.computeAppStorageSizesSync(storeURL: storeURL)
        }.value
    }

    private nonisolated static func computeAppStorageSizesSync(storeURL: URL?) -> (databaseBytes: Int64, cacheBytes: Int64) {
        let fm = FileManager.default

        var dbBytes: Int64 = 0
        if let storeURL {
            let candidatePaths = [
                storeURL.path,
                storeURL.path + "-wal",
                storeURL.path + "-shm"
            ]
            for path in candidatePaths {
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? NSNumber {
                    dbBytes += size.int64Value
                }
            }
        }

        var cacheBytes: Int64 = 0
        if let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let pvCacheDir = cachesDir.appendingPathComponent("PrintVault", isDirectory: true)
            if let enumerator = fm.enumerator(
                at: pvCacheDir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                       values.isRegularFile == true,
                       let size = values.fileSize {
                        cacheBytes += Int64(size)
                    }
                }
            }
        }

        return (dbBytes, cacheBytes)
    }

    private static let mitLicenseText = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

// MARK: - Supporting Subviews

private struct AboutBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(tint.opacity(0.14))
        )
        .foregroundStyle(tint)
    }
}

private struct LibraryStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct FeatureHighlightCard: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ShortcutRow: View {
    let action: String
    let keys: [String]

    var body: some View {
        HStack {
            Text(action)
                .font(.callout)
            Spacer()
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(minWidth: 22, minHeight: 20)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.primary.opacity(0.16), lineWidth: 0.75)
                        )
                }
            }
        }
    }
}

private struct ControlRow: View {
    let gesture: String
    let description: String

    var body: some View {
        HStack {
            Text(gesture)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
            Spacer()
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SystemInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct FlowChipRow: View {
    let items: [String]
    let tint: Color

    var body: some View {
        AboutFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(tint.opacity(0.12))
                    )
                    .foregroundStyle(tint)
            }
        }
    }
}

private struct AboutFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            totalWidth = max(totalWidth, currentX + size.width)
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: totalWidth, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
