import Foundation
import SceneKit
import SceneKit.ModelIO
import ModelIO
import AppKit
import simd

// MARK: - Loaded Mesh Result

public struct MeshMetadata: Sendable, Equatable {
    public let vertexCount: Int
    public let triangleCount: Int
    public let dimensionX: Double
    public let dimensionY: Double
    public let dimensionZ: Double
    public let volumeCm3: Double
    public let surfaceAreaCm2: Double
    public let subModelCount: Int

    public init(
        vertexCount: Int,
        triangleCount: Int,
        dimensionX: Double,
        dimensionY: Double,
        dimensionZ: Double,
        volumeCm3: Double,
        surfaceAreaCm2: Double = 0,
        subModelCount: Int
    ) {
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.dimensionX = dimensionX
        self.dimensionY = dimensionY
        self.dimensionZ = dimensionZ
        self.volumeCm3 = volumeCm3
        self.surfaceAreaCm2 = surfaceAreaCm2
        self.subModelCount = subModelCount
    }
}

public struct LoadedMeshScene: @unchecked Sendable {
    public let rootNode: SCNNode
    public let metadata: MeshMetadata
    public let embeddedThumbnail: NSImage?
}

// MARK: - Small In-Memory Scene Cache (Instant Re-selection of Heavy Models)

private actor LoadedSceneCache {
    static let shared = LoadedSceneCache()
    private var entries: [(key: String, scene: LoadedMeshScene)] = []
    private let maxEntries = 4

    func get(key: String) -> LoadedMeshScene? {
        guard let idx = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: idx)
        entries.append(entry)
        return entry.scene
    }

    func set(key: String, scene: LoadedMeshScene) {
        entries.removeAll { $0.key == key }
        entries.append((key, scene))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}

// MARK: - MeshLoaderService

public enum MeshLoaderService {

    /// Maximum triangles uploaded to SceneKit for interactive preview before applying fast watertight vertex-clustering LOD.
    /// Exact full-resolution triangle count, dimensions, volume, and surface area are always computed from the full mesh.
    private static let previewLODTriangleThreshold = 500_000

    /// Loads a 3D print file (.stl or .3mf) into an `SCNNode` with computed normals and exact millimeter bounding box metadata.
    public static func loadMesh(at url: URL) async throws -> LoadedMeshScene {
        let cacheKey = makeCacheKey(for: url)
        if let cached = await LoadedSceneCache.shared.get(key: cacheKey) {
            return cached
        }

        let ext = url.pathExtension.lowercased()
        let loaded: LoadedMeshScene
        switch ext {
        case "stl":
            loaded = try await Task.detached(priority: .userInitiated) {
                try loadSTL(at: url)
            }.value
        case "3mf":
            loaded = try await Task.detached(priority: .userInitiated) {
                try load3MF(at: url)
            }.value
        default:
            loaded = try await Task.detached(priority: .userInitiated) {
                try loadViaModelIO(at: url)
            }.value
        }

        await LoadedSceneCache.shared.set(key: cacheKey, scene: loaded)
        return loaded
    }

    /// Lightweight metadata-only analyzer for background indexing (skips SceneKit GPU buffer creation for huge files).
    public static func analyzeMetadata(at url: URL) async -> MeshMetadata? {
        let ext = url.pathExtension.lowercased()
        do {
            switch ext {
            case "stl":
                return try await Task.detached(priority: .utility) {
                    try loadSTL(at: url, buildScene: false).metadata
                }.value
            case "3mf":
                return try await Task.detached(priority: .utility) {
                    try load3MF(at: url, buildScene: false).metadata
                }.value
            default:
                return try await Task.detached(priority: .utility) {
                    try loadViaModelIO(at: url).metadata
                }.value
            }
        } catch {
            return nil
        }
    }

