import ArgumentParser
import Darwin
import Foundation

@main
struct Ytx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ytx",
        abstract: "Download and transcribe audio from YouTube (or any yt-dlp URL).",
        version: "0.4.1"
    )

    @Argument(help: "YouTube or any yt-dlp supported URL.")
    var url: String?

    @Option(name: .shortAndLong, help: "Speech recognition locale (default: auto-detect, fallback en-US).")
    var locale: String?

    @Option(name: .shortAndLong, help: "Output format: txt or srt (default: txt).")
    var format: String = "txt"

    @Option(name: .shortAndLong, help: "Directory to save output files.")
    var outputDir: String = "./output"

    @Flag(name: .customLong("stdout"), help: "Write transcript to stdout instead of a file. UI goes to stderr.")
    var toStdout: Bool = false

    @Flag(help: "Keep the downloaded audio file (deleted by default).")
    var keepAudio: Bool = false

    @Option(name: .long, help: "Max characters per SRT line (10-200).")
    var maxLineLength: Int = 40

    @Flag(help: "Also download the video file.")
    var video: Bool = false

    @Flag(help: "Show verbose output (yt-dlp stderr, debug info).")
    var verbose: Bool = false

    mutating func validate() throws {
        if url == nil && !Terminal.isStdinTTY {
            throw ValidationError("Missing expected argument '<url>'")
        }
        guard (10...200).contains(maxLineLength) else {
            throw ValidationError("--max-line-length must be between 10 and 200.")
        }
    }

    mutating func run() async throws {
        let resolvedURL: String
        let isInteractive: Bool
        if let url {
            resolvedURL = url
            isInteractive = false
        } else {
            resolvedURL = try interactiveFlow()
            isInteractive = true
        }

        // Validate URL
        try validateURL(resolvedURL)

        // Parse output format
        guard let outputFormat = OutputFormat(rawValue: format) else {
            throw ValidationError("Invalid format '\(format)'. Use 'txt' or 'srt'.")
        }

        // Validate yt-dlp
        guard Downloader.isAvailable() else {
            printError("yt-dlp not found. Install with: brew install yt-dlp")
            throw ExitCode.failure
        }

        // Validate ffmpeg when video download is requested
        if video {
            guard Downloader.isFfmpegAvailable() else {
                printError("ffmpeg not found. Install with: brew install ffmpeg")
                throw ExitCode.failure
            }
        }

        // Auto-detect locale in CLI mode (interactive flow already handles it)
        if !isInteractive, locale == nil {
            if let detected = detectLocale(url: resolvedURL) {
                locale = detected
            }
        }

        // When piping transcript to stdout, redirect all UI output to stderr
        if toStdout {
            Terminal.uiFd = STDERR_FILENO
        }

        // Create output directory (skip when writing to stdout)
        let outputDirURL: URL
        if toStdout {
            outputDirURL = URL(fileURLWithPath: NSTemporaryDirectory())
        } else {
            outputDirURL = URL(fileURLWithPath: outputDir)
            try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
        }

        // Install signal handler for cleanup even in CLI mode
        Terminal.installSignalHandler()

        // Download with spinner
        uiWrite("\n")
        let dlSpinner = Terminal.Spinner("Downloading \(video ? "video + audio" : "audio")…")
        dlSpinner.start()

        let isVerbose = verbose
        let downloads = try await Downloader.download(
            url: resolvedURL,
            outputDir: outputDirURL,
            video: video,
            verboseLog: { msg in
                if isVerbose {
                    let stderr = FileHandle.standardError
                    stderr.write(Data("[verbose] \(msg)\n".utf8))
                }
            }
        )

        dlSpinner.stop("Downloaded \(downloads.count) file\(downloads.count == 1 ? "" : "s")")

        // Register downloaded files for cleanup on interrupt
        if !toStdout {
            for dl in downloads {
                Terminal.registerCleanup(path: dl.audioFile.path)
                if let videoFile = dl.videoFile {
                    Terminal.registerCleanup(path: videoFile.path)
                }
            }
        }

        // Transcribe each file
        let resolvedLocale = Locale(identifier: locale ?? "en-US")
        let options = TranscriptionEngine.Options(
            locale: resolvedLocale,
            outputFormat: outputFormat,
            maxLength: maxLineLength
        )

        for (index, dl) in downloads.enumerated() {
            uiWrite("\n")
            if downloads.count > 1 {
                printStep("[\(index + 1)/\(downloads.count)] Transcribing \(dl.audioFile.lastPathComponent)")
            } else {
                printStep("Transcribing with locale \(resolvedLocale.identifier)")
            }
            uiWrite("\n")

            let result = try await TranscriptionEngine.transcribe(file: dl.audioFile, options: options)

            if toStdout {
                // Write transcript to stdout
                print(result)
            } else {
                // Register output file for cleanup before writing
                let basename = dl.audioFile.deletingPathExtension().lastPathComponent
                let ext = outputFormat.rawValue
                let outputFile = outputDirURL.appendingPathComponent("\(basename).\(ext)")
                Terminal.registerCleanup(path: outputFile.path)

                // Write output
                try result.write(to: outputFile, atomically: true, encoding: .utf8)
                Terminal.unregisterCleanup(path: outputFile.path)

                uiWrite("\n")
                printDone("Transcription saved to \(outputFile.path)")

                if let videoFile = dl.videoFile {
                    printDone("Video saved to \(videoFile.path)")
                    Terminal.unregisterCleanup(path: videoFile.path)
                }
            }

            // Clean up audio file unless --keep-audio
            if !keepAudio {
                try FileManager.default.removeItem(at: dl.audioFile)
            }
            if !toStdout {
                Terminal.unregisterCleanup(path: dl.audioFile.path)
            }

            // Preview (skip when writing to stdout)
            if !toStdout {
                uiWrite("\n")
                let dim = Terminal.isUITTY ? "\u{1B}[2m" : ""
                let reset = Terminal.isUITTY ? "\u{1B}[0m" : ""
                uiWrite("  \(dim)── Preview ──\(reset)\n")
                let lines = result.components(separatedBy: .newlines)
                for line in lines.prefix(15) {
                    uiWrite("  \(dim)\(line)\(reset)\n")
                }
                if lines.count > 15 {
                    uiWrite("  \(dim)… (\(lines.count - 15) more lines)\(reset)\n")
                }
                uiWrite("  \(dim)─────────────\(reset)\n")
            }
        }
        uiWrite("\n")
    }

    // MARK: - Interactive Flow

    private mutating func interactiveFlow() throws -> String {
        Terminal.printBanner()

        // URL (free-text)
        print("  Enter URL: ", terminator: "")
        fflush(stdout)
        guard let input = readLine(), !input.isEmpty else {
            throw ValidationError("No URL provided.")
        }
        let url = input.trimmingCharacters(in: .whitespaces)
        try validateURL(url)
        print()

        // Format (arrow-key picker)
        let formatItems = [
            Terminal.MenuItem(label: "txt", description: "Plain text transcript"),
            Terminal.MenuItem(label: "srt", description: "Subtitles with timestamps"),
        ]
        guard let formatIdx = Terminal.pick(title: "Format", items: formatItems) else {
            throw ExitCode(0)
        }
        format = formatItems[formatIdx].label
        print()

        // Download video (arrow-key picker)
        let videoItems = [
            Terminal.MenuItem(label: "No", description: "Audio only for transcription"),
            Terminal.MenuItem(label: "Yes", description: "Download video + audio (mp4)"),
        ]
        guard let videoIdx = Terminal.pick(title: "Download video", items: videoItems) else {
            throw ExitCode(0)
        }
        video = videoIdx == 1
        print()

        // Keep audio (arrow-key picker)
        let keepItems = [
            Terminal.MenuItem(label: "No", description: "Delete audio after transcription"),
            Terminal.MenuItem(label: "Yes", description: "Keep the downloaded audio file"),
        ]
        guard let keepIdx = Terminal.pick(title: "Keep audio", items: keepItems) else {
            throw ExitCode(0)
        }
        keepAudio = keepIdx == 1
        print()

        // Auto-detect locale from video, then let user confirm/override
        let detectedLocale = detectLocale(url: url)
        let defaultLocale = detectedLocale ?? "en-US"

        let localeItems = [
            Terminal.MenuItem(label: defaultLocale, description: detectedLocale != nil ? "Detected from video" : "Default"),
            Terminal.MenuItem(label: "Specify", description: "Enter a locale manually"),
        ]
        guard let localeIdx = Terminal.pick(title: "Locale", items: localeItems) else {
            throw ExitCode(0)
        }

        if localeIdx == 1 {
            print()
            print("  Enter locale (e.g. fr-FR): ", terminator: "")
            fflush(stdout)
            if let custom = readLine()?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
                locale = custom
            } else {
                locale = defaultLocale
            }
        } else {
            locale = defaultLocale
        }
        print()

        return url
    }

    // MARK: - URL Validation

    private func validateURL(_ urlString: String) throws {
        guard let url = URL(string: urlString) else {
            throw ValidationError("Invalid URL: '\(urlString)'")
        }
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            throw ValidationError("URL must use http or https scheme: '\(urlString)'")
        }
        guard url.host != nil else {
            throw ValidationError("URL has no host: '\(urlString)'")
        }
    }

    // MARK: - Locale Detection

    private static let languageToLocale: [String: String] = [
        // Major languages
        "en": "en-US", "es": "es-ES", "fr": "fr-FR", "de": "de-DE",
        "pt": "pt-BR", "it": "it-IT", "ja": "ja-JP", "zh": "zh-CN",
        "ko": "ko-KR", "ru": "ru-RU", "ar": "ar-SA", "hi": "hi-IN",
        "nl": "nl-NL", "sv": "sv-SE", "pl": "pl-PL", "tr": "tr-TR",
        // European
        "uk": "uk-UA", "cs": "cs-CZ", "da": "da-DK", "fi": "fi-FI",
        "el": "el-GR", "hu": "hu-HU", "no": "nb-NO", "nb": "nb-NO",
        "ro": "ro-RO", "sk": "sk-SK", "ca": "ca-ES", "hr": "hr-HR",
        "bg": "bg-BG",
        // Middle East / South Asia
        "he": "he-IL", "th": "th-TH", "vi": "vi-VN",
        // Southeast Asia / Malay
        "id": "id-ID", "ms": "ms-MY",
        // Chinese variants
        "zh-Hans": "zh-CN", "zh-Hant": "zh-TW",
    ]

    private func detectLocale(url: String) -> String? {
        let spinner = Terminal.Spinner("Detecting video language...")
        spinner.start()

        guard let langCode = Downloader.fetchLanguage(url: url) else {
            spinner.fail("Language not detected, using \(locale ?? "en-US")")
            return nil
        }

        if verbose {
            let stderr = FileHandle.standardError
            stderr.write(Data("[verbose] Raw language code from yt-dlp: \(langCode)\n".utf8))
        }

        let resolved = Self.languageToLocale[langCode] ?? langCode
        spinner.stop("Detected language: \(langCode) → \(resolved)")
        return resolved
    }
}

// MARK: - Print Helpers

private func uiWrite(_ message: String) {
    let fd = Terminal.uiFd
    write(fd, message, message.utf8.count)
}

func printInfo(_ message: String) {
    if Terminal.isUITTY {
        uiWrite("\u{001B}[1;34m=>\u{001B}[0m \(message)\n")
    } else {
        uiWrite("=> \(message)\n")
    }
}

func printStep(_ message: String) {
    if Terminal.isUITTY {
        uiWrite("  \u{001B}[1;34m▸\u{001B}[0m \u{001B}[1m\(message)\u{001B}[0m\n")
    } else {
        uiWrite("=> \(message)\n")
    }
}

func printDone(_ message: String) {
    if Terminal.isUITTY {
        uiWrite("  \u{001B}[1;32m✓\u{001B}[0m \(message)\n")
    } else {
        uiWrite("=> \(message)\n")
    }
}

func printError(_ message: String) {
    let stderr = FileHandle.standardError
    if Terminal.isStderrTTY {
        stderr.write(Data("\u{001B}[1;31mError:\u{001B}[0m \(message)\n".utf8))
    } else {
        stderr.write(Data("Error: \(message)\n".utf8))
    }
}
