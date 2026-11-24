import Foundation
import AppKit
import Observation
import os

// MARK: - Slicer Hook Protocol & Pipeline Types

public enum SlicerHookStage: String, Sendable {
    case preSlice = "Pre-Slice"
    case postSlice = "Post-Slice"
}

public struct SlicerHookContext: @unchecked Sendable {
    public let items: [PrintFileItem]
    public let profile: SlicerProfile
    public let slicerLaunched: Bool

    public init(items: [PrintFileItem], profile: SlicerProfile, slicerLaunched: Bool = false) {
        self.items = items
        self.profile = profile
        self.slicerLaunched = slicerLaunched
    }
}

public struct SlicerHookResult: Sendable {
    public let hookName: String
    public let succeeded: Bool
    public let output: String?

    public init(hookName: String, succeeded: Bool, output: String? = nil) {
        self.hookName = hookName
        self.succeeded = succeeded
        self.output = output
    }
}

/// Extensible hook interface allowing custom Swift or external automations to run before/after sending models to a slicer.
@MainActor
public protocol SlicerHook: Sendable {
    var id: String { get }
    var name: String { get }
    var stage: SlicerHookStage { get }
    func execute(context: SlicerHookContext) async -> SlicerHookResult
}

// MARK: - Slicer Profile

public struct SlicerProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundleIdentifier: String?
    public var appPath: String
    public var alternateAppPaths: [String]
    public var cliArgumentsTemplate: String // e.g., "{file}" or "--slice {file}"
    public var useDirectCLIExecution: Bool
    public var isBuiltIn: Bool
    public var iconSystemName: String
    public var accentHex: String

    public init(
        id: String,
        name: String,
        bundleIdentifier: String?,
        appPath: String,
        alternateAppPaths: [String] = [],
        cliArgumentsTemplate: String = "{file}",
        useDirectCLIExecution: Bool = false,
        isBuiltIn: Bool = false,
        iconSystemName: String = "printer.fill",
        accentHex: String = "#3B82F6"
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.alternateAppPaths = alternateAppPaths
        self.cliArgumentsTemplate = cliArgumentsTemplate
        self.useDirectCLIExecution = useDirectCLIExecution
        self.isBuiltIn = isBuiltIn
        self.iconSystemName = iconSystemName
        self.accentHex = accentHex
    }

    // Backwards-compatible decoding when alternateAppPaths wasn't stored previously
    enum CodingKeys: String, CodingKey {
        case id, name, bundleIdentifier, appPath, alternateAppPaths
        case cliArgumentsTemplate, useDirectCLIExecution, isBuiltIn
        case iconSystemName, accentHex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        appPath = try c.decode(String.self, forKey: .appPath)
        alternateAppPaths = try c.decodeIfPresent([String].self, forKey: .alternateAppPaths) ?? []
        cliArgumentsTemplate = try c.decode(String.self, forKey: .cliArgumentsTemplate)
        useDirectCLIExecution = try c.decode(Bool.self, forKey: .useDirectCLIExecution)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        iconSystemName = try c.decode(String.self, forKey: .iconSystemName)
        accentHex = try c.decode(String.self, forKey: .accentHex)
    }

    public var appURL: URL {
        URL(fileURLWithPath: appPath)
    }

    public var isInstalled: Bool {
        resolvedAppURL != nil || FileManager.default.isExecutableFile(atPath: appPath)
    }

    public var resolvedAppURL: URL? {
        if FileManager.default.fileExists(atPath: appPath) {
            return URL(fileURLWithPath: appPath)
        }
        for alt in alternateAppPaths {
            if FileManager.default.fileExists(atPath: alt) {
                return URL(fileURLWithPath: alt)
            }
        }
        if let bundleId = bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return url
        }
        return nil
    }

    /// Resolves the inner binary inside `.app/Contents/MacOS/` when CLI arguments are used
    public var resolvedExecutableURL: URL? {
        guard let url = resolvedAppURL else {
            return FileManager.default.isExecutableFile(atPath: appPath) ? URL(fileURLWithPath: appPath) : nil
        }
        if url.pathExtension == "app",
           let bundle = Bundle(url: url),
           let execURL = bundle.executableURL {
            return execURL
        }
        return url
    }

    public static let builtInPresets: [SlicerProfile] = [
        SlicerProfile(
            id: "bambu-studio",
            name: "Bambu Studio",
            bundleIdentifier: "com.bambulab.bambu-studio",
            appPath: "/Applications/BambuStudio.app",
            alternateAppPaths: ["/Applications/Bambu Studio.app"],
            cliArgumentsTemplate: "{file}",
            useDirectCLIExecution: false,
            isBuiltIn: true,
            iconSystemName: "cube.transparent.fill",
            accentHex: "#10B981"
        ),
        SlicerProfile(
            id: "orcaslicer",
            name: "OrcaSlicer",
            bundleIdentifier: "com.softfever3d.orcaslicer",
            appPath: "/Applications/OrcaSlicer.app",
            alternateAppPaths: ["/Applications/Orca Slicer.app"],
            cliArgumentsTemplate: "{file}",
            useDirectCLIExecution: false,
            isBuiltIn: true,
            iconSystemName: "waveform.path.ecg.rectangle.fill",
            accentHex: "#06B6D4"
        ),
        SlicerProfile(
            id: "prusaslicer",
            name: "PrusaSlicer",
            bundleIdentifier: "com.prusa3d.slic3r",
            appPath: "/Applications/PrusaSlicer.app",
            alternateAppPaths: [
                "/Applications/Original Prusa Drivers/PrusaSlicer.app",
                "/Applications/PrusaSlicer/PrusaSlicer.app"
            ],
            cliArgumentsTemplate: "{file}",
            useDirectCLIExecution: false,
            isBuiltIn: true,
            iconSystemName: "flame.circle.fill",
            accentHex: "#F97316"
        ),
        SlicerProfile(
            id: "superslicer",
            name: "SuperSlicer",
            bundleIdentifier: "com.merill.superslicer",
            appPath: "/Applications/SuperSlicer.app",
            alternateAppPaths: [],
            cliArgumentsTemplate: "{file}",
            useDirectCLIExecution: false,
            isBuiltIn: true,
            iconSystemName: "bolt.circle.fill",
            accentHex: "#8B5CF6"
        ),
        SlicerProfile(
            id: "ultimaker-cura",
            name: "UltiMaker Cura",
            bundleIdentifier: "nl.ultimaker.cura",
            appPath: "/Applications/UltiMaker Cura.app",
            alternateAppPaths: ["/Applications/Ultimaker Cura.app", "/Applications/Cura.app"],
            cliArgumentsTemplate: "{file}",
            useDirectCLIExecution: false,
            isBuiltIn: true,
            iconSystemName: "circle.hexagongrid.fill",
            accentHex: "#3B82F6"
        ),
        SlicerProfile(
            id: "lychee-slicer",
            name: "LycheeSlicer",
            bundleIdentifier: "com.mango3d.lycheeslicer",
            appPath: "/Applications/LycheeSlicer.app",
            alternateAppPaths: ["/Applications/Lychee Slicer.app"],
            cliArgumentsTemplate: "{file}",
            useDirectCLIExecution: false,
            isBuiltIn: true,
            iconSystemName: "drop.triangle.fill",
            accentHex: "#EC4899"
        )
    ]
}