    private static func makeCacheKey(for url: URL) -> String {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mod = Int64(vals?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let size = vals?.fileSize ?? 0
        return "\(url.path)|\(mod)|\(size)"
    }

    /// Extracts raw PNG data for an embedded thumbnail from a .3mf archive in a single zip listing pass.
    public static func extract3MFThumbnailData(at url: URL) -> Data? {
        guard url.pathExtension.lowercased() == "3mf" else { return nil }
        let entries = listZipEntries(at: url)
        guard !entries.isEmpty else { return nil }

        let entryLookup = Dictionary(entries.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let preferredPaths = [
            "metadata/plate_1.png",
            "metadata/thumbnail.png",
            "metadata/top_1.png",
            "auxiliaries/.thumbnails/thumbnail_middle.png",
            "auxiliaries/.thumbnails/thumbnail_3mf.png"
        ]
        for candidate in preferredPaths {
            if let exactEntry = entryLookup[candidate],
               let data = unzipEntry(at: url, entryPath: exactEntry) {
                return data
            }
        }
        if let firstPng = entries.first(where: { $0.lowercased().hasSuffix(".png") && !$0.lowercased().contains("filament") }),
           let data = unzipEntry(at: url, entryPath: firstPng) {
            return data
        }
        return nil
    }

    /// Extracts an embedded thumbnail from a .3mf archive if available.
    public static func extract3MFThumbnail(at url: URL) -> NSImage? {
        guard let data = extract3MFThumbnailData(at: url) else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Native Binary & ASCII STL Parser

    private static func loadSTL(at url: URL, buildScene: Bool = true) throws -> LoadedMeshScene {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 84 else {
            if let asciiScene = parseASCIISTL(data: data, buildScene: buildScene) {
                return asciiScene
            }
            return try loadViaModelIO(at: url)
        }

        let triCountU32: UInt32 = data.withUnsafeBytes { rawBuffer in
            UInt32(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
        }
        let expectedBinarySize = 84 + Int(triCountU32) * 50

        if triCountU32 > 0 && data.count >= expectedBinarySize && (data.count - expectedBinarySize) <= 64 {
            return parseBinarySTL(data: data, triangleCount: Int(triCountU32), buildScene: buildScene)
        }

        if let prefix = String(data: data.prefix(1024), encoding: .utf8) ?? String(data: data.prefix(1024), encoding: .ascii) {
            let lowered = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered.hasPrefix("solid") && (lowered.contains("facet") || lowered.contains("vertex")) {
                if let asciiScene = parseASCIISTL(data: data, buildScene: buildScene) {
                    return asciiScene
                }
            }
        }

        return try loadViaModelIO(at: url)
    }

    private static func parseBinarySTL(data: Data, triangleCount: Int, buildScene: Bool) -> LoadedMeshScene {
        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        positions.reserveCapacity(triangleCount * 3)
        if buildScene && triangleCount <= previewLODTriangleThreshold {
            normals.reserveCapacity(triangleCount * 3)
        }

        var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let collectNormals = buildScene && triangleCount <= previewLODTriangleThreshold

        data.withUnsafeBytes { raw in
            var offset = 84
            for _ in 0..<triangleCount {
                guard offset + 50 <= raw.count else { break }

                let v1 = SIMD3<Float>(
                    raw.loadUnaligned(fromByteOffset: offset + 12, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: offset + 16, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: offset + 20, as: Float.self)
                )
                let v2 = SIMD3<Float>(
                    raw.loadUnaligned(fromByteOffset: offset + 24, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: offset + 28, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: offset + 32, as: Float.self)
                )
                let v3 = SIMD3<Float>(
                    raw.loadUnaligned(fromByteOffset: offset + 36, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: offset + 40, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: offset + 44, as: Float.self)
                )

                minBounds = simd_min(minBounds, simd_min(v1, simd_min(v2, v3)))
                maxBounds = simd_max(maxBounds, simd_max(v1, simd_max(v2, v3)))

                positions.append(v1)
                positions.append(v2)
                positions.append(v3)

                if collectNormals {
                    let nx = raw.loadUnaligned(fromByteOffset: offset + 0, as: Float.self)
                    let ny = raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                    let nz = raw.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                    var normal = SIMD3<Float>(nx, ny, nz)
                    let lenSq = simd_length_squared(normal)
                    if lenSq < 1e-6 || !lenSq.isFinite {
                        let cross = simd_cross(v2 - v1, v3 - v1)
                        let cLen = simd_length(cross)
                        normal = cLen > 1e-7 ? (cross / cLen) : SIMD3<Float>(0, 0, 1)
                    } else if abs(lenSq - 1.0) > 1e-3 {
                        normal = normal / sqrt(lenSq)
                    }
                    normals.append(normal)
                    normals.append(normal)
                    normals.append(normal)
                }

                offset += 50
            }
        }

        let (volumeMm3, areaMm2) = computeVolumeAndSurfaceArea(
            positions: positions,
            minBounds: minBounds,
            maxBounds: maxBounds
        )

        return buildSceneFromUnindexedTriangles(
            positions: positions,
            normals: collectNormals ? normals : nil,
            reportedVertexCount: positions.count,
            minBounds: minBounds,
            maxBounds: maxBounds,
            volumeMm3: volumeMm3,
            surfaceAreaMm2: areaMm2,
            subModelCount: 1,
            buildScene: buildScene
        )
    }

    private static func parseASCIISTL(data: Data, buildScene: Bool) -> LoadedMeshScene? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }

        var positions = [SIMD3<Float>]()
        var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        var currentVerts = [SIMD3<Float>]()
        currentVerts.reserveCapacity(3)

        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("vertex") {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 4,
                   let x = Float(parts[1]),
                   let y = Float(parts[2]),
                   let z = Float(parts[3]) {
                    currentVerts.append(SIMD3<Float>(x, y, z))
                    if currentVerts.count == 3 {
                        let v1 = currentVerts[0]
                        let v2 = currentVerts[1]
                        let v3 = currentVerts[2]
                        minBounds = simd_min(minBounds, simd_min(v1, simd_min(v2, v3)))
                        maxBounds = simd_max(maxBounds, simd_max(v1, simd_max(v2, v3)))
                        positions.append(v1)
                        positions.append(v2)
                        positions.append(v3)
                        currentVerts.removeAll(keepingCapacity: true)
                    }
                }
            }
        }

        guard !positions.isEmpty else { return nil }

        let (volumeMm3, areaMm2) = computeVolumeAndSurfaceArea(
            positions: positions,
            minBounds: minBounds,
            maxBounds: maxBounds
        )

        return buildSceneFromUnindexedTriangles(
            positions: positions,
            normals: nil,
            reportedVertexCount: positions.count,
            minBounds: minBounds,
            maxBounds: maxBounds,
            volumeMm3: volumeMm3,
            surfaceAreaMm2: areaMm2,
            subModelCount: 1,
            buildScene: buildScene
        )
    }

    // MARK: - High-Performance Native 3MF Archive & Parallel Byte-Level Mesh Parser

    private struct Resolved3MFMeshInstance {
        var vertices: [SIMD3<Float>]
        var triangles: [Int32] // 3 indices per triangle into `vertices`
    }

    private static func load3MF(at url: URL, buildScene: Bool = true) throws -> LoadedMeshScene {
        // 1. Extract all `.model` XML files in ONE single unzip invocation (instead of re-opening the ZIP per mesh!)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pv_3mf_load_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let extractedModelFiles = extractAllModelFiles(from: url, into: tempDir)
        guard !extractedModelFiles.isEmpty else {
            throw NSError(domain: "MeshLoaderService", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No 3D .model files found inside 3MF archive."
            ])
        }

        // 2. Parse all extracted `.model` files in parallel across CPU cores using our zero-allocation UTF-8 scanner
        final class SyncModelMap: @unchecked Sendable {
            private let lock = NSLock()
            var models: [String: ThreeMFDocument] = [:]
            func set(_ key: String, _ doc: ThreeMFDocument) {
                lock.lock()
                models[key] = doc
                lock.unlock()
            }
        }
        let syncModels = SyncModelMap()

        DispatchQueue.concurrentPerform(iterations: extractedModelFiles.count) { idx in
            let (relativePath, fileURL) = extractedModelFiles[idx]
            guard let xmlData = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return }
            var doc = FastThreeMFByteParser.parse(data: xmlData)
            if doc == nil || doc!.objects.isEmpty {
                let fallback = ThreeMFXMLMeshParser()
                doc = fallback.parseDocument(data: xmlData)
            }
            if let doc {
                let key = normalize3MFPath(relativePath)
                syncModels.set(key, doc)
            }
        }
        let parsedModels = syncModels.models

        let rootKey = parsedModels.keys.first(where: { $0.lowercased() == "3d/3dmodel.model" })
            ?? parsedModels.keys.sorted().first

        // 3. Resolve build hierarchy & transforms into indexed mesh instances (no 3x vertex explosion!)
        var instances: [Resolved3MFMeshInstance] = []
        var totalUniqueVerts = 0
        var totalTriangles = 0
        var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        func collectMesh(_ mesh: ThreeMFMesh, transform: simd_float4x4, unitScale: Float) {
            let srcVerts = mesh.vertices
            let srcTris = mesh.triangles
            guard !srcVerts.isEmpty, srcTris.count >= 3 else { return }

            let isIdentity = transform == matrix_identity_float4x4
            var transformedVerts = [SIMD3<Float>]()
            transformedVerts.reserveCapacity(srcVerts.count)

            if isIdentity && unitScale == 1.0 {
                for v in srcVerts {
                    minBounds = simd_min(minBounds, v)
                    maxBounds = simd_max(maxBounds, v)
                    transformedVerts.append(v)
                }
            } else if isIdentity {
                for v in srcVerts {
                    let sv = v * unitScale
                    minBounds = simd_min(minBounds, sv)
                    maxBounds = simd_max(maxBounds, sv)
                    transformedVerts.append(sv)
                }
            } else {
                for v in srcVerts {
                    let p4 = transform * SIMD4<Float>(v.x, v.y, v.z, 1.0)
                    let sv = SIMD3<Float>(p4.x, p4.y, p4.z) * unitScale
                    minBounds = simd_min(minBounds, sv)
                    maxBounds = simd_max(maxBounds, sv)
                    transformedVerts.append(sv)
                }
            }

            totalUniqueVerts += transformedVerts.count
            totalTriangles += srcTris.count / 3
            instances.append(Resolved3MFMeshInstance(vertices: transformedVerts, triangles: srcTris))
        }

        func resolveObject(
            id: String,
            inDocPath docPath: String,
            parentTransform: simd_float4x4,
            depth: Int
        ) {
            guard depth < 12, let doc = parsedModels[docPath], let obj = doc.objects[id] else { return }
            if let mesh = obj.mesh {
                collectMesh(mesh, transform: parentTransform, unitScale: doc.unitToMillimeters)
            }
            for comp in obj.components {
                let targetDoc = comp.externalPath.map { normalize3MFPath($0) } ?? docPath
                let combined = parentTransform * comp.transform
                resolveObject(id: comp.objectId, inDocPath: targetDoc, parentTransform: combined, depth: depth + 1)
            }
        }

        if let rootKey, let rootDoc = parsedModels[rootKey], !rootDoc.buildItems.isEmpty {
            for buildItem in rootDoc.buildItems {
                resolveObject(
                    id: buildItem.objectId,
                    inDocPath: rootKey,
                    parentTransform: buildItem.transform,
                    depth: 0
                )
            }
        }

