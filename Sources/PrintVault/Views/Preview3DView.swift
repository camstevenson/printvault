import SwiftUI
import SceneKit
import AppKit
import simd

// MARK: - Camera View Preset

enum CameraViewPreset: String, CaseIterable, Identifiable {
    case isometric = "Iso"
    case front = "Front"
    case top = "Top"
    case side = "Side"

    var id: String { rawValue }
}

// MARK: - Filament Shader Preset

struct FilamentMaterialPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let nsColor: NSColor
    let swatchColor: Color
    let roughness: CGFloat
    let metalness: CGFloat

    static let presets: [FilamentMaterialPreset] = [
        FilamentMaterialPreset(
            id: "bambu-green",
            name: "Bambu Green",
            nsColor: NSColor(calibratedRed: 0.16, green: 0.72, blue: 0.46, alpha: 1.0),
            swatchColor: Color(red: 0.16, green: 0.72, blue: 0.46),
            roughness: 0.35,
            metalness: 0.08
        ),
        FilamentMaterialPreset(
            id: "prusa-orange",
            name: "Prusa Orange",
            nsColor: NSColor(calibratedRed: 0.96, green: 0.44, blue: 0.12, alpha: 1.0),
            swatchColor: Color(red: 0.96, green: 0.44, blue: 0.12),
            roughness: 0.38,
            metalness: 0.05
        ),
        FilamentMaterialPreset(
            id: "matte-slate",
            name: "Matte Slate",
            nsColor: NSColor(calibratedRed: 0.38, green: 0.44, blue: 0.54, alpha: 1.0),
            swatchColor: Color(red: 0.38, green: 0.44, blue: 0.54),
            roughness: 0.62,
            metalness: 0.05
        ),
        FilamentMaterialPreset(
            id: "silk-gold",
            name: "Silk Gold",
            nsColor: NSColor(calibratedRed: 0.92, green: 0.74, blue: 0.24, alpha: 1.0),
            swatchColor: Color(red: 0.92, green: 0.74, blue: 0.24),
            roughness: 0.22,
            metalness: 0.55
        ),
        FilamentMaterialPreset(
            id: "resin-cyan",
            name: "Resin Cyan",
            nsColor: NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.88, alpha: 1.0),
            swatchColor: Color(red: 0.14, green: 0.68, blue: 0.88),
            roughness: 0.25,
            metalness: 0.12
        )
    ]
}

// MARK: - Preview3DView

struct Preview3DView: View {
    let item: PrintFileItem
    var onExpand: (() -> Void)? = nil

    @State private var loadedScene: LoadedMeshScene?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedMaterial: FilamentMaterialPreset = FilamentMaterialPreset.presets[0]
    @State private var showWireframe = false
    @State private var showBuildPlate = true
    @State private var autoRotate = false
    @State private var cameraPreset: CameraViewPreset = .isometric
    @State private var cameraResetToken = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if let loaded = loadedScene {
                SceneKitViewportRepresentable(
                    meshRootNode: loaded.rootNode,
                    materialPreset: selectedMaterial,
                    showWireframe: showWireframe,
                    showBuildPlate: showBuildPlate,
                    autoRotate: autoRotate,
                    cameraPreset: cameraPreset,
                    cameraResetToken: cameraResetToken
                )
            } else if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Loading 3D Mesh...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Preview Unavailable")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }

