import ArgumentParser
import Foundation

@main
struct Ytx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ytx",
        abstract: "Download and transcribe audio from YouTube (or any yt-dlp URL)."
    )

    @Argument(help: "YouTube or any yt-dlp supported URL.")
    var url: String

    @Option(name: .shortAndLong, help: "Speech recognition locale (default: en-US).")
    var locale: String = "en-US"

    @Option(name: .shortAndLong, help: "Output format: txt or srt (default: txt).")
    var format: String = "txt"

    @Option(name: .shortAndLong, help: "Directory to save output files (default: ./output).")
    var outputDir: String = "./output"

    mutating func run() async throws {
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
        printInfo("Downloading audio from: \(url)")
        let audioFile = try await Downloader.download(url: url, outputDir: outputDirURL)
        printInfo("Downloaded: \(audioFile.path)")

        // Transcribe
        let resolvedLocale = Locale(identifier: locale)
        printInfo("Transcribing with locale=\(resolvedLocale.identifier) ...")

        let options = TranscriptionEngine.Options(
            locale: resolvedLocale,
            outputFormat: outputFormat,
            maxLength: 40
        )
        let result = try await TranscriptionEngine.transcribe(file: audioFile, options: options)

        // Write output
        let basename = audioFile.deletingPathExtension().lastPathComponent
        let ext = outputFormat.rawValue
        let outputFile = outputDirURL.appendingPathComponent("\(basename).\(ext)")
        try result.write(to: outputFile, atomically: true, encoding: .utf8)

        // Summary
        printInfo("Transcription saved to: \(outputFile.path)")
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

// MARK: - Print Helpers

func printInfo(_ message: String) {
    print("\u{001B}[1;34m=>\u{001B}[0m \(message)")
}

func printError(_ message: String) {
    let stderr = FileHandle.standardError
    stderr.write(Data("\u{001B}[1;31mError:\u{001B}[0m \(message)\n".utf8))
}
