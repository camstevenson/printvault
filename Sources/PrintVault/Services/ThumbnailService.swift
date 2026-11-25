import Foundation
import AppKit
import SceneKit
import QuickLookThumbnailing
import CryptoKit
import ImageIO
import Observation

// MARK: - Off-Main-Thread Serial Metal Snapshot Renderer

private actor OffscreenThumbnailRenderer {
    static let shared = OffscreenThumbnailRenderer()
    private let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    func renderPNGData(
        for url: URL,
        size: CGSize,
        neutralClayStyle: Bool = false
    ) async -> Data? {
        guard !Task.isCancelled, let device else { return nil }
        guard let loaded = try? await MeshLoaderService.loadMesh(at: url) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let modelClone = MeshLoaderService.cloneWithIndependentGeometry(loaded.rootNode)
        if neutralClayStyle {
            Self.applyNeutralClayMaterial(to: modelClone)
        }

        let scene = SCNScene()
        scene.background.contents = neutralClayStyle
            ? NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1.0)
            : NSColor.clear
        scene.rootNode.addChildNode(modelClone)

        let (minB, maxB) = modelClone.boundingBox
        let dx = Float(maxB.x - minB.x)
        let dy = Float(maxB.y - minB.y)
        let dz = Float(maxB.z - minB.z)
        let maxSpan = max(max(dx, dy), max(dz, 1.0))
        let midY = Float(minB.y + maxB.y) * 0.5

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = Double(max(0.1, maxSpan * 0.01))
        camera.zFar = Double(maxSpan * 20.0)
        camera.fieldOfView = 38
        cameraNode.camera = camera

        let dist = maxSpan * 1.85
        cameraNode.position = SCNVector3(CGFloat(dist * 0.78), CGFloat(midY + dist * 0.62), CGFloat(dist * 0.85))
        cameraNode.look(at: SCNVector3(0, CGFloat(midY * 0.85), 0))
        scene.rootNode.addChildNode(cameraNode)

        // Balanced 3-point studio lighting (no autoenablesDefaultLighting blowout)
        MeshLoaderService.addStudioLighting(to: scene)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false

        let pixelSize = neutralClayStyle
            ? NSSize(width: size.width, height: size.height)
            : NSSize(width: size.width * 1.5, height: size.height * 1.5)
        let image = renderer.snapshot(
            atTime: 0,
            with: pixelSize,
            antialiasingMode: .multisampling2X
        )

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    private static func applyNeutralClayMaterial(to node: SCNNode) {
        if let geo = node.geometry?.copy() as? SCNGeometry {
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = NSColor(calibratedWhite: 0.76, alpha: 1.0)
            mat.roughness.contents = 0.55
            mat.metalness.contents = 0.04
            mat.isDoubleSided = true
            geo.materials = [mat]
            node.geometry = geo
        }
        for child in node.childNodes {
            applyNeutralClayMaterial(to: child)
        }
    }
}

// MARK: - Serialized Disk Cache Writer (Synchronized with clearCache)

private actor ThumbnailDiskCache {
    private let directory: URL?
    private var generation: Int = 0

    init(directory: URL?) {
        self.directory = directory
    }

    func clear(toGeneration newGeneration: Int) {
        guard newGeneration > generation else { return }
        generation = newGeneration
        guard let dir = directory else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func writePNGData(_ data: Data, to url: URL, expectedGeneration: Int) {
        guard expectedGeneration >= generation else { return }
        try? data.write(to: url, options: .atomic)
    }

    func writeDownsampledPNG(cgImage: CGImage, fallbackData: Data, to url: URL, expectedGeneration: Int) {
        guard expectedGeneration >= generation else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url, options: .atomic)
        } else {
            try? fallbackData.write(to: url, options: .atomic)
        }
    }
}

// MARK: - ThumbnailService

@MainActor
@Observable
public final class ThumbnailService {
    public static let shared = ThumbnailService()

    private struct InFlightThumbnail {
        let task: Task<CGImage?, Never>
        var waiters: Set<UUID>
    }

