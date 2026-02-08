import ArgumentParser
import Foundation

@main
struct Ytx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ytx",
        abstract: "Download and transcribe audio from YouTube (or any yt-dlp URL).",
        version: "0.3.1"
    )

    @Argument(help: "YouTube or any yt-dlp supported URL.")
    var url: String?

    @Option(name: .shortAndLong, help: "Speech recognition locale (default: auto-detect, fallback en-US).")
    var locale: String = "en-US"

    @Option(name: .shortAndLong, help: "Output format: txt or srt (default: txt).")
    var format: String = "txt"

    @Option(name: .shortAndLong, help: "Directory to save output files (default: ./output).")
    var outputDir: String = "./output"

    @Flag(help: "Keep the downloaded audio file (deleted by default).")
    var keepAudio: Bool = false

    @Flag(help: "Also download the video file.")
    var video: Bool = false

    // Track whether --locale was explicitly passed
    private var localeExplicit: Bool {
        ProcessInfo.processInfo.arguments.contains("--locale")
            || ProcessInfo.processInfo.arguments.contains("-l")
    }

    mutating func validate() throws {
        if url == nil && !Terminal.isStdinTTY {
            throw ValidationError("Missing expected argument '<url>'")
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

        // Parse output format
        guard let outputFormat = OutputFormat(rawValue: format) else {
            throw ValidationError("Invalid format '\(format)'. Use 'txt' or 'srt'.")
        }

        // Validate yt-dlp
        guard Downloader.isAvailable() else {
            printError("yt-dlp not found. Install with: brew install yt-dlp")
            throw ExitCode.failure
        }

        // Auto-detect locale in CLI mode (interactive flow already handles it)
        if !isInteractive, !localeExplicit {
            if let detected = detectLocale(url: resolvedURL) {
                locale = detected
            }
        }

        // Create output directory
        let outputDirURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)

        // Install signal handler for cleanup even in CLI mode
        Terminal.installSignalHandler()

        // Download with spinner
        print()
        let dlSpinner = Terminal.Spinner("Downloading \(video ? "video + audio" : "audio")…")
        dlSpinner.start()

        let downloads = try await Downloader.download(
            url: resolvedURL,
            outputDir: outputDirURL,
            video: video
        )

        dlSpinner.stop("Downloaded \(downloads.count) file\(downloads.count == 1 ? "" : "s")")

        // Register downloaded files for cleanup on interrupt
        for dl in downloads {
            Terminal.registerCleanup(path: dl.audioFile.path)
            if let videoFile = dl.videoFile {
                Terminal.registerCleanup(path: videoFile.path)
            }
        }

        // Transcribe each file
        let resolvedLocale = Locale(identifier: locale)
        let options = TranscriptionEngine.Options(
            locale: resolvedLocale,
            outputFormat: outputFormat,
            maxLength: 40
        )

        for (index, dl) in downloads.enumerated() {
            print()
            if downloads.count > 1 {
                printStep("[\(index + 1)/\(downloads.count)] Transcribing \(dl.audioFile.lastPathComponent)")
            } else {
                printStep("Transcribing with locale \(resolvedLocale.identifier)")
            }
            print()

            // Register output file for cleanup before writing
            let basename = dl.audioFile.deletingPathExtension().lastPathComponent
            let ext = outputFormat.rawValue
            let outputFile = outputDirURL.appendingPathComponent("\(basename).\(ext)")
            Terminal.registerCleanup(path: outputFile.path)

            let result = try await TranscriptionEngine.transcribe(file: dl.audioFile, options: options)

            // Write output
            try result.write(to: outputFile, atomically: true, encoding: .utf8)
            Terminal.unregisterCleanup(path: outputFile.path)

            print()
            printDone("Transcription saved to \(outputFile.path)")

            if let videoFile = dl.videoFile {
                printDone("Video saved to \(videoFile.path)")
                Terminal.unregisterCleanup(path: videoFile.path)
            }

            // Clean up audio file unless --keep-audio
            if !keepAudio {
                try FileManager.default.removeItem(at: dl.audioFile)
            }
            Terminal.unregisterCleanup(path: dl.audioFile.path)

            // Preview
            print()
            let dim = Terminal.isStdoutTTY ? "\u{1B}[2m" : ""
            let reset = Terminal.isStdoutTTY ? "\u{1B}[0m" : ""
            print("  \(dim)── Preview ──\(reset)")
            let lines = result.components(separatedBy: .newlines)
            for line in lines.prefix(15) {
                print("  \(dim)\(line)\(reset)")
            }
            if lines.count > 15 {
                print("  \(dim)… (\(lines.count - 15) more lines)\(reset)")
            }
            print("  \(dim)─────────────\(reset)")
        }
        print()
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

    // MARK: - Locale Detection

    private static let languageToLocale: [String: String] = [
        "en": "en-US", "es": "es-ES", "fr": "fr-FR", "de": "de-DE",
        "pt": "pt-BR", "it": "it-IT", "ja": "ja-JP", "zh": "zh-CN",
        "ko": "ko-KR", "ru": "ru-RU", "ar": "ar-SA", "hi": "hi-IN",
        "nl": "nl-NL", "sv": "sv-SE", "pl": "pl-PL", "tr": "tr-TR",
    ]

    private func detectLocale(url: String) -> String? {
        let spinner = Terminal.Spinner("Detecting video language...")
        spinner.start()

        guard let langCode = Downloader.fetchLanguage(url: url) else {
            spinner.fail("Language not detected, using \(locale)")
            return nil
        }

        let resolved = Self.languageToLocale[langCode] ?? langCode
        spinner.stop("Detected language: \(langCode) → \(resolved)")
        return resolved
    }
}

// MARK: - Print Helpers

func printInfo(_ message: String) {
    if Terminal.isStdoutTTY {
        print("\u{001B}[1;34m=>\u{001B}[0m \(message)")
    } else {
        print("=> \(message)")
    }
}

func printStep(_ message: String) {
    if Terminal.isStdoutTTY {
        print("  \u{001B}[1;34m▸\u{001B}[0m \u{001B}[1m\(message)\u{001B}[0m")
    } else {
        print("=> \(message)")
    }
}

func printDone(_ message: String) {
    if Terminal.isStdoutTTY {
        print("  \u{001B}[1;32m✓\u{001B}[0m \(message)")
    } else {
        print("=> \(message)")
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