        if instances.isEmpty {
            for doc in parsedModels.values {
                for obj in doc.objects.values {
                    if let mesh = obj.mesh {
                        collectMesh(mesh, transform: matrix_identity_float4x4, unitScale: doc.unitToMillimeters)
                    }
                }
            }
        }

        guard !instances.isEmpty else {
            throw NSError(domain: "MeshLoaderService", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No 3D mesh geometry found inside 3MF archive."
            ])
        }
        let resolvedTotalTriangles = instances.reduce(0) { $0 + ($1.triangles.count / 3) }
        guard resolvedTotalTriangles > 0 else {
            throw NSError(domain: "MeshLoaderService", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No 3D mesh geometry found inside 3MF archive."
            ])
        }

        // 4. Compute exact full-resolution volume (per sub-mesh instance, centroid-shifted) & exact surface area in parallel
        final class MetricBox: @unchecked Sendable {
            var volumes: [Double]
            var areas: [Double]
            init(count: Int) {
                self.volumes = [Double](repeating: 0, count: count)
                self.areas = [Double](repeating: 0, count: count)
            }
        }
        let metricBox = MetricBox(count: instances.count)
        let capturedInstances = instances

        DispatchQueue.concurrentPerform(iterations: capturedInstances.count) { idx in
            let instance = capturedInstances[idx]
            let verts = instance.vertices
            let tris = instance.triangles
            let vCount = verts.count
            var instMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var instMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in verts {
                instMin = simd_min(instMin, v)
                instMax = simd_max(instMax, v)
            }
            let cx = Double(instMin.x + instMax.x) * 0.5
            let cy = Double(instMin.y + instMax.y) * 0.5
            let cz = Double(instMin.z + instMax.z) * 0.5

            var instSignedVol: Double = 0
            var instArea: Double = 0
            var i = 0
            while i + 2 < tris.count {
                let i1 = Int(tris[i])
                let i2 = Int(tris[i + 1])
                let i3 = Int(tris[i + 2])
                i += 3
                guard i1 >= 0, i2 >= 0, i3 >= 0, i1 < vCount, i2 < vCount, i3 < vCount else { continue }
                let p1 = verts[i1]
                let p2 = verts[i2]
                let p3 = verts[i3]

                let a = SIMD3<Double>(Double(p1.x) - cx, Double(p1.y) - cy, Double(p1.z) - cz)
                let b = SIMD3<Double>(Double(p2.x) - cx, Double(p2.y) - cy, Double(p2.z) - cz)
                let c = SIMD3<Double>(Double(p3.x) - cx, Double(p3.y) - cy, Double(p3.z) - cz)

                instArea += 0.5 * simd_length(simd_cross(b - a, c - a))
                instSignedVol += simd_dot(a, simd_cross(b, c)) / 6.0
            }
            metricBox.volumes[idx] = abs(instSignedVol)
            metricBox.areas[idx] = instArea
        }

        let totalVolMm3 = metricBox.volumes.reduce(0, +)
        let totalAreaMm2 = metricBox.areas.reduce(0, +)

        let dx = Double(max(0, maxBounds.x - minBounds.x))
        let dy = Double(max(0, maxBounds.y - minBounds.y))
        let dz = Double(max(0, maxBounds.z - minBounds.z))

        let metadata = MeshMetadata(
            vertexCount: totalUniqueVerts,
            triangleCount: totalTriangles,
            dimensionX: dx,
            dimensionY: dy,
            dimensionZ: dz,
            volumeCm3: max(0.01, totalVolMm3 / 1000.0),
            surfaceAreaCm2: max(0.0, totalAreaMm2 / 100.0),
            subModelCount: max(instances.count, 1)
        )

        guard buildScene else {
            return LoadedMeshScene(rootNode: SCNNode(), metadata: metadata, embeddedThumbnail: nil)
        }

        // 5. Build fast packed Float32 indexed SceneKit geometry (with watertight vertex-clustering LOD if > 500k triangles)
        let rootNode: SCNNode
        if totalTriangles > previewLODTriangleThreshold {
            rootNode = buildClusteredPreviewNode(
                instances: instances,
                minBounds: minBounds,
                maxBounds: maxBounds
            )
        } else {
            rootNode = buildIndexedSceneNode(
                instances: instances,
                minBounds: minBounds,
                maxBounds: maxBounds
            )
        }

        return LoadedMeshScene(rootNode: rootNode, metadata: metadata, embeddedThumbnail: nil)
    }

    private static func normalize3MFPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        return trimmed.lowercased()
    }

    // MARK: - ModelIO Fallback Loader (.stl)

    private static func loadViaModelIO(at url: URL) throws -> LoadedMeshScene {
        let asset = MDLAsset(url: url)
        asset.loadTextures()

        let rootNode = SCNNode()
        var totalVerts = 0
        var totalTris = 0

        for i in 0..<asset.count {
            let obj = asset.object(at: i)
            let childNode = SCNNode(mdlObject: obj)
            rootNode.addChildNode(childNode)
        }

        func countGeometry(_ node: SCNNode) {
            if let geo = node.geometry {
                for src in geo.sources(for: .vertex) {
                    totalVerts += src.vectorCount
                }
                for elem in geo.elements {
                    totalTris += elem.primitiveCount
                }
                geo.firstMaterial = defaultPrintMaterial()
            }
            for child in node.childNodes {
                countGeometry(child)
            }
        }
        countGeometry(rootNode)

        guard totalTris > 0 || totalVerts > 0 else {
            throw NSError(domain: "MeshLoaderService", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Unable to parse 3D geometry from \(url.lastPathComponent)."
            ])
        }

        let (bMin, bMax) = rootNode.boundingBox
        let dx = Double(max(0, bMax.x - bMin.x))
        let dy = Double(max(0, bMax.y - bMin.y))
        let dz = Double(max(0, bMax.z - bMin.z))

        let centerX = (bMin.x + bMax.x) * 0.5
        let centerY = (bMin.y + bMax.y) * 0.5
        let minZ = bMin.z

        let wrapper = SCNNode()
        rootNode.position = SCNVector3(-centerX, -centerY, -minZ)
        let zUpContainer = SCNNode()
        zUpContainer.eulerAngles.x = -.pi / 2
        zUpContainer.addChildNode(rootNode)
        wrapper.addChildNode(zUpContainer)

        let approxVolCm3 = (dx * dy * dz * 0.35) / 1000.0
        let meta = MeshMetadata(
            vertexCount: totalVerts,
            triangleCount: totalTris,
            dimensionX: dx,
            dimensionY: dy,
            dimensionZ: dz,
            volumeCm3: approxVolCm3,
            subModelCount: max(asset.count, 1)
        )

        return LoadedMeshScene(rootNode: wrapper, metadata: meta, embeddedThumbnail: nil)
    }

    // MARK: - Accurate Volume (Per-Component) & Surface Area Computation

    private struct QuantizedVertex: Hashable {
        let x: Int64
        let y: Int64
        let z: Int64

        init(_ p: SIMD3<Float>) {
            self.x = Int64((Double(p.x) * 100.0).rounded())
            self.y = Int64((Double(p.y) * 100.0).rounded())
            self.z = Int64((Double(p.z) * 100.0).rounded())
        }
    }

    /// Computes exact surface area (mm²) and positive volume (mm³), shifting around the mesh centroid for numerical stability
    /// and summing `abs(volume)` per connected shell so mirrored/inverted sub-parts never cancel each other out.
    private static func computeVolumeAndSurfaceArea(
        positions: [SIMD3<Float>],
        minBounds: SIMD3<Float>,
        maxBounds: SIMD3<Float>
    ) -> (volumeMm3: Double, surfaceAreaMm2: Double) {
        let triCount = positions.count / 3
        guard triCount > 0 else { return (0, 0) }

        let cx = Double(minBounds.x + maxBounds.x) * 0.5
        let cy = Double(minBounds.y + maxBounds.y) * 0.5
        let cz = Double(minBounds.z + maxBounds.z) * 0.5

        var totalAreaMm2: Double = 0

        if triCount > 250_000 {
            var signedVol: Double = 0
            for t in 0..<triCount {
                let p1 = positions[t * 3]
                let p2 = positions[t * 3 + 1]
                let p3 = positions[t * 3 + 2]

                let a = SIMD3<Double>(Double(p1.x) - cx, Double(p1.y) - cy, Double(p1.z) - cz)
                let b = SIMD3<Double>(Double(p2.x) - cx, Double(p2.y) - cy, Double(p2.z) - cz)
                let c = SIMD3<Double>(Double(p3.x) - cx, Double(p3.y) - cy, Double(p3.z) - cz)

                let crossEdge = simd_cross(b - a, c - a)
                totalAreaMm2 += 0.5 * simd_length(crossEdge)
                signedVol += simd_dot(a, simd_cross(b, c)) / 6.0
            }
            return (abs(signedVol), totalAreaMm2)
        }

        var parent: [Int] = []
        parent.reserveCapacity(min(triCount * 2, 128_000))
        var vertexToNode: [QuantizedVertex: Int] = [:]
        vertexToNode.reserveCapacity(min(triCount * 2, 128_000))

        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root {
                root = parent[root]
            }
            var cur = x
            while parent[cur] != root {
                let next = parent[cur]
                parent[cur] = root
                cur = next
            }
            return root
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb {
                parent[rb] = ra
            }
        }

        func nodeIndex(for p: SIMD3<Float>) -> Int {
            let key = QuantizedVertex(p)
            if let existing = vertexToNode[key] {
                return existing
            }
            let idx = parent.count
            parent.append(idx)
            vertexToNode[key] = idx
            return idx
        }

        var triFirstNode = [Int](repeating: 0, count: triCount)
        var triSignedVol = [Double](repeating: 0, count: triCount)

        for t in 0..<triCount {
            let p1 = positions[t * 3]
            let p2 = positions[t * 3 + 1]
            let p3 = positions[t * 3 + 2]

            let n1 = nodeIndex(for: p1)
            let n2 = nodeIndex(for: p2)
            let n3 = nodeIndex(for: p3)
            union(n1, n2)
            union(n1, n3)
            triFirstNode[t] = n1

            let a = SIMD3<Double>(Double(p1.x) - cx, Double(p1.y) - cy, Double(p1.z) - cz)
            let b = SIMD3<Double>(Double(p2.x) - cx, Double(p2.y) - cy, Double(p2.z) - cz)
            let c = SIMD3<Double>(Double(p3.x) - cx, Double(p3.y) - cy, Double(p3.z) - cz)

            let crossEdge = simd_cross(b - a, c - a)
            totalAreaMm2 += 0.5 * simd_length(crossEdge)
            triSignedVol[t] = simd_dot(a, simd_cross(b, c)) / 6.0
        }

        var componentVolumes: [Int: Double] = [:]
        for t in 0..<triCount {
            let root = find(triFirstNode[t])
            componentVolumes[root, default: 0] += triSignedVol[t]
        }

        let totalVolMm3 = componentVolumes.values.reduce(0.0) { $0 + abs($1) }
        return (totalVolMm3, totalAreaMm2)
    }

    // MARK: - Packed Float32 SceneKit Geometry Builders + Watertight Vertex-Clustering LOD

    private struct PackedFloat3 {
        var x: Float
        var y: Float
        var z: Float
    }

    private static func makeFloat3GeometrySource(
        _ array: [PackedFloat3],
        semantic: SCNGeometrySource.Semantic
    ) -> SCNGeometrySource {
        let data = array.withUnsafeBytes { Data($0) }
        return SCNGeometrySource(
            data: data,
            semantic: semantic,
            vectorCount: array.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<PackedFloat3>.stride
        )
    }

    private static func buildSceneFromUnindexedTriangles(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>]?,
        reportedVertexCount: Int,
        minBounds: SIMD3<Float>,
        maxBounds: SIMD3<Float>,
        volumeMm3: Double,
        surfaceAreaMm2: Double,
        subModelCount: Int,
        buildScene: Bool
    ) -> LoadedMeshScene {
        let triCount = positions.count / 3
        let dx = Double(max(0, maxBounds.x - minBounds.x))
        let dy = Double(max(0, maxBounds.y - minBounds.y))
        let dz = Double(max(0, maxBounds.z - minBounds.z))

        let metadata = MeshMetadata(
            vertexCount: reportedVertexCount,
            triangleCount: triCount,
            dimensionX: dx,
            dimensionY: dy,
            dimensionZ: dz,
            volumeCm3: max(0.01, volumeMm3 / 1000.0),
            surfaceAreaCm2: max(0.0, surfaceAreaMm2 / 100.0),
            subModelCount: subModelCount
        )

        guard buildScene else {
            return LoadedMeshScene(rootNode: SCNNode(), metadata: metadata, embeddedThumbnail: nil)
        }

        // For massive STLs (> 500k triangles), use watertight spatial vertex clustering for instant interactive preview
        if triCount > previewLODTriangleThreshold {
            let rootNode = buildClusteredPreviewNodeFromUnindexed(
                positions: positions,
                minBounds: minBounds,
                maxBounds: maxBounds
            )
            return LoadedMeshScene(rootNode: rootNode, metadata: metadata, embeddedThumbnail: nil)
        }

        let centerX = (minBounds.x + maxBounds.x) * 0.5
        let centerY = (minBounds.y + maxBounds.y) * 0.5
        let baseZ = minBounds.z

        var packedVerts = [PackedFloat3]()
        var packedNormals = [PackedFloat3]()
        packedVerts.reserveCapacity(positions.count)
        packedNormals.reserveCapacity(positions.count)

        if let normals, normals.count == positions.count {
            for i in 0..<positions.count {
                let p = positions[i]
                let n = normals[i]
                packedVerts.append(PackedFloat3(x: p.x - centerX, y: p.z - baseZ, z: -(p.y - centerY)))
                packedNormals.append(PackedFloat3(x: n.x, y: n.z, z: -n.y))
            }
        } else {
            var i = 0
            while i + 2 < positions.count {
                let v1 = positions[i]
                let v2 = positions[i + 1]
                let v3 = positions[i + 2]
                let cross = simd_cross(v2 - v1, v3 - v1)
                let len = simd_length(cross)
                let n = len > 1e-7 ? (cross / len) : SIMD3<Float>(0, 0, 1)
                let pn = PackedFloat3(x: n.x, y: n.z, z: -n.y)

                packedVerts.append(PackedFloat3(x: v1.x - centerX, y: v1.z - baseZ, z: -(v1.y - centerY)))
                packedVerts.append(PackedFloat3(x: v2.x - centerX, y: v2.z - baseZ, z: -(v2.y - centerY)))
                packedVerts.append(PackedFloat3(x: v3.x - centerX, y: v3.z - baseZ, z: -(v3.y - centerY)))
                packedNormals.append(pn)
                packedNormals.append(pn)
                packedNormals.append(pn)
                i += 3
            }
        }

        let vertexSource = makeFloat3GeometrySource(packedVerts, semantic: .vertex)
        let normalSource = makeFloat3GeometrySource(packedNormals, semantic: .normal)
        var indices = [Int32](repeating: 0, count: packedVerts.count)
        for idx in 0..<packedVerts.count { indices[idx] = Int32(idx) }
        let indexData = indices.withUnsafeBytes { Data($0) }

        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: packedVerts.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        geometry.firstMaterial = defaultPrintMaterial()

        let meshNode = SCNNode(geometry: geometry)
        meshNode.name = "PrintMeshNode"

        let rootNode = SCNNode()
        rootNode.addChildNode(meshNode)
        return LoadedMeshScene(rootNode: rootNode, metadata: metadata, embeddedThumbnail: nil)
    }

    /// Builds compact indexed SceneKit geometry directly from resolved 3MF mesh instances (6x less memory than unindexed!).
    private static func buildIndexedSceneNode(
        instances: [Resolved3MFMeshInstance],
        minBounds: SIMD3<Float>,
        maxBounds: SIMD3<Float>
    ) -> SCNNode {
        let centerX = (minBounds.x + maxBounds.x) * 0.5
        let centerY = (minBounds.y + maxBounds.y) * 0.5
        let baseZ = minBounds.z

        let totalVerts = instances.reduce(0) { $0 + $1.vertices.count }
        let totalIndices = instances.reduce(0) { $0 + $1.triangles.count }

        var packedVerts = [PackedFloat3]()
        var accumNormals = [SIMD3<Float>](repeating: .zero, count: totalVerts)
        var allIndices = [Int32]()
        packedVerts.reserveCapacity(totalVerts)
        allIndices.reserveCapacity(totalIndices)

        var vertexOffset: Int32 = 0
        for inst in instances {
            let verts = inst.vertices
            let vCount = verts.count
            for p in verts {
                packedVerts.append(PackedFloat3(x: p.x - centerX, y: p.z - baseZ, z: -(p.y - centerY)))
            }

            let tris = inst.triangles
            var i = 0
            while i + 2 < tris.count {
                let l1 = Int(tris[i])
                let l2 = Int(tris[i + 1])
                let l3 = Int(tris[i + 2])
                i += 3
                guard l1 >= 0, l2 >= 0, l3 >= 0, l1 < vCount, l2 < vCount, l3 < vCount else { continue }
                let g1 = Int(vertexOffset) + l1
                let g2 = Int(vertexOffset) + l2
                let g3 = Int(vertexOffset) + l3

                // Area-weighted face normal accumulated onto shared vertices for smooth shading
                let fn = simd_cross(verts[l2] - verts[l1], verts[l3] - verts[l1])
                accumNormals[g1] += fn
                accumNormals[g2] += fn
                accumNormals[g3] += fn

                allIndices.append(Int32(g1))
                allIndices.append(Int32(g2))
                allIndices.append(Int32(g3))
            }
            vertexOffset += Int32(vCount)
        }

        var packedNormals = [PackedFloat3]()
        packedNormals.reserveCapacity(totalVerts)
        for n in accumNormals {
            let len = simd_length(n)
            let unit = len > 1e-7 ? (n / len) : SIMD3<Float>(0, 0, 1)
            packedNormals.append(PackedFloat3(x: unit.x, y: unit.z, z: -unit.y))
        }

        return makeSceneRootNode(verts: packedVerts, normals: packedNormals, indices: allIndices)
    }

    /// Fast watertight vertex-clustering LOD for ultra-dense meshes (> 500k triangles, e.g. 6M-triangle sculpts).
    /// Quantizes vertices onto a fine 3D spatial grid (per sub-mesh bounding box for crisp detail even across wide plates),
    /// averages vertex positions inside each cell, and drops degenerate triangles — producing a hole-free preview in milliseconds.
    private static func buildClusteredPreviewNode(
        instances: [Resolved3MFMeshInstance],
        minBounds: SIMD3<Float>,
        maxBounds: SIMD3<Float>
    ) -> SCNNode {
        let centerX = (minBounds.x + maxBounds.x) * 0.5
        let centerY = (minBounds.y + maxBounds.y) * 0.5
        let baseZ = minBounds.z

        let totalTris = instances.reduce(0) { $0 + ($1.triangles.count / 3) }
        let ratio = Float(previewLODTriangleThreshold) / Float(max(totalTris, 1))
        let gridSteps = max(96.0, min(320.0, 280.0 * sqrt(ratio)))

        struct ClusteredPart {
            var verts: [PackedFloat3] = []
            var normals: [PackedFloat3] = []
            var indices: [Int32] = []
        }

        final class PartsBox: @unchecked Sendable {
            var parts: [ClusteredPart]
            init(count: Int) { self.parts = Array(repeating: ClusteredPart(), count: count) }
        }
        let box = PartsBox(count: instances.count)
        let capturedInstances = instances

        // Cluster each sub-mesh independently in parallel across CPU cores
        DispatchQueue.concurrentPerform(iterations: capturedInstances.count) { idx in
            let inst = capturedInstances[idx]
            let verts = inst.vertices
            let tris = inst.triangles
            let vCount = verts.count
            guard vCount > 0, tris.count >= 3 else { return }

            var iMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var iMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for v in verts {
                iMin = simd_min(iMin, v)
                iMax = simd_max(iMax, v)
            }
            let span = max(max(iMax.x - iMin.x, iMax.y - iMin.y), max(iMax.z - iMin.z, 1e-3))
            let invCell = gridSteps / span

            var cellToCluster: [Int64: Int32] = [:]
            cellToCluster.reserveCapacity(min(vCount, 65_536))
            var clusterSum = [SIMD3<Float>]()
            var clusterCount = [Int32]()
            var vertToCluster = [Int32](repeating: 0, count: vCount)

            for vIdx in 0..<vCount {
                let p = verts[vIdx]
                let gx = Int64((p.x - iMin.x) * invCell)
                let gy = Int64((p.y - iMin.y) * invCell)
                let gz = Int64((p.z - iMin.z) * invCell)
                let key = (gx & 0x1FFFFF) | ((gy & 0x1FFFFF) << 21) | ((gz & 0x1FFFFF) << 42)
                if let existing = cellToCluster[key] {
                    vertToCluster[vIdx] = existing
                    clusterSum[Int(existing)] += p
                    clusterCount[Int(existing)] += 1
                } else {
                    let cid = Int32(clusterSum.count)
                    cellToCluster[key] = cid
                    vertToCluster[vIdx] = cid
                    clusterSum.append(p)
                    clusterCount.append(1)
                }
            }

            let cCount = clusterSum.count
            var partVerts = [PackedFloat3]()
            var clusterAvg = [SIMD3<Float>]()
            var accumNormals = [SIMD3<Float>](repeating: .zero, count: cCount)
            partVerts.reserveCapacity(cCount)
            clusterAvg.reserveCapacity(cCount)

            for c in 0..<cCount {
                let avg = clusterSum[c] / Float(clusterCount[c])
                clusterAvg.append(avg)
                partVerts.append(PackedFloat3(x: avg.x - centerX, y: avg.z - baseZ, z: -(avg.y - centerY)))
            }

            var partIndices = [Int32]()
            partIndices.reserveCapacity(min(tris.count, cCount * 6))
            var i = 0
            while i + 2 < tris.count {
                let l1 = Int(tris[i])
                let l2 = Int(tris[i + 1])
                let l3 = Int(tris[i + 2])
                i += 3
                guard l1 >= 0, l2 >= 0, l3 >= 0, l1 < vCount, l2 < vCount, l3 < vCount else { continue }
                let c1 = vertToCluster[l1]
                let c2 = vertToCluster[l2]
                let c3 = vertToCluster[l3]
                if c1 == c2 || c2 == c3 || c1 == c3 { continue }

                let p1 = clusterAvg[Int(c1)]
                let p2 = clusterAvg[Int(c2)]
                let p3 = clusterAvg[Int(c3)]
                let fn = simd_cross(p2 - p1, p3 - p1)

                accumNormals[Int(c1)] += fn
                accumNormals[Int(c2)] += fn
                accumNormals[Int(c3)] += fn

                partIndices.append(c1)
                partIndices.append(c2)
                partIndices.append(c3)
            }

            var partNormals = [PackedFloat3]()
            partNormals.reserveCapacity(cCount)
            for n in accumNormals {
                let len = simd_length(n)
                let unit = len > 1e-7 ? (n / len) : SIMD3<Float>(0, 0, 1)
                partNormals.append(PackedFloat3(x: unit.x, y: unit.z, z: -unit.y))
            }

            box.parts[idx] = ClusteredPart(verts: partVerts, normals: partNormals, indices: partIndices)
        }

        let totalOutVerts = box.parts.reduce(0) { $0 + $1.verts.count }
        let totalOutIndices = box.parts.reduce(0) { $0 + $1.indices.count }
        var outVerts = [PackedFloat3]()
        var outNormals = [PackedFloat3]()
        var outIndices = [Int32]()
        outVerts.reserveCapacity(totalOutVerts)
        outNormals.reserveCapacity(totalOutVerts)
        outIndices.reserveCapacity(totalOutIndices)

        for part in box.parts where !part.indices.isEmpty {
            let baseOffset = Int32(outVerts.count)
            outVerts.append(contentsOf: part.verts)
            outNormals.append(contentsOf: part.normals)
            for idx in part.indices {
                outIndices.append(baseOffset + idx)
            }
        }

        return makeSceneRootNode(verts: outVerts, normals: outNormals, indices: outIndices)
    }

    private static func buildClusteredPreviewNodeFromUnindexed(
        positions: [SIMD3<Float>],
        minBounds: SIMD3<Float>,
        maxBounds: SIMD3<Float>
    ) -> SCNNode {
        let centerX = (minBounds.x + maxBounds.x) * 0.5
        let centerY = (minBounds.y + maxBounds.y) * 0.5
        let baseZ = minBounds.z

        let triCount = positions.count / 3
        let ratio = Float(previewLODTriangleThreshold) / Float(max(triCount, 1))
        let gridSteps = max(80.0, min(320.0, 260.0 * sqrt(ratio)))
        let span = max(max(maxBounds.x - minBounds.x, maxBounds.y - minBounds.y), max(maxBounds.z - minBounds.z, 1e-3))
        let invCell = gridSteps / span

        var cellToCluster: [Int64: Int32] = [:]
        cellToCluster.reserveCapacity(180_000)
        var clusterSum = [SIMD3<Float>]()
        var clusterCount = [Int32]()
        var outIndices = [Int32]()
        outIndices.reserveCapacity(previewLODTriangleThreshold * 3)

        func clusterId(for p: SIMD3<Float>) -> Int32 {
            let gx = Int64((p.x - minBounds.x) * invCell)
            let gy = Int64((p.y - minBounds.y) * invCell)
            let gz = Int64((p.z - minBounds.z) * invCell)
            let key = (gx & 0x1FFFFF) | ((gy & 0x1FFFFF) << 21) | ((gz & 0x1FFFFF) << 42)
            if let existing = cellToCluster[key] {
                clusterSum[Int(existing)] += p
                clusterCount[Int(existing)] += 1
                return existing
            } else {
                let cid = Int32(clusterSum.count)
                cellToCluster[key] = cid
                clusterSum.append(p)
                clusterCount.append(1)
                return cid
            }
        }

        var i = 0
        while i + 2 < positions.count {
            let c1 = clusterId(for: positions[i])
            let c2 = clusterId(for: positions[i + 1])
            let c3 = clusterId(for: positions[i + 2])
            i += 3
            if c1 == c2 || c2 == c3 || c1 == c3 { continue }
            outIndices.append(c1)
            outIndices.append(c2)
            outIndices.append(c3)
        }

        let vCount = clusterSum.count
        var avgVerts = [SIMD3<Float>]()
        var outVerts = [PackedFloat3]()
        var accumNormals = [SIMD3<Float>](repeating: .zero, count: vCount)
        avgVerts.reserveCapacity(vCount)
        outVerts.reserveCapacity(vCount)

        for c in 0..<vCount {
            let avg = clusterSum[c] / Float(clusterCount[c])
            avgVerts.append(avg)
            outVerts.append(PackedFloat3(x: avg.x - centerX, y: avg.z - baseZ, z: -(avg.y - centerY)))
        }

        var j = 0
        while j + 2 < outIndices.count {
            let i1 = Int(outIndices[j])
            let i2 = Int(outIndices[j + 1])
            let i3 = Int(outIndices[j + 2])
            j += 3
            let fn = simd_cross(avgVerts[i2] - avgVerts[i1], avgVerts[i3] - avgVerts[i1])
            accumNormals[i1] += fn
            accumNormals[i2] += fn
            accumNormals[i3] += fn
        }

        var outNormals = [PackedFloat3]()
        outNormals.reserveCapacity(vCount)
        for n in accumNormals {
            let len = simd_length(n)
            let unit = len > 1e-7 ? (n / len) : SIMD3<Float>(0, 0, 1)
            outNormals.append(PackedFloat3(x: unit.x, y: unit.z, z: -unit.y))
        }

        return makeSceneRootNode(verts: outVerts, normals: outNormals, indices: outIndices)
    }

    private static func makeSceneRootNode(
        verts: [PackedFloat3],
        normals: [PackedFloat3],
        indices: [Int32]
    ) -> SCNNode {
        let vertexSource = makeFloat3GeometrySource(verts, semantic: .vertex)
        let normalSource = makeFloat3GeometrySource(normals, semantic: .normal)
        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
        geometry.firstMaterial = defaultPrintMaterial()

        let meshNode = SCNNode(geometry: geometry)
        meshNode.name = "PrintMeshNode"

        let rootNode = SCNNode()
        rootNode.addChildNode(meshNode)
        return rootNode
    }

    public static func defaultPrintMaterial(color: NSColor = NSColor(calibratedRed: 0.22, green: 0.68, blue: 0.45, alpha: 1.0)) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = 0.38
        material.metalness.contents = 0.08
        material.isDoubleSided = true
        return material
    }

    // MARK: - ZIP Extraction Helpers for 3MF

    /// Extracts all `.model` files from a `.3mf` archive in ONE single `/usr/bin/unzip` pass.
    private static func extractAllModelFiles(from archiveURL: URL, into tempDir: URL) -> [(relativePath: String, fileURL: URL)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // `-qq` quiet, `-o` overwrite, `-C` case-insensitive wildcard match for `*.model`
        proc.arguments = ["-qq", "-o", "-C", archiveURL.path, "*.model", "-d", tempDir.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }

        let resolvedTempDir = tempDir.resolvingSymlinksInPath().standardizedFileURL
        var results: [(String, URL)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedTempDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let basePath = resolvedTempDir.path.hasSuffix("/") ? resolvedTempDir.path : resolvedTempDir.path + "/"
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "model" {
                let resolvedFilePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                let rel = resolvedFilePath.hasPrefix(basePath)
                    ? String(resolvedFilePath.dropFirst(basePath.count))
                    : fileURL.lastPathComponent
                results.append((rel, fileURL))
            }
        }
        return results
    }

    private static func listZipEntries(at url: URL) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z1", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return [] }
            return out.split(whereSeparator: \.isNewline).map(String.init)
        } catch {
            return []
        }
    }

    private static func unzipEntry(at url: URL, entryPath: String) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", url.path, entryPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }
}