// MARK: - Slicer Hook Configuration

public struct SlicerHookConfiguration: Codable, Equatable, Sendable {
    public var autoUpdateStatusOnSend: Bool = true
    public var targetStatusOnSend: PrintStatus = .queued
    public var syncFinderTagsOnSend: Bool = true
    public var enablePreSliceShellHook: Bool = false
    public var preSliceShellCommand: String = ""
    public var enablePostSliceShellHook: Bool = false
    public var postSliceShellCommand: String = ""
    public var enableURLSchemeHook: Bool = false
    public var urlSchemeTemplate: String = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case autoUpdateStatusOnSend, targetStatusOnSend, syncFinderTagsOnSend
        case enablePreSliceShellHook, preSliceShellCommand
        case enablePostSliceShellHook, postSliceShellCommand
        case enableURLSchemeHook, urlSchemeTemplate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoUpdateStatusOnSend = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateStatusOnSend) ?? true
        targetStatusOnSend = try c.decodeIfPresent(PrintStatus.self, forKey: .targetStatusOnSend) ?? .queued
        syncFinderTagsOnSend = try c.decodeIfPresent(Bool.self, forKey: .syncFinderTagsOnSend) ?? true
        enablePreSliceShellHook = try c.decodeIfPresent(Bool.self, forKey: .enablePreSliceShellHook) ?? false
        preSliceShellCommand = try c.decodeIfPresent(String.self, forKey: .preSliceShellCommand) ?? ""
        enablePostSliceShellHook = try c.decodeIfPresent(Bool.self, forKey: .enablePostSliceShellHook) ?? false
        postSliceShellCommand = try c.decodeIfPresent(String.self, forKey: .postSliceShellCommand) ?? ""
        enableURLSchemeHook = try c.decodeIfPresent(Bool.self, forKey: .enableURLSchemeHook) ?? false
        urlSchemeTemplate = try c.decodeIfPresent(String.self, forKey: .urlSchemeTemplate) ?? ""
    }
}

