# CLAUDE.md - Project Context for AI Assistants

## Project Overview

This is a fork of **TRIO** (an open-source iOS artificial pancreas app) with a custom **Barcode Scanner** feature and **Eversense CGM** support added. The project tracks the upstream TRIO dev branch and merges custom functionality on top.

## Key Branches

- **`upstream/main`** - TRIO's official stable release branch (read-only, fetch only)
- **`upstream/dev`** - TRIO's official dev branch (read-only, fetch only)
- **`build-with-barcode-dev`** - **Current working branch.** Tracks `upstream/dev` with the barcode scanner,
  Garmin companion, nightstand view and treatments layout on top. To update: see the `upstream-merge` skill.
- **`build-with-barcode-main`** - Fallback branch tracking `upstream/main` (stable releases).

EversenseKit is an upstream submodule (loopandlearn/EversenseKit); no manual Xcode setup is needed.

## Code Conventions

### Swift Style
- SwiftUI for views; use `NavigationStack` (not deprecated `NavigationView`)
- UIKit for camera (AVFoundation requires UIViewController)
- Async/await for network calls
- Combine for reactive updates
- `static let` for shared formatters (e.g. `NumberFormatter`) — never computed `var`
- Trio defines its own `NotificationCenter` protocol: write Apple's as `Foundation.NotificationCenter.default`
- `Trio/Sources/Modules` is not a synced Xcode group: new files there need manual `project.pbxproj` entries
  (PBXFileReference, PBXBuildFile, group child, Sources phase)

### Localization
- SwiftUI `Text("literal")` is automatically localized via `LocalizedStringKey`
- UIKit strings must use `NSLocalizedString("key", comment: "...")`
- All custom strings must have entries in `Trio/Sources/Localizations/Main/Localizable.xcstrings`
- New xcstrings entries use `"extractionState": "manual"` and `"state": "new"` for non-English languages

### Error Handling
- Custom error enums with `LocalizedError` conformance
- User-friendly error messages in alerts

### Haptic Feedback
- `UINotificationFeedbackGenerator` for success/warning/error
- `UIImpactFeedbackGenerator` for button taps

### Accessibility
- All interactive elements have `accessibilityLabel`
- Minimum 44x44pt touch targets

## Important Notes

1. **Never push to upstream** - It's read-only (TRIO's official repo)
2. **Keep patches updated** - When changing the barcode scanner, consider updating `patches/local-barcode-patches/` (applied with `./apply_patches.sh <trio-dir>`)
3. **Test after merges** - Always verify compilation after merging upstream
4. **Submodules** - TRIO uses many submodules (DanaKit, LoopKit, EversenseKit, etc.) - these may cause merge conflicts

## Future Enhancements (Recommended)

1. **Flashlight toggle** - For low-light scanning
2. **Manual barcode entry** - Fallback when camera fails
3. **Continuous scanning** - Scan multiple items without closing
4. **Favorites/History** - Quick access to frequently scanned items
5. **Product images** - Display product photo from database
