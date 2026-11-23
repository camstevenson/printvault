import Foundation
import SwiftData
import AppKit
import Observation

// MARK: - VLM Backend & Configuration

public enum VLMBackendKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case customOpenAI = "Custom / MLX-VLM"

    public var id: String { rawValue }

    public var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .lmStudio: return "http://127.0.0.1:1234/v1"
        case .customOpenAI: return "http://127.0.0.1:8080/v1"
        }
    }
}

public struct VLMConfiguration: Codable, Equatable, Sendable {
    public var backend: VLMBackendKind = .ollama
    public var baseURL: String = VLMBackendKind.ollama.defaultBaseURL
    public var selectedModel: String = ""
    public var allowNewCategories: Bool = false
    public var autoApplyHighConfidence: Bool = false
    public var confidenceThreshold: Double = 0.78
    public var applyTags: Bool = true
    public var fillEmptyNotes: Bool = true

    public init() {}
}

// MARK: - VLM Classification Suggestion

public struct VLMCategorizationSuggestion: Identifiable, Sendable {
    public let id = UUID()
    public let itemFilePath: String
    public let fileName: String
    public var suggestedCategoryName: String
    public var matchedCategoryID: UUID?
    public var isNewCategory: Bool
    public let confidence: Double
    public var tags: [String]
    public var summary: String
    public var isSelected: Bool
    public var isApplied: Bool
    public let elapsedSeconds: Double
    public let errorMessage: String?

    public init(
        itemFilePath: String,
        fileName: String,
        suggestedCategoryName: String,
        matchedCategoryID: UUID?,
        isNewCategory: Bool,
        confidence: Double,
        tags: [String],
        summary: String,
        isSelected: Bool,
        isApplied: Bool = false,
        elapsedSeconds: Double = 0,
        errorMessage: String? = nil
    ) {
        self.itemFilePath = itemFilePath
        self.fileName = fileName
        self.suggestedCategoryName = suggestedCategoryName
        self.matchedCategoryID = matchedCategoryID
        self.isNewCategory = isNewCategory
        self.confidence = confidence
        self.tags = tags
        self.summary = summary
        self.isSelected = isSelected
        self.isApplied = isApplied
        self.elapsedSeconds = elapsedSeconds
        self.errorMessage = errorMessage
    }
}

// MARK: - Runtime Detection Status

public enum VLMConnectionState: Equatable, Sendable {
    case unknown
    case checking
    case connected(modelCount: Int)
    case needsVisionModel
    case offline(ollamaInstalled: Bool, lmStudioInstalled: Bool)
    case error(String)
}

// MARK: - VLMCategorizerService

@MainActor
@Observable
public final class VLMCategorizerService {
    public static let shared = VLMCategorizerService()
    public static let recommendedOllamaVisionModel = "qwen2.5vl:3b"

    private let configDefaultsKey = "PrintVault.VLMConfig.v1"

    public var config: VLMConfiguration = VLMConfiguration()
    public var connectionState: VLMConnectionState = .unknown
    public var availableModels: [String] = []
    public var availableVisionModels: [String] = []

    // Pull state (Ollama 1-click download)
    public var isPullingModel: Bool = false
    public var pullProgress: Double = 0
    public var pullStatusText: String = ""

    // Batch classification state
    public var isRunning: Bool = false
    public var currentItemName: String = ""
    public var completedCount: Int = 0
    public var totalCount: Int = 0
    public var suggestions: [VLMCategorizationSuggestion] = []
    public var lastError: String?

    private var activeTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?

    public init(loadPersisted: Bool = true) {
        if loadPersisted {
            loadConfiguration()
        }
    }

    public func loadConfiguration() {
        if let data = UserDefaults.standard.data(forKey: configDefaultsKey),
           let decoded = try? JSONDecoder().decode(VLMConfiguration.self, from: data) {
            config = decoded
        }
    }

