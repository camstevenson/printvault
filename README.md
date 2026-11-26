# PrintVault

**PrintVault** is a native macOS SwiftUI application for discovering, organizing, previewing, and slicing your 3D printing library (`.stl` and `.3mf` files).

Built with **Swift 6**, **SwiftUI**, **SwiftData**, **SceneKit**, and **Metal**, PrintVault indexes models across your Mac, renders interactive 3D previews and print estimates, syncs with native macOS Finder tags, and connects directly to your favorite slicers via a customizable hook pipeline.

---

## Features

### 3D Model Discovery
- **macOS Spotlight Discovery** — Automatically scans your home directory for `.stl` and `.3mf` files using `NSMetadataQuery` with built-in path exclusions (`.Trash`, `node_modules`, `.git`, `.build`, `DerivedData`).
- **Watched Folders** — Track specific folders (defaulting to `~/Downloads` and `~/Documents`) and scan them on launch or on demand.
- **Drag-and-Drop & Manual Import** — Drop individual files or entire folders straight into the browser.
- **Library Maintenance** — Prune missing files on demand from the **Library Tools (`···`)** menu, and automatically re-analyze mesh metrics on rescan when a file's size or modification date changes.

### Organization & Categorization
- **Custom Categories** — Create, edit, and color-code categories with custom SF Symbols, or drag and drop models directly onto sidebar categories.
- **AI Visual Auto-Categorization (Local VLM)** — Renders a neutral matte-gray 3D studio view of each model paired with its physical dimensions (`mm`) and geometry metrics, then classifies models locally via **Ollama**, **LM Studio**, or any OpenAI-compatible **MLX-VLM** server (with auto-detection, 1-click Ollama launch & `qwen2.5vl:3b` download, confidence-scored review UI, optional new-category creation, auto-generated tags, and 1-line model summaries)—plus instant keyword-heuristic fallback.
- **Multi-Select Batch Actions** — `⌘`-click in Grid view (or multi-select in Table view) to categorize, update print status, or send multiple models to a slicer at once.
- **Native macOS Finder Tag Sync** — Read existing Finder tags on import and push categories/tags back to macOS Finder metadata.
- **Download Provenance (`kMDItemWhereFroms`)** — Automatically reads macOS download source metadata during ingestion, persists source URL, designer, and license in SwiftData, and adds a 1-click **Open Source Page** button in the Inspector and context menus.
- **Print Tracking** — Track print status (*Unprinted*, *In Queue*, *Printed*, *Needs Fix*), star ratings, favorites, slice history, and per-model print notes persisted in SwiftData.

### Interactive 3D Preview & Print Estimates
- **Native Binary/ASCII STL & 3MF Parsers** — Parses binary and ASCII `.stl` meshes as well as `.3mf` archives (including 3MF unit conversion to millimeters and `<build>` / `<component>` 3×4 affine transforms for multi-part plates).
- **Slicer-Style 3D Controls**:
  - **Left-click drag:** Orbit around the model
  - **Right-click drag** *(or middle-click / `⌥` + left-drag)*: Move / pan the model 1:1 with the cursor
  - **Scroll wheel / two-finger scroll / pinch:** Smooth zoom in and out
- **Viewport Tools** — Switch filament material presets, toggle wireframe mode, toggle the build-plate grid, enable turntable auto-rotation, jump to `Iso` / `Front` / `Top` / `Side` camera presets, or open the **Expanded 3D Preview** (`⇧⌘P`, double-clicking a grid card, or right-clicking a table row).
- **Geometry & Filament Estimates** — Inspect bounding box dimensions (`mm`), triangle count, per-component mesh volume (`cm³`), estimated PLA weight (`g`, using a surface-area shell + selectable infill model), and estimated **1.75 mm filament length (`m`)**.
- **Fast Thumbnail Pipeline** — Background Metal offscreen snapshots with off-main-thread ImageIO downsampling, cancellation-aware scrolling, disk caching, and a toggle between embedded `.3mf` previews and uniform 3D studio renders.

### Slicer Integrations & Automation Hooks
- **Auto-Detected Slicers** — Built-in profiles for **Bambu Studio**, **OrcaSlicer**, **PrusaSlicer** (including `/Applications/Original Prusa Drivers/`), **SuperSlicer**, **UltiMaker Cura**, and **LycheeSlicer**, plus support for custom `.app` bundles and CLI executables.
- **Direct CLI Arguments** — Launch slicers via standard macOS app open or invoke the underlying binary directly with custom CLI templates.
- **Pre-Slice & Post-Slice Shell Hooks** — Run custom shell scripts before or after sending files to your slicer with safely POSIX-escaped tokens:
  `{file}`, `{files}`, `{dir}`, `{name}`, `{ext}`, `{category}`, `{tags}`, `{slicer}`
