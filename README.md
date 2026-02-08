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

### Homebrew (coming soon)

```bash
brew tap ionmi/tap
brew install ytx
```

## Usage

```
ytx <url> [options]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-l, --locale` | Speech recognition locale | `en-US` |
| `-f, --format` | Output format: `txt` or `srt` | `txt` |
| `-o, --output-dir` | Directory for output files | `./output` |

### Examples

```bash
# Basic transcription
ytx "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Spanish transcription in SRT format
ytx "https://www.youtube.com/watch?v=VIDEO_ID" -l es-ES -f srt

# Custom output directory
ytx "https://www.youtube.com/watch?v=VIDEO_ID" -o ~/transcripts
```

The first time you use a locale, ytx will automatically download the required language model.

## How it works

1. Downloads the best available audio using `yt-dlp`
2. Transcribes locally using Apple's Speech.framework (`SpeechTranscriber`)
3. Outputs plain text (`.txt`) or subtitles (`.srt`) with timestamps

## License

[MIT](LICENSE)
