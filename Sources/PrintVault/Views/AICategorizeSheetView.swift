import SwiftUI
import SwiftData
import AppKit

enum AICategorizeScope: String, CaseIterable, Identifiable {
    case uncategorized = "Uncategorized"
    case selected = "Selected"
    case all = "All Models"

    var id: String { rawValue }
}

struct AICategorizeSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var vlmService: VLMCategorizerService
    let allItems: [PrintFileItem]
    let selectedItems: [PrintFileItem]
    let categories: [PrintCategory]
    var watchedFolderPaths: [String] = []
    let onRunKeywordFallback: () -> Int

    private enum PendingCancelAction {
        case stopBatch
        case closeSheet
    }

    @State private var scope: AICategorizeScope = .uncategorized
    @State private var maxBatchLimit: Int = 50
    @State private var statusBanner: String?
    @State private var pendingCancelAction: PendingCancelAction?

    private var targetItems: [PrintFileItem] {
        let base: [PrintFileItem]
        switch scope {
        case .uncategorized:
            base = allItems.filter { $0.category == nil }
        case .selected:
            base = selectedItems
        case .all:
            base = allItems
        }
        if maxBatchLimit > 0 && base.count > maxBatchLimit {
            return Array(base.prefix(maxBatchLimit))
        }
        return base
    }

    private var fullScopeCount: Int {
        switch scope {
        case .uncategorized: return allItems.filter { $0.category == nil }.count
        case .selected: return selectedItems.count
        case .all: return allItems.count
        }
    }

    private var selectedSuggestionCount: Int {
        vlmService.suggestions.filter { $0.isSelected && !$0.isApplied }.count
    }

    private var unappliedSuggestionCount: Int {
        vlmService.suggestions.filter { !$0.isApplied && $0.errorMessage == nil }.count
    }

    private var needsCancelConfirmation: Bool {
        vlmService.isRunning || vlmService.isPullingModel || unappliedSuggestionCount > 0
    }

    private var alertTitle: String {
        switch pendingCancelAction {
        case .stopBatch:
            return "Cancel AI Categorization?"
        case .closeSheet:
            if vlmService.isRunning {
                return "Cancel AI Categorization & Close?"
            } else if vlmService.isPullingModel {
                return "Cancel Model Download & Close?"
            } else {
                return "Discard Unapplied Suggestions?"
            }
        case .none:
            return ""
        }
    }

    private var alertMessage: String {
        switch pendingCancelAction {
        case .stopBatch:
            return "AI categorization is currently in progress (\(vlmService.completedCount) of \(vlmService.totalCount) completed). Cancel the remaining models? Suggestions already generated will stay available to review."
        case .closeSheet:
            if vlmService.isRunning {
                return "AI categorization is still running (\(vlmService.completedCount) of \(vlmService.totalCount) completed). Closing now will cancel the remaining models."
            } else if vlmService.isPullingModel {
                return "Downloading the local vision model is still in progress (\(Int(vlmService.pullProgress * 100))%). Closing now will cancel the download."
            } else {
                return "You have \(unappliedSuggestionCount) unapplied AI suggestion\(unappliedSuggestionCount == 1 ? "" : "s"). Closing now will discard them."
            }
        case .none:
            return ""
        }
    }

    private var alertConfirmButtonTitle: String {
        switch pendingCancelAction {
        case .stopBatch:
            return "Cancel Analysis"
        case .closeSheet:
            if vlmService.isRunning || vlmService.isPullingModel {
                return "Cancel & Close"
            }
            return "Close Without Applying"
        case .none:
            return "Confirm"
        }
    }

    private var canRunVLM: Bool {
        !vlmService.isRunning
            && !vlmService.isPullingModel
            && !vlmService.config.selectedModel.isEmpty
            && !targetItems.isEmpty
            && isBackendReady
    }

    private var isBackendReady: Bool {
        if case .connected = vlmService.connectionState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                runtimeSetupCard
                scopeAndOptionsCard

                if vlmService.isRunning || !vlmService.suggestions.isEmpty {
                    resultsSection
                } else {
                    emptyResultsPlaceholder
                }
            }
            .padding(16)

            Divider()
            footerBar
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 620, idealHeight: 680)
        .interactiveDismissDisabled(needsCancelConfirmation)
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { pendingCancelAction != nil },
                set: { if !$0 { pendingCancelAction = nil } }
            )
        ) {
            Button("Keep Going", role: .cancel) {
                pendingCancelAction = nil
            }
            Button(alertConfirmButtonTitle, role: .destructive) {
                let action = pendingCancelAction
                pendingCancelAction = nil
                switch action {
                case .stopBatch:
                    vlmService.cancelBatch()
                    statusBanner = "Cancelled AI categorization."
                case .closeSheet:
                    vlmService.cancelBatch()
                    vlmService.cancelPull()
                    dismiss()
                case .none:
                    break
                }
            }
        } message: {
            Text(alertMessage)
        }
        .task {
            if selectedItems.count > 1 && allItems.filter({ $0.category == nil }).isEmpty {
                scope = .selected
            }
            await vlmService.detectLocalRuntimes()
        }
        .onDisappear {
            vlmService.saveConfiguration()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Auto-Categorize (Local Vision-Language Model)")
                    .font(.headline)
                Text("Renders a neutral 3D clay view + geometry metrics and classifies models locally via Ollama, LM Studio, or MLX-VLM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Close") {
                if needsCancelConfirmation {
                    pendingCancelAction = .closeSheet
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Local VLM Runtime Connection Card

    private var runtimeSetupCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    statusBadge

                    Picker("Runtime", selection: $vlmService.config.backend) {
                        ForEach(VLMBackendKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .controlSize(.small)
                    .onChange(of: vlmService.config.backend) { _, newKind in
                        vlmService.config.baseURL = newKind.defaultBaseURL
                        Task { await vlmService.detectLocalRuntimes(preferCurrentBackend: true) }
                    }

                    TextField("Endpoint URL", text: $vlmService.config.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit {
                            Task { await vlmService.detectLocalRuntimes(preferCurrentBackend: true) }
                        }

                    Button {
                        Task { await vlmService.detectLocalRuntimes(preferCurrentBackend: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Re-detect local VLM runtime & models")
                }

                // Model selector or 1-click Start / Pull helper
                switch vlmService.connectionState {
                case .connected:
                    HStack(spacing: 10) {
                        Text("Vision Model:")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        let displayModels = vlmService.availableVisionModels.isEmpty
                            ? vlmService.availableModels
                            : vlmService.availableVisionModels

                        Picker("Model", selection: $vlmService.config.selectedModel) {
                            ForEach(displayModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                            if !vlmService.availableVisionModels.isEmpty
                                && vlmService.availableModels.count > vlmService.availableVisionModels.count {
                                Divider()
                                ForEach(vlmService.availableModels.filter { !vlmService.availableVisionModels.contains($0) }, id: \.self) { other in
                                    Text("\(other) (text-only?)").tag(other)
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        .controlSize(.small)
                        .onChange(of: vlmService.config.selectedModel) { _, _ in
                            vlmService.saveConfiguration()
                        }

                        if vlmService.config.backend == .ollama
                            && !vlmService.availableModels.contains(where: { $0.lowercased().contains("qwen2.5vl") }) {
                            Button {
                                vlmService.pullOllamaModel()
                            } label: {
                                Label("Pull \(VLMCategorizerService.recommendedOllamaVisionModel)", systemImage: "arrow.down.circle")
                            }
                            .controlSize(.small)
                            .disabled(vlmService.isPullingModel)
                        }

                        Spacer()
                    }

                case .needsVisionModel:
                    HStack(spacing: 10) {
                        Image(systemName: "eye.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(vlmService.config.backend == .ollama
                             ? "Ollama is running, but no vision model was found yet."
                             : "Runtime is reachable, but no model is loaded yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if vlmService.config.backend == .ollama {
                            Button {
                                vlmService.pullOllamaModel()
                            } label: {
                                Label("Download \(VLMCategorizerService.recommendedOllamaVisionModel) (~2.4 GB)", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(vlmService.isPullingModel)
                        }
                    }

                case .offline(let ollamaInstalled, let lmStudioInstalled):
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.slash.fill")
                            .foregroundStyle(.orange)
                        Text("No local VLM server detected on localhost.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if ollamaInstalled {
                            Button {
                                Task { await vlmService.startOllama() }
                            } label: {
                                Label("Start Ollama", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        if lmStudioInstalled {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/LM Studio.app"))
                            } label: {
                                Label("Open LM Studio", systemImage: "arrow.up.forward.app")
                            }
                            .controlSize(.small)
                        }
                    }

                case .checking, .unknown:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking local Ollama & LM Studio servers...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .error(let msg):
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if vlmService.isPullingModel {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: vlmService.pullProgress)
                        HStack {
                            Text(vlmService.pullStatusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(vlmService.pullProgress * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch vlmService.connectionState {
        case .connected:
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Connected").font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.14))
            .clipShape(Capsule())
        case .needsVisionModel:
            HStack(spacing: 5) {
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("No Vision Model").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.14))
            .clipShape(Capsule())
        case .checking, .unknown:
            HStack(spacing: 5) {
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text("Checking").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.14))
            .clipShape(Capsule())
        case .offline, .error:
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Offline").font(.caption.weight(.semibold)).foregroundStyle(.red)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.red.opacity(0.14))
            .clipShape(Capsule())
        }
    }

    // MARK: - Scope & Options Card

    private var scopeAndOptionsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Picker("Scope", selection: $scope) {
                        Text("Uncategorized (\(allItems.filter { $0.category == nil }.count))")
                            .tag(AICategorizeScope.uncategorized)
                        Text("Selected (\(selectedItems.count))")
                            .tag(AICategorizeScope.selected)
                        Text("All (\(allItems.count))")
                            .tag(AICategorizeScope.all)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)

                    Picker("Batch", selection: $maxBatchLimit) {
                        Text("Up to 10").tag(10)
                        Text("Up to 25").tag(25)
                        Text("Up to 50").tag(50)
                        Text("Up to 100").tag(100)
                        Text("All (\(fullScopeCount))").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .controlSize(.small)

                    Spacer()

                    if vlmService.isRunning {
                        Button(role: .destructive) {
                            pendingCancelAction = .stopBatch
                        } label: {
                            Label("Cancel", systemImage: "stop.fill")
                        }
                        .controlSize(.regular)
                    } else {
                        Button {
                            statusBanner = nil
                            vlmService.saveConfiguration()
                            vlmService.startBatchClassification(
                                items: targetItems,
                                existingCategories: categories,
                                context: modelContext,
                                allLibraryItems: allItems,
                                watchedFolderPaths: watchedFolderPaths
                            )
                        } label: {
                            Label("Analyze \(targetItems.count) Model\(targetItems.count == 1 ? "" : "s")", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRunVLM)
                    }
                }

                HStack(spacing: 16) {
                    Toggle("Auto-apply ≥ \(Int(vlmService.config.confidenceThreshold * 100))%", isOn: $vlmService.config.autoApplyHighConfidence)
                    Toggle("Allow new categories", isOn: $vlmService.config.allowNewCategories)
                    Toggle("Add AI tags", isOn: $vlmService.config.applyTags)
                    Toggle("Fill empty notes", isOn: $vlmService.config.fillEmptyNotes)
                }
                .font(.caption)
                .toggleStyle(.checkbox)
            }
            .padding(6)
        }
    }

    // MARK: - Live Progress & Suggestions List

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vlmService.isRunning {
                HStack(spacing: 10) {
                    ProgressView(value: Double(vlmService.completedCount), total: Double(max(vlmService.totalCount, 1)))
                    Text("\(vlmService.completedCount) / \(vlmService.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("Analyzing \(vlmService.currentItemName)...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            List {
                ForEach($vlmService.suggestions) { $suggestion in
                    SuggestionRowView(
                        suggestion: $suggestion,
                        categories: categories
                    )
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private var emptyResultsPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 34))
                .foregroundStyle(.secondary.opacity(0.7))
            Text("Ready to Categorize Visually")
                .font(.subheadline.weight(.semibold))
            Text("PrintVault renders a neutral matte-gray 3D view of each model and combines it with physical millimeter dimensions so the local VLM classifies by shape—even when filenames are cryptic.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer Action Bar

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button {
                let count = onRunKeywordFallback()
                statusBanner = "Keyword rules categorized \(count) model(s)."
            } label: {
                Label("Quick Keyword Match", systemImage: "text.magnifyingglass")
            }
            .controlSize(.small)
            .help("Run instant filename/folder keyword heuristics without invoking the VLM")

            if let banner = statusBanner ?? vlmService.lastError {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(vlmService.lastError != nil && statusBanner == nil ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !vlmService.suggestions.isEmpty {
                Button("Select ≥ 80%") {
                    for idx in vlmService.suggestions.indices where !vlmService.suggestions[idx].isApplied {
                        vlmService.suggestions[idx].isSelected = vlmService.suggestions[idx].confidence >= 0.80
                            && vlmService.suggestions[idx].errorMessage == nil
                    }
                }
                .controlSize(.small)

                Button("Select All") {
                    for idx in vlmService.suggestions.indices where !vlmService.suggestions[idx].isApplied {
                        vlmService.suggestions[idx].isSelected = vlmService.suggestions[idx].errorMessage == nil
                    }
                }
                .controlSize(.small)

                Button {
                    let count = vlmService.applySelectedSuggestions(
                        items: allItems,
                        existingCategories: categories,
                        context: modelContext
                    )
                    statusBanner = "Applied AI categories to \(count) model(s)."
                } label: {
                    Label("Apply Selected (\(selectedSuggestionCount))", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSuggestionCount == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Suggestion Row

private struct SuggestionRowView: View {
    @Binding var suggestion: VLMCategorizationSuggestion
    let categories: [PrintCategory]

    @State private var thumb: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: $suggestion.isSelected)
                .labelsHidden()
                .disabled(suggestion.isApplied || suggestion.errorMessage != nil)

            Group {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(red: 0.14, green: 0.15, blue: 0.18)
                        .overlay(Image(systemName: "cube").font(.caption).foregroundStyle(.white.opacity(0.4)))
                }
            }
            .frame(width: 46, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text((suggestion.fileName as NSString).deletingPathExtension)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if suggestion.isApplied {
                        Text("Applied")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.18))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    } else if suggestion.isNewCategory {
                        Text("New Category")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                }

                if let err = suggestion.errorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    if !suggestion.summary.isEmpty {
                        Text(suggestion.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !suggestion.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(suggestion.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Confidence badge
            if suggestion.errorMessage == nil {
                let pct = Int((suggestion.confidence * 100).rounded())
                let color: Color = pct >= 80 ? .green : (pct >= 55 ? .orange : .secondary)
                Text("\(pct)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.14))
                    .clipShape(Capsule())
            }

            // Editable category dropdown
            if suggestion.errorMessage == nil {
                Picker("Category", selection: Binding(
                    get: { suggestion.suggestedCategoryName },
                    set: { newName in
                        suggestion.suggestedCategoryName = newName
                        if let existing = categories.first(where: { $0.name == newName }) {
                            suggestion.matchedCategoryID = existing.id
                            suggestion.isNewCategory = false
                        }
                    }
                )) {
                    if suggestion.isNewCategory && !categories.contains(where: { $0.name == suggestion.suggestedCategoryName }) {
                        Label("\(suggestion.suggestedCategoryName) (New)", systemImage: "sparkles")
                            .tag(suggestion.suggestedCategoryName)
                        Divider()
                    }
                    ForEach(categories) { cat in
                        Label(cat.name, systemImage: cat.iconName)
                            .tag(cat.name)
                    }
                }
                .labelsHidden()
                .frame(width: 175)
                .controlSize(.small)
                .disabled(suggestion.isApplied)
            }
        }
        .padding(.vertical, 3)
        .task(id: suggestion.itemFilePath) {
            if let cached = ThumbnailService.shared.cachedThumbnail(for: suggestion.itemFilePath) {
                thumb = cached
            } else {
                thumb = await ThumbnailService.shared.thumbnail(
                    for: URL(fileURLWithPath: suggestion.itemFilePath),
                    size: CGSize(width: 96, height: 72)
                )
            }
        }
    }
}