// MARK: - Slicer Launch Log Entry

public struct SlicerHookEvent: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let slicerName: String
    public let fileNames: [String]
    public let commandDescription: String
    public let succeeded: Bool
    public let message: String
    public let hookOutput: String?
}

// MARK: - SlicerService

@MainActor
@Observable
public final class SlicerService {
    public static let shared = SlicerService()

    private static let logger = Logger(subsystem: "com.printvault.PrintVault", category: "SlicerService")
    private let profilesDefaultsKey = "PrintVault.SlicerProfiles.v1"
    private let defaultSlicerIdKey = "PrintVault.DefaultSlicerId.v1"
    private let hookConfigKey = "PrintVault.SlicerHookConfig.v1"

    public var profiles: [SlicerProfile] = []
    public var defaultSlicerId: String = "bambu-studio"
    public var hookConfig: SlicerHookConfiguration = SlicerHookConfiguration()
    public var recentEvents: [SlicerHookEvent] = []
    public var lastStatusBanner: String?
    public var detectionRefreshCount: Int = 0
    public private(set) var installedProfileIDs: Set<String> = []

    /// Registered programmatic Swift hooks (executed alongside configured shell/URL hooks)
    private var registeredHooks: [any SlicerHook] = []

    public init(loadPersisted: Bool = true) {
        if loadPersisted {
            loadConfiguration()
        } else {
            profiles = SlicerProfile.builtInPresets
        }
    }

    public func isInstalled(_ profile: SlicerProfile) -> Bool {
        installedProfileIDs.contains(profile.id)
    }

    public func refreshInstallationStatus(for profile: SlicerProfile) {
        if profile.isInstalled {
            installedProfileIDs.insert(profile.id)
        } else {
            installedProfileIDs.remove(profile.id)
        }
    }

    public func registerHook(_ hook: any SlicerHook) {
        registeredHooks.removeAll { $0.id == hook.id }
        registeredHooks.append(hook)
    }

    public func unregisterHook(id: String) {
        registeredHooks.removeAll { $0.id == id }
    }

    public var defaultProfile: SlicerProfile {
        if let match = profiles.first(where: { $0.id == defaultSlicerId }) {
            return match
        }
        if let installed = profiles.first(where: { installedProfileIDs.contains($0.id) }) {
            return installed
        }
        return profiles.first ?? SlicerProfile.builtInPresets[0]
    }

