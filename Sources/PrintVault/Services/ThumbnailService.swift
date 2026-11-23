import Foundation
import AppKit
import SceneKit
import QuickLookThumbnailing
import CryptoKit
import ImageIO

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

        let modelClone = loaded.rootNode.clone()
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
        let keyLightNode = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 900
        keyLightNode.light = keyLight
        keyLightNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(keyLightNode)

        let fillLightNode = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 340
        fillLight.color = NSColor(calibratedRed: 0.85, green: 0.90, blue: 1.0, alpha: 1.0)
        fillLightNode.light = fillLight
        fillLightNode.eulerAngles = SCNVector3(-Float.pi / 5, -Float.pi * 0.65, 0)
        scene.rootNode.addChildNode(fillLightNode)

        let rimLightNode = SCNNode()
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.intensity = 280
        rimLightNode.light = rimLight
        rimLightNode.eulerAngles = SCNVector3(-Float.pi / 6, Float.pi * 0.9, 0)
        scene.rootNode.addChildNode(rimLightNode)

        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 220
        ambient.color = NSColor(calibratedWhite: 0.88, alpha: 1.0)
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

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

// MARK: - ThumbnailService

@MainActor
public final class ThumbnailService {
    public static let shared = ThumbnailService()

    private let preferEmbeddedKey = "PrintVault.PreferEmbedded3MFThumbnails.v1"
    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskCacheDirectory: URL?

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
    }

    public func cachedThumbnail(for path: String) -> NSImage? {
        memoryCache.object(forKey: path as NSString)
    }

    public func clearCache() {
        memoryCache.removeAllObjects()
        if let dir = diskCacheDirectory {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
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

    /// Loads or renders a downsampled, pre-decoded thumbnail, cooperating with SwiftUI `.task` cancellation so fast scrolling never stalls.
    public func thumbnail(for url: URL, size: CGSize = CGSize(width: 240, height: 180)) async -> NSImage? {
        let memKey = url.path as NSString
        if let existing = memoryCache.object(forKey: memKey) {
            return existing
        }

        let maxPixel = Int(max(size.width, size.height) * 2.0)
        let cacheDir = self.diskCacheDirectory
        let useEmbedded3MF = self.preferEmbedded3MFThumbnails

        // 1. Fast path: check disk cache off the main thread and pre-decode CGImage immediately
        let diskURL = await Task.detached(priority: .utility) {
            Self.diskCacheURL(for: url, in: cacheDir, useEmbedded3MF: useEmbedded3MF)
        }.value
        guard !Task.isCancelled else { return nil }

        if let diskURL {
            if let decoded = await Task.detached(priority: .utility, operation: {
                Self.decodeDownsampledCGImage(at: diskURL, maxPixelSize: maxPixel)
            }).value {
                guard !Task.isCancelled else { return nil }
                let img = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                memoryCache.setObject(img, forKey: memKey)
                return img
            }
        }

        // 2. Brief scroll-settle debounce before kicking off expensive 3D / unzip work
        try? await Task.sleep(nanoseconds: 45_000_000)
        guard !Task.isCancelled else { return nil }

        if let existing = memoryCache.object(forKey: memKey) {
            return existing
        }

        // 3. If 3MF has an embedded plate preview PNG and user prefers embedded previews, extract, pad opaque squares seamlessly, & downsample off the main thread
        if useEmbedded3MF && url.pathExtension.lowercased() == "3mf" {
            let targetSize = CGSize(width: size.width * 1.5, height: size.height * 1.5)
            let embeddedResult: (CGImage, Data)? = await Task.detached(priority: .utility) {
                guard !Task.isCancelled,
                      let rawData = MeshLoaderService.extract3MFThumbnailData(at: url),
                      let cgImage = Self.decodeDownsampledCGImage(from: rawData, maxPixelSize: maxPixel) else {
                    return nil
                }
                let framed = Self.padOpaqueThumbnailToAspect(cgImage, targetSize: targetSize)
                return (framed, rawData)
            }.value

            guard !Task.isCancelled else { return nil }
            if let (cgImage, rawData) = embeddedResult {
                if let diskURL {
                    Task.detached(priority: .background) {
                        Self.writeDownsampledPNG(cgImage: cgImage, fallbackData: rawData, to: diskURL)
                    }
                }
                let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                memoryCache.setObject(img, forKey: memKey)
                return img
            }
        }

        // 4. Render offscreen 3D snapshot on serial background Metal actor
        if let pngData = await OffscreenThumbnailRenderer.shared.renderPNGData(for: url, size: size) {
            guard !Task.isCancelled else { return nil }
            let decoded: CGImage? = await Task.detached(priority: .utility) {
                Self.decodeDownsampledCGImage(from: pngData, maxPixelSize: maxPixel)
            }.value
            guard !Task.isCancelled else { return nil }
            if let diskURL {
                Task.detached(priority: .background) {
                    try? pngData.write(to: diskURL, options: .atomic)
                }
            }
            if let decoded {
                let img = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                memoryCache.setObject(img, forKey: memKey)
                return img
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
            let img = rep.nsImage
            memoryCache.setObject(img, forKey: memKey)
            return img
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

    private nonisolated static func writeDownsampledPNG(cgImage: CGImage, fallbackData: Data, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url, options: .atomic)
        } else {
            try? fallbackData.write(to: url, options: .atomic)
        }
    }

    private nonisolated static func diskCacheURL(for fileURL: URL, in dir: URL?, useEmbedded3MF: Bool) -> URL? {
        guard let dir else { return nil }
        let modTime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let mode = useEmbedded3MF ? "emb" : "scn"
        let rawKey = "\(fileURL.path)|\(Int64(modTime))|\(mode)"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(hex).png")
    }
}