    @ObservationIgnored private let preferEmbeddedKey = "PrintVault.PreferEmbedded3MFThumbnails.v1"
    @ObservationIgnored private let memoryCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var latestKeyByPathAndSize: [String: String] = [:]
    @ObservationIgnored private var inFlight: [String: InFlightThumbnail] = [:]
    @ObservationIgnored private var cacheGeneration: Int = 0
    @ObservationIgnored private let diskCacheDirectory: URL?
    @ObservationIgnored private let diskCache: ThumbnailDiskCache

    public var preferEmbedded3MFThumbnails: Bool {
        didSet {
            UserDefaults.standard.set(preferEmbedded3MFThumbnails, forKey: preferEmbeddedKey)
        }
    }

    private init() {
        memoryCache.countLimit = 600
        if UserDefaults.standard.object(forKey: preferEmbeddedKey) != nil {
            self.preferEmbedded3MFThumbnails = UserDefaults.standard.bool(forKey: preferEmbeddedKey)
        } else {
            self.preferEmbedded3MFThumbnails = true
        }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("PrintVault/Thumbnails_v2", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.diskCacheDirectory = dir
        } else {
            self.diskCacheDirectory = nil
        }
        self.diskCache = ThumbnailDiskCache(directory: self.diskCacheDirectory)
    }

    private nonisolated static func maxPixelDimension(for size: CGSize) -> Int {
        Int(max(size.width, size.height) * 2.0)
    }

    private nonisolated static func pathSizeKey(path: String, maxPixel: Int) -> String {
        "\(path)|\(maxPixel)"
    }

    private nonisolated static func fullMemoryKey(
        path: String,
        modTime: Int64,
        useEmbedded3MF: Bool,
        maxPixel: Int
    ) -> String {
        let mode = useEmbedded3MF ? "emb" : "scn"
        return "\(path)|\(modTime)|\(mode)|\(maxPixel)"
    }

    public func cachedThumbnail(
        for path: String,
        size: CGSize = CGSize(width: 240, height: 180)
    ) -> NSImage? {
        let maxPixel = Self.maxPixelDimension(for: size)
        let lookupKey = Self.pathSizeKey(path: path, maxPixel: maxPixel)
        guard let fullKey = latestKeyByPathAndSize[lookupKey] else { return nil }
        return memoryCache.object(forKey: fullKey as NSString)
    }

    public func clearCache() {
        cacheGeneration += 1
        let nextGeneration = cacheGeneration
        memoryCache.removeAllObjects()
        latestKeyByPathAndSize.removeAll()
        for (_, entry) in inFlight {
            entry.task.cancel()
        }
        inFlight.removeAll()
        let disk = self.diskCache
        Task {
            await disk.clear(toGeneration: nextGeneration)
        }
    }

    private func storeInMemory(_ image: NSImage, fullKey: String, path: String, maxPixel: Int) {
        let lookupKey = Self.pathSizeKey(path: path, maxPixel: maxPixel)
        if let oldKey = latestKeyByPathAndSize[lookupKey], oldKey != fullKey {
            memoryCache.removeObject(forKey: oldKey as NSString)
        }
        memoryCache.setObject(image, forKey: fullKey as NSString)
        latestKeyByPathAndSize[lookupKey] = fullKey
    }

