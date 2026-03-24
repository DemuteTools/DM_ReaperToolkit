# DM Batch Renamer
Batch renaming tool for REAPER. Rename multiple items, tracks, regions, and markers at once with live preview before applying changes.

## Why Use This Tool?
Renaming assets in REAPER is tedious and error-prone when done manually, especially in large sessions with hundreds of items, tracks, regions, and markers. DM Batch Renamer lets you rename everything from a single window with instant visual feedback.
- **Live preview before committing**: See exactly what every name will become before applying any change, so you never rename something by accident.
- **Powerful stacking controls**: Combine find/replace, prefix/suffix, case transforms, space replacement, and increment modes in a single pass — no need to run multiple actions.
- **Game audio workflow support**: Folder Items mode with custom naming patterns generates hierarchical names from your region and track structure, tailored for NVK and RenderBlock pipelines.

## How It Works
The script runs inside REAPER as a dockable ReaImGui window. Select a tab for the element type you want to rename, configure your renaming rules in the left panel, and review the results in the preview table on the right.
- **Tab-based element filtering**: Separate tabs for Media Items, Tracks, Regions, Markers, Folder Items, and a combined All view keep things organized.
- **Preset system**: Save and recall your entire renaming configuration so you can reuse complex setups across sessions with one click.
- **Companion scripts for region/marker selection**: Two lightweight helper scripts let you click-select regions and markers directly from the arrange view, working around REAPER's native API limitation.
