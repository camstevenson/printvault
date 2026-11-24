import Foundation
import Testing
import SwiftData
import simd
@testable import PrintVault

@Suite("PrintVault Core Tests")
struct PrintVaultTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintVaultTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Binary STL Generation & Parsing

    @Test("Binary STL sample cube generates valid bytes and parses exact 20mm dimensions and 8cm3 volume")
    func binarySTLGenerationAndParsing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cubeURL = dir.appendingPathComponent("Calibration_XYZ_20mm_Cube.stl")
        let tris = SampleMeshGenerator.makeBoxTriangles(
            min: SIMD3<Float>(-10, -10, 0),
            max: SIMD3<Float>(10, 10, 20)
        )
        #expect(tris.count == 12)

        let written = SampleMeshGenerator.writeBinarySTL(
            triangles: tris,
            headerText: "Unit Test Cube",
            to: cubeURL
        )
        #expect(written == true)

        let rawData = try Data(contentsOf: cubeURL)
        // Binary STL specification: 80-byte header + 4-byte uint32 count + 50 bytes per triangle
        #expect(rawData.count == 84 + 12 * 50)

        let loaded = try await MeshLoaderService.loadMesh(at: cubeURL)
        #expect(loaded.metadata.triangleCount == 12)
        #expect(abs(loaded.metadata.dimensionX - 20.0) < 0.01)
        #expect(abs(loaded.metadata.dimensionY - 20.0) < 0.01)
        #expect(abs(loaded.metadata.dimensionZ - 20.0) < 0.01)
        #expect(abs(loaded.metadata.volumeCm3 - 8.0) < 0.05)
        #expect(abs(loaded.metadata.surfaceAreaCm2 - 24.0) < 0.05)
    }

    @Test("Per-component volume sums disconnected shells even when one shell has inverted triangle winding")
    func perComponentInvertedWindingVolume() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cubeA = SampleMeshGenerator.makeBoxTriangles(
            min: SIMD3<Float>(0, 0, 0),
            max: SIMD3<Float>(20, 20, 20)
        )
        // Second disconnected cube with inverted winding (simulating a mirrored sub-part)
        let cubeBInverted = SampleMeshGenerator.makeBoxTriangles(
            min: SIMD3<Float>(50, 0, 0),
            max: SIMD3<Float>(70, 20, 20)
        ).map { ($0.0, $0.2, $0.1) }

        let url = dir.appendingPathComponent("two_cubes_one_mirrored.stl")
        #expect(SampleMeshGenerator.writeBinarySTL(triangles: cubeA + cubeBInverted, headerText: "Mirrored Sub-Part", to: url))

        let loaded = try await MeshLoaderService.loadMesh(at: url)
        #expect(abs(loaded.metadata.volumeCm3 - 16.0) < 0.05)
        #expect(abs(loaded.metadata.surfaceAreaCm2 - 48.0) < 0.05)
    }

    // MARK: - ASCII STL Parsing

    @Test("ASCII STL parses triangles and bounding box dimensions")
    func asciiSTLParsing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let asciiSTL = """
        solid unit_tetra
          facet normal 0 0 -1
            outer loop
              vertex 0 0 0
              vertex 10 0 0
              vertex 0 10 0
            endloop
          endfacet
          facet normal 0 -1 0
            outer loop
              vertex 0 0 0
              vertex 0 0 15
              vertex 10 0 0
            endloop
          endfacet
        endsolid unit_tetra
        """
        let url = dir.appendingPathComponent("ascii_test.stl")
        try asciiSTL.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try await MeshLoaderService.loadMesh(at: url)
        #expect(loaded.metadata.triangleCount == 2)
        #expect(abs(loaded.metadata.dimensionX - 10.0) < 0.01)
        #expect(abs(loaded.metadata.dimensionY - 10.0) < 0.01)
        #expect(abs(loaded.metadata.dimensionZ - 15.0) < 0.01)
    }

    // MARK: - 3MF Generation, Units, and Transform Parsing

    @Test("Sample 3MF archive parses valid hexagonal geometry")
    func sample3MFParsing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("Hexagonal_Desk_Organizer.3mf")
        let created = SampleMeshGenerator.createSample3MFFile(at: url)
        #expect(created == true)

        let loaded = try await MeshLoaderService.loadMesh(at: url)
        #expect(loaded.metadata.triangleCount == 24)
        #expect(abs(loaded.metadata.dimensionZ - 48.0) < 0.1)
        #expect(loaded.metadata.dimensionX > 40.0)
        #expect(loaded.metadata.dimensionY > 40.0)
    }

    @Test("3MF parser converts inch units to mm and applies build item transforms")
    func threeMFUnitAndTransformParsing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let staging = dir.appendingPathComponent("stage", isDirectory: true)
        let modelDir = staging.appendingPathComponent("3D", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // 1x1x1 inch cube placed twice via build transforms: one at origin, one shifted +2 inches in X -> total X span = 3 inches = 76.2 mm
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="inch" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1" type="model">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0" />
                  <vertex x="1" y="0" z="0" />
                  <vertex x="1" y="1" z="0" />
                  <vertex x="0" y="1" z="0" />
                  <vertex x="0" y="0" z="1" />
                  <vertex x="1" y="0" z="1" />
                  <vertex x="1" y="1" z="1" />
                  <vertex x="0" y="1" z="1" />
                </vertices>
                <triangles>
                  <triangle v1="0" v2="2" v3="1" />
                  <triangle v1="0" v2="3" v3="2" />
                  <triangle v1="4" v2="5" v3="6" />
                  <triangle v1="4" v2="6" v3="7" />
                </triangles>
              </mesh>
            </object>
          </resources>
          <build>
            <item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0" />
            <item objectid="1" transform="1 0 0 0 1 0 0 0 1 2 0 0" />
          </build>
        </model>
        """
        try xml.write(to: modelDir.appendingPathComponent("3dmodel.model"), atomically: true, encoding: .utf8)

        let archiveURL = dir.appendingPathComponent("transformed_plate.3mf")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = staging
        proc.arguments = ["-q", "-r", archiveURL.path, "3D"]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)

        let loaded = try await MeshLoaderService.loadMesh(at: archiveURL)
        #expect(loaded.metadata.subModelCount == 2)
        #expect(loaded.metadata.triangleCount == 8)
        #expect(abs(loaded.metadata.dimensionX - 76.2) < 0.1)
        #expect(abs(loaded.metadata.dimensionY - 25.4) < 0.1)
        #expect(abs(loaded.metadata.dimensionZ - 25.4) < 0.1)
    }

    @Test("High-poly 600k-triangle 3MF parses quickly with exact metadata and watertight preview LOD")
    func highPoly3MFFastByteParserAndLOD() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let staging = dir.appendingPathComponent("stage_highpoly", isDirectory: true)
        let objectsDir = staging.appendingPathComponent("3D/Objects", isDirectory: true)
        try FileManager.default.createDirectory(at: objectsDir, withIntermediateDirectories: true)

        // Generate a 550x550 grid (~605,000 triangles) inside an external 3D/Objects/grid.model referenced via <component p:path>
        let n = 550
        var subXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<model unit=\"millimeter\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><resources><object id=\"2\" type=\"model\"><mesh><vertices>\n"
        subXML.reserveCapacity(42_000_000)
        for y in 0...n {
            let fy = Double(y) * (50.0 / Double(n))
            for x in 0...n {
                let fx = Double(x) * (50.0 / Double(n))
                let fz = sin(fx * 0.2) * cos(fy * 0.2) * 5.0 + 5.0
                subXML += "<vertex x=\"\(String(format: "%.3f", fx))\" y=\"\(String(format: "%.3f", fy))\" z=\"\(String(format: "%.3f", fz))\"/>\n"
            }
        }
        subXML += "</vertices><triangles>\n"
        let stride = n + 1
        for y in 0..<n {
            for x in 0..<n {
                let i0 = y * stride + x
                let i1 = i0 + 1
                let i2 = i0 + stride
                let i3 = i2 + 1
                subXML += "<triangle v1=\"\(i0)\" v2=\"\(i1)\" v3=\"\(i3)\"/>\n"
                subXML += "<triangle v1=\"\(i0)\" v2=\"\(i3)\" v3=\"\(i2)\"/>\n"
            }
        }
        subXML += "</triangles></mesh></object></resources></model>"
        try subXML.write(to: objectsDir.appendingPathComponent("grid.model"), atomically: true, encoding: .utf8)

        let rootXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
          <resources>
            <object id="1" type="model">
              <components>
                <component p:path="/3D/Objects/grid.model" objectid="2" transform="1 0 0 0 1 0 0 0 1 0 0 0" />
              </components>
            </object>
          </resources>
          <build>
            <item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0" />
            <item objectid="1" transform="1 0 0 0 1 0 0 0 1 100 0 0" />
          </build>
        </model>
        """
        try rootXML.write(to: staging.appendingPathComponent("3D/3dmodel.model"), atomically: true, encoding: .utf8)

        let archiveURL = dir.appendingPathComponent("highpoly_test.3mf")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = staging
        proc.arguments = ["-q", "-1", "-r", archiveURL.path, "3D"]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)

        let start = CFAbsoluteTimeGetCurrent()
        let loaded = try await MeshLoaderService.loadMesh(at: archiveURL)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Two transformed instances of the 50mm grid (at X=0 and X=100) -> 1,210,000 triangles and 150mm X span!
        #expect(loaded.metadata.subModelCount == 2)
        #expect(loaded.metadata.triangleCount == n * n * 2 * 2)
        #expect(abs(loaded.metadata.dimensionX - 150.0) < 0.1)
        #expect(abs(loaded.metadata.dimensionY - 50.0) < 0.1)
        #expect(elapsed < 10.0)

        // Preview geometry should preserve the full 150mm bounding span across both separated instances
        let (pMin, pMax) = loaded.rootNode.boundingBox
        #expect(abs(Double(pMax.x - pMin.x) - 150.0) < 1.5)
        let previewTris = loaded.rootNode.childNodes.first?.geometry?.elements.first?.primitiveCount ?? 0
        #expect(previewTris > 1000)
        #expect(previewTris < loaded.metadata.triangleCount)
    }

    // MARK: - File Scanner & Auto-Categorization

    @Test("Folder scanning finds 3D models, skips ignored dirs, and matches folder boundaries safely")
    @MainActor
    func folderScanningAndBoundaryMatching() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let created = SampleMeshGenerator.createSampleModelsOnDisk(in: dir)
        #expect(created.count == 5)

        // Create unsupported .obj and .ply files plus an ignored node_modules directory with a dummy .stl
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: dir.appendingPathComponent("should_ignore.obj"))
        try Data("ply\nformat ascii 1.0\nend_header\n".utf8).write(to: dir.appendingPathComponent("should_ignore.ply"))
        let ignoredDir = dir.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredDir, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: ignoredDir.appendingPathComponent("ignored.stl"))

        let found = FileScannerService.enumerateFolderRecursively(at: dir, source: .watchedFolder)
        #expect(found.count == 5)
        #expect(found.allSatisfy { !$0.filePath.contains("/node_modules/") })
        #expect(found.allSatisfy { $0.fileExtension == "stl" || $0.fileExtension == "3mf" })

        // Boundary matching prevents /Downloads matching /Downloads2
        #expect(FileScannerService.matchesFolder("/Users/test/Downloads/part.stl", folderPath: "/Users/test/Downloads") == true)
        #expect(FileScannerService.matchesFolder("/Users/test/Downloads2/part.stl", folderPath: "/Users/test/Downloads") == false)
    }

    @Test("Auto-categorization maps Gridfinity, Calibration, and Gear filenames to expected categories")
    @MainActor
    func autoCategorizationHeuristics() {
        let categories = PrintCategory.defaultSeeds.enumerated().map { idx, seed in
            PrintCategory(name: seed.name, iconName: seed.icon, colorHex: seed.hex, sortOrder: idx)
        }

        let binCat = FileScannerService.suggestCategory(
            fileName: "Gridfinity_1x1_Storage_Bin.stl",
            filePath: "/tmp/Gridfinity_1x1_Storage_Bin.stl",
            finderTags: [],
            availableCategories: categories
        )
        #expect(binCat?.name.contains("Organizers") == true)

        let cubeCat = FileScannerService.suggestCategory(
            fileName: "Calibration_XYZ_20mm_Cube.stl",
            filePath: "/tmp/Calibration_XYZ_20mm_Cube.stl",
            finderTags: [],
            availableCategories: categories
        )
        #expect(cubeCat?.name.contains("Calibration") == true)

        let gearCat = FileScannerService.suggestCategory(
            fileName: "Planetary_Spur_Gear_24T.stl",
            filePath: "/tmp/Planetary_Spur_Gear_24T.stl",
            finderTags: [],
            availableCategories: categories
        )
        #expect(gearCat?.name.contains("Functional") == true)
    }

    // MARK: - Slicer Hooks & Safe Shell Escaping

    @Test("Slicer placeholder expansion safely escapes spaces, quotes, and shell metacharacters")
    @MainActor
    func slicerPlaceholderEscaping() {
        let item = PrintFileItem(
            filePath: "/tmp/My Prints/Benchy's $(evil) Model.stl",
            fileName: "Benchy's $(evil) Model.stl",
            fileExtension: "stl",
            fileSize: 1000,
            dateModified: Date(),
            discoverySource: .manual,
            tags: ["PLA", "0.2mm"]
        )

        let expanded = SlicerService.expandPlaceholders(
            template: "echo {file} {name} {slicer}",
            items: [item],
            slicerName: "OrcaSlicer"
        )
        #expect(expanded.contains("'/tmp/My Prints/Benchy'\\''s $(evil) Model.stl'"))
        #expect(expanded.contains("'OrcaSlicer'"))

        let cliArgs = SlicerService.buildCLIArguments(template: "--load {file} --export-dir {dir}", items: [item])
        #expect(cliArgs == ["--load", "/tmp/My Prints/Benchy's $(evil) Model.stl", "--export-dir", "/tmp/My Prints"])
    }

    @Test("SlicerService executes custom CLI slicer, pre/post shell hooks, and programmatic Swift hooks")
    @MainActor
    func endToEndSlicerHookPipeline() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelURL = dir.appendingPathComponent("Test_Bracket.stl")
        SampleMeshGenerator.writeBinarySTL(
            triangles: SampleMeshGenerator.makeBoxTriangles(min: .zero, max: SIMD3<Float>(10, 10, 10)),
            headerText: "Test",
            to: modelURL
        )

        let logFile = dir.appendingPathComponent("hook_log.txt")
        let item = PrintFileItem(
            filePath: modelURL.path,
            fileName: modelURL.lastPathComponent,
            fileExtension: "stl",
            fileSize: 684,
            dateModified: Date(),
            discoverySource: .manual
        )

        let service = SlicerService(loadPersisted: false)
        service.hookConfig.syncFinderTagsOnSend = false
        service.hookConfig.autoUpdateStatusOnSend = true
        service.hookConfig.targetStatusOnSend = .queued
        service.hookConfig.enablePreSliceShellHook = true
        service.hookConfig.preSliceShellCommand = "echo PRE:{name} >> \(SlicerService.shellEscape(logFile.path))"
        service.hookConfig.enablePostSliceShellHook = true
        service.hookConfig.postSliceShellCommand = "echo POST:{slicer} >> \(SlicerService.shellEscape(logFile.path))"

        final class SpyHook: SlicerHook {
            let id = "spy"
            let name = "SpyHook"
            let stage: SlicerHookStage = .postSlice
            var invokedWithCount = 0
            func execute(context: SlicerHookContext) async -> SlicerHookResult {
                invokedWithCount = context.items.count
                return SlicerHookResult(hookName: name, succeeded: true, output: "Spy ran")
            }
        }
        let spy = SpyHook()
        service.registerHook(spy)

        let customCLISlicer = SlicerProfile(
            id: "test-cli",
            name: "TestCLISlicer",
            bundleIdentifier: nil,
            appPath: "/bin/echo",
            cliArgumentsTemplate: "SLICING {file}",
            useDirectCLIExecution: true,
            isBuiltIn: false
        )

        let succeeded = await service.sendToSlicer(items: [item], using: customCLISlicer)
        #expect(succeeded == true)
        #expect(item.sliceCount == 1)
        #expect(item.lastUsedSlicerName == "TestCLISlicer")
        #expect(item.printStatus == .queued)
        #expect(spy.invokedWithCount == 1)

        let logContents = try String(contentsOf: logFile, encoding: .utf8)
        #expect(logContents.contains("PRE:Test_Bracket"))
        #expect(logContents.contains("POST:TestCLISlicer"))
    }

    // MARK: - Filament Weight & 1.75mm Length Estimation

    @Test("Shell + infill filament estimator treats thin-walled models as ~100% solid and thick models as shell + infill")
    @MainActor
    func filamentLengthEstimation() {
        let item = PrintFileItem(
            filePath: "/tmp/model.stl",
            fileName: "model.stl",
            fileExtension: "stl",
            fileSize: 684,
            dateModified: Date(),
            discoverySource: .manual
        )

        // 1. 20mm cube: V = 8.0 cm³, S = 24.0 cm² -> shellFraction = 0.27, + 20% infill of remaining 0.73 = 0.416
        item.estimatedVolumeCm3 = 8.0
        item.surfaceAreaCm2 = 24.0
        #expect(abs(item.estimatedEffectiveFillFraction(wallThicknessMm: 1.0, infillPercent: 20.0) - 0.416) < 0.005)
        #expect(abs(item.estimatedPLAWeightGrams - 4.127) < 0.05)
        #expect(abs(item.estimatedFilamentLengthMeters - 1.384) < 0.02)

        // 2. Thin-walled fence/plate (2mm thick, 100x20x2mm): V = 4.0 cm³, S = 44.8 cm² -> 100% solid walls
        item.estimatedVolumeCm3 = 4.0
        item.surfaceAreaCm2 = 44.8
        #expect(abs(item.estimatedEffectiveFillFraction(wallThicknessMm: 1.0, infillPercent: 20.0) - 1.0) < 0.001)
        #expect(abs(item.estimatedPLAWeightGrams - 4.96) < 0.02)
        #expect(abs(item.estimatedFilamentLengthMeters - 1.663) < 0.01)

        // 3. 100% solid 1 kg spool check (~806.45 cm³ PLA = ~1000 g = ~335.3 m of 1.75mm filament)
        item.estimatedVolumeCm3 = 806.45
        item.surfaceAreaCm2 = 500.0
        #expect(abs(item.estimatedPLAWeightGrams(infillPercent: 100.0) - 1000.0) < 0.5)
        #expect(abs(item.estimatedFilamentLengthMeters(infillPercent: 100.0) - 335.28) < 0.5)
        #expect(item.formattedEstimatedFilamentLength(infillPercent: 100.0) == "~335.3 m")
    }

    // MARK: - Single Instance Guard

    @Test("SingleInstanceGuard prevents a second lock while held and allows re-acquisition after release")
    @MainActor
    func singleInstanceLockEnforcement() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockURL = dir.appendingPathComponent("instance.lock")
        let first = SingleInstanceGuard()
        let second = SingleInstanceGuard()

        #expect(first.tryAcquireLock(at: lockURL) == true)
        #expect(second.tryAcquireLock(at: lockURL) == false)

        let storedPID = try String(contentsOf: lockURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(storedPID == "\(ProcessInfo.processInfo.processIdentifier)")

        first.releaseLock()
        #expect(second.tryAcquireLock(at: lockURL) == true)
        second.releaseLock()
    }

    // MARK: - Local VLM Auto-Categorizer

    @Test("VLM vision model detection prefers Qwen2.5-VL / FastVLM over text-only LLMs")
    func vlmVisionModelSelection() {
        let installed = ["llama3.2:3b", "codellama:7b", "llava:7b", "qwen2.5vl:3b", "nomic-embed-text"]
        #expect(VLMCategorizerService.isLikelyVisionModel("qwen2.5vl:3b") == true)
        #expect(VLMCategorizerService.isLikelyVisionModel("gemma3:4b") == true)
        #expect(VLMCategorizerService.isLikelyVisionModel("llama3.2:3b") == false)
        #expect(VLMCategorizerService.isLikelyVisionModel("codellama:7b") == false)
        #expect(VLMCategorizerService.pickPreferredVisionModel(from: installed) == "qwen2.5vl:3b")
    }

    @Test("VLM JSON parser handles fenced JSON, matches existing categories, sanitizes tags, and supports new categories")
    @MainActor
    func vlmJSONParsingAndCategoryMatching() {
        let categories = PrintCategory.defaultSeeds.enumerated().map { idx, seed in
            PrintCategory(name: seed.name, iconName: seed.icon, colorHex: seed.hex, sortOrder: idx)
        }

        let fencedOutput = """
        Here is my analysis:
        ```json
        {
          "category": "Miniatures & Figurines",
          "isNewCategory": false,
          "confidence": 0.94,
          "tags": ["#gargoyle", "statue", "Statue", "gothic", "a"],
          "summary": "Crouching gothic gargoyle statue with sculpted wings."
        }
        ```
        """
        let suggestion = VLMCategorizerService.parseSuggestion(
            from: fencedOutput,
            itemFilePath: "/tmp/Gargoyle_Crouching.stl",
            fileName: "Gargoyle_Crouching.stl",
            existingCategories: categories,
            allowNewCategories: false,
            confidenceThreshold: 0.78,
            elapsedSeconds: 0.8
        )
        #expect(suggestion.errorMessage == nil)
        #expect(suggestion.suggestedCategoryName == "Miniatures & Figurines")
        #expect(suggestion.matchedCategoryID != nil)
        #expect(suggestion.isNewCategory == false)
        #expect(abs(suggestion.confidence - 0.94) < 0.001)
        #expect(suggestion.tags == ["gargoyle", "statue", "gothic"])
        #expect(suggestion.isSelected == true)

        // Slugified VLM category names must match existing categories instead of spawning duplicates
        for (slug, expected) in [
            ("functional-parts", "Functional Parts"),
            ("functional_parts", "Functional Parts"),
            ("calibration-test", "Calibration & Test"),
            ("household-and-mounts", "Household & Mounts"),
            ("organizers-gridfinity", "Organizers & Gridfinity")
        ] {
            let slugRes = VLMCategorizerService.parseSuggestion(
                from: "{\"category\": \"\(slug)\", \"isNewCategory\": true, \"confidence\": 0.9, \"tags\": [], \"summary\": \"\"}",
                itemFilePath: "/tmp/test.stl",
                fileName: "test.stl",
                existingCategories: categories,
                allowNewCategories: true,
                confidenceThreshold: 0.78,
                elapsedSeconds: 0.2
            )
            #expect(slugRes.suggestedCategoryName == expected)
            #expect(slugRes.matchedCategoryID != nil)
            #expect(slugRes.isNewCategory == false)
        }

        // New category allowed — slugs are formatted cleanly into Title Case
        let newCatOutput = """
        {"category": "tabletop-terrain", "isNewCategory": true, "confidence": 0.89, "tags": ["terrain", "fence"], "summary": "Gothic tabletop terrain."}
        """
        let newCatSuggestion = VLMCategorizerService.parseSuggestion(
            from: newCatOutput,
            itemFilePath: "/tmp/wrought-iron-fence.stl",
            fileName: "wrought-iron-fence.stl",
            existingCategories: categories,
            allowNewCategories: true,
            confidenceThreshold: 0.78,
            elapsedSeconds: 0.6
        )
        #expect(newCatSuggestion.suggestedCategoryName == "Tabletop Terrain")
        #expect(newCatSuggestion.matchedCategoryID == nil)
        #expect(newCatSuggestion.isNewCategory == true)
        #expect(newCatSuggestion.isSelected == true)
    }

    @Test("mergeDuplicateCategories collapses slugified duplicates into canonical categories and preserves models")
    @MainActor
    func mergeDuplicateSlugCategories() throws {
        let schema = Schema([PrintFileItem.self, PrintCategory.self, WatchedFolder.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let ctx = container.mainContext

        let canonical = PrintCategory(name: "Functional Parts", sortOrder: 0)
        let dupHyphen = PrintCategory(name: "functional-parts", sortOrder: 6)
        let dupUnderscore = PrintCategory(name: "functional_parts", sortOrder: 7)
        let distinct = PrintCategory(name: "Keycaps", sortOrder: 8)
        ctx.insert(canonical)
        ctx.insert(dupHyphen)
        ctx.insert(dupUnderscore)
        ctx.insert(distinct)

        let item1 = PrintFileItem(filePath: "/tmp/a.stl", fileName: "a.stl", fileExtension: "stl", fileSize: 10, dateModified: Date(), category: dupHyphen)
        let item2 = PrintFileItem(filePath: "/tmp/b.stl", fileName: "b.stl", fileExtension: "stl", fileSize: 10, dateModified: Date(), category: dupUnderscore)
        let item3 = PrintFileItem(filePath: "/tmp/c.stl", fileName: "c.stl", fileExtension: "stl", fileSize: 10, dateModified: Date(), category: distinct)
        ctx.insert(item1)
        ctx.insert(item2)
        ctx.insert(item3)
        try ctx.save()

        let (removed, moved) = VLMCategorizerService.mergeDuplicateCategories(context: ctx)
        #expect(removed == 2)
        #expect(moved == 2)
        #expect(item1.category?.name == "Functional Parts")
        #expect(item2.category?.name == "Functional Parts")
        #expect(item3.category?.name == "Keycaps")

        let remainingCats = try ctx.fetch(FetchDescriptor<PrintCategory>())
        #expect(remainingCats.count == 2)
    }

    @Test("VLM prompt embeds physical dimensions, geometry stats, and existing categories")
    func vlmPromptConstruction() {
        let prompt = VLMCategorizerService.buildClassificationPrompt(
            fileName: "compromise.stl",
            parentFolder: "Downloads",
            dimensions: "75.2 × 113.3 × 31.1 mm",
            volumeCm3: 7.48,
            surfaceAreaCm2: 92.4,
            triangleCount: 2388,
            subModelCount: 1,
            existingCategories: ["Functional Parts", "Miniatures & Figurines"],
            allowNewCategories: false
        )
        #expect(prompt.contains("75.2 × 113.3 × 31.1 mm"))
        #expect(prompt.contains("7.48 cm³"))
        #expect(prompt.contains("Functional Parts, Miniatures & Figurines"))
        #expect(prompt.contains("ignore cryptic or meaningless filenames"))
    }

    @Test("VLM project context unwraps archive/print-variant folders, omits generic roots, and embeds sibling assembly hints")
    func vlmProjectAndSiblingContextPrompt() {
        let watched = ["/Users/tester/Downloads", "/Users/tester/Documents/3D Printing/STL files"]

        // 1. Thingiverse `files/` wrapper -> unwraps to cleaned project name
        let shavingCtx = ModelGroupingService.meaningfulProjectContext(
            for: URL(fileURLWithPath: "/Users/tester/Documents/3D Printing/STL files/Shaving_Supplies_Stand__2741048/files/compromise.stl"),
            watchedFolderPaths: watched
        )
        #expect(shavingCtx.projectFolder == "Shaving Supplies Stand")
        #expect(shavingCtx.ancestorFolder == nil)

        // 2. Print-variant wrapper (`FDM_Multi_Color`) -> unwraps to parent project
        let terrainCtx = ModelGroupingService.meaningfulProjectContext(
            for: URL(fileURLWithPath: "/Users/tester/Downloads/Foldable_Terrain_Sample/FDM_Multi_Color/Armored_Sample_Floor_A_Clips_Hinge.3mf"),
            watchedFolderPaths: watched
        )
        #expect(terrainCtx.projectFolder == "Foldable Terrain Sample")
        #expect(terrainCtx.ancestorFolder == nil)

        // 3. Nested miniature pack preserves meaningful collection ancestor (`4-Environment`)
        let millCtx = ModelGroupingService.meaningfulProjectContext(
            for: URL(fileURLWithPath: "/Users/tester/Desktop/models/FreeMiniPack_All/4-Environment/OldMill_32mm_Unsupported/OldMill_32mm_1stWall_FDM.stl"),
            watchedFolderPaths: watched
        )
        #expect(millCtx.projectFolder == "OldMill 32mm")
        #expect(millCtx.ancestorFolder == "4 Environment")

        // 4. Generic watched folders omit folder noise entirely
        let looseCtx = ModelGroupingService.meaningfulProjectContext(
            for: URL(fileURLWithPath: "/Users/tester/Downloads/Gargoyle_Crouching.stl"),
            watchedFolderPaths: watched
        )
        #expect(looseCtx.projectFolder == nil)
        #expect(looseCtx.ancestorFolder == nil)

        let genericStlCtx = ModelGroupingService.meaningfulProjectContext(
            for: URL(fileURLWithPath: "/Users/tester/Documents/3D Printing/STL files/car-glasses-clip-v4.stl"),
            watchedFolderPaths: watched
        )
        #expect(genericStlCtx.projectFolder == nil)
        #expect(genericStlCtx.ancestorFolder == nil)

        // 5. Prompt includes project folder, collection folder, and sibling parts
        let prompt = VLMCategorizerService.buildClassificationPrompt(
            fileName: "Handle.stl",
            parentFolder: "Baby Sword Rattle",
            ancestorFolder: "Toys",
            groupTitle: "Baby Sword Rattle",
            groupPartCount: 6,
            siblingPartNames: ["Blade_2", "Jewel", "Pommel"],
            dimensions: "24.0 × 90.0 × 24.0 mm",
            volumeCm3: 14.2,
            surfaceAreaCm2: 88.0,
            triangleCount: 4200,
            subModelCount: 1,
            existingCategories: ["Functional Parts", "Cosplay & Props", "Miniatures & Figurines"],
            allowNewCategories: false
        )
        #expect(prompt.contains("- Filename: Handle.stl"))
        #expect(prompt.contains("- Project folder: Baby Sword Rattle"))
        #expect(prompt.contains("- Collection folder: Toys"))
        #expect(prompt.contains("Part of a 6-part model \"Baby Sword Rattle\" (sibling parts: Blade_2, Jewel, Pommel)"))
    }

    // MARK: - Smart Multi-Part Model Grouping

    private func makeTestItem(
        path: String,
        fileSize: Int64 = 1000,
        category: PrintCategory? = nil
    ) -> PrintFileItem {
        let url = URL(fileURLWithPath: path)
        return PrintFileItem(
            filePath: path,
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            fileSize: fileSize,
            dateModified: Date(),
            discoverySource: .watchedFolder,
            category: category
        )
    }

    @Test("ModelGroupingService groups cohesive project subfolders, unwraps archive wrappers, tolerates VLM category variance across parts, and excludes stray files")
    @MainActor
    func groupingCohesiveSubfoldersAndWrappers() {
        let watched = ["/Users/tester/Downloads"]
        let minisCat = PrintCategory(name: "Miniatures & Figurines", sortOrder: 0)
        let funcCat = PrintCategory(name: "Functional Parts", sortOrder: 1)
        let cosplayCat = PrintCategory(name: "Cosplay & Props", sortOrder: 2)

        // 1. Dedicated project folder with shared folder/file tokens + assembly file + mixed VLM categories
        let hogwarts1 = makeTestItem(path: "/Users/tester/Downloads/Hogwarts_Castle/hogwarts_part_1.3mf", fileSize: 50_000, category: minisCat)
        let hogwarts2 = makeTestItem(path: "/Users/tester/Downloads/Hogwarts_Castle/hogwarts_part_2.3mf", fileSize: 60_000, category: funcCat)
        let hogwartsAsm = makeTestItem(path: "/Users/tester/Downloads/Hogwarts_Castle/hogwarts_assembly.3mf", fileSize: 20_000, category: minisCat)

        // 2. Thingiverse/Printables `files/` wrapper subfolder with VLM category variance across parts
        let rattleBlade = makeTestItem(path: "/Users/tester/Downloads/Baby_Sword_Rattle_1411578/files/Blade_2.stl", fileSize: 12_000, category: minisCat)
        let rattleHandle = makeTestItem(path: "/Users/tester/Downloads/Baby_Sword_Rattle_1411578/files/Handle.stl", fileSize: 18_000, category: funcCat)
        let rattlePommel = makeTestItem(path: "/Users/tester/Downloads/Baby_Sword_Rattle_1411578/files/Pommel.stl", fileSize: 10_000, category: cosplayCat)

        // 3. Printables `-model_files` folder
        let marbleCorner = makeTestItem(path: "/Users/tester/Downloads/wall-mounted-marble-run-model_files/corner-v3.stl", fileSize: 8_000, category: funcCat)
        let marbleLoop = makeTestItem(path: "/Users/tester/Downloads/wall-mounted-marble-run-model_files/loop-track-v2.stl", fileSize: 9_000, category: minisCat)

        // 4. Non-archive project folder with an unrelated stray file dropped inside
        let whelp1 = makeTestItem(path: "/Users/tester/Downloads/warcraft_rumble_whelp_eggs/Warcraft_Rumble_Whelp_Eggs.stl", category: minisCat)
        let whelp2 = makeTestItem(path: "/Users/tester/Downloads/warcraft_rumble_whelp_eggs/Warcraft_Rumble_Whelp_Eggs_Base.stl", category: minisCat)
        let strayKeycap = makeTestItem(path: "/Users/tester/Downloads/warcraft_rumble_whelp_eggs/1.25u Blank.stl", category: funcCat)

        let entries = ModelGroupingService.groupItems(
            [hogwarts1, hogwarts2, hogwartsAsm, rattleBlade, rattleHandle, rattlePommel, marbleCorner, marbleLoop, whelp1, whelp2, strayKeycap],
            watchedFolderPaths: watched
        )

        // Expect 4 groups + 1 stray standalone keycap
        #expect(entries.count == 5)

        let groups: [ModelGroup] = entries.compactMap { entry in
            if case .group(let g) = entry { return g }
            return nil
        }
        let singles: [PrintFileItem] = entries.compactMap { entry in
            if case .single(let item) = entry { return item }
            return nil
        }

        #expect(groups.count == 4)
        #expect(singles.count == 1)
        #expect(singles.first?.filePath == strayKeycap.filePath)

        let hogwartsGroup = groups.first { $0.title == "Hogwarts Castle" }
        #expect(hogwartsGroup?.items.count == 3)
        #expect(hogwartsGroup?.reason == .projectFolder)
        #expect(hogwartsGroup?.primaryItem.filePath == hogwartsAsm.filePath)

        let rattleGroup = groups.first { $0.title == "Baby Sword Rattle" }
        #expect(rattleGroup?.items.count == 3)
        #expect(rattleGroup?.reason == .projectFolder)

        let marbleGroup = groups.first { $0.title == "Wall Mounted Marble Run" }
        #expect(marbleGroup?.items.count == 2)
    }

    @Test("ModelGroupingService avoids grouping dissimilar files in watched roots, generic STL folders, mixed subfolders, or conflicting weak folders")
    @MainActor
    func groupingAvoidsFalsePositives() {
        let watched = ["/Users/tester/Downloads"]
        let minisCat = PrintCategory(name: "Miniatures & Figurines", sortOrder: 0)
        let funcCat = PrintCategory(name: "Functional Parts", sortOrder: 1)
        let cosplayCat = PrintCategory(name: "Cosplay & Props", sortOrder: 2)

        // 1. Unrelated files directly inside watched Downloads folder
        let gargoyle = makeTestItem(path: "/Users/tester/Downloads/Gargoyle_Crouching.stl", category: minisCat)
        let nipple = makeTestItem(path: "/Users/tester/Downloads/3_4_npt_4_nipple.stl", category: funcCat)
        let compromise = makeTestItem(path: "/Users/tester/Downloads/compromise.stl", category: funcCat)

        // 2. Unrelated files inside a generic `STL files` container
        let ax = makeTestItem(path: "/Users/tester/Documents/3D Printing/STL files/Barbarian_Viking_Ax.stl", category: minisCat)
        let cap = makeTestItem(path: "/Users/tester/Documents/3D Printing/STL files/Cap_51mm.STL", category: funcCat)
        let clip = makeTestItem(path: "/Users/tester/Documents/3D Printing/STL files/car-glasses-clip-v4.stl", category: funcCat)

        // 3. Unrelated files inside a custom grab-bag subfolder
        let dragon = makeTestItem(path: "/Users/tester/Downloads/Weekend_Prints/dragon.stl", category: minisCat)
        let phoneStand = makeTestItem(path: "/Users/tester/Downloads/Weekend_Prints/phone_stand.stl", category: funcCat)
        let hoseAdapter = makeTestItem(path: "/Users/tester/Downloads/Weekend_Prints/hose_adapter.stl", category: funcCat)

        // 4. Weak assembly-word-only subfolder with conflicting categories (Category Consistency Veto)
        let conflictA = makeTestItem(path: "/Users/tester/Downloads/Mixed_Batch/helmet_stand.stl", category: cosplayCat)
        let conflictB = makeTestItem(path: "/Users/tester/Downloads/Mixed_Batch/cable_clip.stl", category: funcCat)

        let entries = ModelGroupingService.groupItems(
            [gargoyle, nipple, compromise, ax, cap, clip, dragon, phoneStand, hoseAdapter, conflictA, conflictB],
            watchedFolderPaths: watched
        )

        #expect(entries.count == 11)
        let groupCount = entries.filter {
            if case .group = $0 { return true }
            return false
        }.count
        #expect(groupCount == 0)
    }

    @Test("ModelGroupingService groups explicit multi-part stems, double extensions, and matching STL/3MF pairs inside generic folders")
    @MainActor
    func groupingSharedStemsInGenericFolder() {
        let watched = ["/Users/tester/Downloads"]

        let hogAsm = makeTestItem(path: "/Users/tester/Downloads/Hogwarts_-_assembly.3mf", fileSize: 30_000)
        let hog1 = makeTestItem(path: "/Users/tester/Downloads/Hogwarts_-_part_1.3mf", fileSize: 80_000)
        let hog2 = makeTestItem(path: "/Users/tester/Downloads/Hogwarts_-_part_2.3mf", fileSize: 90_000)

        let lichBase = makeTestItem(path: "/Users/tester/Desktop/AK_lichking.3mf", fileSize: 40_000)
        let lichCenter = makeTestItem(path: "/Users/tester/Desktop/AK_lichking-center-1.3mf.stl", fileSize: 20_000)
        let lichLeft = makeTestItem(path: "/Users/tester/Desktop/AK_lichking-left.3mf.stl", fileSize: 18_000)

        let tower = makeTestItem(path: "/Users/tester/Desktop/tower.stl", fileSize: 35_000)
        let towerTop = makeTestItem(path: "/Users/tester/Desktop/tower_top.stl", fileSize: 12_000)
        let towerBottom = makeTestItem(path: "/Users/tester/Desktop/tower_bottom.stl", fileSize: 14_000)

        let unrelated = makeTestItem(path: "/Users/tester/Downloads/Gargoyle_Crouching.stl", fileSize: 25_000)

        let entries = ModelGroupingService.groupItems(
            [hog1, unrelated, hogAsm, lichBase, hog2, lichCenter, lichLeft, tower, towerTop, towerBottom],
            watchedFolderPaths: watched
        )

        // Expect: Hogwarts (3), AK Lichking (3), Tower (3), standalone Gargoyle (1)
        #expect(entries.count == 4)

        let groups: [ModelGroup] = entries.compactMap { entry in
            if case .group(let g) = entry { return g }
            return nil
        }
        let singles: [PrintFileItem] = entries.compactMap { entry in
            if case .single(let item) = entry { return item }
            return nil
        }

        #expect(groups.count == 3)
        #expect(singles.count == 1)
        #expect(singles.first?.filePath == unrelated.filePath)

        let hogGroup = groups.first { $0.title == "Hogwarts" }
        #expect(hogGroup?.items.count == 3)
        #expect(hogGroup?.reason == .sharedStem)
        #expect(hogGroup?.primaryItem.filePath == hogAsm.filePath)

        let lichGroup = groups.first { $0.title == "AK lichking" }
        #expect(lichGroup?.items.count == 3)

        let towerGroup = groups.first { $0.title == "Tower" }
        #expect(towerGroup?.items.count == 3)
    }
}