    public var installedProfiles: [SlicerProfile] {
        profiles.filter { installedProfileIDs.contains($0.id) }
    }

    // MARK: - Persistence & Detection

    public func loadConfiguration() {
        if let data = UserDefaults.standard.data(forKey: profilesDefaultsKey),
           var decoded = try? JSONDecoder().decode([SlicerProfile].self, from: data),
           !decoded.isEmpty {
            // Merge alternateAppPaths & new built-in presets into saved config
            for preset in SlicerProfile.builtInPresets {
                if let idx = decoded.firstIndex(where: { $0.id == preset.id }) {
                    if decoded[idx].alternateAppPaths.isEmpty {
                        decoded[idx].alternateAppPaths = preset.alternateAppPaths
                    }
                    if decoded[idx].id == "prusaslicer" && decoded[idx].bundleIdentifier == "com.prusa3d.prusaslicer" {
                        decoded[idx].bundleIdentifier = preset.bundleIdentifier
                    }
                } else {
                    decoded.append(preset)
                }
            }
            profiles = decoded
        } else {
            profiles = SlicerProfile.builtInPresets
        }

        // Auto-sync resolved paths for built-in slicers found in alternate paths
        rescanInstalledSlicers(save: false)

        if let savedDefault = UserDefaults.standard.string(forKey: defaultSlicerIdKey),
           profiles.contains(where: { $0.id == savedDefault }) {
            defaultSlicerId = savedDefault
        } else if let firstInstalled = profiles.first(where: { $0.isInstalled }) {
            defaultSlicerId = firstInstalled.id
        }

        if let hookData = UserDefaults.standard.data(forKey: hookConfigKey),
           let decodedHook = try? JSONDecoder().decode(SlicerHookConfiguration.self, from: hookData) {
            hookConfig = decodedHook
        }
    }

    public func rescanInstalledSlicers(save: Bool = true) {
        var detected = Set<String>()
        for idx in profiles.indices {
            if !FileManager.default.fileExists(atPath: profiles[idx].appPath),
               let resolved = profiles[idx].resolvedAppURL {
                profiles[idx].appPath = resolved.path
            }
            if profiles[idx].isInstalled {
                detected.insert(profiles[idx].id)
            }
        }
        installedProfileIDs = detected
        if !installedProfileIDs.contains(defaultProfile.id),
           let firstInstalled = profiles.first(where: { installedProfileIDs.contains($0.id) }) {
            defaultSlicerId = firstInstalled.id
        }
        detectionRefreshCount += 1
        if save {
            saveConfiguration()
        }
    }

