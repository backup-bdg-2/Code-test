# Swift Files in Settings Directory

## Important Information for Developers

### Problem
The Swift compiler looks for certain files directly in the `iOS/Views/Settings/` directory, while these files were originally organized in subdirectories like `iOS/Views/Settings/About/` and `iOS/Views/Settings/AI Learning/`.

### Current Solution
We've created duplicates of the following files directly in the Settings directory:

1. `SettingsHeaderTableViewCell.swift` - Original in `About/` directory
2. `AILearningSettingsViewController.swift` - Original in `AI Learning/` directory
3. `ImprovedLearningSettingsCell.swift` - Original in `AI Learning/` directory
4. `ImprovedLearningViewController.swift` - Original in `AI Learning/` directory
5. `ModelServerIntegrationViewController.swift` - Original in `AI Learning/` directory

### Why This Approach
We initially tried using symbolic links, but this caused conflicts during the build process:
- Multiple commands produced the same output files
- README.md conflicts occurred (FIXED - see README_BUILD_FIX.md in the root directory)

Direct duplication ensures the compiler can find the files it expects while avoiding the problems with symbolic links.

### Important Notice
**If you make changes to any of these files, please update both the original file and the copy!**

This is a temporary solution until the Xcode project configuration can be properly fixed to address the correct file paths.

### Long-term Solutions
For a proper fix, consider:
1. Updating the project.pbxproj file to reference the files in their correct locations
2. Creating a build phase script to handle the file copying automatically
3. Reorganizing the project structure to match what the compiler expects

### Build Fixes
- The README.md conflict issue has been fixed with a post-build script (ExcludeReadmeFiles.sh) that removes duplicate README.md files from the app bundle. See README_BUILD_FIX.md for details.
