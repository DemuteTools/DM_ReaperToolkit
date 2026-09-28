# ReaAnimViewer
3D animation viewer for REAPER. Load glTF and FBX animations straight onto your timeline and watch the animated character play in sync with the REAPER playhead — from any camera angle.

# Why Use This Tool?
Sound designing for game characters usually means screen-recording every animation in the engine, importing the videos into REAPER, and redoing all of it every time an animator changes a few frames. Once recorded, the camera angle is frozen: if the gesture you need to time is hidden behind the character, you're back to the engine. ReaAnimViewer removes the video step entirely.


- No more screen captures: Drop the animation file itself on a track. The rig is rendered live, frame-accurate, with no video file, no stutter, no re-recording. 
- Move the camera while you design: Orbit, pan and zoom around the character at any time, and snap to front/side/top views with the navigation cube, see the foot contact or the hand swing the recorded video would have hidden.
- Behaves like native REAPER media: Animation items can be moved, trimmed, looped, saved with the project and copied into the project folder like any audio item, so your session and your sounds stay in sync.

# How It Works

ReaAnimViewer is a native REAPER extension (a single `.dll`). It teaches REAPER to read `.glb`, `.gltf` and `.fbx` files as media: drop one on a track and it becomes an item whose length matches the animation. A dockable viewer window renders the animated mesh at the current playhead position. Play, stop, scrub or loop and the character follows. 
Engine agnostic: Works with any animation exported to glTF or FBX from Unreal, Unity, Godot, Blender, Maya or a proprietary engine.
Skinned meshes and textures: Full skeletal deformation, diffuse/normal/specular maps, multi-material meshes.
Several animations per project: Put different animations on different tracks; the viewer shows the one on the topmost track under the playhead.
Viewer tools: A built-in side menu for lighting, floor, shadows and render quality.
Everything bundled: No ReaImGui, no SWS, no runtime to install. ReaPack installs one file and that's it.
