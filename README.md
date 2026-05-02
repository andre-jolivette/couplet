# Conjunct — Xcode Project Setup

## What's in this zip

All Swift source files for the Conjunct app shell. The project is
stub-driven (hardcoded sample data) — engine integration is the next
pass after the UI is validated.

```
Conjunct/
├── ConjunctApp.swift           App entry point + window config
├── ContentView.swift           Root NavigationSplitView
├── Views/
│   ├── Sidebar/
│   │   └── SidebarView.swift   Folders + Collections sections
│   └── PairsGrid/
│       ├── FilterBarView.swift Modality pills, sort, search
│       ├── PairTileView.swift  Individual pair tile + hover controls
│       └── PairsGridView.swift LazyVGrid canvas
├── ViewModels/
│   ├── LibraryViewModel.swift  Sidebar state + selection
│   └── PairsGridViewModel.swift Grid state, filtering, sorting, decisions
└── Models/
    ├── AppModels.swift         All display-layer structs and enums
    └── SampleData.swift        Stub folders, collections, and 12 sample pairs
```

---

## Step 1 — Create the Xcode project

1. Open Xcode → File → New → Project
2. Choose **macOS** → **App**
3. Fill in:
   - Product Name: `Conjunct`
   - Organization Identifier: your reverse-domain (e.g. `com.yourname`)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Uncheck "Include Tests" (tests live in ConjunctEngine for now)
4. Save the project inside your `_conjunct` folder, **one level above** `ConjunctEngine`:
   ```
   _conjunct/
   ├── ConjunctEngine/       ← the Swift Package
   ├── Conjunct/             ← the new Xcode project (save here)
   └── clip-vit-base-patch32.mlpackage
   ```

---

## Step 2 — Delete the default files

Xcode generates a `ContentView.swift` and an `Assets.xcassets`.
Delete the default `ContentView.swift` (move to trash — you'll add the
provided one in Step 4).
Keep `Assets.xcassets`.

---

## Step 3 — Set deployment target

1. Click the **Conjunct** project in the Project Navigator
2. Select the **Conjunct** target
3. Under **General → Minimum Deployments**, set macOS to **13.0**

---

## Step 4 — Add the source files

Drag the entire `Conjunct/` folder from this zip into the Project
Navigator, **on top of the yellow Conjunct group** (not the blue
project root). In the dialog that appears:

- ✅ Copy items if needed
- ✅ Create groups
- Target membership: ✅ Conjunct

Xcode will create groups matching the folder structure automatically.

---

## Step 5 — Set appearance to Dark

1. Open `Assets.xcassets`
2. Click **+** → **New Color Set** (or skip — the app forces dark mode via `preferredColorScheme(.dark)` in `ContentView` and `ConjunctApp`, so no asset change is required)

---

## Step 6 — Build and run

Press **⌘R**. The app should launch showing:

- Dark window, ~1200×780
- Left sidebar with 3 stub folders and 3 stub collections
- Main canvas with 12 pair tiles in a 2-column grid
- Each tile shows two coloured rectangles (stub thumbnails), a modality badge, and a confidence score
- Hover over a tile to see Like / Reject / Delete buttons appear
- Clicking a modality pill filters the grid
- The sort dropdown and search field are functional

---

## What's stubbed (to be replaced in the engine-connected pass)

| Component | Stub | Production replacement |
|-----------|------|----------------------|
| Thumbnails | Coloured rectangles | Real NSImage from thumbnailPath |
| Pair data | `SampleData.pairs` (12 hardcoded pairs) | QueryEngine async stream |
| Folder list | `SampleData.folders` | DatabaseManager + folder scan |
| Collections | `SampleData.collections` | DatabaseManager collections table |
| Decisions | In-memory on `DisplayPair` | userDecisions table via DatabaseManager |
| Lightbox | `lightboxPairID` state (no-op) | Full LightboxView (next pass) |
| Find Pairs For… | Toolbar button (no-op) | Dedicated anchor query sheet |

---

## Adding ConjunctEngine as a local package (next pass)

When you're ready to connect the real engine:

1. In Xcode: **File → Add Package Dependencies**
2. Click **Add Local…** and navigate to `_conjunct/ConjunctEngine`
3. Add the `ConjunctEngine` library product to the **Conjunct** target
4. Replace `SampleData` references in the ViewModels with real engine calls
