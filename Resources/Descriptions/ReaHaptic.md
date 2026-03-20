# Reahaptic

Reahaptic is a package for Reaper that contains a collection of scripts that allows the creation, editing, exporting, and testing of haptic files all inside Reaper, focused on haptics for mobile devices. and comes with a mobile testing app called the Reahaptic Receiver that you can connect to Reaper and immediately test your haptics.

## Why Use This Tool?
We wanted to make haptic creation and testing for games as a sound designer as easy and efficient as possible. These were the goals for this project:

- **Immediate feedback**: When creating a haptic file, we want to be able to test it immediately without having to export a file, on both mobile and gamepads.
- **Sound Designer workflow**: A comfortable haptics creation workflow that plugs in seamlessly with your sound design workflow. And you are able to design your haptics with the context of a video track and audio. And immediately test it on your target device.
- **Format agnostic**: We want to support as many haptic formats as possible so you are not tied to a specific implementation/platform, and we could also serve as a conversion tool.

## How It Works
ReaHaptic adds a set of tools to Reaper that let you treat Reaper Envelopes as haptic data. 
- **Draw Haptics using Reaper envelopes**: Haptics are authored using three envelope tracks: Amplitude, Frequency, and Emphasis. Amplitude controls vibration strength, Frequency controls vibration speed, and Emphasis provides short, punchy bursts.
- **Live link to mobile app**: Using the ReaHaptic Live Reaper Link, haptic data is streamed in real time to the ReaHaptic Receiver app over the network. When you press play in Reaper, haptics trigger on the connected device exactly as the timeline cursor passes over them.
- **Export different file types**: Finished haptics can be exported directly from Reaper to multiple supported formats, including .haptic and .haps. These files are ready to be used in game engines, or loaded back into the Receiver app.
