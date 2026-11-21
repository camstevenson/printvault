import Foundation
import SwiftData
import SwiftUI

// MARK: - Print File Format

public enum PrintFileFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case stl = "stl"
    case threemf = "3mf"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stl: return "STL Mesh"
        case .threemf: return "3MF Project"
        }
    }

    public var badgeText: String {
        rawValue.uppercased()
    }

    public var badgeColor: Color {
        switch self {
        case .stl: return .blue
        case .threemf: return .green
        }
    }

    public static let supportedExtensions: Set<String> = ["stl", "3mf"]

    public static func from(extension ext: String) -> PrintFileFormat? {
        PrintFileFormat(rawValue: ext.lowercased())
    }
}

// MARK: - Print Status

public enum PrintStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case unprinted = "unprinted"
    case queued = "queued"
    case printing = "printing"
    case printed = "printed"
    case failed = "failed"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .unprinted: return "Unprinted"
        case .queued: return "In Queue"
        case .printing: return "Printing"
        case .printed: return "Printed"
        case .failed: return "Needs Fix"
        }
    }

    public var systemImage: String {
        switch self {
        case .unprinted: return "cube.transparent"
        case .queued: return "tray.full.fill"
        case .printing: return "flame.fill"
        case .printed: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    public var color: Color {
        switch self {
        case .unprinted: return .secondary
        case .queued: return .blue
        case .printing: return .orange
        case .printed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Discovery Source

public enum DiscoverySource: String, Codable, Sendable {
    case spotlight = "Spotlight"
    case watchedFolder = "Watched Folder"
    case manual = "Manual Import"
}

// MARK: - PrintCategory (@Model)

@Model
public final class PrintCategory {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var iconName: String
    public var colorHex: String
    public var sortOrder: Int
    public var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \PrintFileItem.category)
    public var items: [PrintFileItem] = []

    public init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "cube.box.fill",
        colorHex: String = "#3B82F6",
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    public var color: Color {
        Color(hex: colorHex) ?? .accentColor
    }

    public static var defaultSeeds: [(name: String, icon: String, hex: String)] {
        [
            ("Functional Parts", "gearshape.2.fill", "#3B82F6"),
            ("Organizers & Gridfinity", "square.grid.3x3.topleft.filled", "#10B981"),
            ("Miniatures & Figurines", "figure.stand", "#8B5CF6"),
            ("Household & Mounts", "house.fill", "#F59E0B"),
            ("Cosplay & Props", "theatermasks.fill", "#EC4899"),
            ("Calibration & Test", "ruler.fill", "#06B6D4")
        ]
    }
}

// MARK: - PrintFileItem (@Model)

@Model
public final class PrintFileItem {
    @Attribute(.unique) public var filePath: String
    public var fileName: String
    public var fileExtension: String
    public var fileSize: Int64
    public var dateModified: Date
    public var dateAdded: Date
    public var discoverySourceRaw: String

    // Organization & Metadata
    public var category: PrintCategory?
    public var tags: [String]
    public var isFavorite: Bool
    public var printStatusRaw: String
    public var rating: Int
    public var notes: String

    // 3D Geometry Metrics
    public var meshAnalyzed: Bool
    public var vertexCount: Int
    public var triangleCount: Int
    public var dimensionX: Double // mm
    public var dimensionY: Double // mm
    public var dimensionZ: Double // mm
    public var estimatedVolumeCm3: Double
    public var surfaceAreaCm2: Double = 0
    public var embeddedSubModelCount: Int

    // Slicer Tracking
    public var lastSentToSlicerDate: Date?
    public var lastUsedSlicerName: String?
    public var sliceCount: Int

    public init(
        filePath: String,
        fileName: String,
        fileExtension: String,
        fileSize: Int64,
        dateModified: Date,
        discoverySource: DiscoverySource = .watchedFolder,
        category: PrintCategory? = nil,
        tags: [String] = []
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.fileExtension = fileExtension.lowercased()
        self.fileSize = fileSize
        self.dateModified = dateModified
        self.dateAdded = Date()
        self.discoverySourceRaw = discoverySource.rawValue
        self.category = category
        self.tags = tags
        self.isFavorite = false
        self.printStatusRaw = PrintStatus.unprinted.rawValue
        self.rating = 0
        self.notes = ""
        self.meshAnalyzed = false
        self.vertexCount = 0
        self.triangleCount = 0
        self.dimensionX = 0
        self.dimensionY = 0
        self.dimensionZ = 0
        self.estimatedVolumeCm3 = 0
        self.surfaceAreaCm2 = 0
        self.embeddedSubModelCount = 1
        self.lastSentToSlicerDate = nil
        self.lastUsedSlicerName = nil
        self.sliceCount = 0
    }

    public var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    public var format: PrintFileFormat {
        PrintFileFormat.from(extension: fileExtension) ?? .stl
    }

    public var printStatus: PrintStatus {
        get { PrintStatus(rawValue: printStatusRaw) ?? .unprinted }
        set { printStatusRaw = newValue.rawValue }
    }

    public var discoverySource: DiscoverySource {
        get { DiscoverySource(rawValue: discoverySourceRaw) ?? .watchedFolder }
        set { discoverySourceRaw = newValue.rawValue }
    }

    public var displayTitle: String {
        (fileName as NSString).deletingPathExtension
    }

    public var parentFolderName: String {
        fileURL.deletingLastPathComponent().lastPathComponent
    }

    public var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    public var hasDimensions: Bool {
        dimensionX > 0 || dimensionY > 0 || dimensionZ > 0
    }

    public var formattedDimensions: String {
        guard hasDimensions else { return "—" }
        return String(format: "%.1f × %.1f × %.1f mm", dimensionX, dimensionY, dimensionZ)
    }

    /// Effective solid-fill fraction (0...1) using a shell + infill model:
    /// thin-walled geometry (high surface-area-to-volume ratio) approaches 100% solid walls,
    /// while thick geometry combines outer walls/top/bottom (`wallThicknessMm`) with interior `infillPercent`.
    public func estimatedEffectiveFillFraction(
        wallThicknessMm: Double = 1.0,
        infillPercent: Double = 20.0
    ) -> Double {
        guard estimatedVolumeCm3 > 0 else { return 0 }
        let infill = min(max(infillPercent / 100.0, 0.0), 1.0)
        guard surfaceAreaCm2 > 0 else {
            // Fallback for legacy records before surface area is populated
            return max(infill, 0.35)
        }
        let wallThicknessCm = max(wallThicknessMm, 0.0) / 10.0
        let rawShellRatio = (surfaceAreaCm2 * wallThicknessCm) / estimatedVolumeCm3
        // Steiner parallel-body correction keeps cubes/cylinders accurate while saturating thin walls (<= 2*wall) at 100%
        let shellFraction = min(1.0, rawShellRatio * 0.90)
        return shellFraction + infill * (1.0 - shellFraction)
    }

    /// Effective plastic volume in cm³ (walls + top/bottom + infill)
    public func estimatedEffectivePlasticVolumeCm3(
        wallThicknessMm: Double = 1.0,
        infillPercent: Double = 20.0
    ) -> Double {
        guard estimatedVolumeCm3 > 0 else { return 0 }
        return estimatedVolumeCm3 * estimatedEffectiveFillFraction(
            wallThicknessMm: wallThicknessMm,
            infillPercent: infillPercent
        )
    }

    /// Convenience default effective plastic volume (1.0 mm walls + 20% infill)
    public var estimatedEffectivePlasticVolumeCm3: Double {
        estimatedEffectivePlasticVolumeCm3(wallThicknessMm: 1.0, infillPercent: 20.0)
    }

    /// PLA weight estimate (g) using 1.24 g/cm³ PLA density
    public func estimatedPLAWeightGrams(
        wallThicknessMm: Double = 1.0,
        infillPercent: Double = 20.0
    ) -> Double {
        estimatedEffectivePlasticVolumeCm3(wallThicknessMm: wallThicknessMm, infillPercent: infillPercent) * 1.24
    }

    public var estimatedPLAWeightGrams: Double {
        estimatedPLAWeightGrams(wallThicknessMm: 1.0, infillPercent: 20.0)
    }

    /// Filament length estimate in meters for standard 1.75mm diameter filament
    public var estimatedFilamentLengthMeters: Double {
        estimatedFilamentLengthMeters(diameterMm: 1.75, wallThicknessMm: 1.0, infillPercent: 20.0)
    }

    /// Filament length estimate in meters for given filament diameter, wall thickness, and infill
    public func estimatedFilamentLengthMeters(
        diameterMm: Double = 1.75,
        wallThicknessMm: Double = 1.0,
        infillPercent: Double = 20.0
    ) -> Double {
        let volCm3 = estimatedEffectivePlasticVolumeCm3(wallThicknessMm: wallThicknessMm, infillPercent: infillPercent)
        guard volCm3 > 0, diameterMm > 0 else { return 0 }
        let radiusMm = diameterMm / 2.0
        let crossSectionMm2 = Double.pi * radiusMm * radiusMm
        // 1 cm³ = 1000 mm³, and 1 m = 1000 mm, so cm³ / mm² equals length directly in meters
        return volCm3 / crossSectionMm2
    }

    public func formattedEstimatedFilamentLength(
        diameterMm: Double = 1.75,
        wallThicknessMm: Double = 1.0,
        infillPercent: Double = 20.0
    ) -> String {
        let meters = estimatedFilamentLengthMeters(
            diameterMm: diameterMm,
            wallThicknessMm: wallThicknessMm,
            infillPercent: infillPercent
        )
        guard meters > 0 else { return "—" }
        if meters < 10.0 {
            return String(format: "~%.2f m", meters)
        }
        return String(format: "~%.1f m", meters)
    }

    public var formattedEstimatedFilamentLength: String {
        formattedEstimatedFilamentLength(diameterMm: 1.75, wallThicknessMm: 1.0, infillPercent: 20.0)
    }

    public var fileExistsOnDisk: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }
}

// MARK: - WatchedFolder (@Model)

@Model
public final class WatchedFolder {
    @Attribute(.unique) public var path: String
    public var displayName: String
    public var isEnabled: Bool
    public var lastScannedAt: Date?
    public var discoveredFileCount: Int

    public init(path: String, displayName: String? = nil, isEnabled: Bool = true) {
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.isEnabled = isEnabled
        self.lastScannedAt = nil
        self.discoveredFileCount = 0
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }
}

// MARK: - Color Hex Helper

extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") {
            cleaned.removeFirst()
        }
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else {
            return nil
        }
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    func toHex() -> String {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else {
            return "#3B82F6"
        }
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