    /// Renders a clean 384×384 neutral clay-gray studio PNG for Vision-Language Model classification
    /// so filament color or bright slicer thumbnails don't bias shape recognition.
    public func renderNeutralVLMPreviewPNG(for url: URL, size: CGSize = CGSize(width: 384, height: 384)) async -> Data? {
        if let rendered = await OffscreenThumbnailRenderer.shared.renderPNGData(
            for: url,
            size: size,
            neutralClayStyle: true
        ) {
            return rendered
        }
        // Fallback: if 3D render fails, convert whatever cached/embedded thumbnail we have into PNG bytes
        if let thumb = await thumbnail(for: url, size: size),
           let tiff = thumb.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    /// Loads or renders a downsampled, pre-decoded thumbnail, cooperating with SwiftUI `.task` cancellation and coalescing duplicate requests.
    public func thumbnail(for url: URL, size: CGSize = CGSize(width: 240, height: 180)) async -> NSImage? {
        guard !Task.isCancelled else { return nil }

        let maxPixel = Self.maxPixelDimension(for: size)
        let cacheDir = self.diskCacheDirectory
        let useEmbedded3MF = self.preferEmbedded3MFThumbnails
        let disk = self.diskCache
        let generation = self.cacheGeneration

        // Stat modTime off the main actor so modified files never hit stale memory cache entries
        let (modTime, diskURL) = await Self.resolveCacheMetadata(
            for: url,
            in: cacheDir,
            useEmbedded3MF: useEmbedded3MF
        )
        guard !Task.isCancelled else { return nil }

        let fullKey = Self.fullMemoryKey(
            path: url.path,
            modTime: modTime,
            useEmbedded3MF: useEmbedded3MF,
            maxPixel: maxPixel
        )
        if let existing = memoryCache.object(forKey: fullKey as NSString) {
            latestKeyByPathAndSize[Self.pathSizeKey(path: url.path, maxPixel: maxPixel)] = fullKey
            return existing
        }

        // Coalesce concurrent requests for the exact same (path, modTime, mode, size)
        let waiterID = UUID()
        let task: Task<CGImage?, Never>
        if var existing = inFlight[fullKey] {
            existing.waiters.insert(waiterID)
            inFlight[fullKey] = existing
            task = existing.task
        } else {
            let created = Task<CGImage?, Never> {
                await Self.loadOrRenderThumbnail(
                    url: url,
                    size: size,
                    maxPixel: maxPixel,
                    diskURL: diskURL,
                    useEmbedded3MF: useEmbedded3MF,
                    diskCache: disk,
                    generation: generation
                )
            }
            inFlight[fullKey] = InFlightThumbnail(task: created, waiters: [waiterID])
            task = created
        }

        let cgImage: CGImage? = await withTaskCancellationHandler {
            let result = await task.value
            finishWaiter(fullKey: fullKey, task: task, waiterID: waiterID)
            return result
        } onCancel: {
            Task { @MainActor in
                self.cancelWaiter(fullKey: fullKey, task: task, waiterID: waiterID)
            }
        }

        guard !Task.isCancelled, let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        if self.cacheGeneration == generation {
            storeInMemory(image, fullKey: fullKey, path: url.path, maxPixel: maxPixel)
        }
        return image
    }

    private func finishWaiter(fullKey: String, task: Task<CGImage?, Never>, waiterID: UUID) {
        guard var existing = inFlight[fullKey], existing.task == task else { return }
        existing.waiters.remove(waiterID)
        if existing.waiters.isEmpty {
            inFlight[fullKey] = nil
        } else {
            inFlight[fullKey] = existing
        }
    }

    private func cancelWaiter(fullKey: String, task: Task<CGImage?, Never>, waiterID: UUID) {
        guard var existing = inFlight[fullKey], existing.task == task else { return }
        existing.waiters.remove(waiterID)
        if existing.waiters.isEmpty {
            existing.task.cancel()
            inFlight[fullKey] = nil
        } else {
            inFlight[fullKey] = existing
        }
    }

    // MARK: - Off-Main-Actor Pipeline (Inherits Cooperative Cancellation)

    private nonisolated static func resolveCacheMetadata(
        for fileURL: URL,
        in dir: URL?,
        useEmbedded3MF: Bool
    ) async -> (modTime: Int64, diskURL: URL?) {
        let modTime = Int64(
            (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate?.timeIntervalSince1970) ?? 0
        )
        guard let dir else { return (modTime, nil) }
        let mode = useEmbedded3MF ? "emb" : "scn"
        let rawKey = "\(fileURL.path)|\(modTime)|\(mode)"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (modTime, dir.appendingPathComponent("\(hex).png"))
    }

    private nonisolated static func loadOrRenderThumbnail(
        url: URL,
        size: CGSize,
        maxPixel: Int,
        diskURL: URL?,
        useEmbedded3MF: Bool,
        diskCache: ThumbnailDiskCache,
        generation: Int
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }

        // 1. Fast path: check disk cache and pre-decode CGImage off the main actor
        if let diskURL,
           let decoded = decodeDownsampledCGImage(at: diskURL, maxPixelSize: maxPixel) {
            guard !Task.isCancelled else { return nil }
            return decoded
        }

        // 2. Brief scroll-settle debounce before kicking off expensive 3D / unzip work
        try? await Task.sleep(for: .milliseconds(45))
        guard !Task.isCancelled else { return nil }

        // 3. If 3MF has an embedded plate preview PNG and user prefers embedded previews
        if useEmbedded3MF && url.pathExtension.lowercased() == "3mf" {
            let targetSize = CGSize(width: size.width * 1.5, height: size.height * 1.5)
            if let rawData = MeshLoaderService.extract3MFThumbnailData(at: url),
               !Task.isCancelled,
               let cgImage = decodeDownsampledCGImage(from: rawData, maxPixelSize: maxPixel) {
                let framed = padOpaqueThumbnailToAspect(cgImage, targetSize: targetSize)
                guard !Task.isCancelled else { return nil }
                if let diskURL {
                    Task(priority: .background) {
                        await diskCache.writeDownsampledPNG(
                            cgImage: framed,
                            fallbackData: rawData,
                            to: diskURL,
                            expectedGeneration: generation
                        )
                    }
                }
                return framed
            }
        }

        guard !Task.isCancelled else { return nil }

        // 4. Render offscreen 3D snapshot on serial background Metal actor
        if let pngData = await OffscreenThumbnailRenderer.shared.renderPNGData(for: url, size: size) {
            guard !Task.isCancelled else { return nil }
            let decoded = decodeDownsampledCGImage(from: pngData, maxPixelSize: maxPixel)
            guard !Task.isCancelled else { return nil }
            if let diskURL {
                Task(priority: .background) {
                    await diskCache.writePNGData(pngData, to: diskURL, expectedGeneration: generation)
                }
            }
            if let decoded {
                return decoded
            }
        }

        guard !Task.isCancelled else { return nil }

        // 5. Fallback to macOS QuickLookThumbnailing
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2.0,
            representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            guard !Task.isCancelled else { return nil }
            return rep.cgImage
        }

