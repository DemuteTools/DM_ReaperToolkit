# Subproject Manager
The Subproject Manager is a REAPER tool designed to make working with subprojects a bit easier.

## ‍Why Use This Tool?
We often work with subprojects when doing sound design for videos that contain a lot of repeated audio, such as gameplay footage. 
This allows us to design the sound in a subproject and then place instances of it throughout the video—so when we update the sound, it changes everywhere automatically.
And also easily handle variations.

The problem we sometimes encounter is that renaming subprojects and exporting them individually can be a hassle and take a lot of time. 
Normally, you would have to open each subproject, create regions for each variation, and render them manually. With this tool, it’s reduced to a single button.

## How It Works
The tool generates a list of all the subprojects in the open REAPER project and allows you to select them and perform actions on them. 
It also shows how many instances and variations each subproject has.
- **Export**: Select one or multiple subprojects and export them with a single button. It uses the last render settings.
- **Rename**: Select a subproject and rename it. The tool updates the subproject file and all its instances without breaking references.
