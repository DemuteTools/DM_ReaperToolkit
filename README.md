# Demute Reaper Toolkit
The Demute Reaper toolkit is a manager that collects our Reaper tools.

## Requirements:
- **Reaper**: Package was made for reaper 7.62+ but should work for older versions as well.
- **Reapack** : Used to import the package in reaper.
- **Python**: Some of the packages use use python scripts, so make sure your reaper has a recognised python installation. You can check this here: **options >preferences >Plug-ins >ReaScript**
- **ReaImGui**: Most of the tool ise ReaImgui, Is included in the ReaTeam Extensions Package that you can install with Reapack. To check if it is installed, you should have a ReaImGui Tab under the ReaScript tab in the preferences: **options >preferences >Plug-ins >ReaImGui** 

## Reapack:
To install Reapack follow these steps:
1. Download Reapack for your platform here(also the user Guide): [Reapack Download](https://reapack.com/user-guide#installation)
2. From REAPER: **Options > Show REAPER resource path in explorer/finder**
3. Put the downloaded file in the **UserPlugins** subdirectory
4. Restart REAPER. Done!

If you have Reapack installed go to **Extensions->Reapack->Import Repositories** paste the following link there and press **Ok**.

--> https://raw.githubusercontent.com/DemuteStudio/DM_ReaperToolkit/refs/heads/main/index.xml

Then in **Extensions->Reapack->Manage repositories** you should see **Demute_Toolkit**. Then click **Browse Packages** and search for **DM_ReaperToolkit** click install and apply.

To install **ReaImGui**, find **ReaTeam Extensions** in Manage repositories. Then if you only want ReaImGui Choose **Install individual packages in this repository** and find ReaImGui.