        return nil
    }

    // MARK: - Off-Main-Thread ImageIO Downsampling & Seamless Framing

    /// If an embedded .3mf thumbnail has an opaque solid backdrop (e.g. light-gray square renders from PrusaSlicer/Printables),
    /// expands the canvas to match the card aspect ratio using its corner background color so there are no dark vertical side pillars.
    private nonisolated static func padOpaqueThumbnailToAspect(_ image: CGImage, targetSize: CGSize) -> CGImage {
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        guard srcW > 4, srcH > 4 else { return image }

        let targetAspect = targetSize.width / max(targetSize.height, 1)
        let srcAspect = srcW / srcH
        // Already close to card aspect ratio — leave untouched
        guard abs(srcAspect - targetAspect) > 0.12 else { return image }

        // Sample top-left pixel RGBA to check if background is opaque
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let sampleCtx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        sampleCtx.draw(image, in: CGRect(x: 0, y: -(image.height - 1), width: image.width, height: image.height))

        // If corner is transparent (e.g. Bambu Studio transparent plate PNG), let the card's dark studio backdrop show through
        guard pixel[3] > 235 else { return image }

        let dstW = Int(targetSize.width)
        let dstH = Int(targetSize.height)
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        ctx.setFillColor(
            red: CGFloat(pixel[0]) / 255.0,
            green: CGFloat(pixel[1]) / 255.0,
            blue: CGFloat(pixel[2]) / 255.0,
            alpha: 1.0
        )
        ctx.fill(CGRect(x: 0, y: 0, width: dstW, height: dstH))

        let scale = min(CGFloat(dstW) / srcW, CGFloat(dstH) / srcH)
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawRect = CGRect(
            x: (CGFloat(dstW) - drawW) * 0.5,
            y: (CGFloat(dstH) - drawH) * 0.5,
            width: drawW,
            height: drawH
        )
        ctx.interpolationQuality = .high
        ctx.draw(image, in: drawRect)
        return ctx.makeImage() ?? image
    }

    private nonisolated static func decodeDownsampledCGImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        return makeThumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func decodeDownsampledCGImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        return makeThumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func makeThumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