// MARK: - 3MF Document Structures

private struct ThreeMFMesh {
    var vertices: [SIMD3<Float>] = []
    var triangles: [Int32] = [] // flat triples (v1, v2, v3)
}

private struct ThreeMFComponent {
    let objectId: String
    let externalPath: String?
    let transform: simd_float4x4
}

private struct ThreeMFObject {
    let id: String
    var mesh: ThreeMFMesh?
    var components: [ThreeMFComponent] = []
}

private struct ThreeMFBuildItem {
    let objectId: String
    let transform: simd_float4x4
}

private struct ThreeMFDocument {
    var unitToMillimeters: Float = 1.0
    var objects: [String: ThreeMFObject] = [:]
    var buildItems: [ThreeMFBuildItem] = []
}

// MARK: - Zero-Allocation High-Speed UTF-8 3MF Byte Parser (~50-100x faster than Foundation XMLParser)

private enum FastThreeMFByteParser {
    private static let lt: UInt8 = 0x3C     // '<'
    private static let gt: UInt8 = 0x3E     // '>'
    private static let slash: UInt8 = 0x2F  // '/'
    private static let eq: UInt8 = 0x3D     // '='
    private static let dquote: UInt8 = 0x22 // '"'
    private static let squote: UInt8 = 0x27 // '\''
    private static let colon: UInt8 = 0x3A  // ':'
    private static let qmark: UInt8 = 0x3F  // '?'
    private static let bang: UInt8 = 0x21   // '!'

