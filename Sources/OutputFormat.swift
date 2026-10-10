import CoreMedia
import Foundation

enum OutputFormat: String {
    case txt
    case srt

    var needsAudioTimeRange: Bool {
        switch self {
        case .srt: true
        default: false
        }
    }

    func text(for transcript: AttributedString, maxLength: Int) -> String {
        switch self {
        case .txt:
            return String(transcript.characters)
        case .srt:
            let format = Self.timestamp
            return transcript.sentences(maxLength: maxLength).compactMap { (sentence: AttributedString) -> (CMTimeRange, String)? in
                guard let timeRange = sentence.audioTimeRange else { return nil }
                return (timeRange, String(sentence.characters))
            }.enumerated().map { index, run in
                let (timeRange, text) = run
                return """

                \(index + 1)
                \(format(timeRange.start.seconds)) --> \(format(timeRange.end.seconds))
                \(text.trimmingCharacters(in: .whitespacesAndNewlines))

                """
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Render caption cues downloaded from YouTube.
    /// ponytail: SRT keeps YouTube's own cue splits; --max-line-length not applied.
    func text(for captions: [Caption]) -> String {
        switch self {
        case .txt:
            return captions.map(\.text).joined(separator: " ")
        case .srt:
            return captions.enumerated().map { index, cue in
                "\(index + 1)\n\(Self.timestamp(cue.start)) --> \(Self.timestamp(cue.end))\n\(cue.text)\n"
            }.joined(separator: "\n")
        }
    }

    static func timestamp(_ timeInterval: TimeInterval) -> String {
        // Round once, then integer math: 1.001 s must not render as ",000"
        let total = Int((max(timeInterval, 0) * 1000).rounded())
        let ms = total % 1000
        let s = total / 1000 % 60
        let m = total / 60_000 % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
