# ytx

Local YouTube transcriber for macOS. Downloads audio with `yt-dlp` and transcribes it using Apple's Speech.framework — no cloud APIs, everything runs on-device.

## Requirements

- macOS 26+ (Tahoe)
- Apple Silicon
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (`brew install yt-dlp`)
- [ffmpeg](https://ffmpeg.org/) — only needed for `--video` (`brew install ffmpeg`)

## Install

### Homebrew

```bash
brew tap ionmi/tap
brew install ytx
```

### From source

Requires Xcode or the Xcode Command Line Tools.

```bash
git clone https://github.com/ionmi/ytx.git
cd ytx
swift build -c release
cp .build/release/ytx /usr/local/bin/
```

## Usage

```
ytx [<url>] [options]
```

Run with no arguments for an interactive guided flow, or pass a URL directly.

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-l, --locale` | Speech recognition locale | auto-detect, fallback `en-US` |
| `-f, --format` | Output format: `txt` or `srt` | `txt` |
| `-o, --output-dir` | Directory for output files | `./output` |
| `--stdout` | Write transcript to stdout (UI goes to stderr) | off |
| `--video` | Also download the video file (mp4). Requires ffmpeg | off |
| `--keep-audio` | Keep the downloaded audio file | off (deleted) |
| `--max-line-length` | Max characters per SRT subtitle line (10-200) | `40` |
| `--verbose` | Show debug output (yt-dlp stderr, commands, etc.) | off |
| `--version` | Print version | |

### Examples

```bash
# Basic transcription
ytx "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Spanish transcription in SRT format
ytx "https://www.youtube.com/watch?v=VIDEO_ID" -l es-ES -f srt

# Custom output directory
ytx "https://www.youtube.com/watch?v=VIDEO_ID" -o ~/transcripts

# Download the video alongside the transcript
ytx "https://www.youtube.com/watch?v=VIDEO_ID" --video

# Keep the downloaded audio file
ytx "https://www.youtube.com/watch?v=VIDEO_ID" --keep-audio

# SRT with wider subtitle lines
ytx "https://www.youtube.com/watch?v=VIDEO_ID" -f srt --max-line-length 80

# Transcribe an entire playlist
ytx "https://www.youtube.com/playlist?list=PLAYLIST_ID"

# Debug a failing download
ytx "https://www.youtube.com/watch?v=VIDEO_ID" --verbose

# Interactive mode — guided prompts for URL, format, locale
ytx
```

The locale is auto-detected from the video's metadata when `--locale` is not specified. The first time you use a locale, ytx will automatically download the required language model.

### Piping (`--stdout`)

Use `--stdout` to write the transcript to stdout instead of a file. All UI output (spinners, progress bars, status messages) is redirected to stderr so the transcript stream stays clean:

```bash
# Save transcript while seeing progress on stderr
ytx "https://..." --stdout > transcript.txt

# Pipe into another tool
ytx "https://..." --stdout -f srt | my-subtitle-tool

# Search the transcript
ytx "https://..." --stdout | grep -i "keyword"

# Word count
ytx "https://..." --stdout | wc -w
```

### Scripting

ANSI escape codes are automatically suppressed when stdout/stderr is not a terminal, so ytx works cleanly in pipelines and scripts:

```bash
# Log everything to a file
ytx "https://..." -f srt -o ~/transcripts 2>&1 | tee log.txt

# Use from a shell script
URL="https://www.youtube.com/watch?v=VIDEO_ID"
ytx "$URL" -f srt -o ~/transcripts
```

## Shell completions

```bash
# Zsh
ytx --generate-completion-script zsh > ~/.zfunc/_ytx

# Bash
ytx --generate-completion-script bash > /etc/bash_completion.d/ytx

# Fish
ytx --generate-completion-script fish > ~/.config/fish/completions/ytx.fish
```

## How it works

1. Downloads the best available audio (and optionally video) using `yt-dlp`
2. Auto-detects the video's language for speech recognition
3. Transcribes locally using Apple's Speech.framework
4. Outputs plain text (`.txt`) or subtitles (`.srt`) with timestamps

## Disclaimer

Respect content creators' rights. Only download content you have permission to use.

## License

[MIT](LICENSE)
