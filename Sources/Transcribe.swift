import ArgumentParser
import Foundation

@main
struct Ytx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ytx",
        abstract: "Download and transcribe audio from YouTube (or any yt-dlp URL).",
        version: "0.2.0"
    )

    @Argument(help: "YouTube or any yt-dlp supported URL.")
    var url: String?

    @Option(name: .shortAndLong, help: "Speech recognition locale (default: en-US).")
    var locale: String = "en-US"

    @Option(name: .shortAndLong, help: "Output format: txt or srt (default: txt).")
    var format: String = "txt"

    @Option(name: .shortAndLong, help: "Directory to save output files (default: ./output).")
    var outputDir: String = "./output"

    @Flag(help: "Keep the downloaded audio file (deleted by default).")
    var keepAudio: Bool = false

    mutating func validate() throws {
        if url == nil && !Terminal.isStdinTTY {
            throw ValidationError("Missing expected argument '<url>'")
        }
    }

    mutating func run() async throws {
        let resolvedURL: String
        if let url {
            resolvedURL = url
        } else {
            resolvedURL = try interactiveFlow()
        }

        // Parse output format
        guard let outputFormat = OutputFormat(rawValue: format) else {
            throw ValidationError("Invalid format '\(format)'. Use 'txt' or 'srt'.")
        }

        // Validate yt-dlp is available
        printInfo("Checking for yt-dlp...")
        guard Downloader.isAvailable() else {
            printError("yt-dlp not found. Install with: brew install yt-dlp")
            throw ExitCode.failure
        }

        // Create output directory
        let outputDirURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)

        // Download audio
        printInfo("Downloading audio from: \(resolvedURL)")
        let audioFiles = try await Downloader.download(url: resolvedURL, outputDir: outputDirURL)
        printInfo("Downloaded \(audioFiles.count) file\(audioFiles.count == 1 ? "" : "s").")

        // Transcribe each file
        let resolvedLocale = Locale(identifier: locale)
        let options = TranscriptionEngine.Options(
            locale: resolvedLocale,
            outputFormat: outputFormat,
            maxLength: 40
        )

        for (index, audioFile) in audioFiles.enumerated() {
            if audioFiles.count > 1 {
                printInfo("[\(index + 1)/\(audioFiles.count)] \(audioFile.lastPathComponent)")
            }

            printInfo("Transcribing with locale=\(resolvedLocale.identifier) ...")
            let result = try await TranscriptionEngine.transcribe(file: audioFile, options: options)

            // Write output
            let basename = audioFile.deletingPathExtension().lastPathComponent
            let ext = outputFormat.rawValue
            let outputFile = outputDirURL.appendingPathComponent("\(basename).\(ext)")
            try result.write(to: outputFile, atomically: true, encoding: .utf8)

            printInfo("Transcription saved to: \(outputFile.path)")

            // Clean up audio file unless --keep-audio
            if !keepAudio {
                try FileManager.default.removeItem(at: audioFile)
            }

            // Preview
            print("")
            print("-- Preview (first 20 lines) --")
            let lines = result.components(separatedBy: .newlines)
            for line in lines.prefix(20) {
                print(line)
            }
            print("")
            print("------------------------------")
        }
    }

    // MARK: - Interactive Flow

    private mutating func interactiveFlow() throws -> String {
        // URL
        print("Enter URL: ", terminator: "")
        fflush(stdout)
        guard let input = readLine(), !input.isEmpty else {
            throw ValidationError("No URL provided.")
        }
        let url = input.trimmingCharacters(in: .whitespaces)

        // Format
        print("")
        print("Output format:")
        print("  1) txt")
        print("  2) srt")
        print("Choose [1]: ", terminator: "")
        fflush(stdout)
        if let choice = readLine(), !choice.isEmpty {
            switch choice.trimmingCharacters(in: .whitespaces) {
            case "2", "srt": format = "srt"
            default: format = "txt"
            }
        }

        // Locale
        let locales = [
            "en-US", "es-ES", "fr-FR", "de-DE",
            "pt-BR", "it-IT", "ja-JP", "zh-CN",
        ]
        print("")
        print("Locale:")
        for (i, loc) in locales.enumerated() {
            print("  \(i + 1)) \(loc)")
        }
        print("Choose or type locale [1]: ", terminator: "")
        fflush(stdout)
        if let choice = readLine(), !choice.isEmpty {
            let trimmed = choice.trimmingCharacters(in: .whitespaces)
            if let num = Int(trimmed), (1...locales.count).contains(num) {
                locale = locales[num - 1]
            } else if !trimmed.isEmpty {
                locale = trimmed
            }
        }

        // Keep audio
        print("")
        print("Keep audio file? [y/N]: ", terminator: "")
        fflush(stdout)
        if let choice = readLine() {
            keepAudio = choice.trimmingCharacters(in: .whitespaces).lowercased() == "y"
        }

        print("")
        return url
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

func printError(_ message: String) {
    let stderr = FileHandle.standardError
    if Terminal.isStderrTTY {
        stderr.write(Data("\u{001B}[1;31mError:\u{001B}[0m \(message)\n".utf8))
    } else {
        stderr.write(Data("Error: \(message)\n".utf8))
    }
}
