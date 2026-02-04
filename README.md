# recordit

A macOS CLI that records audio, screen, or camera output and prints the output file path.

## Build

```bash
swift build
```

## Run

```bash
.build/arm64-apple-macosx/debug/recordit audio
.build/arm64-apple-macosx/debug/recordit screen
.build/arm64-apple-macosx/debug/recordit camera
```

The command prints the output file path to stdout. Status messages go to stderr so the output is pipeline-friendly.

## Usage

```bash
recordit audio [options]
recordit screen [options]
recordit camera [options]
```

## Audio Options

- `--duration <seconds>`: Stop automatically after this many seconds. If omitted, press `S` to stop.
- `--output <path>`: Write output to this file or directory. Default: temporary directory.
- `--name <pattern>`: Filename pattern when output is a directory. Supports strftime tokens, `{uuid}`, and `{chunk}`. Default: `micrec-%Y%m%d-%H%M%S` (or `micrec-%Y%m%d-%H%M%S-{chunk}` when splitting).
- `--overwrite`: Overwrite output file if it exists.
- `--json`: Print machine-readable JSON to stdout.
- `--list-devices`: List available input devices and exit.
- `--list-formats`: List available audio formats and exit.
- `--list-qualities`: List available encoder qualities and exit.
- `--device <device>`: Input device UID or name to use for recording.
- `--stop-key <char>`: Stop key (single ASCII character). Default: `s` (case-insensitive).
- `--pause-key <char>`: Pause key (single ASCII character). Default: `p` (case-insensitive). If same as resume key, toggles pause/resume.
- `--resume-key <char>`: Resume key (single ASCII character). Default: `r` (case-insensitive). If same as pause key, toggles pause/resume.
- `--silence-db <db>`: Silence threshold in dBFS (e.g. `-50`). Requires `--silence-duration`.
- `--silence-duration <seconds>`: Stop after this many seconds of continuous silence. Requires `--silence-db`.
- `--max-size <mb>`: Stop when output file reaches this size in MB.
- `--split <seconds>`: Split recording into chunks of this many seconds. Output must be a directory.
- `--sample-rate <hz>`: Sample rate in Hz. Default: `44100`.
- `--channels <count>`: Number of channels. Default: `1`.
- `--bit-rate <bps>`: Encoder bit rate in bps. Default: `128000`. Ignored for `linearPCM`.
- `--format <format>`: Audio format. Default: `linearPCM`.
- `--quality <quality>`: Encoder quality. Default: `high`.

Supported formats:
- `aac`, `alac`, `linearPCM`, `appleIMA4`, `ulaw`, `alaw`

File extension mapping:
- `aac`, `alac` -> `.m4a`
- `linearPCM`, `appleIMA4`, `ulaw`, `alaw` -> `.caf`

## Screen Options

- `--duration <seconds>`: Stop automatically after this many seconds. If omitted, use the stop key or Ctrl-C.
- `--output <path>`: Write output to this file or directory. Default: temporary directory.
- `--name <pattern>`: Filename pattern when output is a directory. Supports strftime tokens, `{uuid}`, and `{chunk}`.
- `--overwrite`: Overwrite output file if it exists.
- `--json`: Print machine-readable JSON to stdout.
- `--list-displays`: List available displays and exit.
- `--list-windows`: List available windows and exit.
- `--display <id|primary>`: Capture a display by ID or the primary display.
- `--window <id|title>`: Capture a window by ID or title/app substring.
- `--stop-key <char>`: Stop key (single ASCII character). Default: `s` (case-insensitive).
- `--pause-key <char>`: Pause key (single ASCII character). Default: `p` (case-insensitive). If same as resume key, toggles pause/resume.
- `--resume-key <char>`: Resume key (single ASCII character). Default: `r` (case-insensitive). If same as pause key, toggles pause/resume.
- `--max-size <mb>`: Stop when output file reaches this size in MB.
- `--split <seconds>`: Split recording into chunks of this many seconds. Output must be a directory.
- `--fps <fps>`: Frames per second. Default: `30`.
- `--codec <h264|hevc|prores>`: Video codec. Default: `h264`.
- `--bit-rate <bps>`: Video bit rate in bps (applies to h264/hevc).
- `--scale <factor>`: Scale factor (e.g. `0.5` for half size). Default: `1`.
- `--hide-cursor`: Hide the cursor in the recording.
- `--show-clicks`: Show mouse click highlights (macOS 15+).
- `--region <spec>`: Capture region as `x,y,w,h`. Values may be pixels, 0..1 fractions, or percentages (e.g. `10%,10%,80%,80%`).
- `--audio <none|system|mic|both>`: Capture system and/or mic audio. Default: `none`.
- `--audio-sample-rate <hz>`: Audio sample rate. Default: `48000`.
- `--audio-channels <count>`: Audio channel count. Default: `2`.

