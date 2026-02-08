import Foundation

enum Downloader {
    /// Check if yt-dlp is available in PATH.
    static func isAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["yt-dlp"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Download the best audio from a URL using yt-dlp.
    /// Returns the file URL of the downloaded audio.
    static func download(url: String, outputDir: URL) async throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "yt-dlp",
            "--format", "bestaudio[ext=m4a]/bestaudio/best",
            "--output", "\(outputDir.path)/%(title)s.%(ext)s",
            "--print", "after_move:filepath",
            "--no-simulate",
            url,
        ]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // Let stderr pass through to terminal for download progress
        process.standardError = FileHandle.standardError

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = { proc in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard proc.terminationStatus == 0 else {
                    continuation.resume(throwing: DownloadError.processFailure(proc.terminationStatus))
                    return
                }

                // The last non-empty line is the file path
                let filePath = output.components(separatedBy: .newlines).last(where: { !$0.isEmpty }) ?? ""
                guard !filePath.isEmpty else {
                    continuation.resume(throwing: DownloadError.noOutputPath)
                    return
                }

                let fileURL = URL(fileURLWithPath: filePath)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    continuation.resume(throwing: DownloadError.fileNotFound(filePath))
                    return
                }

                continuation.resume(returning: fileURL)
            }
        }
    }
}

// MARK: - DownloadError

enum DownloadError: Error, LocalizedError {
    case processFailure(Int32)
    case noOutputPath
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .processFailure(status):
            "yt-dlp exited with status \(status)."
        case .noOutputPath:
            "yt-dlp did not return a file path."
        case let .fileNotFound(path):
            "Downloaded file not found: \(path)"
        }
    }
}
