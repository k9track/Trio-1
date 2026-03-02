#!/bin/bash

#################################
# Automated Patch Application Script
# Applies barcode scanner patches to TRIO codebase
#
# Patches (applied in order):
#   0001 - BarCode Scanner (initial feature)
#   0002 - Update .gitignore
#   0003 - Update MinimedKit
#   0004 - Scan and portions update
#   0005 - Updates
#   0006 - Scanner updates
#   0007 - Update TreatmentsRootView.swift
#   0008 - Update BarcodeScannerView.swift
#   0009 - Update BarcodeScannerView.swift
#   0010 - Scanner: permission alert / authorization flow
#   0011 - Code quality fixes (scan line animation, nutriment fallbacks,
#           NavigationStack, static numberFormatter, localization, CLAUDE.md)
#
# combined.diff - Full diff of all barcode scanner files vs upstream/dev
#################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PATCHES_DIR="$SCRIPT_DIR/patches/local-barcode-patches"
TARGET_DIR="${1:-.}"

# Validate patch directory exists
if [ ! -d "$PATCHES_DIR" ]; then
    echo -e "${RED}Error: Patches directory not found at $PATCHES_DIR${NC}"
    exit 1
fi

# Validate target directory exists
if [ ! -d "$TARGET_DIR" ]; then
    echo -e "${RED}Error: Target directory not found at $TARGET_DIR${NC}"
    exit 1
fi

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}Patch Application Script${NC}"
echo -e "${BLUE}================================${NC}"
echo -e "Patches directory: ${GREEN}$PATCHES_DIR${NC}"
echo -e "Target directory:  ${GREEN}$TARGET_DIR${NC}"
echo ""

# Change to target directory
cd "$TARGET_DIR"

# Collect all patch files in order
PATCHES=()
while IFS= read -r -d '' file; do
    PATCHES+=("$file")
done < <(find "$PATCHES_DIR" -maxdepth 1 -name "*.patch" -not -name "combined.diff" -print0 | sort -z)

if [ ${#PATCHES[@]} -eq 0 ]; then
    echo -e "${RED}Error: No patch files found in $PATCHES_DIR${NC}"
    exit 1
fi

echo -e "${YELLOW}Found ${#PATCHES[@]} patch files to apply:${NC}"
for patch in "${PATCHES[@]}"; do
    echo "  - $(basename "$patch")"
done
echo ""

# Function to apply a single patch
apply_patch() {
    local patch_file="$1"
    local patch_name=$(basename "$patch_file")

    # Check if this is a submodule patch
    if grep -q "^Subproject commit" "$patch_file" 2>/dev/null; then
        # This is a submodule update - use git apply for better submodule support
        if git apply --dry-run < "$patch_file" > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $patch_name (dry run OK - submodule)"
            return 0
        else
            echo -e "  ${RED}✗${NC} $patch_name (dry run FAILED - submodule)"
            return 1
        fi
    else
        # Regular file patch - use standard patch command
        if patch -p1 --dry-run < "$patch_file" > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $patch_name (dry run OK)"
            return 0
        else
            echo -e "  ${RED}✗${NC} $patch_name (dry run FAILED)"
            return 1
        fi
    fi
}

# Function to actually apply a patch
apply_patch_actual() {
    local patch_file="$1"
    local patch_name=$(basename "$patch_file")

    # Check if this is a submodule patch
    if grep -q "^Subproject commit" "$patch_file" 2>/dev/null; then
        # Use git apply for submodules
        if git apply < "$patch_file" > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} Applied: $patch_name"
            return 0
        else
            echo -e "  ${RED}✗${NC} Failed to apply: $patch_name"
            return 1
        fi
    else
        # Use standard patch command
        if patch -p1 < "$patch_file" > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} Applied: $patch_name"
            return 0
        else
            echo -e "  ${RED}✗${NC} Failed to apply: $patch_name"
            return 1
        fi
    fi
}

# Dry run first
echo -e "${YELLOW}Running dry run to check for conflicts...${NC}"
DRY_RUN_FAILED=0
for patch in "${PATCHES[@]}"; do
    if ! apply_patch "$patch"; then
        DRY_RUN_FAILED=1
    fi
done
echo ""

if [ $DRY_RUN_FAILED -eq 1 ]; then
    echo -e "${RED}Dry run failed! Some patches may not apply cleanly.${NC}"
    echo -e "${YELLOW}Continue anyway? (y/n)${NC}"
    read -r RESPONSE
    if [[ ! "$RESPONSE" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Aborting patch application.${NC}"
        exit 1
    fi
fi

# Apply patches
echo -e "${YELLOW}Applying patches...${NC}"
FAILED_PATCHES=()
APPLIED_PATCHES=()

for patch in "${PATCHES[@]}"; do
    if apply_patch_actual "$patch"; then
        APPLIED_PATCHES+=("$(basename "$patch")")
    else
        FAILED_PATCHES+=("$(basename "$patch")")
    fi
done

echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}Patch Application Summary${NC}"
echo -e "${BLUE}================================${NC}"
echo -e "Applied: ${GREEN}${#APPLIED_PATCHES[@]}${NC}"
echo -e "Failed:  ${RED}${#FAILED_PATCHES[@]}${NC}"

if [ ${#FAILED_PATCHES[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed patches:${NC}"
    for patch in "${FAILED_PATCHES[@]}"; do
        echo "  - $patch"
    done
    echo ""
    echo -e "${YELLOW}Partially applied patches remain in the working directory.${NC}"
    echo -e "${YELLOW}Please review conflicts manually and resolve them.${NC}"
    exit 1
else
    echo ""
    echo -e "${GREEN}All patches applied successfully!${NC}"
    exit 0
fi
