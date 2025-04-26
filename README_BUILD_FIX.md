# README.md Build Conflict Fix

## Issue

The build was failing with the error:

```
Multiple commands produce '/Users/runner/.../backdoor.app/README.md'
```

This error occurs because multiple README.md files from different locations in the project are being copied to the same destination in the app bundle during the build process.

## Root Cause

The project contains multiple README.md files:
- ./README.md (root)
- ./iOS/Views/Home/README.md
- ./iOS/Debugger/README.md

When the app is built, all of these files are being included in the app bundle with the same filename and path, causing a conflict.

## Solution

We've implemented a post-build script (`ExcludeReadmeFiles.sh`) that runs after the main build process and removes any duplicate README.md files from the app bundle, keeping only the root README.md file.

The script is added as a "Run Script" build phase that executes after the "Copy Bundle Resources" phase.

## Alternative Solutions

Other potential solutions that were considered:

1. **Rename the README.md files**: Change the names of the README.md files in subdirectories to more specific names (e.g., HOME_README.md, DEBUGGER_README.md).

2. **Exclude files from target membership**: Remove the README.md files from being included in the target's "Copy Bundle Resources" build phase.

3. **Custom destination paths**: Modify the build phases to copy the README.md files to different destination paths in the app bundle.

The script approach was chosen because it:
- Doesn't require modifying existing files
- Works automatically without manual configuration
- Is easy to maintain and understand
- Preserves the developer-friendly naming convention of README.md files in each directory

## How to Verify

After implementing this fix, the build should complete successfully without the "Multiple commands produce" error.