            // Top overlay badges + camera preset switcher + expand button
            VStack {
                HStack(spacing: 6) {
                    Text(item.format.badgeText)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(item.format.badgeColor.opacity(0.88))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())

                    if item.hasDimensions {
                        Text(item.formattedDimensions)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Menu {
                        ForEach(CameraViewPreset.allCases) { preset in
                            Button {
                                cameraPreset = preset
                                cameraResetToken += 1
                            } label: {
                                if cameraPreset == preset {
                                    Label(preset.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(preset.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.viewfinder")
                            Text(cameraPreset.rawValue)
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .environment(\.colorScheme, .dark)
                    .fixedSize()
                    .help("Camera Angle Preset")

                    if let onExpand {
                        Button(action: onExpand) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Expand Interactive 3D Preview")
                    }
                }
                .padding(10)
                Spacer()
            }

            // Bottom floating viewport toolbar
            HStack(spacing: 10) {
                // Filament color swatches
                HStack(spacing: 5) {
                    ForEach(FilamentMaterialPreset.presets) { preset in
                        Button {
                            selectedMaterial = preset
                        } label: {
                            Circle()
                                .fill(preset.swatchColor)
                                .frame(width: 15, height: 15)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            selectedMaterial.id == preset.id ? Color.white : Color.clear,
                                            lineWidth: 2
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }

                Divider()
                    .frame(height: 14)

                Toggle(isOn: $showWireframe) {
                    Image(systemName: "network")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Toggle Wireframe Mesh")

                Toggle(isOn: $showBuildPlate) {
                    Image(systemName: "squareshape.split.3x3")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Toggle Slicer Build Plate Grid")

                Toggle(isOn: $autoRotate) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Toggle Turntable Auto-Rotation")

                Button {
                    cameraPreset = .isometric
                    cameraResetToken += 1
                } label: {
                    Image(systemName: "scope")
                }
                .controlSize(.small)
                .help("Reset Camera View")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.58))
            .environment(\.colorScheme, .dark)
            .clipShape(Capsule())
            .padding(.bottom, 10)
        }
        .task(id: item.filePath) {
            await loadItemMesh()
        }
    }

    private func loadItemMesh() async {
        isLoading = true
        errorMessage = nil
        loadedScene = nil

        do {
            let result = try await MeshLoaderService.loadMesh(at: item.fileURL)
            guard !Task.isCancelled else { return }
            loadedScene = result
            // Update SwiftData item metrics if not yet populated (or upgrading legacy records without surface area)
            if !item.meshAnalyzed || item.triangleCount == 0 || item.surfaceAreaCm2 == 0 {
                item.vertexCount = result.metadata.vertexCount
                item.triangleCount = result.metadata.triangleCount
                item.dimensionX = result.metadata.dimensionX
                item.dimensionY = result.metadata.dimensionY
                item.dimensionZ = result.metadata.dimensionZ
                item.estimatedVolumeCm3 = result.metadata.volumeCm3
                item.surfaceAreaCm2 = result.metadata.surfaceAreaCm2
                item.embeddedSubModelCount = result.metadata.subModelCount
                item.meshAnalyzed = true
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        if !Task.isCancelled {
            isLoading = false
        }
    }
}

// MARK: - Expanded Fullscreen 3D Preview Sheet

struct ExpandedPreview3DSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: PrintFileItem
    let slicerService: SlicerService

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.headline)
                    HStack(spacing: 10) {
                        Text(item.fileName)
                        if item.hasDimensions {
                            Text("• \(item.formattedDimensions)")
                        }
                        if item.triangleCount > 0 {
                            Text("• \(item.triangleCount.formatted()) triangles")
                        }
                        if item.estimatedVolumeCm3 > 0 {
                            Text(String(format: "• %.1f cm³ (~%.1f g / %@)", item.estimatedVolumeCm3, item.estimatedPLAWeightGrams, item.formattedEstimatedFilamentLength))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        _ = await slicerService.sendToSlicer(items: [item])
                    }
                } label: {
                    Label("Send to \(slicerService.defaultProfile.name)", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Preview3DView(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}

// MARK: - Custom Slicer-Style Orbit / Pan / Zoom SCNView

private final class OrbitPanZoomSCNView: SCNView {
    private var orbitTarget = SIMD3<Float>(0, 0, 0)
    private var yaw: Float = 0.72          // radians around Y axis
    private var pitch: Float = 0.52        // radians above XZ plane
    private var distance: Float = 100.0
    private var modelSpan: Float = 50.0

    private var lastDragPoint: NSPoint?

    func configureCamera(for node: SCNNode, preset: CameraViewPreset) {
        let (minB, maxB) = node.boundingBox
        let dx = Float(maxB.x - minB.x)
        let dy = Float(maxB.y - minB.y)
        let dz = Float(maxB.z - minB.z)
        let span = max(max(dx, dy), max(dz, 10.0))
        let midY = Float(minB.y + maxB.y) * 0.5

        modelSpan = span
        orbitTarget = SIMD3<Float>(0, midY * 0.85, 0)
        distance = span * 2.2

        switch preset {
        case .isometric:
            yaw = 0.72
            pitch = 0.50
        case .front:
            yaw = 0.0
            pitch = 0.08
        case .top:
            yaw = 0.0
            pitch = (.pi / 2) - 0.03
        case .side:
            yaw = .pi / 2
            pitch = 0.08
        }

        applyCameraTransform()
    }

    private func applyCameraTransform() {
        guard let cameraNode = pointOfView else { return }

        let minDist = max(modelSpan * 0.15, 2.0)
        let maxDist = max(modelSpan * 15.0, 200.0)
        distance = min(max(distance, minDist), maxDist)
        pitch = min(max(pitch, -(.pi / 2) + 0.03), (.pi / 2) - 0.03)

        let cosPitch = cos(pitch)
        let offset = SIMD3<Float>(
            distance * cosPitch * sin(yaw),
            distance * sin(pitch),
            distance * cosPitch * cos(yaw)
        )
        let camPos = orbitTarget + offset

        cameraNode.camera?.zNear = Double(max(0.05, distance * 0.005))
        cameraNode.camera?.zFar = Double(max(modelSpan * 30.0, distance * 12.0))
        cameraNode.position = SCNVector3(CGFloat(camPos.x), CGFloat(camPos.y), CGFloat(camPos.z))
        cameraNode.look(at: SCNVector3(CGFloat(orbitTarget.x), CGFloat(orbitTarget.y), CGFloat(orbitTarget.z)))
    }

    // MARK: Left-Click Drag -> Orbit

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)
        guard let prev = lastDragPoint else {
            lastDragPoint = current
            return
        }
        let dx = Float(current.x - prev.x)
        let dy = Float(current.y - prev.y)
        lastDragPoint = current

        if event.modifierFlags.contains(.option) {
            panModel(dx: dx, dy: dy)
        } else {
            let sensitivity: Float = 0.0085
            yaw -= dx * sensitivity
            pitch -= dy * sensitivity
            applyCameraTransform()
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }

    // MARK: Right-Click Drag (or Middle-Click Drag) -> Pan / Move Model

    override func rightMouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)
        guard let prev = lastDragPoint else {
            lastDragPoint = current
            return
        }
        let dx = Float(current.x - prev.x)
        let dy = Float(current.y - prev.y)
        lastDragPoint = current
        panModel(dx: dx, dy: dy)
    }

    override func rightMouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func otherMouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)
        guard let prev = lastDragPoint else {
            lastDragPoint = current
            return
        }
        let dx = Float(current.x - prev.x)
        let dy = Float(current.y - prev.y)
        lastDragPoint = current
        panModel(dx: dx, dy: dy)
    }

    override func otherMouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }

    private func panModel(dx: Float, dy: Float) {
        guard let cameraNode = pointOfView else { return }

        // Compute world units per point at the orbit target plane so the model tracks 1:1 under the cursor
        let fovDeg = Float(cameraNode.camera?.fieldOfView ?? 40.0)
        let fovRad = fovDeg * .pi / 180.0
        let viewHeight = max(Float(bounds.height), 1.0)
        let worldHeightAtTarget = 2.0 * distance * tan(fovRad * 0.5)
        let unitsPerPoint = worldHeightAtTarget / viewHeight

        let camTransform = cameraNode.simdTransform
        let right = simd_normalize(SIMD3<Float>(camTransform.columns.0.x, camTransform.columns.0.y, camTransform.columns.0.z))
        let up = simd_normalize(SIMD3<Float>(camTransform.columns.1.x, camTransform.columns.1.y, camTransform.columns.1.z))

        // Dragging right/up moves the model right/up on screen by shifting the orbit pivot in the opposite direction
        orbitTarget -= right * (dx * unitsPerPoint)
        orbitTarget -= up * (dy * unitsPerPoint)
        applyCameraTransform()
    }

    // MARK: Scroll Wheel & Pinch -> Zoom In / Out

    override func scrollWheel(with event: NSEvent) {
        let rawDelta = Float(event.scrollingDeltaY)
        guard abs(rawDelta) > 0.0001 else { return }

        let scaleFactor: Float = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
        let zoomDelta = rawDelta * scaleFactor
        distance *= exp(-zoomDelta)
        applyCameraTransform()
    }

    override func magnify(with event: NSEvent) {
        let mag = Float(event.magnification)
        let factor = max(0.5, min(2.0, 1.0 + mag))
        distance /= factor
        applyCameraTransform()
    }
}

// MARK: - SceneKit NSViewRepresentable

private struct SceneKitViewportRepresentable: NSViewRepresentable {
    let meshRootNode: SCNNode
    let materialPreset: FilamentMaterialPreset
    let showWireframe: Bool
    let showBuildPlate: Bool
    let autoRotate: Bool
    let cameraPreset: CameraViewPreset
    let cameraResetToken: Int

    final class Coordinator {
        var currentMeshClone: SCNNode?
        var buildPlateNode: SCNNode?
        var cameraNode: SCNNode?
        var lastResetToken: Int = -1
        var lastMaterialId: String?
        var lastAutoRotate: Bool = false
        var lastShowBuildPlate: Bool?
        var lastShowWireframe: Bool?
        var currentSourceNode: SCNNode?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> OrbitPanZoomSCNView {
        let scnView = OrbitPanZoomSCNView()
        scnView.allowsCameraControl = false
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)

        let scene = SCNScene()
        scnView.scene = scene

        // Balanced 3-point studio lighting for crisp 3D depth without overexposure
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

        let backLightNode = SCNNode()
        let backLight = SCNLight()
        backLight.type = .directional
        backLight.intensity = 280
        backLightNode.light = backLight
        backLightNode.eulerAngles = SCNVector3(-Float.pi / 6, Float.pi * 0.9, 0)
        scene.rootNode.addChildNode(backLightNode)

        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 220
        ambient.color = NSColor(calibratedWhite: 0.88, alpha: 1.0)
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 40
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        context.coordinator.cameraNode = cameraNode

        return scnView
    }

    func updateNSView(_ scnView: OrbitPanZoomSCNView, context: Context) {
        guard let scene = scnView.scene else { return }

        var meshReplaced = false
        if context.coordinator.currentSourceNode !== meshRootNode {
            context.coordinator.currentMeshClone?.removeFromParentNode()
            context.coordinator.buildPlateNode?.removeFromParentNode()

            let clone = meshRootNode.clone()
            scene.rootNode.addChildNode(clone)
            context.coordinator.currentMeshClone = clone
            context.coordinator.currentSourceNode = meshRootNode
            context.coordinator.lastMaterialId = nil
            meshReplaced = true

            // Create build plate grid sized to model (standard 180-250mm+ plate feel)
            let (minB, maxB) = clone.boundingBox
            let spanX = Float(maxB.x - minB.x)
            let spanZ = Float(maxB.z - minB.z)
            let plateSize = max(120.0, max(spanX, spanZ) * 1.6)
            let plate = makeBuildPlateNode(size: CGFloat(plateSize))
            scene.rootNode.addChildNode(plate)
            context.coordinator.buildPlateNode = plate

            scnView.configureCamera(for: clone, preset: cameraPreset)
            context.coordinator.lastResetToken = cameraResetToken
        }

        if !meshReplaced && context.coordinator.lastResetToken != cameraResetToken,
           let clone = context.coordinator.currentMeshClone {
            scnView.configureCamera(for: clone, preset: cameraPreset)
            context.coordinator.lastResetToken = cameraResetToken
        }

        if let clone = context.coordinator.currentMeshClone {
            // Only allocate/assign material when preset actually changed or mesh was replaced
            if context.coordinator.lastMaterialId != materialPreset.id {
                applyMaterial(preset: materialPreset, to: clone)
                context.coordinator.lastMaterialId = materialPreset.id
            }

            if meshReplaced || context.coordinator.lastAutoRotate != autoRotate {
                clone.removeAction(forKey: "turntable")
                if autoRotate {
                    let spin = SCNAction.repeatForever(
                        SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 12.0)
                    )
                    clone.runAction(spin, forKey: "turntable")
                }
                context.coordinator.lastAutoRotate = autoRotate
            }
        }

        if meshReplaced || context.coordinator.lastShowBuildPlate != showBuildPlate {
            context.coordinator.buildPlateNode?.isHidden = !showBuildPlate
            context.coordinator.lastShowBuildPlate = showBuildPlate
        }
        if context.coordinator.lastShowWireframe != showWireframe {
            scnView.debugOptions = showWireframe ? [.showWireframe] : []
            context.coordinator.lastShowWireframe = showWireframe
        }
    }

    private func applyMaterial(preset: FilamentMaterialPreset, to node: SCNNode) {
        if let geo = node.geometry {
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = preset.nsColor
            mat.roughness.contents = preset.roughness
            mat.metalness.contents = preset.metalness
            mat.isDoubleSided = true
            geo.materials = [mat]
        }
        for child in node.childNodes {
            applyMaterial(preset: preset, to: child)
        }
    }

    private func makeBuildPlateNode(size: CGFloat) -> SCNNode {
        let container = SCNNode()
        let half = Float(size / 2.0)
        let step: Float = size > 260 ? 20.0 : 10.0

        var lineVerts: [SCNVector3] = []
        var indices: [Int32] = []

        var current = -half
        while current <= half + 0.01 {
            let idx = Int32(lineVerts.count)
            lineVerts.append(SCNVector3(CGFloat(current), -0.05, CGFloat(-half)))
            lineVerts.append(SCNVector3(CGFloat(current), -0.05, CGFloat(half)))
            indices.append(idx)
            indices.append(idx + 1)

            let idx2 = Int32(lineVerts.count)
            lineVerts.append(SCNVector3(CGFloat(-half), -0.05, CGFloat(current)))
            lineVerts.append(SCNVector3(CGFloat(half), -0.05, CGFloat(current)))
            indices.append(idx2)
            indices.append(idx2 + 1)

            current += step
        }

        let src = SCNGeometrySource(vertices: lineVerts)
        let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let elem = SCNGeometryElement(
            data: data,
            primitiveType: .line,
            primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        let gridGeo = SCNGeometry(sources: [src], elements: [elem])
        let gridMat = SCNMaterial()
        gridMat.lightingModel = .constant
        gridMat.diffuse.contents = NSColor(calibratedWhite: 0.35, alpha: 0.55)
        gridGeo.firstMaterial = gridMat

        let gridNode = SCNNode(geometry: gridGeo)
        container.addChildNode(gridNode)

        // Subtle X (red) and Y (green) origin axis bars on the build plate
        let axisLen = CGFloat(min(size * 0.25, 30.0))
        let xAxis = SCNNode(geometry: SCNBox(width: axisLen, height: 0.4, length: 0.4, chamferRadius: 0))
        xAxis.geometry?.firstMaterial?.lightingModel = .constant
        xAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.systemRed.withAlphaComponent(0.75)
        xAxis.position = SCNVector3(axisLen / 2, -0.02, 0)
        container.addChildNode(xAxis)

        let yAxis = SCNNode(geometry: SCNBox(width: 0.4, height: 0.4, length: axisLen, chamferRadius: 0))
        yAxis.geometry?.firstMaterial?.lightingModel = .constant
        yAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.systemGreen.withAlphaComponent(0.75)
        yAxis.position = SCNVector3(0, -0.02, -axisLen / 2)
        container.addChildNode(yAxis)

        return container
    }
}