    public func saveConfiguration() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configDefaultsKey)
        }
    }

    public var isOllamaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ollama")
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ollama")
    }

    public var isLMStudioInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/LM Studio.app")
    }

    // MARK: - Vision Model Heuristics

    /// Returns `true` if the model name is a known Vision-Language Model family.
    public nonisolated static func isLikelyVisionModel(_ modelName: String) -> Bool {
        let lower = modelName.lowercased()
        let markers = [
            "vl", "vision", "llava", "gemma3", "gemma-3", "minicpm-v", "moondream",
            "bakllava", "pixtral", "internvl", "cogvlm", "smolvlm", "fastvlm",
            "mistral-small3.1", "mistral-small-3.1", "phi4-multimodal", "phi-4-multimodal",
            "qwen2.5vl", "qwen2.5-vl", "qwen3-vl", "qwen3vl", "qwen2-vl", "llama3.2-vision",
            "granite3.2-vision", "kimi-vl", "aya-vision"
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Selects the highest-priority vision model from an installed model list (preferring fast, accurate Qwen2.5-VL / FastVLM / Gemma3).
    public nonisolated static func pickPreferredVisionModel(from models: [String]) -> String? {
        let visionModels = models.filter { isLikelyVisionModel($0) }
        guard !visionModels.isEmpty else { return nil }

        let priorityOrder = [
            "qwen2.5vl:3b", "qwen2.5-vl-3b", "fastvlm", "qwen3-vl", "qwen2.5vl:7b",
            "qwen2.5vl", "gemma3:4b", "gemma3", "llama3.2-vision", "minicpm-v",
            "moondream", "llava"
        ]
        for pref in priorityOrder {
            if let match = visionModels.first(where: { $0.lowercased().contains(pref) }) {
                return match
            }
        }
        return visionModels.first
    }

    // MARK: - Auto-Detection & Ollama Startup / Model Pull

    public func detectLocalRuntimes(preferCurrentBackend: Bool = false) async {
        connectionState = .checking
        lastError = nil

        if preferCurrentBackend {
            if await probeBackend(config.backend, baseURL: config.baseURL) {
                saveConfiguration()
                return
            }
        }

        // Try Ollama first, then LM Studio, then Custom/MLX-VLM
        let order: [(VLMBackendKind, String)] = [
            (config.backend, config.baseURL),
            (.ollama, VLMBackendKind.ollama.defaultBaseURL),
            (.lmStudio, VLMBackendKind.lmStudio.defaultBaseURL),
            (.customOpenAI, VLMBackendKind.customOpenAI.defaultBaseURL)
        ]

        var seen = Set<String>()
        for (kind, url) in order {
            let key = "\(kind.rawValue)|\(url)"
            guard seen.insert(key).inserted else { continue }
            if await probeBackend(kind, baseURL: url) {
                config.backend = kind
                config.baseURL = url
                saveConfiguration()
                return
            }
        }

        availableModels = []
        availableVisionModels = []
        connectionState = .offline(
            ollamaInstalled: isOllamaInstalled,
            lmStudioInstalled: isLMStudioInstalled
        )
    }

    private func probeBackend(_ kind: VLMBackendKind, baseURL: String) async -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return false }

        let session = makeShortTimeoutSession(seconds: 2.5)

        switch kind {
        case .ollama:
            guard let url = URL(string: "\(trimmed)/api/tags") else { return false }
            guard let (data, resp) = try? await session.data(from: url),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return false
            }
            struct OllamaTagsResponse: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]?
            }
            let decoded = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            let names = (decoded?.models ?? []).map(\.name)
            applyDetectedModels(names, kind: .ollama)
            return true

        case .lmStudio, .customOpenAI:
            guard let url = URL(string: "\(trimmed)/models") else { return false }
            guard let (data, resp) = try? await session.data(from: url),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return false
            }
            struct OpenAIModelsResponse: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]?
            }
            let decoded = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            let names = (decoded?.data ?? []).map(\.id)
            applyDetectedModels(names, kind: kind)
            return true
        }
    }

    private func applyDetectedModels(_ names: [String], kind: VLMBackendKind) {
        availableModels = names
        let vision = names.filter { Self.isLikelyVisionModel($0) }
        availableVisionModels = vision

        if !names.contains(config.selectedModel) {
            if let preferred = Self.pickPreferredVisionModel(from: names) {
                config.selectedModel = preferred
            } else if let first = names.first {
                config.selectedModel = first
            } else {
                config.selectedModel = ""
            }
        }

        if kind == .ollama && vision.isEmpty {
            connectionState = .needsVisionModel
        } else if names.isEmpty {
            connectionState = .needsVisionModel
        } else {
            connectionState = .connected(modelCount: names.count)
        }
    }

    /// Starts Ollama.app (or `ollama serve`) and waits briefly for localhost:11434 to respond.
    public func startOllama() async {
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            _ = try? await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/Ollama.app"),
                configuration: cfg
            )
        } else {
            let cliPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ollama")
                ? "/opt/homebrew/bin/ollama"
                : "/usr/local/bin/ollama"
            if FileManager.default.isExecutableFile(atPath: cliPath) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: cliPath)
                proc.arguments = ["serve"]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
            }
        }

        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await probeBackend(.ollama, baseURL: VLMBackendKind.ollama.defaultBaseURL) {
                config.backend = .ollama
                config.baseURL = VLMBackendKind.ollama.defaultBaseURL
                saveConfiguration()
                return
            }
        }
        await detectLocalRuntimes()
    }

    /// Streams `POST /api/pull` to download a vision model (e.g. `qwen2.5vl:3b`) directly through local Ollama.
    public func pullOllamaModel(_ modelName: String = recommendedOllamaVisionModel) {
        guard !isPullingModel else { return }
        pullTask?.cancel()
        pullTask = Task { [weak self] in
            guard let self else { return }
            await self.performPullOllamaModel(modelName)
        }
    }

    public func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        isPullingModel = false
        pullStatusText = ""
    }

    private func performPullOllamaModel(_ modelName: String) async {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/pull") else { return }

        isPullingModel = true
        pullProgress = 0
        pullStatusText = "Starting download of \(modelName)..."
        lastError = nil

        defer {
            isPullingModel = false
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 3600
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": modelName, "stream": true])

        struct PullChunk: Decodable {
            let status: String?
            let total: Int64?
            let completed: Int64?
            let error: String?
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                lastError = "Ollama returned an error starting model pull."
                return
            }

            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard let lineData = line.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(PullChunk.self, from: lineData) else {
                    continue
                }
                if let err = chunk.error {
                    lastError = err
                    return
                }
                if let status = chunk.status {
                    pullStatusText = status
                }
                if let total = chunk.total, total > 0, let completed = chunk.completed {
                    pullProgress = min(1.0, max(0.0, Double(completed) / Double(total)))
                }
            }

            if Task.isCancelled { return }
            pullProgress = 1.0
            pullStatusText = "Downloaded \(modelName)"
            config.selectedModel = modelName
            saveConfiguration()
            await detectLocalRuntimes(preferCurrentBackend: true)
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                lastError = "Failed to pull \(modelName): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Single & Batch VLM Classification

    public func classifySingleItem(
        _ item: PrintFileItem,
        existingCategories: [PrintCategory]
    ) async -> VLMCategorizationSuggestion {
        let start = CFAbsoluteTimeGetCurrent()
        let categoryNames = existingCategories.map(\.name)

        guard !config.selectedModel.isEmpty else {
            return VLMCategorizationSuggestion(
                itemFilePath: item.filePath,
                fileName: item.fileName,
                suggestedCategoryName: "Uncategorized",
                matchedCategoryID: nil,
                isNewCategory: false,
                confidence: 0,
                tags: [],
                summary: "",
                isSelected: false,
                elapsedSeconds: 0,
                errorMessage: "No local vision model selected."
            )
        }

        guard let pngData = await ThumbnailService.shared.renderNeutralVLMPreviewPNG(for: item.fileURL) else {
            return VLMCategorizationSuggestion(
                itemFilePath: item.filePath,
                fileName: item.fileName,
                suggestedCategoryName: "Uncategorized",
                matchedCategoryID: nil,
                isNewCategory: false,
                confidence: 0,
                tags: [],
                summary: "",
                isSelected: false,
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - start,
                errorMessage: "Could not render 3D preview image."
            )
        }

        let prompt = Self.buildClassificationPrompt(
            fileName: item.fileName,
            parentFolder: item.parentFolderName,
            dimensions: item.formattedDimensions,
            volumeCm3: item.estimatedVolumeCm3,
            surfaceAreaCm2: item.surfaceAreaCm2,
            triangleCount: item.triangleCount,
            subModelCount: item.embeddedSubModelCount,
            existingCategories: categoryNames,
            allowNewCategories: config.allowNewCategories
        )

        do {
            let rawResponse = try await invokeLocalVLM(
                imagePNGData: pngData,
                prompt: prompt
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return Self.parseSuggestion(
                from: rawResponse,
                itemFilePath: item.filePath,
                fileName: item.fileName,
                existingCategories: existingCategories,
                allowNewCategories: config.allowNewCategories,
                confidenceThreshold: config.confidenceThreshold,
                elapsedSeconds: elapsed
            )
        } catch {
            return VLMCategorizationSuggestion(
                itemFilePath: item.filePath,
                fileName: item.fileName,
                suggestedCategoryName: "Uncategorized",
                matchedCategoryID: nil,
                isNewCategory: false,
                confidence: 0,
                tags: [],
                summary: "",
                isSelected: false,
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - start,
                errorMessage: error.localizedDescription
            )
        }
    }

    public func startBatchClassification(
        items: [PrintFileItem],
        existingCategories: [PrintCategory],
        context: ModelContext
    ) {
        cancelBatch()
        guard !items.isEmpty else { return }

        isRunning = true
        completedCount = 0
        totalCount = items.count
        suggestions = []
        lastError = nil

        activeTask = Task { [weak self] in
            guard let self else { return }
            for item in items {
                if Task.isCancelled { break }
                self.currentItemName = item.displayTitle
                var suggestion = await self.classifySingleItem(item, existingCategories: existingCategories)

                // Auto-apply high-confidence matches immediately when enabled
                if self.config.autoApplyHighConfidence,
                   suggestion.errorMessage == nil,
                   suggestion.confidence >= self.config.confidenceThreshold {
                    let currentCats = (try? context.fetch(FetchDescriptor<PrintCategory>())) ?? existingCategories
                    let applied = self.applySingleSuggestion(suggestion, to: item, existingCategories: currentCats, context: context)
                    if applied {
                        suggestion.isApplied = true
                        suggestion.isSelected = false
                    }
                }

                self.suggestions.append(suggestion)
                self.completedCount += 1
                if let err = suggestion.errorMessage {
                    self.lastError = err
                }
            }

            if self.config.autoApplyHighConfidence {
                try? context.save()
            }
            self.currentItemName = ""
            self.isRunning = false
        }
    }

    public func cancelBatch() {
        activeTask?.cancel()
        activeTask = nil
        isRunning = false
        currentItemName = ""
    }

    // MARK: - Applying Approved Suggestions to SwiftData

    @discardableResult
    public func applySelectedSuggestions(
        items: [PrintFileItem],
        existingCategories: [PrintCategory],
        context: ModelContext
    ) -> Int {
        let itemsByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.filePath, $0) })
        var categories = existingCategories
        var appliedCount = 0

        for idx in suggestions.indices {
            guard suggestions[idx].isSelected && !suggestions[idx].isApplied else { continue }
            guard let item = itemsByPath[suggestions[idx].itemFilePath] else { continue }

            if applySingleSuggestion(suggestions[idx], to: item, existingCategories: categories, context: context) {
                suggestions[idx].isApplied = true
                suggestions[idx].isSelected = false
                appliedCount += 1
                // Refresh category list in case a new category was just inserted
                if let refreshed = try? context.fetch(FetchDescriptor<PrintCategory>()) {
                    categories = refreshed
                }
            }
        }

        if appliedCount > 0 {
            try? context.save()
        }
        return appliedCount
    }

    @discardableResult
    public func applySingleSuggestion(
        _ suggestion: VLMCategorizationSuggestion,
        to item: PrintFileItem,
        existingCategories: [PrintCategory],
        context: ModelContext
    ) -> Bool {
        let targetName = suggestion.suggestedCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty, targetName.caseInsensitiveCompare("Uncategorized") != .orderedSame else {
            return false
        }

        let normalizedTarget = Self.normalizeCategoryKey(targetName)
        if let id = suggestion.matchedCategoryID,
           let matched = existingCategories.first(where: { $0.id == id }) {
            item.category = matched
        } else if let byName = existingCategories.first(where: {
            $0.name.caseInsensitiveCompare(targetName) == .orderedSame
                || (!normalizedTarget.isEmpty && Self.normalizeCategoryKey($0.name) == normalizedTarget)
        }) {
            item.category = byName
        } else {
            let formattedName = Self.formatCategoryDisplayName(targetName)
            let (icon, hex) = Self.pickStyleForNewCategory(name: formattedName, existingCount: existingCategories.count)
            let created = PrintCategory(
                name: formattedName,
                iconName: icon,
                colorHex: hex,
                sortOrder: existingCategories.count
            )
            context.insert(created)
            item.category = created
        }

        if config.applyTags && !suggestion.tags.isEmpty {
            var merged = Set(item.tags.map { $0.lowercased() })
            for tag in suggestion.tags where !merged.contains(tag.lowercased()) {
                item.tags.append(tag)
                merged.insert(tag.lowercased())
            }
        }

        if config.fillEmptyNotes && item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !suggestion.summary.isEmpty {
            item.notes = suggestion.summary
        }

        return true
    }

    // MARK: - HTTP VLM Invocation (Ollama & OpenAI-Compatible Vision API)

    private func invokeLocalVLM(imagePNGData: Data, prompt: String) async throws -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base64Image = imagePNGData.base64EncodedString()

        switch config.backend {
        case .ollama:
            guard let url = URL(string: "\(base)/api/chat") else {
                throw URLError(.badURL)
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "model": config.selectedModel,
                "stream": false,
                "format": "json",
                "options": [
                    "temperature": 0.1,
                    "num_predict": 220
                ],
                "messages": [
                    [
                        "role": "user",
                        "content": prompt,
                        "images": [base64Image]
                    ]
                ]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let errBody = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(domain: "VLMCategorizerService", code: (resp as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [
                    NSLocalizedDescriptionKey: "Ollama error: \(errBody.prefix(200))"
                ])
            }

            struct OllamaChatResponse: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message?
            }
            let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            guard let content = decoded.message?.content, !content.isEmpty else {
                throw NSError(domain: "VLMCategorizerService", code: 502, userInfo: [
                    NSLocalizedDescriptionKey: "Ollama returned an empty response."
                ])
            }
            return content

        case .lmStudio, .customOpenAI:
            guard let url = URL(string: "\(base)/chat/completions") else {
                throw URLError(.badURL)
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "model": config.selectedModel,
                "temperature": 0.1,
                "max_tokens": 220,
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            ["type": "text", "text": prompt],
                            [
                                "type": "image_url",
                                "image_url": ["url": "data:image/png;base64,\(base64Image)"]
                            ]
                        ]
                    ]
                ]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let errBody = String(data: data, encoding: .utf8) ?? "HTTP error"
                throw NSError(domain: "VLMCategorizerService", code: (resp as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [
                    NSLocalizedDescriptionKey: "VLM endpoint error: \(errBody.prefix(200))"
                ])
            }

            struct OpenAIChatResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String? }
                    let message: Message
                }
                let choices: [Choice]
            }
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
                throw NSError(domain: "VLMCategorizerService", code: 502, userInfo: [
                    NSLocalizedDescriptionKey: "VLM returned an empty response."
                ])
            }
            return content
        }
    }

    private func makeShortTimeoutSession(seconds: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = seconds
        cfg.timeoutIntervalForResource = seconds
        return URLSession(configuration: cfg)
    }

    // MARK: - Prompt Builder & Robust JSON Parser

    public nonisolated static func buildClassificationPrompt(
        fileName: String,
        parentFolder: String,
        dimensions: String,
        volumeCm3: Double,
        surfaceAreaCm2: Double,
        triangleCount: Int,
        subModelCount: Int,
        existingCategories: [String],
        allowNewCategories: Bool
    ) -> String {
        let categoryList = existingCategories.isEmpty
            ? "Functional Parts, Organizers & Gridfinity, Miniatures & Figurines, Household & Mounts, Cosplay & Props, Calibration & Test"
            : existingCategories.joined(separator: ", ")

        let categoryRule = allowNewCategories
            ? "Choose the best matching category from the list above using its EXACT spelling and capitalization (never return hyphenated or underscored slugs like 'functional-parts'). Only if the object clearly belongs to a distinct niche not covered (e.g. Keycaps, Tabletop Terrain, Board Games, Jewelry), propose a concise 1–3 word Title Case category name and set \"isNewCategory\": true."
            : "You MUST choose the single best matching category strictly from this list using its EXACT spelling: [\(categoryList)]. Set \"isNewCategory\": false."

        var metricsLines: [String] = []
        if dimensions != "—" { metricsLines.append("- Dimensions: \(dimensions)") }
        if volumeCm3 > 0 { metricsLines.append(String(format: "- Mesh Volume: %.2f cm³", volumeCm3)) }
        if surfaceAreaCm2 > 0 { metricsLines.append(String(format: "- Surface Area: %.1f cm²", surfaceAreaCm2)) }
        if triangleCount > 0 { metricsLines.append("- Triangles: \(triangleCount)") }
        if subModelCount > 1 { metricsLines.append("- Sub-Models on plate: \(subModelCount)") }
        metricsLines.append("- Filename (secondary hint only): \(fileName)")
        if !parentFolder.isEmpty { metricsLines.append("- Parent folder: \(parentFolder)") }

        return """
        You are classifying a 3D printable model from its neutral-gray 3D studio render and geometry metadata.
        Rely primarily on the visual 3D shape and physical scale in millimeters; treat the filename only as secondary context (ignore cryptic or meaningless filenames).

        Model metadata:
        \(metricsLines.joined(separator: "\n"))

        Available categories: [\(categoryList)]
        \(categoryRule)

        Respond ONLY with a single valid JSON object (no markdown, no extra commentary) with these exact keys:
        {
          "category": "<category name>",
          "isNewCategory": false,
          "confidence": 0.85,
          "tags": ["tag1", "tag2", "tag3"],
          "summary": "One concise sentence describing what this 3D print model is."
        }
        Rules for tags: 2 to 4 short lowercase descriptive tags (e.g. "gargoyle", "plumbing", "keycap", "terrain", "bracket").
        """
    }

    public static func parseSuggestion(
        from rawText: String,
        itemFilePath: String,
        fileName: String,
        existingCategories: [PrintCategory],
        allowNewCategories: Bool,
        confidenceThreshold: Double,
        elapsedSeconds: Double
    ) -> VLMCategorizationSuggestion {
        let jsonString = extractJSONObject(from: rawText)
        struct RawVLMResult: Decodable {
            let category: String?
            let isNewCategory: Bool?
            let confidence: Double?
            let tags: [String]?
            let summary: String?
        }

        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(RawVLMResult.self, from: data) else {
            return VLMCategorizationSuggestion(
                itemFilePath: itemFilePath,
                fileName: fileName,
                suggestedCategoryName: "Uncategorized",
                matchedCategoryID: nil,
                isNewCategory: false,
                confidence: 0,
                tags: [],
                summary: "",
                isSelected: false,
                elapsedSeconds: elapsedSeconds,
                errorMessage: "Could not parse JSON from VLM output."
            )
        }

        let rawCategory = (parsed.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = min(1.0, max(0.0, parsed.confidence ?? 0.7))

        // Match against existing categories: exact -> normalized slug/punctuation -> normalized substring
        let normalizedRaw = normalizeCategoryKey(rawCategory)
        let matchedCat: PrintCategory? = existingCategories.first(where: {
            $0.name.caseInsensitiveCompare(rawCategory) == .orderedSame
        }) ?? existingCategories.first(where: {
            !normalizedRaw.isEmpty && normalizeCategoryKey($0.name) == normalizedRaw
        }) ?? existingCategories.first(where: {
            let normExisting = normalizeCategoryKey($0.name)
            return !normalizedRaw.isEmpty && !normExisting.isEmpty
                && (normExisting.contains(normalizedRaw) || normalizedRaw.contains(normExisting))
        })

        let finalCategoryName: String
        let isNew: Bool
        if let matchedCat {
            finalCategoryName = matchedCat.name
            isNew = false
        } else if allowNewCategories && !rawCategory.isEmpty && rawCategory.caseInsensitiveCompare("Uncategorized") != .orderedSame {
            finalCategoryName = formatCategoryDisplayName(rawCategory)
            isNew = true
        } else if let fallback = existingCategories.first, !rawCategory.isEmpty {
            finalCategoryName = fallback.name
            isNew = false
        } else {
            finalCategoryName = rawCategory.isEmpty ? "Uncategorized" : formatCategoryDisplayName(rawCategory)
            isNew = matchedCat == nil && allowNewCategories
        }

        // Clean & deduplicate tags (max 5)
        var seenTags = Set<String>()
        var cleanTags: [String] = []
        for rawTag in (parsed.tags ?? []) {
            let cleaned = rawTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "#", with: "")
            guard cleaned.count >= 2, cleaned.count <= 28 else { continue }
            let key = cleaned.lowercased()
            if seenTags.insert(key).inserted {
                cleanTags.append(cleaned)
            }
            if cleanTags.count >= 5 { break }
        }

        let summary = (parsed.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let autoCheck = finalCategoryName != "Uncategorized" && confidence >= min(confidenceThreshold, 0.55)

        return VLMCategorizationSuggestion(
            itemFilePath: itemFilePath,
            fileName: fileName,
            suggestedCategoryName: finalCategoryName,
            matchedCategoryID: matchedCat?.id,
            isNewCategory: isNew,
            confidence: confidence,
            tags: cleanTags,
            summary: summary,
            isSelected: autoCheck,
            elapsedSeconds: elapsedSeconds,
            errorMessage: nil
        )
    }

    /// Normalizes category names so slugified VLM outputs (e.g. "functional-parts", "functional_parts",
    /// "calibration-test", "household-and-mounts") match existing categories ("Functional Parts",
    /// "Calibration & Test", "Household & Mounts").
    public nonisolated static func normalizeCategoryKey(_ name: String) -> String {
        let tokens = name
            .lowercased()
            .replacingOccurrences(of: "&", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "and" }
        return tokens.joined(separator: " ")
    }

    /// Formats a proposed new category slug (e.g. "tabletop-terrain" or "keycaps") into clean Title Case ("Tabletop Terrain", "Keycaps").
    public nonisolated static func formatCategoryDisplayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // If it already contains uppercase letters and spaces (and no slug separators), preserve it as-is
        let hasSlugSep = trimmed.contains("-") || trimmed.contains("_")
        let hasUpper = trimmed.rangeOfCharacter(from: .uppercaseLetters) != nil
        if hasUpper && !hasSlugSep {
            return trimmed
        }

        let words = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else { return trimmed }

        return words.enumerated().map { idx, word in
            let lower = word.lowercased()
            if idx > 0 && lower == "and" { return "&" }
            if idx > 0 && (lower == "of" || lower == "for" || lower == "the") { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    /// Merges any duplicate categories that share the same normalized key (e.g. `functional-parts` and `functional_parts` into `Functional Parts`).
    /// Returns `(mergedCategoriesRemoved, modelsMoved)`.
    @discardableResult
    public static func mergeDuplicateCategories(context: ModelContext) -> (removedCategories: Int, movedModels: Int) {
        let categories = (try? context.fetch(FetchDescriptor<PrintCategory>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let items = (try? context.fetch(FetchDescriptor<PrintFileItem>())) ?? []

        var groups: [String: [PrintCategory]] = [:]
        for cat in categories {
            let key = normalizeCategoryKey(cat.name)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(cat)
        }

        var removedCount = 0
        var movedCount = 0

        for (_, group) in groups where group.count > 1 {
            // Prefer non-slug, capitalized, earliest-created category as the canonical target
            let sorted = group.sorted { a, b in
                let aSlug = a.name.contains("-") || a.name.contains("_") || a.name == a.name.lowercased()
                let bSlug = b.name.contains("-") || b.name.contains("_") || b.name == b.name.lowercased()
                if aSlug != bSlug { return !aSlug }
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.createdAt < b.createdAt
            }
            guard let canonical = sorted.first else { continue }
            let duplicates = sorted.dropFirst()
            let duplicateIDs = Set(duplicates.map(\.id))

            for item in items {
                if let catID = item.category?.id, duplicateIDs.contains(catID) {
                    item.category = canonical
                    movedCount += 1
                }
            }
            for dup in duplicates {
                context.delete(dup)
                removedCount += 1
            }
        }

        if removedCount > 0 || movedCount > 0 {
            try? context.save()
        }
        return (removedCount, movedCount)
    }

    /// Extracts the outermost `{ ... }` JSON object from raw LLM output (handling markdown code fences or prose preambles).
    public nonisolated static func extractJSONObject(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let closingRange = text.range(of: "```", options: .backwards) {
                text = String(text[..<closingRange.lowerBound])
            }
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[start...end])
    }

    private static func pickStyleForNewCategory(name: String, existingCount: Int) -> (icon: String, hex: String) {
        let lower = name.lowercased()
        if lower.contains("keycap") || lower.contains("keyboard") { return ("keyboard.fill", "#6366F1") }
        if lower.contains("terrain") || lower.contains("scenery") || lower.contains("diorama") { return ("mountain.2.fill", "#14B8A6") }
        if lower.contains("game") || lower.contains("board") { return ("gamecontroller.fill", "#A855F7") }
        if lower.contains("tool") || lower.contains("hardware") || lower.contains("plumb") { return ("wrench.and.screwdriver.fill", "#0EA5E9") }
        if lower.contains("decor") || lower.contains("art") || lower.contains("vase") { return ("sparkles", "#F43F5E") }
        if lower.contains("tech") || lower.contains("electron") || lower.contains("cable") { return ("cpu.fill", "#3B82F6") }

        let palette = ["#6366F1", "#14B8A6", "#F43F5E", "#84CC16", "#A855F7", "#0EA5E9"]
        return ("cube.box.fill", palette[existingCount % palette.count])
    }
}