    public func saveConfiguration() {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: profilesDefaultsKey)
        } catch {
            Self.logger.error("Failed to encode slicer profiles: \(error.localizedDescription, privacy: .public)")
        }
        UserDefaults.standard.set(defaultSlicerId, forKey: defaultSlicerIdKey)
        do {
            let hookData = try JSONEncoder().encode(hookConfig)
            UserDefaults.standard.set(hookData, forKey: hookConfigKey)
        } catch {
            Self.logger.error("Failed to encode slicer hook config: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func addCustomProfile(
        name: String,
        appPath: String,
        cliArgumentsTemplate: String = "{file}",
        useDirectCLIExecution: Bool = false
    ) {
        let profile = SlicerProfile(
            id: "custom-\(UUID().uuidString.prefix(8))",
            name: name,
            bundleIdentifier: nil,
            appPath: appPath,
            alternateAppPaths: [],
            cliArgumentsTemplate: cliArgumentsTemplate.isEmpty ? "{file}" : cliArgumentsTemplate,
            useDirectCLIExecution: useDirectCLIExecution,
            isBuiltIn: false,
            iconSystemName: "terminal.fill",
            accentHex: "#EC4899"
        )
        profiles.append(profile)
        if profile.isInstalled {
            installedProfileIDs.insert(profile.id)
        }
        saveConfiguration()
    }

    public func updateProfile(_ updated: SlicerProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == updated.id }) {
            profiles[idx] = updated
            if updated.isInstalled {
                installedProfileIDs.insert(updated.id)
            } else {
                installedProfileIDs.remove(updated.id)
            }
            saveConfiguration()
        }
    }

    public func removeProfile(id: String) {
        profiles.removeAll { $0.id == id && !$0.isBuiltIn }
        installedProfileIDs.remove(id)
        if defaultSlicerId == id, let first = profiles.first {
            defaultSlicerId = first.id
        }
        saveConfiguration()
    }

    // MARK: - Send to Slicer & Hook Pipeline

    @discardableResult
    public func sendToSlicer(
        items: [PrintFileItem],
        using profile: SlicerProfile? = nil
    ) async -> Bool {
        let validItems = items.filter { $0.fileExistsOnDisk }
        guard !validItems.isEmpty else {
            recordEvent(
                slicerName: profile?.name ?? "Slicer",
                fileNames: items.map(\.fileName),
                command: "validate",
                succeeded: false,
                message: "File no longer exists on disk.",
                hookOutput: nil
            )
            return false
        }

        let targetProfile = profile ?? defaultProfile
        let fileURLs = validItems.map(\.fileURL)
        var hookLogs: [String] = []

        // 1. Pre-slice Finder Tag Sync Hook
        if hookConfig.syncFinderTagsOnSend {
            for item in validItems {
                FinderTagService.syncToFinder(for: item)
            }
        }

        // 2. Registered Programmatic Pre-Slice Hooks
        let preCtx = SlicerHookContext(items: validItems, profile: targetProfile, slicerLaunched: false)
        for hook in registeredHooks where hook.stage == .preSlice {
            let res = await hook.execute(context: preCtx)
            if let out = res.output, !out.isEmpty {
                hookLogs.append("[\(res.hookName)] \(out)")
            }
        }

        // 3. Pre-slice Custom Shell Hook
        if hookConfig.enablePreSliceShellHook && !hookConfig.preSliceShellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cmd = Self.expandPlaceholders(
                template: hookConfig.preSliceShellCommand,
                items: validItems,
                slicerName: targetProfile.name
            )
            let (ok, output) = await Self.executeShellCommand(cmd)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            hookLogs.append("[Pre-Hook \(ok ? "OK" : "FAIL")] \(trimmed.isEmpty ? cmd : trimmed)")
        }

        // 4. Launch Slicer (App Bundle open or CLI with custom arguments)
        let (launched, cmdDesc, message) = await launchSlicerProcess(
            profile: targetProfile,
            items: validItems,
            fileURLs: fileURLs
        )

        // 5. Update item tracking & status hooks
        if launched {
            let now = Date()
            for item in validItems {
                item.lastSentToSlicerDate = now
                item.lastUsedSlicerName = targetProfile.name
                item.sliceCount += 1
                if hookConfig.autoUpdateStatusOnSend && item.printStatus == .unprinted {
                    item.printStatus = hookConfig.targetStatusOnSend
                }
            }
        }

        // 6. URL Scheme / Shortcuts / Webhook Hook
        if launched && hookConfig.enableURLSchemeHook && !hookConfig.urlSchemeTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expandedURLStr = Self.expandURLTemplate(
                template: hookConfig.urlSchemeTemplate,
                items: validItems,
                slicerName: targetProfile.name
            )
            if let hookURL = URL(string: expandedURLStr) {
                let opened = NSWorkspace.shared.open(hookURL)
                hookLogs.append("[URL Hook \(opened ? "OK" : "FAIL")] \(expandedURLStr)")
            } else {
                hookLogs.append("[URL Hook FAIL] Invalid URL: \(expandedURLStr)")
            }
        }

        // 7. Post-slice Custom Shell Hook
        if launched && hookConfig.enablePostSliceShellHook && !hookConfig.postSliceShellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cmd = Self.expandPlaceholders(
                template: hookConfig.postSliceShellCommand,
                items: validItems,
                slicerName: targetProfile.name
            )
            let (ok, output) = await Self.executeShellCommand(cmd)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            hookLogs.append("[Post-Hook \(ok ? "OK" : "FAIL")] \(trimmed.isEmpty ? cmd : trimmed)")
        }

        // 8. Registered Programmatic Post-Slice Hooks
        let postCtx = SlicerHookContext(items: validItems, profile: targetProfile, slicerLaunched: launched)
        for hook in registeredHooks where hook.stage == .postSlice {
            let res = await hook.execute(context: postCtx)
            if let out = res.output, !out.isEmpty {
                hookLogs.append("[\(res.hookName)] \(out)")
            }
        }

        let combinedOutput = hookLogs.isEmpty ? nil : hookLogs.joined(separator: "\n")
        recordEvent(
            slicerName: targetProfile.name,
            fileNames: validItems.map(\.fileName),
            command: cmdDesc,
            succeeded: launched,
            message: message,
            hookOutput: combinedOutput
        )
        return launched
    }

    /// Tests a shell hook template against a sample or real model path and returns `(succeeded, expandedCommand, output)`.
    public func testShellHook(template: String, sampleItem: PrintFileItem? = nil) async -> (Bool, String, String) {
        let testItems: [PrintFileItem]
        if let sampleItem {
            testItems = [sampleItem]
        } else {
            testItems = [
                PrintFileItem(
                    filePath: "/Users/Shared/Sample_Benchy.stl",
                    fileName: "Sample_Benchy.stl",
                    fileExtension: "stl",
                    fileSize: 102400,
                    dateModified: Date(),
                    discoverySource: .manual,
                    tags: ["PLA", "Test"]
                )
            ]
        }
        let expanded = Self.expandPlaceholders(template: template, items: testItems, slicerName: defaultProfile.name)
        let (ok, output) = await Self.executeShellCommand(expanded)
        return (ok, expanded, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func launchSlicerProcess(
        profile: SlicerProfile,
        items: [PrintFileItem],
        fileURLs: [URL]
    ) async -> (Bool, String, String) {
        // Mode A: Direct CLI execution or custom CLI flags
        let hasCustomArgs = profile.cliArgumentsTemplate.trimmingCharacters(in: .whitespaces) != "{file}"
        if profile.useDirectCLIExecution || hasCustomArgs {
            if let execURL = profile.resolvedExecutableURL {
                let expandedArgs = Self.buildCLIArguments(template: profile.cliArgumentsTemplate, items: items)
                let cmdDesc = "\(Self.shellEscape(execURL.path)) " + expandedArgs.map { Self.shellEscape($0) }.joined(separator: " ")
                do {
                    let proc = Process()
                    proc.executableURL = execURL
                    proc.arguments = expandedArgs
                    try proc.run()
                    return (true, cmdDesc, "Launched \(profile.name) via CLI hook.")
                } catch {
                    return (false, cmdDesc, "CLI launch failed: \(error.localizedDescription)")
                }
            } else {
                // Treat appPath + cliArgumentsTemplate as a shell command template
                let fullTemplate = "\(profile.appPath) \(profile.cliArgumentsTemplate)"
                let cmd = Self.expandPlaceholders(template: fullTemplate, items: items, slicerName: profile.name)
                let (ok, output) = await Self.executeShellCommand(cmd)
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    ok,
                    cmd,
                    ok
                        ? (detail.isEmpty ? "Executed custom slicer command." : "Executed: \(detail)")
                        : (detail.isEmpty ? "Custom slicer command failed." : "Failed: \(detail)")
                )
            }
        }

        // Mode B: Standard macOS Application Bundle Open (`NSWorkspace`)
        if let appURL = profile.resolvedAppURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let cmdDesc = "open -a \(Self.shellEscape(appURL.path)) " + fileURLs.map { Self.shellEscape($0.path) }.joined(separator: " ")
            do {
                _ = try await NSWorkspace.shared.open(fileURLs, withApplicationAt: appURL, configuration: config)
                return (true, cmdDesc, "Sent \(fileURLs.count) file(s) to \(profile.name).")
            } catch {
                return (false, cmdDesc, "Failed to open \(profile.name): \(error.localizedDescription)")
            }
        } else {
            // Fallback: try `/usr/bin/open -a <Name>` off the main actor
            let args = ["-a", profile.name] + fileURLs.map(\.path)
            let cmdDesc = "open -a \(Self.shellEscape(profile.name)) " + fileURLs.map { Self.shellEscape($0.path) }.joined(separator: " ")
            let (ok, output) = await Self.runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: args
            )
            if ok {
                return (true, cmdDesc, "Opened in \(profile.name).")
            }

            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = detail.isEmpty
                ? "\(profile.name) was not found at \(profile.appPath). Configure its path in Slicer Hooks Settings."
                : "\(profile.name) could not be opened: \(detail)"
            return (false, cmdDesc, msg)
        }
    }

    // MARK: - Safe Placeholder Expansion & Shell Escaping

    /// Query-value character set that also percent-encodes `&`, `=`, `+`, and `?` so values like
    /// `"Organizers & Gridfinity"` never break URL query parameter parsing.
    private nonisolated static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        return allowed
    }()

    /// Escapes a string safely for POSIX shells (`zsh` / `sh`) using single-quote wrapping.
    public nonisolated static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func expandPlaceholders(template: String, items: [PrintFileItem], slicerName: String) -> String {
        guard let primary = items.first else { return template }
        let quotedFiles = items.map { shellEscape($0.filePath) }.joined(separator: " ")
        var result = template
        result = result.replacingOccurrences(of: "{files}", with: quotedFiles)
        result = result.replacingOccurrences(of: "{file}", with: shellEscape(primary.filePath))
        result = result.replacingOccurrences(of: "{dir}", with: shellEscape(primary.fileURL.deletingLastPathComponent().path))
        result = result.replacingOccurrences(of: "{name}", with: shellEscape(primary.displayTitle))
        result = result.replacingOccurrences(of: "{ext}", with: shellEscape(primary.fileExtension))
        result = result.replacingOccurrences(of: "{category}", with: shellEscape(primary.category?.name ?? "Uncategorized"))
        result = result.replacingOccurrences(of: "{tags}", with: shellEscape(primary.tags.joined(separator: ",")))
        result = result.replacingOccurrences(of: "{slicer}", with: shellEscape(slicerName))
        return result
    }

    public static func expandURLTemplate(template: String, items: [PrintFileItem], slicerName: String) -> String {
        guard let primary = items.first else { return template }
        let encode: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: urlQueryValueAllowed) ?? $0
        }
        var result = template
        result = result.replacingOccurrences(of: "{files}", with: encode(items.map(\.filePath).joined(separator: ",")))
        result = result.replacingOccurrences(of: "{file}", with: encode(primary.filePath))
        result = result.replacingOccurrences(of: "{dir}", with: encode(primary.fileURL.deletingLastPathComponent().path))
        result = result.replacingOccurrences(of: "{name}", with: encode(primary.displayTitle))
        result = result.replacingOccurrences(of: "{ext}", with: encode(primary.fileExtension))
        result = result.replacingOccurrences(of: "{category}", with: encode(primary.category?.name ?? "Uncategorized"))
        result = result.replacingOccurrences(of: "{tags}", with: encode(primary.tags.joined(separator: ",")))
        result = result.replacingOccurrences(of: "{slicer}", with: encode(slicerName))
        return result
    }

    public static func buildCLIArguments(template: String, items: [PrintFileItem]) -> [String] {
        guard let primary = items.first else { return [] }
        let parts = template.split(whereSeparator: \.isWhitespace).map(String.init)
        var args: [String] = []
        for token in parts {
            switch token {
            case "{file}", "{files}":
                args.append(contentsOf: items.map(\.filePath))
            case "{dir}":
                args.append(primary.fileURL.deletingLastPathComponent().path)
            case "{name}":
                args.append(primary.displayTitle)
            case "{ext}":
                args.append(primary.fileExtension)
            case "{category}":
                args.append(primary.category?.name ?? "Uncategorized")
            case "{tags}":
                args.append(primary.tags.joined(separator: ","))
            default:
                args.append(
                    token
                        .replacingOccurrences(of: "{file}", with: primary.filePath)
                        .replacingOccurrences(of: "{dir}", with: primary.fileURL.deletingLastPathComponent().path)
                        .replacingOccurrences(of: "{name}", with: primary.displayTitle)
                )
            }
        }
        return args
    }

    public nonisolated static func executeShellCommand(_ command: String) async -> (Bool, String) {
        await runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", command]
        )
    }

    /// Runs a child process without blocking Swift's cooperative thread pool, draining stdout and stderr
    /// concurrently to prevent pipe buffer deadlocks and terminating the process if the task is cancelled.
    public nonisolated static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) async -> (Bool, String) {
        guard !Task.isCancelled else { return (false, "Cancelled") }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        final class OutputCollector: @unchecked Sendable {
            private let lock = NSLock()
            var outData = Data()
            var errData = Data()
            var terminationStatus: Int32 = -1

            func setOut(_ data: Data) {
                lock.lock()
                outData = data
                lock.unlock()
            }

            func setErr(_ data: Data) {
                lock.lock()
                errData = data
                lock.unlock()
            }

            func setStatus(_ status: Int32) {
                lock.lock()
                terminationStatus = status
                lock.unlock()
            }

            func finish() -> (Bool, String) {
                lock.lock()
                let status = terminationStatus
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                lock.unlock()
                let combined = [outStr, errStr].filter { !$0.isEmpty }.joined(separator: "\n")
                return (status == 0, combined)
            }
        }

        let collector = OutputCollector()
        let group = DispatchGroup()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                group.enter() // process exit
                proc.terminationHandler = { process in
                    collector.setStatus(process.terminationStatus)
                    group.leave()
                }

                do {
                    try proc.run()
                } catch {
                    proc.terminationHandler = nil
                    group.leave()
                    continuation.resume(returning: (false, error.localizedDescription))
                    return
                }

                // Close parent write ends so pipe readers see EOF as soon as child exits
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()

                group.enter() // stdout drain
                DispatchQueue.global(qos: .utility).async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    try? outPipe.fileHandleForReading.close()
                    collector.setOut(data)
                    group.leave()
                }

                group.enter() // stderr drain
                DispatchQueue.global(qos: .utility).async {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    try? errPipe.fileHandleForReading.close()
                    collector.setErr(data)
                    group.leave()
                }

                group.notify(queue: DispatchQueue.global(qos: .utility)) {
                    continuation.resume(returning: collector.finish())
                }
            }
        } onCancel: {
            if proc.isRunning {
                proc.terminate()
            }
        }
    }

    private func recordEvent(
        slicerName: String,
        fileNames: [String],
        command: String,
        succeeded: Bool,
        message: String,
        hookOutput: String?
    ) {
        let event = SlicerHookEvent(
            timestamp: Date(),
            slicerName: slicerName,
            fileNames: fileNames,
            commandDescription: command,
            succeeded: succeeded,
            message: message,
            hookOutput: hookOutput
        )
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 50 {
            recentEvents.removeLast()
        }
        lastStatusBanner = message
    }
}
