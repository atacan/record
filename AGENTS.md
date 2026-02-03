# AGENTS.md

## Project summary

recordit is a macOS CLI that records audio or screen output and prints the output file path to stdout. Status messages go to stderr to keep stdout pipeline-friendly.

## Key files

- `Sources/recordit/recordit.swift`: Root command and subcommand wiring.
- `Sources/recordit/AudioCommand.swift`: Audio recording implementation.
- `Sources/recordit/ScreenCommand.swift`: Screen recording implementation.
- `Package.swift`: SwiftPM manifest.

## Build and run

```bash
swift build
.build/arm64-apple-macosx/debug/recordit audio --duration 5
.build/arm64-apple-macosx/debug/recordit screen --duration 5
```

## CLI behavior

- Argument parsing uses Swift Argument Parser (`AsyncParsableCommand`).
- `recordit` has subcommands: `audio` (default) and `screen`.

### Audio defaults

- format: `linearPCM`
- sample rate: `44100`
- channels: `1`
- bit rate: `128000` (ignored for `linearPCM`)
- quality: `high`

### Audio output

- Extensions:
  - `aac`, `alac` -> `.m4a`
  - `linearPCM`, `appleIMA4`, `ulaw`, `alaw` -> `.caf`
- Stop controls: `--stop-key`, `--pause-key`, `--resume-key` (toggle when identical).
- Auto-stop: `--duration`, `--silence-db` + `--silence-duration`, `--max-size`.
- Split: `--split` writes multiple chunks; `{chunk}` supported in `--name`.
- `--json` prints structured output; with `--split` it emits NDJSON.

### Screen capture

- Discovery:
  - `--list-displays`, `--list-windows` (use `--json` for machine output).
  - Select with `--display <id|primary>` or `--window <id|title>`.
- Video options: `--fps`, `--codec`, `--bit-rate`, `--scale`, `--hide-cursor`, `--show-clicks` (macOS 15+).
- Region cropping: `--region` accepts pixels, fractions, or percentages.
- Audio options: `--audio <none|system|mic|both>`, `--audio-sample-rate`, `--audio-channels`.
- Stop controls and split/max-size behavior mirror the audio command.

## Testing notes

- Microphone permission must be granted to the terminal app or the audio command exits with code 2.
- Screen recording permission must be granted to the terminal app for screen capture.
- When updating options or defaults, keep help text in sync and update `README.md`.
