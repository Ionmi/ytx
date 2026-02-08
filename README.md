# ytx

Local YouTube transcriber for macOS. Downloads audio with `yt-dlp` and transcribes it using Apple's Speech.framework — no cloud APIs, everything runs on-device.

## Requirements

- macOS 26+ (Tahoe)
- Apple Silicon
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (`brew install yt-dlp`)

## Install

### From source

```bash
git clone https://github.com/ionmi/ytx.git
cd ytx
swift build -c release
cp .build/release/ytx /usr/local/bin/
```

### Homebrew

```bash
brew tap ionmi/tap
brew install ytx
```

## Usage

```
ytx [<url>] [options]
```

Run with no arguments for an interactive guided flow, or pass a URL directly.

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-l, --locale` | Speech recognition locale | `en-US` |
| `-f, --format` | Output format: `txt` or `srt` | `txt` |
| `-o, --output-dir` | Directory for output files | `./output` |
| `--keep-audio` | Keep the downloaded audio file | off (deleted) |
| `--version` | Print version | |

### Examples

```bash
# Basic transcription
ytx "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Spanish transcription in SRT format
ytx "https://www.youtube.com/watch?v=VIDEO_ID" -l es-ES -f srt

# Custom output directory
ytx "https://www.youtube.com/watch?v=VIDEO_ID" -o ~/transcripts

# Keep the downloaded audio file
ytx "https://www.youtube.com/watch?v=VIDEO_ID" --keep-audio

# Transcribe an entire playlist
ytx "https://www.youtube.com/playlist?list=PLAYLIST_ID"

# Interactive mode — guided prompts for URL, format, locale
ytx
```

The first time you use a locale, ytx will automatically download the required language model.

### Scripting

ANSI escape codes are automatically suppressed when stdout/stderr is not a terminal, so ytx works cleanly in pipelines and scripts:

```bash
# Pipe output without ANSI codes
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

1. Downloads the best available audio using `yt-dlp`
2. Transcribes locally using Apple's Speech.framework (`SpeechTranscriber`)
3. Outputs plain text (`.txt`) or subtitles (`.srt`) with timestamps

## Disclaimer

Respect content creators' rights. Only download content you have permission to use.

## License

[MIT](LICENSE)
