# Subproject Manager
The Subproject Manager is a REAPER tool designed to make working with subprojects a bit easier.

## How to Use:
- **Launch** — Run the script. It scans the current project and lists all subprojects (.rpp items).
- **Browse subprojects** — The main list shows each subproject with its variation count and instance count (e.g. 3v ×2 = 3 variations, 2 instances). Use the Search bar to filter by name.
- **Select** — Click a subproject to select it. Ctrl+click to multi-select. Use Select All to select everything.
- **Navigate instances** — When a subproject is selected, the bottom panel lists every instance with its track and timeline position. Click an instance to jump to it in the arrange view.
- **Refresh** — rescan the project for subproject.
- **Add** — create a new subproject with options like amount of variations and to Import the reference Video.
- **Delete** — Delete selected subprojects instances and file(Cant be Undone) 
- **Rename** — Select a single subproject, click Rename, type the new name, and press Apply (or Enter). This renames the .rpp file and updates all instances in the project.
- **Open** — Select a single subproject and click Open to open it in a new REAPER project tab.
- **Export** — Set an export folder in the path field (or click Browse to pick one). Select one or more subprojects, then click Export. Each subproject is exported as with the last render settings sliced in varitions by markers. Single-variation subprojects export as name.wav; multi-variation ones as name_01.wav, name_02.wav, etc.
- **Refresh** — Click Refresh to rescan the project after making changes outside the tool.
 
## installation:
Install with the Demute Reaper Toolkit: https://github.com/DemuteStudio/DM_ReaperToolkit
or directly with Reapack.

