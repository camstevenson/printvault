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
}
