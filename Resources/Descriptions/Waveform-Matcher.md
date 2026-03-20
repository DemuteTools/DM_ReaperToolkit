# Waveform Matcher

Automatically match similar voice recordings from different media items using peak detection analysis.

## Use Case

The Waveform Matcher solves a common workflow challenge in game audio production: working with dual audio sources during remote voice recording sessions. It helps match edited remote recordings against clean, unedited local recordings, eliminating the need for manual segment matching.

## How It Works

The tool employs a four-step peak pattern matching algorithm:

1. **Peak Detection** — Identifies prominent amplitude peaks in both recordings
2. **Pattern Extraction** — Analyzes the pattern surrounding each peak
3. **Pattern Matching** — Compares edited peak patterns against all positions in the clean file
4. **Scoring** — Ranks matches based on similarity of peak patterns