## Camera Options

- `--list-cameras`: List available cameras and exit.
- `--camera <id|name>`: Camera ID or name substring to use for capture.
- `--mode <video|photo>`: Capture mode. Default: `video`.
- `--photo`: Capture a single photo (alias for `--mode photo`).
- `--duration <seconds>`: Stop recording after this many seconds. If omitted, press the stop key (video only).
- `--output <path>`: Write output to this file or directory. Default: temporary directory.
- `--name <pattern>`: Filename pattern when output is a directory. Supports strftime tokens, `{uuid}`, and `{chunk}`.
- `--overwrite`: Overwrite output file if it exists.
- `--json`: Print machine-readable JSON to stdout.
- `--stop-key <char>`: Stop key (single ASCII character). Default: `s` (case-insensitive).
- `--max-size <mb>`: Stop when output file reaches this size in MB (video only).
- `--split <seconds>`: Split recording into chunks of this many seconds. Output must be a directory (video only).
- `--fps <fps>`: Frames per second (video only).
- `--resolution <WxH>`: Capture resolution (e.g. `1280x720`).
- `--audio`: Record from the system default microphone (video only).
- `--photo-format <jpeg|heic>`: Photo format. Default: `jpeg` (photo only).

Region examples:
- `--region 0.1,0.1,0.8,0.8` (fractions)
- `--region 10%,10%,80%,80%` (percentages)
- `--region 100,200,1280,720` (pixels)
- `--region center:80%x80%` (centered)

## Examples

Audio:
```bash
recordit audio --duration 5
recordit audio --list-devices
recordit audio --list-formats --json
recordit audio --device "MacBook Pro Microphone" --duration 10
recordit audio --stop-key q --duration 30
recordit audio --pause-key p --resume-key r
recordit audio --pause-key p --resume-key p
recordit audio --silence-db -50 --silence-duration 3
recordit audio --max-size 50
recordit audio --split 30 --output /tmp
recordit audio --split 10 --name "micrec-%Y%m%d-%H%M%S-{chunk}-{uuid}"
recordit audio --output /tmp --name "micrec-%Y%m%d-%H%M%S-{uuid}"
recordit audio --output /tmp/meeting.caf --overwrite
recordit audio --duration 5 --json
recordit audio --sample-rate 48000 --channels 2 --format aac --quality high
recordit audio --format linearPCM --sample-rate 44100 --channels 1
```

Screen:
```bash
recordit screen --duration 5
recordit screen --list-displays
recordit screen --list-windows --json
recordit screen --display primary --fps 60
recordit screen --window "Safari" --region 10%,10%,80%,80%
recordit screen --split 30 --output /tmp
recordit screen --codec hevc --bit-rate 6000000 --scale 0.5
recordit screen --audio system
recordit screen --audio both --audio-sample-rate 48000 --audio-channels 2
```

Camera:
```bash
recordit camera --duration 5
recordit camera --list-cameras
recordit camera --camera "FaceTime" --duration 10
recordit camera --photo
recordit camera --photo --photo-format heic
recordit camera --resolution 1280x720 --fps 30
recordit camera --split 30 --output /tmp
recordit camera --audio --duration 5
```

## Notes

- Microphone permission is required for audio recording. In macOS: System Settings -> Privacy & Security -> Microphone -> enable your terminal app.
- Screen recording permission is required for screen capture. In macOS: System Settings -> Privacy & Security -> Screen Recording -> enable your terminal app.
- Camera permission is required for camera capture. In macOS: System Settings -> Privacy & Security -> Camera -> enable your terminal app.
- Microphone permission is required for camera capture when using `--audio`.
- Stopping with `S` requires a real TTY (Terminal/iTerm). IDE consoles may not deliver single-key input.
- With `--split --json`, the tool prints one JSON object per chunk (NDJSON).
- While paused, split timing does not advance.
