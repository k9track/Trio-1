---
name: upstream-merge
description: Merge a new TRIO upstream release (dev or main) into this fork, resolve submodule and xcstrings conflicts, verify the build, or re-apply the barcode patches to a fresh upstream clone.
---

# Merging upstream TRIO into this fork

Working branch `build-with-barcode-dev` tracks `upstream/dev`; `build-with-barcode-main` tracks `upstream/main`
(substitute `main` for `dev` below on that branch).

## 1. Check versions

```bash
git fetch upstream dev
grep 'APP_DEV_VERSION' Config.xcconfig
git show upstream/dev:Config.xcconfig | grep 'APP_DEV_VERSION'
```

## 2. Merge

1. Stash Xcode churn first (Package.resolved, xcschemes, InfoPlist.xcstrings, submodule pointers): `git stash`
2. `git merge upstream/dev -m "Merge Trio dev (<version>) with barcode scanner and Garmin companion"`
3. Bring submodules in line: `git submodule sync && git submodule update --init --recursive`

## 3. Conflicts

- **`Localizable.xcstrings`**: take upstream's file, then insert only our custom entries back in textually.
  Never re-serialize the whole file (it rewrites thousands of lines). The result should have zero deletions vs upstream.
- **Submodules**: `git checkout --theirs <submodule>` does not work. `cd <submodule> && git checkout <upstream-commit>`,
  then `git add <submodule>` from the repo root.
- **Our Swift files** (GarminManager, Garmin companion, barcode views): keep our logic, adopt upstream's renames
  (e.g. log categories, wording). Plain upstream files: usually `git checkout --theirs <file>`.
- `git stash pop` afterwards; drop the stash if it only held Xcode churn.

## 4. Verify the build

The user builds and installs from Xcode themselves. For a command-line compile check:

```bash
xcodebuild -workspace Trio.xcworkspace -scheme Trio -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Caches/TrioVerifyBuild \
  -enableThreadSanitizer NO ENABLE_THREAD_SANITIZER=NO ENABLE_DEBUG_DYLIB=NO CODE_SIGNING_ALLOWED=NO build
```

- Must use `-workspace`, not `-project` (module dependency errors otherwise).
- The scheme enables TSan; without both TSan flags and `ENABLE_DEBUG_DYLIB=NO` the watch targets fail.
- Quick syntax check of the barcode files: `swiftc -parse Trio/Sources/Services/FoodDatabaseService.swift Trio/Sources/Views/BarcodeScannerView.swift Trio/Sources/Views/ScannedItemsView.swift`

## Fresh upstream clone

```bash
cp -r patches apply_patches.sh /path/to/fresh/Trio/
cd /path/to/fresh/Trio && ./apply_patches.sh .
```

Never push to `upstream`. Ask before pushing to `origin`.
