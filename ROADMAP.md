# PrintVault Feature Roadmap

Planned features and enhancements for **PrintVault**. Check off items as they are completed (`- [x]`).

---

## Phase 1: High-Impact Wins

- [ ] **Deep `.3mf` Slicer Metadata Parsing**
  - [ ] Parse `Metadata/slice_info.config` and `Metadata/project_settings.config` (print time, filament weight, AMS colors, nozzle size, layer height, infill %, support usage, plate count)
  - [ ] Parse `.model` XML `<metadata>` tags (title, designer, license, creation date, description, source URL)
  - [ ] Render `.3mf` `<basematerials>` / painted multi-color surfaces in the 3D preview
- [x] **Download Provenance (`kMDItemWhereFroms`)**
  - [x] Read `com.apple.metadata:kMDItemWhereFroms` during file ingestion
  - [x] Persist source URL, designer, and license fields in SwiftData (`PrintFileItem`)
  - [x] Add a 1-click "Open Source Page" button in the Inspector
- [ ] **Printer Profiles & Build-Volume Fit Checks**
  - [ ] Add user-defined printer profiles with bed X/Y/Z dimensions (plus built-in presets for Bambu, Prusa, Elegoo, etc.)
  - [ ] Scale the 3D viewport build-plate grid to the active printer profile
  - [ ] Badge models that exceed build volume and add a "Fits on [Printer]" filter
- [ ] **Multi-Material & Cost Estimation**
  - [ ] Add filament material presets (PLA, PETG, ABS, ASA, TPU, Resin) with accurate densities
  - [ ] Add configurable `$/kg` spool pricing to show estimated print cost alongside grams and meters
- [ ] **Expanded File Format Support**
  - [ ] Add `.obj` support (via ModelIO)
  - [ ] Add `.step` / `.stp` support
  - [ ] Add `.gcode` / `.bgcode` support (header stats + embedded thumbnail extraction)
  - [ ] Add `.zip` archive auto-unpack and drag-and-drop import

---

## Phase 2: 3D Printability & Inspection Tools

- [ ] **Mesh Health & Printability Diagnostics**
  - [ ] Detect non-manifold edges, open holes, and inverted normals during mesh analysis
  - [ ] Detect likely inch-vs-mm scale issues and models floating off `Z = 0`
  - [ ] Surface mesh health warning badges in the Inspector
- [ ] **Advanced 3D Viewport Tools**
  - [ ] Add an overhang heatmap shader toggle (highlight downward faces steeper than 45°)
  - [ ] Add a Z-height cross-section slice slider to inspect internal geometry
  - [ ] Add a point-to-point caliper measurement tool in Expanded 3D Preview
- [ ] **Companion Project Files Viewer**
  - [ ] Display companion `README.md`, `LICENSE.txt`, assembly PDFs, and creator photos for grouped projects

---

## Phase 3: Library Organization & Maintenance

- [ ] **Live Background Folder Watching**
  - [ ] Monitor watched folders in real time with `FSEventStream`
  - [ ] Add an optional "Vault Inbox" rule to auto-move and organize new downloads
- [ ] **Duplicate & Near-Duplicate Finder**
  - [ ] Detect exact duplicates via SHA-256 hash
  - [ ] Detect geometry near-duplicates (normalized bounding-box ratio + triangle count + volume)
  - [ ] Add a side-by-side comparison and safe Move-to-Trash cleanup UI
- [ ] **Manual Multi-Part Group Overrides**
  - [ ] Persist manual group merge, split, rename, and pinned hero-part overrides in SwiftData
- [ ] **Smart Collections & Multi-Facet Filtering**
  - [ ] Support saved Smart Collections combining category, status, tags, rating, weight, and printer fit
  - [ ] Add range filters for dimensions, weight, triangle count, and star rating
- [ ] **Library Backup, Export & Sync**
  - [ ] Export/import library metadata (categories, tags, notes, ratings, print status) as JSON/CSV
  - [ ] Evaluate CloudKit metadata sync across Macs

---

## Phase 4: Print Tracking & Filament Ecosystem

- [ ] **Per-Model Print Journal**
  - [ ] Add `@Model PrintRun` history per model (date, printer, filament, scale %, print time, outcome, failure reason)
  - [ ] Support attaching photos of finished physical prints to print runs
- [ ] **Filament Spool Inventory**
  - [ ] Track owned spools (brand, material, color hex, remaining grams)
  - [ ] Preview models in actual on-hand spool colors and deduct usage on completed prints
  - [ ] Add optional Spoolman API sync
- [ ] **Direct Printer / Farm Integration**
  - [ ] Connect to OctoPrint, Moonraker (Klipper), PrusaLink, or Bambu Lab LAN mode
  - [ ] View live printer status and send pre-sliced `.gcode` / `.3mf` files directly

---

## Phase 5: Native macOS Extensions

- [ ] **Finder Quick Look Extensions**
  - [ ] Add `QLThumbnailProvider` for `.stl` and `.3mf` Finder thumbnails
  - [ ] Add `QLPreviewProvider` for interactive Spacebar 3D previews in Finder
- [ ] **App Intents & Spotlight Integration**
  - [ ] Index PrintVault metadata (categories, AI summaries, tags) into `CoreSpotlight`
  - [ ] Add native Apple Shortcuts App Intents for searching and slicing models
- [ ] **Menu Bar Quick-Drop**
  - [ ] Add an optional menu bar icon drop zone for instant import and categorization
