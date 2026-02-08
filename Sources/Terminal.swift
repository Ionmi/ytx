import Darwin
import Foundation
import Synchronization

enum Terminal {
    static let isStdinTTY  = isatty(STDIN_FILENO) != 0
    static let isStdoutTTY = isatty(STDOUT_FILENO) != 0
    static let isStderrTTY = isatty(STDERR_FILENO) != 0

    /// File descriptor used for UI output (spinners, progress, status).
    /// Defaults to stdout; set to STDERR_FILENO when stdout carries data (e.g. `-o -`).
    nonisolated(unsafe) static var uiFd: Int32 = STDOUT_FILENO

    /// Whether the UI file descriptor is a TTY.
    static var isUITTY: Bool { isatty(uiFd) != 0 }

    static var width: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }

    // MARK: - Raw Mode

    // These are `nonisolated(unsafe)` because they must be accessible from the
    // POSIX signal handler installed via `signal(SIGINT)`. Signal handlers run
    // on an arbitrary thread outside Swift's concurrency model, so using actors
    // or locks is not safe. We accept the race-condition trade-off here since
    // the signal handler only runs during process teardown.
    nonisolated(unsafe) private static var originalTermios = termios()
    nonisolated(unsafe) private static var rawModeActive = false
    nonisolated(unsafe) private static var cleanupPaths: [String] = []
    nonisolated(unsafe) private static var signalHandlerInstalled = false

    /// Register a file path to be deleted on Ctrl-C.
    static func registerCleanup(path: String) {
        cleanupPaths.append(path)
    }

    /// Remove a path from the cleanup list (e.g. after successful completion).
    static func unregisterCleanup(path: String) {
        cleanupPaths.removeAll { $0 == path }
    }

    static func enableRawMode() {
        guard isStdinTTY else { return }
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        rawModeActive = true
        installSignalHandler()
    }

    static func disableRawMode() {
        guard rawModeActive else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        rawModeActive = false
    }

    static func installSignalHandler() {
        guard !signalHandlerInstalled else { return }
        signalHandlerInstalled = true
        signal(SIGINT) { _ in
            Terminal.disableRawMode()
            for path in Terminal.cleanupPaths {
                unlink(path)
            }
            write(STDOUT_FILENO, "\u{1B}[?25h", 6)
            let msg = "\n\u{1B}[2m=> Interrupted, cleaned up partial files.\u{1B}[0m\n"
            write(STDERR_FILENO, msg, msg.utf8.count)
            _exit(130)
        }
    }

    // MARK: - Spinner

    final class Spinner: Sendable {
        private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        private let running = Mutex(true)
        private let finished = Mutex(false)
        private let message: String

        init(_ message: String) {
            self.message = message
        }

        func start() {
            let fd = Terminal.uiFd
            guard Terminal.isUITTY else {
                let line = "  \u{1B}[2m\(message)\u{1B}[0m\n"
                write(fd, line, line.utf8.count)
                finished.withLock { $0 = true }
                return
            }
            let t = Thread { [self] in
                var i = 0
                while running.withLock({ $0 }) {
                    let frame = frames[i % frames.count]
                    let line = "\r\u{1B}[K  \u{1B}[1;34m\(frame)\u{1B}[0m \u{1B}[2m\(message)\u{1B}[0m"
                    write(fd, line, line.utf8.count)
                    i += 1
                    Thread.sleep(forTimeInterval: 0.08)
                }
                finished.withLock { $0 = true }
            }
            t.start()
        }

        private func waitForThread() {
            while !finished.withLock({ $0 }) {
                usleep(5_000)
            }
        }

        func stop(_ result: String? = nil) {
            running.withLock { $0 = false }
            waitForThread()
            let fd = Terminal.uiFd
            guard Terminal.isUITTY else {
                if let result {
                    let line = "  \(result)\n"
                    write(fd, line, line.utf8.count)
                }
                return
            }
            if let result {
                let line = "\r\u{1B}[K  \u{1B}[1;32m✓\u{1B}[0m \(result)\n"
                write(fd, line, line.utf8.count)
            } else {
                let clear = "\r\u{1B}[K"
                write(fd, clear, clear.utf8.count)
            }
        }

        func fail(_ result: String) {
            running.withLock { $0 = false }
            waitForThread()
            let fd = Terminal.uiFd
            guard Terminal.isUITTY else {
                let line = "  \(result)\n"
                write(fd, line, line.utf8.count)
                return
            }
            let line = "\r\u{1B}[K  \u{1B}[1;33m⚠\u{1B}[0m \u{1B}[2m\(result)\u{1B}[0m\n"
            write(fd, line, line.utf8.count)
        }
    }

    // MARK: - Progress Bar

    /// Render a progress bar in-place (overwrites current line).
    /// The bar + label is truncated to fit the terminal width so it never wraps.
    static func renderProgress(percent: Int, barWidth: Int = 25, label: String = "") {
        let fd = uiFd
        guard isUITTY else { return }
        let pct = min(max(percent, 0), 100)
        let filled = Int(Double(pct) / 100.0 * Double(barWidth))
        let empty = barWidth - filled
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        let pctStr = String(format: "%3d%%", pct)

        // 2 (indent) + barWidth + 1 (space) + 4 (pct) = fixed portion
        let fixedWidth = 2 + barWidth + 1 + 4
        let termW = Terminal.width
        var line = "\r\u{1B}[K  \u{1B}[32m\(bar)\u{1B}[0m \(pctStr)"

        if !label.isEmpty {
            let maxLabel = termW - fixedWidth - 2  // 2 for "  " gap
            if maxLabel > 3 {
                let truncated = label.count > maxLabel
                    ? String(label.prefix(maxLabel - 1)) + "…"
                    : label
                line += "  \u{1B}[2m\(truncated)\u{1B}[0m"
            }
        }

        write(fd, line, line.utf8.count)
    }

    /// Finish the progress bar with a final message.
    static func finishProgress(_ message: String) {
        let fd = uiFd
        guard isUITTY else {
            let line = "  \(message)\n"
            write(fd, line, line.utf8.count)
            return
        }
        let line = "\r\u{1B}[K  \u{1B}[1;32m✓\u{1B}[0m \(message)\n"
        write(fd, line, line.utf8.count)
    }

    // MARK: - Key Reading

    enum Key {
        case up, down, enter
        case char(Character)
    }

    static func readKey() -> Key {
        var buf = [UInt8](repeating: 0, count: 3)
        let n = read(STDIN_FILENO, &buf, 3)
        guard n > 0 else { return .enter }

        if n == 1 {
            switch buf[0] {
            case 0x0A, 0x0D: return .enter
            case 0x03:
                disableRawMode()
                _exit(130)
            default:
                return .char(Character(UnicodeScalar(buf[0])))
            }
        }

        if n == 3, buf[0] == 0x1B, buf[1] == 0x5B {
            switch buf[2] {
            case 0x41: return .up
            case 0x42: return .down
            default: break
            }
        }

        return .char(Character(UnicodeScalar(buf[0])))
    }

    // MARK: - Pick Menu

    struct MenuItem {
        let label: String
        let description: String
    }

    /// Arrow-key navigable menu. Returns selected index.
    static func pick(title: String, items: [MenuItem]) -> Int? {
        guard isStdinTTY, isStdoutTTY else { return 0 }

        enableRawMode()
        defer { disableRawMode() }

        var selected = 0
        // Layout: title, blank, N items, blank, hint (no trailing \n)
        // Cursor always ends at end of hint line
        let moveUp = items.count + 3

        func render(firstTime: Bool) {
            var buf = ""
            if !firstTime {
                buf += "\u{1B}[\(moveUp)A\r"
            }
            buf += "  \u{1B}[1m\(title):\u{1B}[0m\n"
            buf += "\n"
            for (i, item) in items.enumerated() {
                let sel = i == selected
                let marker = sel ? ">" : " "
                let num = "\(i + 1)."
                let label = sel ? "\u{1B}[1;32m\(item.label)\u{1B}[0m" : item.label
                let desc = "\u{1B}[2m\(item.description)\u{1B}[0m"
                buf += "  \(marker) \(num) \(label)  \(desc)\u{1B}[K\n"
            }
            buf += "\n  \u{1B}[2m↑↓ Navigate  Enter Select  q Quit\u{1B}[0m\u{1B}[K"
            write(STDOUT_FILENO, buf, buf.utf8.count)
        }

        // Erase the blank + hint lines, leaving cursor right after items
        func cleanup() {
            let clear = "\u{1B}[1A\r\u{1B}[J"
            write(STDOUT_FILENO, clear, clear.utf8.count)
        }

        render(firstTime: true)

        while true {
            let key = readKey()
            switch key {
            case .up, .char("k"):
                selected = (selected - 1 + items.count) % items.count
                render(firstTime: false)
            case .down, .char("j"):
                selected = (selected + 1) % items.count
                render(firstTime: false)
            case .char("q"):
                cleanup()
                return nil
            case .char(let c) where c.isNumber:
                if let num = Int(String(c)), num >= 1, num <= items.count {
                    selected = num - 1
                    render(firstTime: false)
                    cleanup()
                    return selected
                }
            case .enter:
                cleanup()
                return selected
            default:
                break
            }
        }
    }

    // MARK: - ASCII Art Banner

    static func printBanner() {
        guard isUITTY else { return }
        let art = """
                _
          _   _| |___  __
         | | | | __\\ \\/ /
         | |_| | |_ >  <
          \\__, |\\__/_/\\_\\
          |___/
        """
        let blue = "\u{1B}[1;34m"
        let dim = "\u{1B}[2m"
        let reset = "\u{1B}[0m"
        let fd = uiFd
        let line = "\(blue)\(art)\(reset)\n  \(dim)YouTube downloader + transcriber\(reset)\n\n"
        write(fd, line, line.utf8.count)
    }
}
