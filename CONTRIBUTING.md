# Contributing to PrintVault

Thank you for considering contributing to **PrintVault**! Contributions of all kinds—bug reports, feature suggestions, documentation improvements, slicer profiles, and code changes—are welcome.

---

## Development Setup

### Requirements
- **macOS 15.0** (Sequoia) or later
- **Swift 6.0** / **Xcode 16+**
- *(Optional)* [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) when adding, removing, or moving Swift source files
- *(Optional)* [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai) if working on local VLM auto-categorization

### Building & Running
Clone your fork and run with Swift Package Manager:

```bash
git clone https://github.com/<your-username>/PrintVault.git
cd PrintVault
swift run
```

For faster performance when testing large multi-million-triangle `.3mf` or `.stl` files, use a Release build:

```bash
swift run -c release
```

Or open the Xcode project directly:

```bash
open PrintVault.xcodeproj
```

> **Note:** PrintVault enforces a single running instance via `SingleInstanceGuard` (`~/Library/Application Support/PrintVault/instance.lock`). Quit any running copy of PrintVault before launching a new build.

### Keeping `PrintVault.xcodeproj` in Sync
If you add, rename, or remove source or test files, regenerate the Xcode project from `project.yml`:

```bash
xcodegen generate
```

---

## Running Tests

PrintVault uses **Swift Testing** (`Tests/PrintVaultTests/PrintVaultTests.swift`). Run the full test suite before opening a pull request:

```bash
swift test
```

All tests must pass with **zero compiler warnings** under Swift 6 strict concurrency.

---

## Architecture & Coding Guidelines

- **Swift 6 Concurrency:** Maintain strict concurrency safety—annotate UI/service state with `@MainActor` where appropriate, keep background mesh parsing and rendering off the main actor, and avoid `@unchecked Sendable` unless synchronized explicitly.
- **No Unnecessary External Dependencies:** PrintVault intentionally relies on native Apple frameworks (`SwiftUI`, `SwiftData`, `SceneKit`, `Metal`, `AppKit`, `CryptoKit`, `ImageIO`, `QuickLookThumbnailing`) so `swift build`, `swift test`, and Xcode stay fast and self-contained. Please open an issue before introducing any new SwiftPM dependency.
- **File Scope:** PrintVault focuses strictly on **`.stl`** and **`.3mf`** 3D printing files.
- **Performance:** Keep scrolling and thumbnail rendering responsive on large libraries (500–2,000+ models)—avoid main-thread file I/O, per-card `.shadow` / `.ultraThinMaterial` passes inside scrolling grids, and uncancelled offscreen 3D renders.
- **Shell Safety:** When touching `SlicerService` or shell hooks, always escape file paths and metadata tokens with `SlicerService.shellEscape(_:)`.

---

## Common Ways to Contribute

- **Slicer Profiles:** Add or update built-in macOS bundle identifiers and alternate application paths in `Sources/PrintVault/Services/SlicerService.swift`.
- **3MF & STL Compatibility:** If you encounter a `.stl` or `.3mf` file that fails to parse or renders with wrong scale/transforms, please open an issue with details (slicer used to export it, unit type, triangle count, and a minimal reproducible file if possible).
- **Slicer Hooks & Automations:** Extend `SlicerHook` or improve CLI/URL-scheme hook workflows.
- **Local VLM Categorization:** Improve prompt quality, add local vision model detection patterns in `VLMCategorizerService.swift`, or enhance the review UI in `AICategorizeSheetView.swift`.

---

## Pull Request Process

1. Create a focused branch from `main` (for example, `git checkout -b feat/my-feature` or `fix/my-bugfix`).
2. Keep commits clean and scoped to the change.
3. Add or update unit tests in `Tests/PrintVaultTests/PrintVaultTests.swift` covering your changes.
4. Run `xcodegen generate` if files were added, moved, or deleted.
5. Verify `swift build` and `swift test` succeed with zero warnings.
6. Update `README.md` if your change alters user-facing behavior, shortcuts, or project structure.
7. Open a pull request describing **what** changed, **why**, and **how** you tested it (screenshots or short recordings are especially helpful for UI or 3D viewport changes).

---

## Reporting Issues

When filing a bug report, please include:
- macOS version and Apple Silicon / Intel architecture
- How you built/ran PrintVault (`swift run`, Release vs Debug, or Xcode)
- Steps to reproduce and expected vs. actual behavior
- Relevant details for file-specific issues (file format `.stl` / `.3mf`, file size, exporting slicer, and whether it's a multi-part plate)

---

## License

By contributing to PrintVault, you agree that your contributions will be licensed under the [MIT License](LICENSE).
