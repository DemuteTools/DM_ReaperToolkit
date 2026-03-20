# Waveform Matcher

The Waveform Matcher is a REAPER tool that automatically matches similar voice recordings from different media items using peak detection analysis.

## ‍Why Use This Tool?

When doing remote voice recording (e.g., via SessionLink), you may work with two versions of the same audio:

Remote recording - already edited during the recording session but contains artifacts, compression, or quality issues
Clean local recording - Long uninterrupted voice recording, high quality but unedited recorded locally by the voice actor.
Manually finding and matching each edited segment in the clean recording is very time-consuming. The Waveform Matcher automates this process, saving hours of work.

## How It Works

The Waveform Matcher uses a peak pattern matching algorithm that compares characteristics of audio waveforms:

1. **Peak Detection** — The tool identifies prominent amplitude peaks in both the edited and clean recordings.
2. **Pattern Extraction** — For each peak, it analyzes the pattern of surrounding peaks.
3. **Pattern Matching** — The edited peak pattern is compared against every possible position in the clean file.
4. **Scoring** — Matches are scored based on how similar the peak patterns are.