    static func parse(data: Data) -> ThreeMFDocument? {
        // Bail out to XMLParser fallback if UTF-16 BOM detected
        if data.count >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF)) {
            return nil
        }

        return data.withUnsafeBytes { rawBuf -> ThreeMFDocument? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return parseBuffer(base, count: rawBuf.count)
        }
    }

    @inline(__always)
    private static func findByte(_ byte: UInt8, in base: UnsafePointer<UInt8>, from pos: Int, count: Int) -> Int? {
        guard pos < count, let ptr = memchr(base + pos, Int32(byte), count - pos) else { return nil }
        return UnsafePointer(ptr.assumingMemoryBound(to: UInt8.self)) - base
    }

    private static func parseBuffer(_ base: UnsafePointer<UInt8>, count: Int) -> ThreeMFDocument {
        var doc = ThreeMFDocument()
        var currentObject: ThreeMFObject?
        var currentMesh: ThreeMFMesh?

        let estimatedElements = max(64, count / 90)

        var pos = 0
        while pos < count {
            guard let ltIndex = findByte(lt, in: base, from: pos, count: count) else { break }
            pos = ltIndex + 1
            guard pos < count else { break }

            let firstByte = base[pos]
            if firstByte == qmark || firstByte == bang {
                if let gtIndex = findByte(gt, in: base, from: pos, count: count) {
                    pos = gtIndex + 1
                } else {
                    break
                }
                continue
            }

            let isClosing = (firstByte == slash)
            if isClosing { pos += 1 }

            var localStart = pos
            while pos < count {
                let c = base[pos]
                if c <= 0x20 || c == gt || c == slash { break }
                if c == colon { localStart = pos + 1 }
                pos += 1
            }
            let nameLen = pos - localStart

            guard let tagEnd = findByte(gt, in: base, from: pos, count: count) else { break }

            if isClosing {
                if nameLen == 4 && matches(base + localStart, "mesh") {
                    if let mesh = currentMesh, !mesh.vertices.isEmpty, !mesh.triangles.isEmpty {
                        currentObject?.mesh = mesh
                    }
                    currentMesh = nil
                } else if nameLen == 6 && matches(base + localStart, "object") {
                    if let obj = currentObject {
                        doc.objects[obj.id] = obj
                    }
                    currentObject = nil
                }
                pos = tagEnd + 1
                continue
            }

            // Hot path #1: `<vertex x="..." y="..." z="..." />`
            if nameLen == 6 && base[localStart] == 0x76 && matches(base + localStart, "vertex") {
                if currentMesh != nil {
                    var vx: Float = 0, vy: Float = 0, vz: Float = 0
                    var foundMask: UInt8 = 0
                    var p = pos
                    while p < tagEnd {
                        while p < tagEnd && (base[p] <= 0x20 || base[p] == slash) { p += 1 }
                        guard p < tagEnd else { break }
                        let aStart = p
                        while p < tagEnd && base[p] != eq && base[p] > 0x20 { p += 1 }
                        let aLen = p - aStart
                        while p < tagEnd && base[p] != dquote && base[p] != squote { p += 1 }
                        guard p < tagEnd else { break }
                        let quote = base[p]; p += 1
                        let vStart = p
                        while p < tagEnd && base[p] != quote { p += 1 }
                        let vEnd = p
                        if p < tagEnd { p += 1 }

                        if aLen == 1 {
                            let ch = base[aStart]
                            if ch == 0x78 {
                                vx = parseFastFloat(base, vStart, vEnd); foundMask |= 1
                            } else if ch == 0x79 {
                                vy = parseFastFloat(base, vStart, vEnd); foundMask |= 2
                            } else if ch == 0x7A {
                                vz = parseFastFloat(base, vStart, vEnd); foundMask |= 4
                            }
                        }
                    }
                    if foundMask == 7 {
                        currentMesh!.vertices.append(SIMD3<Float>(vx, vy, vz))
                    }
                }
                pos = tagEnd + 1
                continue
            }

            // Hot path #2: `<triangle v1="..." v2="..." v3="..." />`
            if nameLen == 8 && base[localStart] == 0x74 && matches(base + localStart, "triangle") {
                if currentMesh != nil {
                    var v1: Int32 = 0, v2: Int32 = 0, v3: Int32 = 0
                    var foundMask: UInt8 = 0
                    var p = pos
                    while p < tagEnd {
                        while p < tagEnd && (base[p] <= 0x20 || base[p] == slash) { p += 1 }
                        guard p < tagEnd else { break }
                        let aStart = p
                        while p < tagEnd && base[p] != eq && base[p] > 0x20 { p += 1 }
                        let aLen = p - aStart
                        while p < tagEnd && base[p] != dquote && base[p] != squote { p += 1 }
                        guard p < tagEnd else { break }
                        let quote = base[p]; p += 1
                        let vStart = p
                        while p < tagEnd && base[p] != quote { p += 1 }
                        let vEnd = p
                        if p < tagEnd { p += 1 }

                        if aLen == 2 && base[aStart] == 0x76 {
                            let d = base[aStart + 1]
                            if d == 0x31 {
                                v1 = parseFastInt32(base, vStart, vEnd); foundMask |= 1
                            } else if d == 0x32 {
                                v2 = parseFastInt32(base, vStart, vEnd); foundMask |= 2
                            } else if d == 0x33 {
                                v3 = parseFastInt32(base, vStart, vEnd); foundMask |= 4
                            }
                        }
                    }
                    if foundMask == 7 {
                        currentMesh!.triangles.append(v1)
                        currentMesh!.triangles.append(v2)
                        currentMesh!.triangles.append(v3)
                    }
                }
                pos = tagEnd + 1
                continue
            }

            // Structural tags (rare — called only a handful of times per file)
            if nameLen == 4 && matches(base + localStart, "mesh") {
                var mesh = ThreeMFMesh()
                mesh.vertices.reserveCapacity(min(estimatedElements / 2, 2_000_000))
                mesh.triangles.reserveCapacity(min(estimatedElements * 3, 6_000_000))
                currentMesh = mesh
            } else if nameLen == 6 && matches(base + localStart, "object") {
                let attrs = parseAttributes(base, pos, tagEnd)
                let id = attrs["id"] ?? UUID().uuidString
                currentObject = ThreeMFObject(id: id)
            } else if nameLen == 9 && matches(base + localStart, "component") {
                let attrs = parseAttributes(base, pos, tagEnd)
                if let objId = attrs["objectid"] {
                    let extPath = attrs.first(where: { $0.key == "path" || $0.key.hasSuffix(":path") })?.value
                    let transform = parse3MFTransform(attrs["transform"])
                    currentObject?.components.append(
                        ThreeMFComponent(objectId: objId, externalPath: extPath, transform: transform)
                    )
                }
            } else if nameLen == 4 && matches(base + localStart, "item") {
                let attrs = parseAttributes(base, pos, tagEnd)
                if let objId = attrs["objectid"] {
                    let transform = parse3MFTransform(attrs["transform"])
                    doc.buildItems.append(ThreeMFBuildItem(objectId: objId, transform: transform))
                }
            } else if nameLen == 5 && matches(base + localStart, "model") {
                let attrs = parseAttributes(base, pos, tagEnd)
                if let unit = attrs["unit"]?.lowercased() {
                    doc.unitToMillimeters = unitScale(for: unit)
                }
            }

            pos = tagEnd + 1
        }

        return doc
    }

    @inline(__always)
    private static func matches(_ ptr: UnsafePointer<UInt8>, _ literal: StaticString) -> Bool {
        literal.withUTF8Buffer { buf in
            for i in 0..<buf.count {
                if ptr[i] != buf[i] { return false }
            }
            return true
        }
    }

    @inline(__always)
    private static func parseFastInt32(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Int32 {
        var p = start
        while p < end && base[p] <= 0x20 { p += 1 }
        var sign: Int32 = 1
        if p < end && base[p] == 0x2D { sign = -1; p += 1 }
        else if p < end && base[p] == 0x2B { p += 1 }
        var val: Int32 = 0
        while p < end {
            let d = base[p] &- 0x30
            if d > 9 { break }
            val = val &* 10 &+ Int32(d)
            p += 1
        }
        return val &* sign
    }

    @inline(__always)
    private static func parseFastFloat(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Float {
        var p = start
        while p < end && base[p] <= 0x20 { p += 1 }
        guard p < end else { return 0 }

        var negative = false
        if base[p] == 0x2D { // '-'
            negative = true
            p += 1
        } else if base[p] == 0x2B { // '+'
            p += 1
        }

        var value: Double = 0
        while p < end {
            let d = base[p] &- 0x30
            if d > 9 { break }
            value = value * 10.0 + Double(d)
            p += 1
        }

        if p < end && base[p] == 0x2E { // '.'
            p += 1
            var fracScale: Double = 0.1
            while p < end {
                let d = base[p] &- 0x30
                if d > 9 { break }
                value += Double(d) * fracScale
                fracScale *= 0.1
                p += 1
            }
        }

        if p < end && (base[p] == 0x65 || base[p] == 0x45) { // 'e' or 'E'
            p += 1
            var expNeg = false
            if p < end && base[p] == 0x2D { expNeg = true; p += 1 }
            else if p < end && base[p] == 0x2B { p += 1 }
            var expVal = 0
            while p < end {
                let d = base[p] &- 0x30
                if d > 9 { break }
                expVal = expVal * 10 + Int(d)
                p += 1
            }
            if expVal > 0 {
                let factor = pow(10.0, Double(expNeg ? -expVal : expVal))
                value *= factor
            }
        }

        return Float(negative ? -value : value)
    }

    private static func parseAttributes(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> [String: String] {
        var attrs: [String: String] = [:]
        var p = start
        while p < end {
            while p < end && (base[p] <= 0x20 || base[p] == slash) { p += 1 }
            guard p < end else { break }
            let kStart = p
            while p < end && base[p] != eq && base[p] > 0x20 { p += 1 }
            let kEnd = p
            while p < end && base[p] != dquote && base[p] != squote { p += 1 }
            guard p < end else { break }
            let quote = base[p]; p += 1
            let vStart = p
            while p < end && base[p] != quote { p += 1 }
            let vEnd = p
            if p < end { p += 1 }

            let key = String(decoding: UnsafeBufferPointer(start: base + kStart, count: kEnd - kStart), as: UTF8.self)
            let val = String(decoding: UnsafeBufferPointer(start: base + vStart, count: vEnd - vStart), as: UTF8.self)
            attrs[key] = val
        }
        return attrs
    }
}

private func unitScale(for unit: String) -> Float {
    switch unit {
    case "micron": return 0.001
    case "millimeter": return 1.0
    case "centimeter": return 10.0
    case "inch": return 25.4
    case "foot": return 304.8
    case "meter": return 1000.0
    default: return 1.0
    }
}

private func parse3MFTransform(_ str: String?) -> simd_float4x4 {
    guard let str else { return matrix_identity_float4x4 }
    let nums = str.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
    guard nums.count == 12 else { return matrix_identity_float4x4 }
    return simd_float4x4(columns: (
        SIMD4<Float>(nums[0], nums[1], nums[2], 0),
        SIMD4<Float>(nums[3], nums[4], nums[5], 0),
        SIMD4<Float>(nums[6], nums[7], nums[8], 0),
        SIMD4<Float>(nums[9], nums[10], nums[11], 1)
    ))
}

// MARK: - Fallback Foundation XMLParser (e.g. UTF-16 3MF files)

private final class ThreeMFXMLMeshParser: NSObject, XMLParserDelegate {
    private var document = ThreeMFDocument()
    private var currentObject: ThreeMFObject?
    private var currentMesh: ThreeMFMesh?

    func parseDocument(data: Data) -> ThreeMFDocument? {
        document = ThreeMFDocument()
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return document
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch localName {
        case "model":
            if let unit = attributeDict["unit"]?.lowercased() {
                document.unitToMillimeters = unitScale(for: unit)
            }
        case "object":
            let id = attributeDict["id"] ?? UUID().uuidString
            currentObject = ThreeMFObject(id: id)
        case "mesh":
            currentMesh = ThreeMFMesh()
        case "vertex":
            if let xStr = attributeDict["x"], let yStr = attributeDict["y"], let zStr = attributeDict["z"],
               let x = Float(xStr), let y = Float(yStr), let z = Float(zStr) {
                currentMesh?.vertices.append(SIMD3<Float>(x, y, z))
            }
        case "triangle":
            if let v1Str = attributeDict["v1"], let v2Str = attributeDict["v2"], let v3Str = attributeDict["v3"],
               let v1 = Int32(v1Str), let v2 = Int32(v2Str), let v3 = Int32(v3Str) {
                currentMesh?.triangles.append(v1)
                currentMesh?.triangles.append(v2)
                currentMesh?.triangles.append(v3)
            }
        case "component":
            if let objId = attributeDict["objectid"] {
                let extPath = attributeDict.first(where: { key, _ in
                    key == "path" || key.hasSuffix(":path")
                })?.value
                let transform = parse3MFTransform(attributeDict["transform"])
                currentObject?.components.append(
                    ThreeMFComponent(objectId: objId, externalPath: extPath, transform: transform)
                )
            }
        case "item":
            if let objId = attributeDict["objectid"] {
                let transform = parse3MFTransform(attributeDict["transform"])
                document.buildItems.append(ThreeMFBuildItem(objectId: objId, transform: transform))
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch localName {
        case "mesh":
            if let mesh = currentMesh, !mesh.vertices.isEmpty, !mesh.triangles.isEmpty {
                currentObject?.mesh = mesh
            }
            currentMesh = nil
        case "object":
            if let obj = currentObject {
                document.objects[obj.id] = obj
            }
            currentObject = nil
        default:
            break
        }
    }
}
