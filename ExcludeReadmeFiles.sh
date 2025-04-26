#!/bin/bash

# Script to remove duplicate README.md files from the app bundle
# This fixes the "Multiple commands produce '/path/to/backdoor.app/README.md'" error

# Find all README.md files in the app bundle and remove duplicates
# Keep only the root README.md file

# Get the path to the app bundle
APP_BUNDLE_PATH="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"

# Remove any README.md files from subdirectories in the app bundle
find "$APP_BUNDLE_PATH" -path "$APP_BUNDLE_PATH/README.md" -prune -o -name "README.md" -exec rm -f {} \;

echo "Removed duplicate README.md files from the app bundle"
exit 0
