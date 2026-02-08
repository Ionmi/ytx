import Foundation
import Synchronization

enum Downloader {
    /// Check if yt-dlp is available in PATH.
    static func isAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["yt-dlp"]
        process.standardInput = FileHandle.nullDevice
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

    /// Fetch the video's language metadata via yt-dlp (metadata-only, no download).
    /// Returns a 2-letter language code (e.g. "en", "es") or nil if unavailable.
    static func fetchLanguage(url: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["yt-dlp", "--print", "%(language)s", "--no-download", url]

        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read pipe BEFORE waitUntilExit to avoid deadlock if pipe buffer fills
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !output.isEmpty, output.lowercased() != "na", output != "none" else {
            return nil
        }

        return output
    }

    /// Download result containing audio path and optional video path.
    struct DownloadResult {
        let audioFile: URL
        let videoFile: URL?
    }

    /// Download audio (and optionally video) from a URL using yt-dlp.
    /// When `video` is true, downloads video+audio merged, then extracts audio for transcription.
    /// The `onProgress` callback receives raw stderr text for progress parsing.
    static func download(
        url: String,
        outputDir: URL,
        video: Bool = false,
        onProgress: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws -> [DownloadResult] {
        let format = video
            ? "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
            : "bestaudio[ext=m4a]/bestaudio/best"

        var args = [
            "yt-dlp",
            "--format", format,
            "--output", "\(outputDir.path)/%(title)s.%(ext)s",
            "--print", "after_move:filepath",
            "--no-simulate",
            "--newline",
            "--progress",
        ]
        if video {
            args += ["--merge-output-format", "mp4"]
        }
        args.append(url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Accumulate stdout (contains both --print paths and --progress lines)
        let stdoutAccum = Mutex(Data())
        let stdoutHandle = stdoutPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInteractive).async {
            while true {
                let data = stdoutHandle.availableData
                if data.isEmpty { break }
                stdoutAccum.withLock { $0.append(data) }
                if let text = String(data: data, encoding: .utf8) {
                    onProgress(text)
                }
            }
        }

        // Drain stderr to prevent pipe blocking
        let stderrHandle = stderrPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = stderrHandle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    onProgress(text)
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // waitUntilExit is reliable — no race unlike terminationHandler
                process.waitUntilExit()
                // Let pipe readers finish draining
                Thread.sleep(forTimeInterval: 0.15)

                let data = stdoutAccum.withLock { $0 }
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: DownloadError.processFailure(process.terminationStatus))
                    return
                }

                // Filter: only keep absolute paths (skip [download], [info], etc.)
                let filePaths = output.components(separatedBy: .newlines).filter { $0.hasPrefix("/") }
                guard !filePaths.isEmpty else {
                    continuation.resume(throwing: DownloadError.noOutputPath)
                    return
                }

                var results: [DownloadResult] = []
                for filePath in filePaths {
                    let fileURL = URL(fileURLWithPath: filePath)
                    guard FileManager.default.fileExists(atPath: fileURL.path) else {
                        continuation.resume(throwing: DownloadError.fileNotFound(filePath))
                        return
                    }

                    if video {
                        let audioURL = fileURL.deletingPathExtension().appendingPathExtension("m4a")
                        let extract = Process()
                        extract.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        extract.arguments = [
                            "ffmpeg", "-i", fileURL.path,
                            "-vn", "-acodec", "copy",
                            "-y", audioURL.path,
                        ]
                        extract.standardOutput = FileHandle.nullDevice
                        extract.standardError = FileHandle.nullDevice
                        do {
                            try extract.run()
                            extract.waitUntilExit()
                            guard extract.terminationStatus == 0 else {
                                continuation.resume(throwing: DownloadError.audioExtractFailed)
                                return
                            }
                        } catch {
                            continuation.resume(throwing: DownloadError.audioExtractFailed)
                            return
                        }
                        results.append(DownloadResult(audioFile: audioURL, videoFile: fileURL))
                    } else {
                        results.append(DownloadResult(audioFile: fileURL, videoFile: nil))
                    }
                }

                continuation.resume(returning: results)
            }
        }
    }
}

// MARK: - DownloadError

enum DownloadError: Error, LocalizedError {
    case processFailure(Int32)
    case noOutputPath
    case fileNotFound(String)
    case audioExtractFailed

    var errorDescription: String? {
        switch self {
        case let .processFailure(status):
            "yt-dlp exited with status \(status)."
        case .noOutputPath:
            "yt-dlp did not return a file path."
        case let .fileNotFound(path):
            "Downloaded file not found: \(path)"
        case .audioExtractFailed:
            "Failed to extract audio from video. Is ffmpeg installed?"
        }
    }
}
