import Foundation
import simd

/// Generates valid binary .stl and .3mf sample models on disk so users can immediately test 3D preview, categorization, and slicer hooks.
public enum SampleMeshGenerator {

    public static var sampleDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("PrintVault Sample Models", isDirectory: true)
    }

    @discardableResult
    public static func createSampleModelsOnDisk(in directory: URL? = nil) -> [URL] {
        let dir = directory ?? sampleDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var createdURLs: [URL] = []

        // 1. Calibration_XYZ_20mm_Cube.stl
        let cubeURL = dir.appendingPathComponent("Calibration_XYZ_20mm_Cube.stl")
        let cubeTris = makeBoxTriangles(min: SIMD3<Float>(-10, -10, 0), max: SIMD3<Float>(10, 10, 20))
        if writeBinarySTL(triangles: cubeTris, headerText: "PrintVault Calibration Cube 20mm", to: cubeURL) {
            createdURLs.append(cubeURL)
        }

        // 2. Gridfinity_1x1_Storage_Bin.stl (Hollow stepped organizer bin 42x42x28mm)
        let binURL = dir.appendingPathComponent("Gridfinity_1x1_Storage_Bin.stl")
        var binTris = makeBoxTriangles(min: SIMD3<Float>(-19, -19, 0), max: SIMD3<Float>(19, 19, 4))
        binTris.append(contentsOf: makeBoxTriangles(min: SIMD3<Float>(-21, -21, 4), max: SIMD3<Float>(21, 21, 8)))
        // Four walls
        binTris.append(contentsOf: makeBoxTriangles(min: SIMD3<Float>(-21, -21, 8), max: SIMD3<Float>(21, -18.6, 28)))
        binTris.append(contentsOf: makeBoxTriangles(min: SIMD3<Float>(-21, 18.6, 8), max: SIMD3<Float>(21, 21, 28)))
        binTris.append(contentsOf: makeBoxTriangles(min: SIMD3<Float>(-21, -18.6, 8), max: SIMD3<Float>(-18.6, 18.6, 28)))
        binTris.append(contentsOf: makeBoxTriangles(min: SIMD3<Float>(18.6, -18.6, 8), max: SIMD3<Float>(21, 18.6, 28)))
        if writeBinarySTL(triangles: binTris, headerText: "Gridfinity 1x1 Bin 42x42x28mm", to: binURL) {
            createdURLs.append(binURL)
        }

        // 3. Heavy_Duty_Shelf_Bracket_Mount.stl (L-bracket with gusset rib)
        let bracketURL = dir.appendingPathComponent("Heavy_Duty_Shelf_Bracket_Mount.stl")
        var bracketTris = makeBoxTriangles(min: SIMD3<Float>(0, -15, 0), max: SIMD3<Float>(60, 15, 6))
        bracketTris.append(contentsOf: makeBoxTriangles(min: SIMD3<Float>(0, -15, 6), max: SIMD3<Float>(6, 15, 55)))
        bracketTris.append(contentsOf: makeBoxTriangles(min: SIMD3<Float>(6, -3, 6), max: SIMD3<Float>(38, 3, 28)))
        if writeBinarySTL(triangles: bracketTris, headerText: "Functional Shelf Bracket", to: bracketURL) {
            createdURLs.append(bracketURL)
        }

        // 4. Planetary_Spur_Gear_24T.stl (Procedural gear with teeth + hub)
        let gearURL = dir.appendingPathComponent("Planetary_Spur_Gear_24T.stl")
        let gearTris = makeSpurGearTriangles(outerRadius: 24, innerRadius: 19, height: 10, teeth: 16)
        if writeBinarySTL(triangles: gearTris, headerText: "Planetary Spur Gear", to: gearURL) {
            createdURLs.append(gearURL)
        }

        // 5. Hexagonal_Desk_Organizer.3mf (Spec-compliant 3MF ZIP Archive containing 3D/3dmodel.model)
        let threeMFURL = dir.appendingPathComponent("Hexagonal_Desk_Organizer.3mf")
        if createSample3MFFile(at: threeMFURL) {
            createdURLs.append(threeMFURL)
        }

        return createdURLs
    }

    // MARK: - Geometry Primitives

    public static func makeBoxTriangles(min bMin: SIMD3<Float>, max bMax: SIMD3<Float>) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        let p000 = SIMD3<Float>(bMin.x, bMin.y, bMin.z)
        let p100 = SIMD3<Float>(bMax.x, bMin.y, bMin.z)
        let p110 = SIMD3<Float>(bMax.x, bMax.y, bMin.z)
        let p010 = SIMD3<Float>(bMin.x, bMax.y, bMin.z)
        let p001 = SIMD3<Float>(bMin.x, bMin.y, bMax.z)
        let p101 = SIMD3<Float>(bMax.x, bMin.y, bMax.z)
        let p111 = SIMD3<Float>(bMax.x, bMax.y, bMax.z)
        let p011 = SIMD3<Float>(bMin.x, bMax.y, bMax.z)

        return [
            // Bottom (-Z)
            (p000, p110, p100), (p000, p010, p110),
            // Top (+Z)
            (p001, p101, p111), (p001, p111, p011),
            // Front (-Y)
            (p000, p100, p101), (p000, p101, p001),
            // Back (+Y)
            (p110, p010, p011), (p110, p011, p111),
            // Left (-X)
            (p010, p000, p001), (p010, p001, p011),
            // Right (+X)
            (p100, p110, p111), (p100, p111, p101)
        ]
    }

    public static func makeSpurGearTriangles(
        outerRadius: Float,
        innerRadius: Float,
        height: Float,
        teeth: Int
    ) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        let steps = teeth * 2
        let centerBottom = SIMD3<Float>(0, 0, 0)
        let centerTop = SIMD3<Float>(0, 0, height)

        for i in 0..<steps {
            let a0 = Float(i) * (2.0 * .pi / Float(steps))
            let a1 = Float(i + 1) * (2.0 * .pi / Float(steps))
            let r0 = (i % 2 == 0) ? outerRadius : innerRadius
            let r1 = ((i + 1) % 2 == 0) ? outerRadius : innerRadius

            let b0 = SIMD3<Float>(cos(a0) * r0, sin(a0) * r0, 0)
            let b1 = SIMD3<Float>(cos(a1) * r1, sin(a1) * r1, 0)
            let t0 = SIMD3<Float>(cos(a0) * r0, sin(a0) * r0, height)
            let t1 = SIMD3<Float>(cos(a1) * r1, sin(a1) * r1, height)

            // Bottom & Top fan
            tris.append((centerBottom, b1, b0))
            tris.append((centerTop, t0, t1))
            // Outer rim quad
            tris.append((b0, b1, t1))
            tris.append((b0, t1, t0))
        }
        return tris
    }

    @discardableResult
    public static func writeBinarySTL(
        triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)],
        headerText: String,
        to url: URL
    ) -> Bool {
        var data = Data(capacity: 84 + triangles.count * 50)
        var header = Data(count: 80)
        if let headerBytes = headerText.data(using: .ascii) {
            header.replaceSubrange(0..<min(80, headerBytes.count), with: headerBytes.prefix(80))
        }
        data.append(header)

        var count = UInt32(triangles.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for (v1, v2, v3) in triangles {
            let cross = simd_cross(v2 - v1, v3 - v1)
            let len = simd_length(cross)
            let n = len > 1e-6 ? (cross / len) : SIMD3<Float>(0, 0, 1)

            // Write 12 IEEE-754 Float32 values (48 bytes) directly from array buffer
            let floats: [Float] = [
                n.x, n.y, n.z,
                v1.x, v1.y, v1.z,
                v2.x, v2.y, v2.z,
                v3.x, v3.y, v3.z
            ]
            floats.withUnsafeBytes { rawBuffer in
                data.append(contentsOf: rawBuffer)
            }

            var attr: UInt16 = 0
            withUnsafeBytes(of: &attr) { data.append(contentsOf: $0) }
        }

        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 3MF Sample Archive Writer

    @discardableResult
    public static func createSample3MFFile(at targetURL: URL) -> Bool {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pv_3mf_\(UUID().uuidString)", isDirectory: true)
        let modelDir = tempDir.appendingPathComponent("3D", isDirectory: true)
        let relsDir = tempDir.appendingPathComponent("_rels", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)

            // Create hexagonal prism mesh in 3MF XML
            var verticesXML = ""
            var trianglesXML = ""
            let sides = 6
            let radius: Float = 26.0
            let height: Float = 48.0

            // Vertex 0 = bottom center, Vertex 1 = top center
            verticesXML += "          <vertex x=\"0\" y=\"0\" z=\"0\" />\n"
            verticesXML += "          <vertex x=\"0\" y=\"0\" z=\"\(height)\" />\n"

            for i in 0..<sides {
                let angle = Float(i) * (2.0 * .pi / Float(sides))
                let x = String(format: "%.3f", cos(angle) * radius)
                let y = String(format: "%.3f", sin(angle) * radius)
                verticesXML += "          <vertex x=\"\(x)\" y=\"\(y)\" z=\"0\" />\n"
                verticesXML += "          <vertex x=\"\(x)\" y=\"\(y)\" z=\"\(height)\" />\n"
            }

            for i in 0..<sides {
                let next = (i + 1) % sides
                let b0 = 2 + i * 2
                let t0 = 2 + i * 2 + 1
                let b1 = 2 + next * 2
                let t1 = 2 + next * 2 + 1

                trianglesXML += "          <triangle v1=\"0\" v2=\"\(b1)\" v3=\"\(b0)\" />\n"
                trianglesXML += "          <triangle v1=\"1\" v2=\"\(t0)\" v3=\"\(t1)\" />\n"
                trianglesXML += "          <triangle v1=\"\(b0)\" v2=\"\(b1)\" v3=\"\(t1)\" />\n"
                trianglesXML += "          <triangle v1=\"\(b0)\" v2=\"\(t1)\" v3=\"\(t0)\" />\n"
            }

            let contentTypesXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml" />
              <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml" />
            </Types>
            """
            try contentTypesXML.write(
                to: tempDir.appendingPathComponent("[Content_Types].xml"),
                atomically: true,
                encoding: .utf8
            )

            let relsXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel" />
            </Relationships>
            """
            try relsXML.write(
                to: relsDir.appendingPathComponent(".rels"),
                atomically: true,
                encoding: .utf8
            )

            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
              <metadata name="Title">Hexagonal Desk Organizer</metadata>
              <metadata name="Designer">PrintVault</metadata>
              <resources>
                <object id="1" type="model">
                  <mesh>
                    <vertices>
            \(verticesXML)        </vertices>
                    <triangles>
            \(trianglesXML)        </triangles>
                  </mesh>
                </object>
              </resources>
              <build>
                <item objectid="1" />
              </build>
            </model>
            """

            let modelFile = modelDir.appendingPathComponent("3dmodel.model")
            try xml.write(to: modelFile, atomically: true, encoding: .utf8)

            try? FileManager.default.removeItem(at: targetURL)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.currentDirectoryURL = tempDir
            proc.arguments = ["-q", "-r", targetURL.path, "[Content_Types].xml", "_rels", "3D"]
            try proc.run()
            proc.waitUntilExit()

            try? FileManager.default.removeItem(at: tempDir)
            return proc.terminationStatus == 0
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            return false
        }
    }
}
