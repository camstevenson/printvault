import SwiftUI
import AppKit

struct SlicerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var slicerService: SlicerService
    var isEmbeddedInSettingsWindow: Bool = false

    @State private var newSlicerName: String = ""
    @State private var newSlicerPath: String = ""
    @State private var newSlicerArgs: String = "{file}"
    @State private var newUseDirectCLI: Bool = false
    @State private var showAddCustomSheet: Bool = false
    @State private var hookTestResult: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Slicer Integrations & Automation Hooks")
                        .font(.title3.weight(.semibold))
                    Text("Configure Bambu Studio, OrcaSlicer, PrusaSlicer, Cura, LycheeSlicer, CLI flags, URL schemes, and shell hooks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isEmbeddedInSettingsWindow {
                    Button("Done") {
                        slicerService.saveConfiguration()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Section 1: Slicer Profiles
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Configured Slicers", systemImage: "printer.fill")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    slicerService.rescanInstalledSlicers()
                                } label: {
                                    Label("Rescan Installed", systemImage: "arrow.clockwise")
                                }
                                .controlSize(.small)

                                Button {
                                    showAddCustomSheet = true
                                } label: {
                                    Label("Add Custom Slicer / CLI", systemImage: "plus")
                                }
                                .controlSize(.small)
                            }

                            ForEach($slicerService.profiles) { $profile in
                                SlicerProfileRow(
                                    profile: $profile,
                                    isDefault: slicerService.defaultSlicerId == profile.id,
                                    isInstalled: slicerService.isInstalled(profile),
                                    onPathChanged: { updated in
                                        slicerService.refreshInstallationStatus(for: updated)
                                    },
                                    onSetDefault: {
                                        slicerService.defaultSlicerId = profile.id
                                        slicerService.saveConfiguration()
                                    },
                                    onDelete: {
                                        slicerService.removeProfile(id: profile.id)
                                    }
                                )
                                Divider()
                            }
                        }
                        .padding(8)
                    }

                    // Section 2: Automation Hooks
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Send-to-Slicer Hooks", systemImage: "bolt.horizontal.circle.fill")
                                .font(.headline)

                            Toggle(
                                "Automatically update model Print Status when sent to slicer",
                                isOn: $slicerService.hookConfig.autoUpdateStatusOnSend
                            )

                            if slicerService.hookConfig.autoUpdateStatusOnSend {
                                Picker("Target Status on Send:", selection: $slicerService.hookConfig.targetStatusOnSend) {
                                    ForEach(PrintStatus.allCases) { status in
                                        Text(status.label).tag(status)
                                    }
                                }
                                .frame(maxWidth: 280)
                                .padding(.leading, 20)
                            }

                            Toggle(
                                "Sync Category & Tags to macOS Finder Tags before sending",
                                isOn: $slicerService.hookConfig.syncFinderTagsOnSend
                            )

                            Divider()

                            // Pre-Slice Shell Hook
                            Toggle(
                                "Run Pre-Slice Shell Command Hook",
                                isOn: $slicerService.hookConfig.enablePreSliceShellHook
                            )
                            if slicerService.hookConfig.enablePreSliceShellHook {
                                HStack(spacing: 6) {
                                    TextField(
                                        "e.g. echo \"Slicing {name} in {slicer}\" >> ~/slicer.log",
                                        text: $slicerService.hookConfig.preSliceShellCommand
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))

                                    Button("Test") {
                                        Task {
                                            let (ok, cmd, out) = await slicerService.testShellHook(
                                                template: slicerService.hookConfig.preSliceShellCommand
                                            )
                                            hookTestResult = "\(ok ? "OK" : "FAILED"): \(cmd)" + (out.isEmpty ? "" : "\nOutput: \(out)")
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(slicerService.hookConfig.preSliceShellCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }

                            // Post-Slice Shell Hook
                            Toggle(
                                "Run Post-Slice Shell Command Hook",
                                isOn: $slicerService.hookConfig.enablePostSliceShellHook
                            )
                            if slicerService.hookConfig.enablePostSliceShellHook {
                                HStack(spacing: 6) {
                                    TextField(
                                        "e.g. /usr/local/bin/notify-printer --file {file} --category {category}",
                                        text: $slicerService.hookConfig.postSliceShellCommand
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))

                                    Button("Test") {
                                        Task {
                                            let (ok, cmd, out) = await slicerService.testShellHook(
                                                template: slicerService.hookConfig.postSliceShellCommand
                                            )
                                            hookTestResult = "\(ok ? "OK" : "FAILED"): \(cmd)" + (out.isEmpty ? "" : "\nOutput: \(out)")
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(slicerService.hookConfig.postSliceShellCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }

                            // URL Scheme / Shortcuts Hook
                            Toggle(
                                "Open URL Scheme / Apple Shortcut Hook after sending",
                                isOn: $slicerService.hookConfig.enableURLSchemeHook
                            )
                            if slicerService.hookConfig.enableURLSchemeHook {
                                TextField(
                                    "e.g. shortcuts://run-shortcut?name=LogPrint&input={name}",
                                    text: $slicerService.hookConfig.urlSchemeTemplate
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            }

                            if let hookTestResult {
                                HStack(alignment: .top, spacing: 6) {
                                    Text(hookTestResult)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        self.hookTestResult = nil
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }

                            Text("Tokens (safely quoted in shell hooks): `{file}`, `{files}`, `{dir}`, `{name}`, `{ext}`, `{category}`, `{tags}`, `{slicer}`")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }

                    // Section 3: Recent Hook Activity Log
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Recent Slicer Hook Activity", systemImage: "clock.arrow.circlepath")
                                .font(.headline)

                            if slicerService.recentEvents.isEmpty {
                                Text("No files sent to a slicer in this session yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 6)
                            } else {
                                ForEach(slicerService.recentEvents.prefix(10)) { event in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: event.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                            .foregroundStyle(event.succeeded ? .green : .red)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(event.slicerName)
                                                    .font(.caption.weight(.semibold))
                                                Text("• \(event.fileNames.joined(separator: ", "))")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text(event.timestamp, style: .time)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            Text(event.commandDescription)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            Text(event.message)
                                                .font(.caption2)
                                                .foregroundStyle(event.succeeded ? Color.secondary : Color.red)
                                            if let output = event.hookOutput, !output.isEmpty {
                                                Text(output)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(3)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                        .padding(8)
                    }
                }
                .padding()
            }
        }
        .frame(width: 700, height: 640)
        .onChange(of: slicerService.profiles) { _, _ in
            slicerService.saveConfiguration()
        }
        .onChange(of: slicerService.hookConfig) { _, _ in
            slicerService.saveConfiguration()
        }
        .onDisappear {
            slicerService.saveConfiguration()
        }
        .sheet(isPresented: $showAddCustomSheet) {
            addCustomSlicerSheet
        }
    }

    private var addCustomSlicerSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Custom Slicer or CLI Hook")
                .font(.headline)

            TextField("Display Name (e.g. CHITUBOX, IdeaMaker, Custom Script)", text: $newSlicerName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Application or Executable Path (e.g. /Applications/CHITUBOX.app)", text: $newSlicerPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url {
                        newSlicerPath = url.path
                        if newSlicerName.isEmpty {
                            newSlicerName = url.deletingPathExtension().lastPathComponent
                        }
                    }
                }
            }

            TextField("CLI Arguments Template (default: {file})", text: $newSlicerArgs)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Toggle("Invoke inner binary directly with CLI arguments", isOn: $newUseDirectCLI)
                .font(.caption)

            HStack {
                Spacer()
                Button("Cancel") {
                    showAddCustomSheet = false
                }
                Button("Add Slicer") {
                    guard !newSlicerName.isEmpty, !newSlicerPath.isEmpty else { return }
                    slicerService.addCustomProfile(
                        name: newSlicerName,
                        appPath: newSlicerPath,
                        cliArgumentsTemplate: newSlicerArgs,
                        useDirectCLIExecution: newUseDirectCLI
                    )
                    newSlicerName = ""
                    newSlicerPath = ""
                    newSlicerArgs = "{file}"
                    newUseDirectCLI = false
                    showAddCustomSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newSlicerName.isEmpty || newSlicerPath.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - SlicerProfileRow

private struct SlicerProfileRow: View {
    @Binding var profile: SlicerProfile
    let isDefault: Bool
    let isInstalled: Bool
    let onPathChanged: (SlicerProfile) -> Void
    let onSetDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: profile.iconSystemName)
                    .font(.title3)
                    .foregroundStyle(Color(hex: profile.accentHex) ?? .accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.subheadline.weight(.semibold))

                        if isInstalled {
                            Text("Detected")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.18))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        } else {
                            Text("Not Installed")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }

                        if isDefault {
                            Text("Default Slicer")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        TextField("App Path", text: $profile.appPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onChange(of: profile.appPath) { _, _ in
                                onPathChanged(profile)
                            }
                        Button("Locate...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            if panel.runModal() == .OK, let url = panel.url {
                                profile.appPath = url.path
                            }
                        }
                        .controlSize(.small)
                    }
                }

                Spacer()

                if !isDefault {
                    Button("Set Default") {
                        onSetDefault()
                    }
                    .controlSize(.small)
                }

                if !profile.isBuiltIn {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Text("CLI Hook Args:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
                TextField("{file}", text: $profile.cliArgumentsTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption2, design: .monospaced))
                Toggle("Direct CLI", isOn: $profile.useDirectCLIExecution)
                    .font(.caption2)
                    .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, 4)
    }
}
