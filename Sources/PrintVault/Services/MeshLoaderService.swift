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
    public let subModelCount: Int

    public init(
        vertexCount: Int,
        triangleCount: Int,
        dimensionX: Double,
        dimensionY: Double,
        dimensionZ: Double,
        volumeCm3: Double,
        subModelCount: Int
    ) {
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.dimensionX = dimensionX
        self.dimensionY = dimensionY
        self.dimensionZ = dimensionZ
        self.volumeCm3 = volumeCm3
        self.subModelCount = subModelCount
    }
}

public struct LoadedMeshScene: @unchecked Sendable {
    public let rootNode: SCNNode
    public let metadata: MeshMetadata
    public let embeddedThumbnail: NSImage?
}

// MARK: - MeshLoaderService

public enum MeshLoaderService {

    /// Loads a 3D print file (.stl or .3mf) into an `SCNNode` with computed normals and exact millimeter bounding box metadata.
    public static func loadMesh(at url: URL) async throws -> LoadedMeshScene {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "stl":
            return try await Task.detached(priority: .userInitiated) {
                try loadSTL(at: url)
            }.value
        case "3mf":
            return try await Task.detached(priority: .userInitiated) {
                try load3MF(at: url)
            }.value
        default:
            return try await Task.detached(priority: .userInitiated) {
                try loadViaModelIO(at: url)
            }.value
        }
    }

    /// Lightweight metadata-only analyzer for background indexing.
    public static func analyzeMetadata(at url: URL) async -> MeshMetadata? {
        do {
            let loaded = try await loadMesh(at: url)
            return loaded.metadata
        } catch {
            return nil
        }
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

    private static func loadSTL(at url: URL) throws -> LoadedMeshScene {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 84 else {
            if let asciiScene = parseASCIISTL(data: data) {
                return asciiScene
            }
            return try loadViaModelIO(at: url)
        }

        // Check if binary STL matches expected byte size: 80 header + 4 uint32 count + count * 50 bytes
        let triCountU32: UInt32 = data.withUnsafeBytes { rawBuffer in
            UInt32(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
        }
        let expectedBinarySize = 84 + Int(triCountU32) * 50

        // Exact match (or minor trailing padding) indicates binary STL
        if triCountU32 > 0 && data.count >= expectedBinarySize && (data.count - expectedBinarySize) <= 64 {
            return parseBinarySTL(data: data, triangleCount: Int(triCountU32))
        }

        // Check if ASCII STL ("solid ...")
        if let prefix = String(data: data.prefix(1024), encoding: .utf8) ?? String(data: data.prefix(1024), encoding: .ascii) {
            let lowered = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered.hasPrefix("solid") && (lowered.contains("facet") || lowered.contains("vertex")) {
                if let asciiScene = parseASCIISTL(data: data) {
                    return asciiScene
                }
            }
        }

        // Fallback to ModelIO
        return try loadViaModelIO(at: url)
    }

    private static func parseBinarySTL(data: Data, triangleCount: Int) -> LoadedMeshScene {
        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var indices = [Int32]()

        positions.reserveCapacity(triangleCount * 3)
        normals.reserveCapacity(triangleCount * 3)
        indices.reserveCapacity(triangleCount * 3)

        var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var signedVolume: Double = 0

        data.withUnsafeBytes { raw in
            var offset = 84
            for i in 0..<triangleCount {
                guard offset + 50 <= raw.count else { break }

                let nx = raw.loadUnaligned(fromByteOffset: offset + 0, as: Float.self)
                let ny = raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                let nz = raw.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)

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

                var normal = SIMD3<Float>(nx, ny, nz)
                let lenSq = simd_length_squared(normal)
                if lenSq < 1e-6 || !lenSq.isFinite {
                    let cross = simd_cross(v2 - v1, v3 - v1)
                    let cLen = simd_length(cross)
                    normal = cLen > 1e-7 ? (cross / cLen) : SIMD3<Float>(0, 0, 1)
                } else if abs(lenSq - 1.0) > 1e-3 {
                    normal = normal / sqrt(lenSq)
                }

                minBounds = simd_min(minBounds, simd_min(v1, simd_min(v2, v3)))
                maxBounds = simd_max(maxBounds, simd_max(v1, simd_max(v2, v3)))

                // Signed tetrahedron volume (in mm^3)
                let v321 = Double(v3.x) * Double(v2.y) * Double(v1.z)
                let v231 = Double(v2.x) * Double(v3.y) * Double(v1.z)
                let v312 = Double(v3.x) * Double(v1.y) * Double(v2.z)
                let v132 = Double(v1.x) * Double(v3.y) * Double(v2.z)
                let v213 = Double(v2.x) * Double(v1.y) * Double(v3.z)
                let v123 = Double(v1.x) * Double(v2.y) * Double(v3.z)
                signedVolume += (-v321 + v231 + v312 - v132 - v213 + v123) / 6.0

                positions.append(v1)
                positions.append(v2)
                positions.append(v3)
                normals.append(normal)
                normals.append(normal)
                normals.append(normal)

                let baseIdx = Int32(i * 3)
                indices.append(baseIdx)
                indices.append(baseIdx + 1)
                indices.append(baseIdx + 2)

                offset += 50
            }
        }

        return buildSceneFromArrays(
            positions: positions,
            normals: normals,
            indices: indices,
            reportedVertexCount: positions.count,
            minBounds: minBounds,
            maxBounds: maxBounds,
            volumeMm3: abs(signedVolume),
            subModelCount: 1,
            thumbnail: nil
        )
    }

    private static func parseASCIISTL(data: Data) -> LoadedMeshScene? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }

        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var indices = [Int32]()
        var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var signedVolume: Double = 0

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
                        let cross = simd_cross(v2 - v1, v3 - v1)
                        let cLen = simd_length(cross)
                        let normal = cLen > 1e-7 ? (cross / cLen) : SIMD3<Float>(0, 0, 1)

                        minBounds = simd_min(minBounds, simd_min(v1, simd_min(v2, v3)))
                        maxBounds = simd_max(maxBounds, simd_max(v1, simd_max(v2, v3)))

                        let crossProd = simd_cross(v1, v2)
                        signedVolume += Double(simd_dot(crossProd, v3)) / 6.0

                        let baseIdx = Int32(positions.count)
                        positions.append(v1)
                        positions.append(v2)
                        positions.append(v3)
                        normals.append(normal)
                        normals.append(normal)
                        normals.append(normal)
                        indices.append(baseIdx)
                        indices.append(baseIdx + 1)
                        indices.append(baseIdx + 2)
                        currentVerts.removeAll(keepingCapacity: true)
                    }
                }
            }
        }

        guard !positions.isEmpty else { return nil }

        return buildSceneFromArrays(
            positions: positions,
            normals: normals,
            indices: indices,
            reportedVertexCount: positions.count,
            minBounds: minBounds,
            maxBounds: maxBounds,
            volumeMm3: abs(signedVolume),
            subModelCount: 1,
            thumbnail: nil
        )
    }

    // MARK: - Native 3MF Archive & Mesh Parser (with Units, Components & Build Transforms)

    private static func load3MF(at url: URL) throws -> LoadedMeshScene {
        let entries = listZipEntries(at: url)
        let modelEntries = entries.filter { $0.lowercased().hasSuffix(".model") }
        let targets = modelEntries.isEmpty ? ["3D/3dmodel.model"] : modelEntries

        // Parse every .model file in the archive into a dictionary keyed by normalized archive path
        var parsedModels: [String: ThreeMFDocument] = [:]
        for entryPath in targets {
            guard let xmlData = unzipEntry(at: url, entryPath: entryPath) else { continue }
            let parser = ThreeMFXMLMeshParser()
            if let doc = parser.parseDocument(data: xmlData) {
                parsedModels[normalize3MFPath(entryPath)] = doc
            }
        }

        // Identify the primary root model (usually 3D/3dmodel.model)
        let rootKey = parsedModels.keys.first(where: { $0.lowercased() == "3d/3dmodel.model" })
            ?? parsedModels.keys.sorted().first

        var allPositions = [SIMD3<Float>]()
        var allNormals = [SIMD3<Float>]()
        var allIndices = [Int32]()
        var totalUniqueVerts = 0
        var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var signedVolume: Double = 0
        var emittedMeshCount = 0

        func emitMesh(_ mesh: ThreeMFMesh, transform: simd_float4x4, unitScale: Float) {
            let verts = mesh.vertices
            guard !verts.isEmpty, !mesh.triangles.isEmpty else { return }
            emittedMeshCount += 1
            totalUniqueVerts += verts.count

            // Pre-transform vertices once per mesh instance
            var transformedVerts = [SIMD3<Float>]()
            transformedVerts.reserveCapacity(verts.count)
            for v in verts {
                let p4 = transform * SIMD4<Float>(v.x, v.y, v.z, 1.0)
                transformedVerts.append(SIMD3<Float>(p4.x, p4.y, p4.z) * unitScale)
            }

            for (i1, i2, i3) in mesh.triangles {
                guard i1 >= 0, i2 >= 0, i3 >= 0,
                      i1 < transformedVerts.count, i2 < transformedVerts.count, i3 < transformedVerts.count else {
                    continue
                }
                let v1 = transformedVerts[i1]
                let v2 = transformedVerts[i2]
                let v3 = transformedVerts[i3]

                let cross = simd_cross(v2 - v1, v3 - v1)
                let cLen = simd_length(cross)
                let normal = cLen > 1e-7 ? (cross / cLen) : SIMD3<Float>(0, 0, 1)

                minBounds = simd_min(minBounds, simd_min(v1, simd_min(v2, v3)))
                maxBounds = simd_max(maxBounds, simd_max(v1, simd_max(v2, v3)))

                let crossProd = simd_cross(v1, v2)
                signedVolume += Double(simd_dot(crossProd, v3)) / 6.0

                let baseIdx = Int32(allPositions.count)
                allPositions.append(v1)
                allPositions.append(v2)
                allPositions.append(v3)
                allNormals.append(normal)
                allNormals.append(normal)
                allNormals.append(normal)
                allIndices.append(baseIdx)
                allIndices.append(baseIdx + 1)
                allIndices.append(baseIdx + 2)
            }
        }

        func resolveObject(
            id: String,
            inDocPath docPath: String,
            parentTransform: simd_float4x4,
            depth: Int
        ) {
            guard depth < 12, let doc = parsedModels[docPath], let obj = doc.objects[id] else { return }
            if let mesh = obj.mesh {
                emitMesh(mesh, transform: parentTransform, unitScale: doc.unitToMillimeters)
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

        // Fallback: if <build> items produced nothing (e.g. external model without build items), emit all meshes directly
        if allPositions.isEmpty {
            for doc in parsedModels.values {
                for obj in doc.objects.values {
                    if let mesh = obj.mesh {
                        emitMesh(mesh, transform: matrix_identity_float4x4, unitScale: doc.unitToMillimeters)
                    }
                }
            }
        }

        let thumb = extract3MFThumbnail(at: url)

        guard !allPositions.isEmpty else {
            throw NSError(domain: "MeshLoaderService", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "No 3D mesh geometry found inside 3MF archive."
            ])
        }

        return buildSceneFromArrays(
            positions: allPositions,
            normals: allNormals,
            indices: allIndices,
            reportedVertexCount: totalUniqueVerts > 0 ? totalUniqueVerts : allPositions.count,
            minBounds: minBounds,
            maxBounds: maxBounds,
            volumeMm3: abs(signedVolume),
            subModelCount: max(emittedMeshCount, 1),
            thumbnail: thumb
        )
    }

    private static func normalize3MFPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        return trimmed
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

        // Convert Z-up (3D printing standard) to SceneKit Y-up and center on build plate
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

    // MARK: - Scene Builder Helper

    private static func buildSceneFromArrays(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        indices: [Int32],
        reportedVertexCount: Int,
        minBounds: SIMD3<Float>,
        maxBounds: SIMD3<Float>,
        volumeMm3: Double,
        subModelCount: Int,
        thumbnail: NSImage?
    ) -> LoadedMeshScene {
        let centerX = (minBounds.x + maxBounds.x) * 0.5
        let centerY = (minBounds.y + maxBounds.y) * 0.5
        let baseZ = minBounds.z

        var scnVertices = [SCNVector3]()
        var scnNormals = [SCNVector3]()
        scnVertices.reserveCapacity(positions.count)
        scnNormals.reserveCapacity(normals.count)

        for i in 0..<positions.count {
            let p = positions[i]
            let n = normals[i]
            // Map Z-up (printer space) to Y-up (SceneKit space)
            let sx = CGFloat(p.x - centerX)
            let sy = CGFloat(p.z - baseZ)
            let sz = CGFloat(-(p.y - centerY))
            scnVertices.append(SCNVector3(sx, sy, sz))

            let nx = CGFloat(n.x)
            let ny = CGFloat(n.z)
            let nz = CGFloat(-n.y)
            scnNormals.append(SCNVector3(nx, ny, nz))
        }

        let vertexSource = SCNGeometrySource(vertices: scnVertices)
        let normalSource = SCNGeometrySource(normals: scnNormals)
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
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

        let dx = Double(max(0, maxBounds.x - minBounds.x))
        let dy = Double(max(0, maxBounds.y - minBounds.y))
        let dz = Double(max(0, maxBounds.z - minBounds.z))
        let volCm3 = max(0.01, volumeMm3 / 1000.0)

        let metadata = MeshMetadata(
            vertexCount: reportedVertexCount,
            triangleCount: indices.count / 3,
            dimensionX: dx,
            dimensionY: dy,
            dimensionZ: dz,
            volumeCm3: volCm3,
            subModelCount: subModelCount
        )

        return LoadedMeshScene(rootNode: rootNode, metadata: metadata, embeddedThumbnail: thumbnail)
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

// MARK: - 3MF XML Document & Parser

private struct ThreeMFMesh {
    var vertices: [SIMD3<Float>] = []
    var triangles: [(Int, Int, Int)] = []
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

private final class ThreeMFXMLMeshParser: NSObject, XMLParserDelegate {
    private var document = ThreeMFDocument()
    private var currentObjectId: String?
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
                switch unit {
                case "micron": document.unitToMillimeters = 0.001
                case "millimeter": document.unitToMillimeters = 1.0
                case "centimeter": document.unitToMillimeters = 10.0
                case "inch": document.unitToMillimeters = 25.4
                case "foot": document.unitToMillimeters = 304.8
                case "meter": document.unitToMillimeters = 1000.0
                default: document.unitToMillimeters = 1.0
                }
            }
        case "object":
            let id = attributeDict["id"] ?? UUID().uuidString
            currentObjectId = id
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
               let v1 = Int(v1Str), let v2 = Int(v2Str), let v3 = Int(v3Str) {
                currentMesh?.triangles.append((v1, v2, v3))
            }
        case "component":
            if let objId = attributeDict["objectid"] {
                // Production extension external path may appear as "p:path" or "path"
                let extPath = attributeDict.first(where: { key, _ in
                    key == "path" || key.hasSuffix(":path")
                })?.value
                let transform = Self.parseTransform(attributeDict["transform"])
                currentObject?.components.append(
                    ThreeMFComponent(objectId: objId, externalPath: extPath, transform: transform)
                )
            }
        case "item":
            if let objId = attributeDict["objectid"] {
                let transform = Self.parseTransform(attributeDict["transform"])
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
            currentObjectId = nil
        default:
            break
        }
    }

    /// Parses a 3MF 12-float row-major 3x4 affine transform string:
    /// `m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32` where `(m30, m31, m32)` is translation.
    /// In 3MF spec §3.3, `[x' y' z' 1] = [x y z 1] * M_row`, which corresponds to SIMD column-major:
    /// col0 = (m00, m01, m02, 0), col1 = (m10, m11, m12, 0), col2 = (m20, m21, m22, 0), col3 = (m30, m31, m32, 1).
    private static func parseTransform(_ str: String?) -> simd_float4x4 {
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
}