- **URL Scheme / Apple Shortcuts Hook** — Trigger custom URL schemes or macOS Shortcuts (e.g., `shortcuts://run-shortcut?name=LogPrint&input={name}`) after slicing.
- **Built-In Hook Testing & Activity Log** — Test shell hooks directly from Settings (`⌘,`) and inspect command history plus captured stdout/stderr.
- **Programmatic Swift Hook API** — Extend the send-to-slicer pipeline by registering custom types conforming to `SlicerHook`.

---

## Requirements

- **macOS 15.0** (Sequoia) or later
- **Swift 6.0** / **Xcode 16+**
- *(Optional)* [XcodeGen](https://github.com/yonaskolb/XcodeGen) if modifying `project.yml`

---

## Getting Started

### Run with Swift Package Manager
```bash
git clone https://github.com/<your-username>/PrintVault.git
cd PrintVault
swift run
```

### Open in Xcode
```bash
open PrintVault.xcodeproj
```
Press **`⌘R`** to build and run. If you edit `project.yml`, regenerate the Xcode project with:
```bash
xcodegen generate
```

### Run Unit Tests
```bash
swift test
```

> **Tip:** On first launch with an empty library, PrintVault generates a small set of valid sample `.stl` and `.3mf` models in `~/Documents/PrintVault Sample Models` (calibration cube, Gridfinity bin, shelf bracket, spur gear, and hexagonal desk organizer) so you can immediately explore 3D previews, categorization, and slicer hooks.

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `⌘↩` | Send selected model(s) to the default slicer |
| `⌘R` | Scan watched folders and Spotlight |
| `⌘I` | Import 3D files or folders |
| `⇧⌘P` | Expand interactive 3D preview |
| `⌘,` | Open Slicer Integrations & Hooks settings |

---

## Extending Slicer Hooks in Swift

In addition to shell and URL-scheme hooks in Settings, you can register custom Swift hooks via `SlicerService.shared.registerHook(_:)`:

```swift
@MainActor
struct PrintLogHook: SlicerHook {
    let id = "com.example.print-log"
    let name = "Print Log"
    let stage: SlicerHookStage = .postSlice

    func execute(context: SlicerHookContext) async -> SlicerHookResult {
        let names = context.items.map(\.fileName).joined(separator: ", ")
        return SlicerHookResult(
            hookName: name,
            succeeded: context.slicerLaunched,
            output: "Sent \(names) to \(context.profile.name)"
        )
    }
}
```

---

## Project Structure

```text
PrintVault/
├── Package.swift                                 # SwiftPM manifest (macOS 15+, Swift 6)
├── project.yml                                   # XcodeGen project specification
├── PrintVault.xcodeproj/                         # Generated Xcode project
├── Sources/PrintVault/
│   ├── App/
│   │   ├── PrintVaultApp.swift                   # App entry point, menus, Settings scene
│   │   ├── Info.plist                            # Document type declarations (.stl, .3mf)
│   │   └── PrintVault.entitlements
│   ├── Models/
│   │   ├── DownloadProvenance.swift              # Download provenance value type
│   │   └── PrintModels.swift                     # SwiftData models & filament estimators
│   ├── Services/
│   │   ├── DownloadProvenanceService.swift       # macOS kMDItemWhereFroms provenance parser
│   │   ├── FileScannerService.swift              # Watched folders, Spotlight, auto-categorizer
│   │   ├── FinderTagService.swift                # macOS Finder tag read/write sync
│   │   ├── MeshLoaderService.swift               # Native binary/ASCII STL & 3MF parsers
│   │   ├── SampleMeshGenerator.swift             # Procedural sample .stl & .3mf generator
│   │   ├── SingleInstanceGuard.swift             # Single-instance POSIX lock & window focus
│   │   ├── SlicerService.swift                   # Slicer detection & extensible hook pipeline
│   │   ├── ThumbnailService.swift                # Off-main-thread Metal renderer & disk cache
│   │   └── VLMCategorizerService.swift           # Local VLM (Ollama/LM Studio/MLX-VLM) categorizer
│   └── Views/
│       ├── AICategorizeSheetView.swift           # Batch AI categorization & confidence review UI
│       ├── ContentView.swift                     # Split-view sidebar, grid/table browser, batch bar
│       ├── ModelGridCardView.swift               # Lightweight model card with drag & context menu
│       ├── InspectorPaneView.swift               # Metrics, categorization, tags, slicer actions
│       ├── InspectorProvenanceFieldsView.swift   # Editable source URL, designer & license fields
│       ├── InspectorProvenanceSectionView.swift  # Download provenance header, actions & refresh
│       ├── Preview3DView.swift                   # SceneKit orbit/pan/zoom viewport & expanded sheet
│       └── SlicerSettingsView.swift              # Slicer profiles, shell/URL hooks & activity log
└── Tests/PrintVaultTests/
    └── PrintVaultTests.swift                     # Swift Testing suite (STL, 3MF, scanner, hooks)
```

---

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, coding guidelines, and the pull request process.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
