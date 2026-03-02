# CLAUDE.md - Project Context for AI Assistants

## Project Overview

This is a fork of **TRIO** (an open-source iOS artificial pancreas app) with a custom **Barcode Scanner** feature added for food tracking. The project tracks the upstream TRIO dev branch and merges custom barcode scanning functionality on top.

## Repository Structure

```
Trio/
├── Config.xcconfig              # App version (APP_DEV_VERSION)
├── Trio.xcodeproj/              # Xcode project
├── Trio/
│   ├── Sources/
│   │   ├── Views/
│   │   │   ├── BarcodeScannerView.swift    # Camera barcode scanner UI
│   │   │   ├── ScannedItemsView.swift      # Scanned food items list
│   │   │   └── EditServingSizeView.swift   # Serving size editor
│   │   ├── Services/
│   │   │   └── FoodDatabaseService.swift   # OpenFoodFacts API integration
│   │   └── Modules/
│   │       └── Treatments/
│   │           └── View/
│   │               └── TreatmentsRootView.swift  # Where scanner is accessed
│   └── Resources/
├── patches/
│   └── local-barcode-patches/   # Git patches for barcode scanner feature
└── apply_patches.sh             # Script to apply patches to fresh upstream
```

## Key Branches

- **`upstream/dev`** - TRIO's official dev branch (read-only, fetch only)
- **`build-with-barcode`** - Main working branch with barcode scanner merged into latest upstream dev

## Barcode Scanner Feature

### Files Added
1. **`BarcodeScannerView.swift`** - Camera-based barcode scanner with:
   - Corner bracket visual guides
   - Animated scan line (constraint-based, starts in `viewDidAppear`)
   - Haptic feedback on successful scan
   - Modern SF Symbol close button
   - Accessibility labels (all UIKit strings via `NSLocalizedString`)

2. **`ScannedItemsView.swift`** - Manages scanned food items:
   - List of scanned items with nutritional info
   - Duplicate detection with alerts
   - Swipe to delete/edit
   - Haptic feedback (success/warning/error)
   - Serving size editing
   - Uses `NavigationStack` (iOS 16+)
   - `numberFormatter` is `static let` per struct (not recreated per render)

3. **`FoodDatabaseService.swift`** - API integration:
   - OpenFoodFacts API for nutritional data
   - In-memory caching (NSCache)
   - Network reachability monitoring
   - Request timeout handling
   - Comprehensive error handling and logging
   - Falls back to non-`_100g` nutriment fields when `_100g` variants are absent

4. **`EditServingSizeView.swift`** - Serving size adjustment (defined in `ScannedItemsView.swift`):
   - Portion stepper (0.5-50 portions)
   - Real-time nutritional value updates
   - Input validation with warnings
   - Uses `NavigationStack` (iOS 16+)

### Barcode Types Supported
- EAN-8, EAN-13, UPC-E
- QR Code, PDF417, Aztec, DataMatrix
- Code 128, Code 39, Code 93
- Interleaved 2 of 5, ITF-14

## Common Workflows

### Updating to Latest Upstream Dev

When TRIO releases a new dev version:

```bash
# 1. Fetch latest upstream
git fetch upstream dev

# 2. Check versions
echo "Your version:" && grep 'APP_DEV_VERSION' Config.xcconfig
echo "Latest:" && git show upstream/dev:Config.xcconfig | grep 'APP_DEV_VERSION'

# 3. Merge if different
git merge upstream/dev -m "Merge latest upstream/dev with barcode scanner"

# 4. Verify compilation
swiftc -parse Trio/Sources/Services/FoodDatabaseService.swift \
       Trio/Sources/Views/BarcodeScannerView.swift \
       Trio/Sources/Views/ScannedItemsView.swift

# 5. Build in Xcode
open Trio.xcodeproj
```

### Applying Patches to Fresh Upstream Clone

If starting from a fresh TRIO clone:

```bash
# Copy patches directory and script
cp -r patches /path/to/fresh/Trio/
cp apply_patches.sh /path/to/fresh/Trio/

# Run patch script
cd /path/to/fresh/Trio
./apply_patches.sh .
```

### Resolving Merge Conflicts

If merge conflicts occur:
1. Stash local changes: `git stash`
2. Merge upstream: `git merge upstream/dev`
3. For submodule conflicts: check out the upstream commit with `cd <submodule> && git checkout <upstream-commit-hash>`, then `git add <submodule>` from the repo root
4. For file conflicts: Usually take upstream with `git checkout --theirs <file>`
5. Restore stash: `git stash pop`

> **Note:** `git checkout --theirs <submodule>` does not work for submodules — you must manually check out the correct commit inside the submodule directory.

## Code Conventions

### Swift Style
- SwiftUI for views; use `NavigationStack` (not deprecated `NavigationView`)
- UIKit for camera (AVFoundation requires UIViewController)
- Async/await for network calls
- Combine for reactive updates
- `static let` for shared formatters (e.g. `NumberFormatter`) — never computed `var`

### Localization
- SwiftUI `Text("literal")` is automatically localized via `LocalizedStringKey`
- UIKit strings must use `NSLocalizedString("key", comment: "...")`
- All custom strings must have entries in `Trio/Sources/Localizations/Main/Localizable.xcstrings`
- New xcstrings entries use `"extractionState": "manual"` and `"state": "new"` for non-English languages

### Error Handling
- Custom error enums with `LocalizedError` conformance
- User-friendly error messages in alerts
- Console logging for debugging

### Haptic Feedback
- `UINotificationFeedbackGenerator` for success/warning/error
- `UIImpactFeedbackGenerator` for button taps

### Accessibility
- All interactive elements have `accessibilityLabel`
- Minimum 44x44pt touch targets

## Build Requirements

- **Xcode:** Latest stable version
- **iOS Target:** Check Trio.xcodeproj for minimum iOS version
- **Signing:** Requires Apple Developer account and provisioning profile

## Important Notes

1. **Never push to upstream** - It's read-only (TRIO's official repo)
2. **Keep patches updated** - When making changes to barcode scanner, consider updating patch files
3. **Test after merges** - Always verify compilation after merging upstream
4. **Submodules** - TRIO uses many submodules (DanaKit, LoopKit, etc.) - these may cause merge conflicts

## Useful Commands

```bash
# Check current version
grep 'APP_DEV_VERSION' Config.xcconfig

# Verify barcode scanner compiles
swiftc -parse Trio/Sources/Services/FoodDatabaseService.swift \
       Trio/Sources/Views/BarcodeScannerView.swift \
       Trio/Sources/Views/ScannedItemsView.swift

# View recent upstream changes
git log upstream/dev --oneline -10

# Check what's different from upstream
git diff upstream/dev --stat | head -20
```

## API Reference

### OpenFoodFacts API
- Base URL: `https://world.openfoodfacts.org/api/v0/product/{barcode}.json`
- User-Agent: `TrioApp/1.0`
- Timeout: 10 seconds
- Returns: Product name, brand, nutritional info per 100g
- Nutriment fields: prefer `*_100g` variants; fall back to plain variants (e.g. `carbohydrates_100g` → `carbohydrates`)

## Future Enhancements (Recommended)

1. **Flashlight toggle** - For low-light scanning
2. **Manual barcode entry** - Fallback when camera fails
3. **Continuous scanning** - Scan multiple items without closing
4. **Favorites/History** - Quick access to frequently scanned items
5. **Product images** - Display product photo from database
